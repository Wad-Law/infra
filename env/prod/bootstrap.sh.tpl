#!/bin/bash
set -euo pipefail

# --- Variables from Terraform ---
AWS_REGION="${region}"
ACCOUNT_ID="${account_id}"

echo "[BOOTSTRAP] Starting setup for ${ACCOUNT_ID} in ${AWS_REGION}"

# --- Basic setup ---
apt-get update -y
apt-get install -y ca-certificates curl unzip jq gnupg lsb-release

# --- Install Docker ---
echo "[BOOTSTRAP] Installing Docker..."
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# --- Install AWS CLI v2 ---
echo "[BOOTSTRAP] Installing AWS CLI..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# --- Setup stack directory ---
mkdir -p /opt/stack
cd /opt/stack

# --- Write .env file ---
cat > .env <<EOF
ENVIRONMENT=PROD
ACCOUNT_ID=${ACCOUNT_ID}
AWS_REGION=${AWS_REGION}
EOF
chmod 600 .env

# --- Write docker-compose.yml and deploy.sh ---
# heredoc in quotes because we don't want variables to expand
cat > docker-compose.yml <<'COMPOSE'
${file("${path.module}/files/docker-compose.yml")}
COMPOSE

cat > deploy.sh <<'DEPLOY'
${file("${path.module}/files/deploy.sh")}
DEPLOY
chmod +x deploy.sh

# --- Initial deploy ---
echo "[BOOTSTRAP] Running initial deploy..."
/opt/stack/deploy.sh

echo "[BOOTSTRAP] Completed successfully."