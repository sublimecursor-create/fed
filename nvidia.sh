#!/usr/bin/env bash
# Install NVIDIA open kernel module drivers and related compute/graphics libraries on Fedora
set -euo pipefail

echo "==> Enabling RPM Fusion free and nonfree repositories..."
dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# akmod-nvidia-open is located in rpmfusion-nonfree-tainted
echo "==> Enabling RPM Fusion nonfree tainted repository..."
dnf config-manager setopt rpmfusion-nonfree-tainted.enabled=1

echo "==> Installing NVIDIA Open kernel modules and user-space libraries..."
dnf install \
  kernel-devel \
  kernel-headers \
  akmod-nvidia-open \
  xorg-x11-drv-nvidia \
  xorg-x11-drv-nvidia-libs \
  xorg-x11-drv-nvidia-cuda \
  xorg-x11-drv-nvidia-cuda-libs \
  xorg-x11-drv-nvidia-power \
  libglvnd \
  libglvnd-egl \
  libglvnd-gles \
  libglvnd-glx \
  libglvnd-opengl \
  opencl-filesystem \
  ocl-icd \
  clinfo

echo "==> Ensuring nouveau is blacklisted..."
mkdir -p /etc/modprobe.d
cat <<'EOF' > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

# Append nouveau blacklist to kernel cmdline if /etc/kernel/cmdline exists
#if [[ -f /etc/kernel/cmdline ]] && ! grep -q "rd.driver.blacklist=nouveau" /etc/kernel/cmdline; then
#  sed -i 's/$/ rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1/' /etc/kernel/cmdline
#fi

echo "==> Triggering akmods kernel module build..."
akmods --force || true

#echo "==> Enabling NVIDIA power management services..."
#systemctl enable nvidia-hibernate.service nvidia-suspend.service nvidia-resume.service nvidia-powerd.service || true

echo "==> NVIDIA open driver installation complete."
