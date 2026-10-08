#!/usr/bin/env bash
# RPM Fusion NVIDIA drivers (akmod). Run inside the installed system after the kernel is present.
set -euo pipefail

echo "==> Enabling RPM Fusion free and nonfree..."
dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

echo "==> Installing NVIDIA driver..."
dnf install -y akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda

echo "==> NVIDIA packages installed. Reboot after akmods finishes building the module."
