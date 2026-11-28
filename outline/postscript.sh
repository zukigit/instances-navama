#!/bin/bash
# Installs Docker and Outline server. Run by Terraform (provision.tf) over SSH;
# all output is streamed to `terraform apply`.
#
# Usage: postscript.sh <api_port> <keys_port> <installer_commit> <installer_sha256>
set -euo pipefail

API_PORT="${1:-8443}"
KEYS_PORT="${2:-9443}"
INSTALLER_COMMIT="${3:?installer commit required}"
INSTALLER_SHA256="${4:?installer sha256 required}"

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
# The installer is pinned to a commit and checked against its SHA-256, so a
# change upstream can't run as root here. (The server image itself is still
# kept up to date by the installer's watchtower.)
# Download into a private folder (not shared /tmp), since it runs as root.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "https://raw.githubusercontent.com/Jigsaw-Code/outline-server/${INSTALLER_COMMIT}/src/server_manager/install_scripts/install_server.sh" \
  -o "$WORK/install_server.sh"
echo "${INSTALLER_SHA256}  $WORK/install_server.sh" | sha256sum -c -
# Fixed ports so they match the firewall rule (TCP api port, TCP+UDP keys port).
sudo bash "$WORK/install_server.sh" --api-port="${API_PORT}" --keys-port="${KEYS_PORT}"

echo
echo "===== Outline Manager config (/opt/outline/access.txt) ====="
sudo cat /opt/outline/access.txt
