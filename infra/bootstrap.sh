#!/bin/bash
# Manual host bootstrap (optional — terraform apply now does all of this too).
# Installs Docker (enabled on boot), zRAM, and a swap file on the runner host.
set -e

HOST="${1:?usage: bootstrap.sh <host> <ssh-user>}"
USER="${2:?usage: bootstrap.sh <host> <ssh-user>}"
ZRAM_SIZE_MIB="${ZRAM_SIZE_MIB:-8192}"
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-16}"

echo "Bootstrapping Docker on $USER@$HOST..."
ssh "$USER@$HOST" "bash -s" <<REMOTE_SCRIPT
set -e

# --- Docker: install if missing, always start on boot ---
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  sudo apt-get -o DPkg::Lock::Timeout=600 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y ca-certificates curl gnupg < /dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get -o DPkg::Lock::Timeout=600 update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin < /dev/null
  sudo usermod -aG docker \$USER || true
fi
sudo systemctl enable --now docker

# --- zRAM: compressed swap in RAM, used first (highest priority) ---
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold install -y zram-tools < /dev/null
printf 'ALGO=zstd\nSIZE=%s\nPRIORITY=100\n' "$ZRAM_SIZE_MIB" > /tmp/zramswap.conf
if ! sudo cmp -s /tmp/zramswap.conf /etc/default/zramswap; then
  sudo cp /tmp/zramswap.conf /etc/default/zramswap
  sudo systemctl restart zramswap
fi
sudo systemctl enable --now zramswap

# --- Swap file: lower priority, absorbs spikes beyond zRAM ---
if [ ! -f /swapfile ] || [ "\$(sudo blkid -o value -s TYPE /swapfile 2>/dev/null || true)" != "swap" ]; then
  sudo swapoff /swapfile 2>/dev/null || true
  sudo fallocate -l ${SWAP_SIZE_GIB}G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
fi
sudo swapon --show=NAME --noheadings | grep -qx /swapfile || sudo swapon -p 10 /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab > /dev/null
echo 'vm.swappiness=100' | sudo tee /etc/sysctl.d/99-github-runners.conf > /dev/null
sudo sysctl -q -p /etc/sysctl.d/99-github-runners.conf
REMOTE_SCRIPT

echo "Done! You can now run terraform."
