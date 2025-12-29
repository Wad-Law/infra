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
echo "[BOOTSTRAP] Downloading config from S3://${S3_BUCKET}..."

aws s3 cp "s3://${S3_BUCKET}/prometheus.yml" prometheus.yml

# --- Grafana Provisioning ---
mkdir -p grafana/datasources grafana/dashboards

aws s3 cp "s3://${S3_BUCKET}/datasource.yml" grafana/datasources/datasource.yml
aws s3 cp "s3://${S3_BUCKET}/dashboard.yml" grafana/dashboards/dashboard.yml
aws s3 cp "s3://${S3_BUCKET}/polymind_main.json" grafana/dashboards/polymind_main.json

aws s3 cp "s3://${S3_BUCKET}/filebeat.yml" filebeat.yml
aws s3 cp "s3://${S3_BUCKET}/docker-compose.observability.yml" docker-compose.observability.yml

echo "[BOOTSTRAP] Launching observability stack..."
docker-compose -f docker-compose.observability.yml up -d

# --- Initial deploy ---
echo "[BOOTSTRAP] Running initial deploy..."
/opt/stack/deploy.sh

echo "[BOOTSTRAP] Completed successfully."