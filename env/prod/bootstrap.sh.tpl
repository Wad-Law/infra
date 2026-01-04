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
POLY_API_KEY="${poly_api_key}"
POLY_API_SECRET="${poly_api_secret}"
POLY_API_PASSPHRASE="${poly_api_passphrase}"

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
POLY_API_KEY=$${POLY_API_KEY}
POLY_API_SECRET=$${POLY_API_SECRET}
POLY_API_PASSPHRASE=$${POLY_API_PASSPHRASE}
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

echo "[BOOTSTRAP] Completed successfully."