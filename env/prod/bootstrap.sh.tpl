#!/bin/bash
set -euo pipefail

# Force Refresh: Updated to t3.small
# --- Variables from Terraform ---
AWS_REGION="${region}"
ACCOUNT_ID="${account_id}"
DB_ENDPOINT="${db_endpoint}"
DB_USERNAME="${db_username}"
DB_PASSWORD="${db_password}"
LLM_API_KEY="${llm_api_key}"
POLY_PROXY_ADDRESS="${poly_proxy_address}"
POLY_PRIVATE_KEY="${poly_private_key}"

echo "[BOOTSTRAP] Starting setup for $${ACCOUNT_ID} in $${AWS_REGION}"

# AL2023 uses dnf
dnf update -y
dnf install -y docker
# --- System Configuration ---
# Fix for Elasticsearch "max virtual memory areas vm.max_map_count [65530] is too low"
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/elasticsearch.conf

# Add 2GB Swap for t3.small/medium buffer
dd if=/dev/zero of=/swapfile bs=128M count=16
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile swap swap defaults 0 0" >> /etc/fstab

# --- Docker Setup ---
systemctl enable --now docker

sudo curl -L https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Optional: ensure AWS CLI v2 present (usually preinstalled)
if ! command -v aws >/dev/null 2>&1; then
  curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
  unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip
fi

# --- Setup stack directory ---
mkdir -p /opt/stack
cd /opt/stack

# --- Write .env file ---
cat > .env <<EOF
ENVIRONMENT=PROD
ACCOUNT_ID=$${ACCOUNT_ID}
AWS_REGION=$${AWS_REGION}
DATABASE_URL=postgres://$${DB_USERNAME}:$${DB_PASSWORD}@$${DB_ENDPOINT}/polymind
LLM_API_KEY=$${LLM_API_KEY}
POLY_PROXY_ADDRESS=$${POLY_PROXY_ADDRESS}
POLY_PRIVATE_KEY=$${POLY_PRIVATE_KEY}
EOF
chmod 600 .env

# --- Write docker-compose.yml and deploy.sh ---
# heredoc in quotes because we don't want variables to expand
cat > docker-compose.yml <<'COMPOSE'
${compose_content}
COMPOSE

cat > deploy.sh <<'DEPLOY'
${deploy_content}
DEPLOY
chmod +x deploy.sh

# --- Connectivity ---
docker network create polymind_net || true

S3_BUCKET="${s3_bucket_id}"

# --- Observability Stack (S3 Download) ---
echo "[BOOTSTRAP] Downloading config from S3://$${S3_BUCKET}..."

aws s3 cp "s3://$${S3_BUCKET}/prometheus.yml" prometheus.yml

# --- Grafana Provisioning ---
mkdir -p grafana/datasources grafana/dashboards

aws s3 cp "s3://$${S3_BUCKET}/datasource.yml" grafana/datasources/datasource.yml
aws s3 cp "s3://$${S3_BUCKET}/dashboard.yml" grafana/dashboards/dashboard.yml
aws s3 cp "s3://$${S3_BUCKET}/polymind_main.json" grafana/dashboards/polymind_main.json

aws s3 cp "s3://$${S3_BUCKET}/filebeat.yml" filebeat.yml
aws s3 cp "s3://$${S3_BUCKET}/docker-compose.observability.yml" docker-compose.observability.yml


aws s3 cp "s3://$${S3_BUCKET}/export.ndjson" export.ndjson

echo "[BOOTSTRAP] Launching observability stack..."
docker-compose -f docker-compose.observability.yml up -d

# --- Initial deploy (App Critical Path) ---
echo "[BOOTSTRAP] Running initial deploy..."
/opt/stack/deploy.sh

# --- Create Provisioning Script ---
cat > provision_kibana.sh <<'EOF'
#!/bin/bash
echo "[PROVISION] Waiting for Kibana to be ready..."
retries=0
max_retries=120
# Sleep initial 20s to allow process start
sleep 20

until curl -s --max-time 10 http://localhost:5601/api/status | grep -q '"level":"available"'; do
  if [ $retries -ge $max_retries ]; then
    echo "[PROVISION] Timeout waiting for Kibana. Last status:"
    curl -s --max-time 5 http://localhost:5601/api/status || echo "Unreachable"
    echo "[PROVISION] Skipping provisioning."
    exit 1
  fi
  echo "  Waiting for Kibana... ($retries/$max_retries)"
  sleep 5
  retries=$((retries+1))
done

echo "[PROVISION] Importing Kibana Saved Objects..."
# Sleep to ensure API is fully accepting writes
sleep 10
curl -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  --form file=@export.ndjson
echo "[PROVISION] Provisioning complete."
EOF
chmod +x provision_kibana.sh

# --- Execute Provisioning in Background ---
echo "[BOOTSTRAP] Launching Kibana provisioning in background..."
nohup ./provision_kibana.sh > provision.log 2>&1 &

# --- WireGuard Egress Tunnel Setup ---
echo "[BOOTSTRAP] Setting up WireGuard Egress Tunnel..."
bn_name_prefix="wad-law" # Hardcoded matching terraform name_prefix default

# Install WireGuard
dnf install -y wireguard-tools iptables-services

# Enable IP Forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Helper functions
get_ssm() {
    aws ssm get-parameter --region ${AWS_REGION} --name "$1" --query "Parameter.Value" --output text
}
put_ssm() {
    aws ssm put-parameter --region ${AWS_REGION} --name "$1" --value "$2" --type String --overwrite
}

# Generate Local Keys
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)

# Publish my key for Sweden to see
put_ssm "/${bn_name_prefix}/paris/public_key" "$PUBLIC_KEY"

# Wait for Sweden endpoint
echo "Waiting for Sweden Exit Node..."
SWEDEN_ENDPOINT=""
SWEDEN_PUB_KEY=""
MAX_RETRIES=30
count=0

while [ $count -lt $MAX_RETRIES ]; do
    SWEDEN_ENDPOINT=$(get_ssm "/${bn_name_prefix}/sweden/endpoint" || echo "NONE")
    SWEDEN_PUB_KEY=$(get_ssm "/${bn_name_prefix}/sweden/public_key" || echo "NONE")

    if [ "$SWEDEN_ENDPOINT" != "NONE" ] && [ "$SWEDEN_PUB_KEY" != "NONE" ]; then
        break
    fi
    echo "Waiting for Sweden... ($count/$MAX_RETRIES)"
    sleep 10
    count=$((count + 1))
done

if [ "$SWEDEN_ENDPOINT" != "NONE" ] && [ "$SWEDEN_PUB_KEY" != "NONE" ]; then
    echo "Found Sweden Exit Node: $SWEDEN_ENDPOINT"

    # Configure wg0
    # Routing: By using AllowedIPs=0.0.0.0/0, wg-quick handles default route override
    # It adds two /1 routes to override the default /0 route without deleting it.
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.99.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SWEDEN_PUB_KEY
Endpoint = $SWEDEN_ENDPOINT:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

    # Start WireGuard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    echo "WireGuard Tunnel Activated."
else
    echo "ERROR: Timed out waiting for Sweden Exit Node. Egress tunnel NOT active."
fi

echo "[BOOTSTRAP] Completed successfully."