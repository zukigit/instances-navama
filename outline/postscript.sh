#!/bin/bash
# Installs Docker and Outline server. Run by Terraform (provision.tf) over SSH;
# all output is streamed to `terraform apply`.
#
# Usage: postscript.sh <api_port> <keys_port>
set -euo pipefail

API_PORT="${1:-8443}"
KEYS_PORT="${2:-9443}"

# No interactive prompts from apt.
export DEBIAN_FRONTEND=noninteractive

# Add Docker's official GPG key:
sudo -E apt-get update
sudo -E apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# install docker
sudo -E apt-get update
sudo -E apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable docker
sudo systemctl restart docker

# install outline server
# Download first so a failed download stops the script instead of running nothing.
curl -fsSL https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh \
  -o /tmp/install_server.sh
# Fixed ports so they match the firewall rule (TCP api port, TCP+UDP keys port).
sudo bash /tmp/install_server.sh --api-port="${API_PORT}" --keys-port="${KEYS_PORT}"

echo
echo "===== Outline Manager config (/opt/outline/access.txt) ====="
sudo cat /opt/outline/access.txt
