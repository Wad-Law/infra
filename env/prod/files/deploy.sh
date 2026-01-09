#!/bin/bash
set -euo pipefail
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].RegionName" --output text)
export ACCOUNT_ID AWS_REGION

# Ensure we run in the directory containing `docker-compose.yml`
cd "$(dirname "$0")"

aws ecr get-login-password --region "$AWS_REGION" \
| docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"


if [ $# -eq 1 ]; then
  docker-compose pull "$1"
  docker-compose up -d "$1"
else
  docker-compose pull
  docker-compose up -d
fi

docker image prune -f
