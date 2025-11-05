#!/bin/bash
set -euo pipefail

# --- Variables from Terraform ---
AWS_REGION="${region}"
ACCOUNT_ID="${account_id}"

echo "[BOOTSTRAP] Starting setup for $${ACCOUNT_ID} in $${AWS_REGION}"

# AL2023 uses dnf
dnf update -y
dnf install -y docker
systemctl enable --now docker

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

# --- Initial deploy ---
echo "[BOOTSTRAP] Running initial deploy..."
/opt/stack/deploy.sh

echo "[BOOTSTRAP] Completed successfully."