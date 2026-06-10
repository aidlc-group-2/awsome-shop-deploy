#!/bin/bash
set -euxo pipefail

# --- System update ---
dnf update -y

# --- Docker ---
dnf install -y docker git
systemctl enable --now docker

# Allow ec2-user and ssm-user to run docker without sudo
usermod -aG docker ec2-user || true
id ssm-user >/dev/null 2>&1 && usermod -aG docker ssm-user || true

# --- Docker Compose v2 (CLI plugin) ---
DOCKER_CONFIG=/usr/local/lib/docker
mkdir -p "$DOCKER_CONFIG/cli-plugins"
ARCH="$(uname -m)"
COMPOSE_VERSION="v2.39.4"
curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
  -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

# Make compose plugin available to all users
mkdir -p /usr/libexec/docker/cli-plugins
ln -sf "$DOCKER_CONFIG/cli-plugins/docker-compose" /usr/libexec/docker/cli-plugins/docker-compose

# --- Shared working directory for the team ---
mkdir -p /opt/awsomeshop
chgrp docker /opt/awsomeshop
chmod 2775 /opt/awsomeshop

# --- Verify ---
docker --version
docker compose version
echo "AWSomeShop staging bootstrap complete" > /var/log/awsomeshop-bootstrap.done
