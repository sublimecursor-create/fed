#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing kernel and firmware..."
dnf install -y \
  kernel \
  intel-audio-firmware \
  intel-gpu-firmware \
  alsa-sof-firmware

echo "==> Installing systemd-boot (no EFI variables)..."
bootctl install --variables=no

echo "==> Creating user..."
read -r -p "Full name (-c): " full_name
read -r -p "Login shell (-s): " shell
read -r -p "Groups (-G, comma-separated): " groups
read -r -p "Username: " username

useradd -m -G "$groups" -c "$full_name" -s "$shell" "$username"
echo "[+] Created user ${username}"

echo "==> exiting chroot..."
exit 0
exit
