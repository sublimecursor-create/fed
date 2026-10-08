#!/usr/bin/env bash
# Fedora the Arch way installer. Functions are added per task, then arranged later.
set -euo pipefail

MNT=/mnt
DISK=
EFI_PART=
LINUX_PART=
LUKS_NAME=system
VG_NAME=fedora

configure_dnf() {
  local conf=/etc/dnf/dnf.conf
  mkdir -p /etc/dnf
  if [[ ! -f "$conf" ]] || ! grep -q '^\[main\]' "$conf"; then
    printf '%s\n' '[main]' > "$conf"
  fi
  set_dnf_opt() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$conf"; then
      sed -i "s/^${key}=.*/${key}=${val}/" "$conf"
    else
      sed -i "/^\[main\]/a ${key}=${val}" "$conf"
    fi
  }
  set_dnf_opt max_parallel_downloads 10
  set_dnf_opt fastestmirror True
  dnf install -y arch-install-scripts gdisk
}

partition_disk() {
  echo
  lsblk -dpno NAME,SIZE,MODEL
  echo
  read -r -p "Target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
  read -r -p "EFI partition size (e.g. 512MiB): " efi_size
  read -r -p "Root partition size (e.g. 50GiB, or 100% for the rest of the disk): " root_size

  echo
  echo "This will wipe ${DISK}: EFI=${efi_size}, Linux=${root_size}"
  read -r -p "Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }

  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk --clear "$DISK"
  sgdisk -n "1:0:+${efi_size}" -t 1:ef00 -c 1:EFI "$DISK"
  if [[ "$root_size" == "100%" ]]; then
    sgdisk -n 2:0:0 -t 2:8309 -c 2:Linux "$DISK"
  else
    sgdisk -n "2:0:+${root_size}" -t 2:8309 -c 2:Linux "$DISK"
  fi
  partprobe "$DISK"
  udevadm settle
  if [[ "$DISK" =~ (nvme|mmcblk|loop|nbd) ]]; then
    EFI_PART="${DISK}p1"
    LINUX_PART="${DISK}p2"
  else
    EFI_PART="${DISK}1"
    LINUX_PART="${DISK}2"
  fi
}

encrypt_linux() {
  command -v cryptsetup >/dev/null || dnf install -y cryptsetup

  cryptsetup luksFormat \
    --type luks2 \
    --key-size 512 \
    --hash sha512 \
    --use-urandom \
    --label OS \
    --force-password \
    "$LINUX_PART"

  cryptsetup open \
    --persistent \
    --allow-discards \
    --perf-no_read_workqueue \
    --perf-no_write_workqueue \
    "$LINUX_PART" \
    "$LUKS_NAME"
}

setup_lvm() {
  command -v pvcreate >/dev/null || dnf install -y lvm2
  pvcreate "/dev/mapper/${LUKS_NAME}"
  vgcreate "$VG_NAME" "/dev/mapper/${LUKS_NAME}"

  echo
  read -r -p "root LV size (e.g. 40G, or 100% for remaining): " lv_root_size
  read -r -p "swap LV size (e.g. 8G, or 100% for remaining): " lv_swap_size
  read -r -p "home LV size (e.g. 100G, or 100% for remaining): " lv_home_size

  create_lv() {
    local name="$1" size="$2"
    if [[ "$size" == "100%" || "$size" == "100%FREE" ]]; then
      lvcreate -y -l 100%FREE -n "$name" "$VG_NAME"
    else
      lvcreate -y -L "$size" -n "$name" "$VG_NAME"
    fi
  }

  create_lv root "$lv_root_size"
  create_lv swap "$lv_swap_size"
  create_lv home "$lv_home_size"
}

format_filesystems() {
  command -v mkfs.vfat >/dev/null || dnf install -y dosfstools e2fsprogs
  mkfs.vfat -F 32 -n BOOT "$EFI_PART"
  mkfs.ext4 -L Root "/dev/${VG_NAME}/root"
  mkfs.ext4 -L Home "/dev/${VG_NAME}/home"
  mkswap -L Swap "/dev/${VG_NAME}/swap"
}

mount_filesystems() {
  mount "/dev/${VG_NAME}/root" "$MNT"
  mkdir -p "$MNT/home" "$MNT/boot/efi"
  mount "/dev/${VG_NAME}/home" "$MNT/home"
  mount -o umask=0077 "$EFI_PART" "$MNT/boot/efi"
  swapon "/dev/${VG_NAME}/swap"
}

mount_api_filesystems() {
  mkdir -p "$MNT"/{dev,proc,sys}
  mount --rbind /dev "$MNT/dev"
  mount --make-rslave "$MNT/dev"
  mount --rbind /proc "$MNT/proc"
  mount --make-rslave "$MNT/proc"
}

write_cmdline_and_crypttab() {
  local luks_uuid
  luks_uuid=$(blkid -s UUID -o value "$LINUX_PART")

  # /etc/kernel/cmdline — consumed by dracut / systemd-ukify when building UKIs
  mkdir -p "$MNT/etc/kernel"
  printf 'rd.luks.uuid=%s rd.lvm.lv=%s/root rd.lvm.lv=%s/swap root=/dev/mapper/%s-root rootfstype=ext4 rootflags=ro,relatime\n' \
    "$luks_uuid" "$VG_NAME" "$VG_NAME" "$VG_NAME" > "$MNT/etc/kernel/cmdline"

  # /etc/kernel/install.conf — kernel-install configuration for UKI generation
  cat <<'EOF' > "$MNT/etc/kernel/install.conf"
layout=uki
initrd_generator=dracut
uki_generator=ukify
BOOT_ROOT=/boot/efi
EOF

  # /etc/crypttab — tells systemd-cryptsetup to unlock at boot
  # Format: <name>  <device>            <keyfile>  <options>
  mkdir -p "$MNT/etc"
  printf '%s  UUID=%s  none  luks,x-initrd.attach\n' \
    "$LUKS_NAME" "$luks_uuid" > "$MNT/etc/crypttab"

  echo "[+] Wrote kernel cmdline       -> $MNT/etc/kernel/cmdline"
  echo "[+] Wrote kernel install.conf  -> $MNT/etc/kernel/install.conf"
  echo "[+] Wrote crypttab             -> $MNT/etc/crypttab"
}

bootstrap() {
  dnf --installroot="$MNT" \
    --use-host-config \
    --releasever=44 \
    --setopt=install_weak_deps=False \
    -y \
    install \
      audit \
      bash \
      coreutils \
      dnf5 \
      dnf5-plugins \
      filesystem \
      glibc \
      hostname \
      iproute \
      iputils \
      kbd \
      less \
      man-db \
      ncurses \
      openssh-clients \
      parted \
      policycoreutils \
      procps-ng \
      rootfiles \
      rpm \
      selinux-policy-targeted \
      setup \
      shadow-utils \
      sssd-common \
      sssd-kcm \
      sudo \
      systemd \
      util-linux \
      firewalld \
      fwupd \
      NetworkManager \
      prefixdevname \
      systemd-pam \
      dracut \
      lvm2 \
      cryptsetup \
      systemd-boot \
      zstd \
      systemd-ukify \
      neovim \
      zsh \
      binutils \
      tar \
      \
      curl \
      fastfetch \
      fd-find \
      fzf \
      git \
      htop \
      ripgrep \
      rsync \
      ShellCheck \
      tmux \
      unzip \
      wget \
      zoxide \
      \
      e2fsprogs \
      gdisk \
      hdparm \
      nvme-cli \
      xfsprogs \
      \
      clang \
      golang \
      python3 \
      tree-sitter-cli \
      zig \
      \
      rofi \
      SwayNotificationCenter \
      brightnessctl \
      wl-clipboard \
      waybar \
      \
      foot \
      \
      kvantum \
      qt6ct \
      xdg-user-dirs \
      xdg-user-dirs-gtk \
      nm-connection-editor \
      qimgv \
      \
      nemo \
      nemo-fileroller \
      nemo-extensions \
      \
      mpv \
      \
      acpica-tools \
      android-tools \
      efibootmgr \
      egl-wayland \
      libxcrypt \
      pipewire \
      wireplumber 
      # NOTE: pantheon.switchboard-plug-network is an Elementary OS / NixOS-only package;
      # there is no equivalent in Fedora repositories. Skip it.
}

configure_chroot() {
  local here
  here="$(dirname "$0")"
  genfstab -U "$MNT" > "$MNT/etc/fstab"
  cp "$here/nvidia.sh" "$MNT/nvidia.sh" 2>/dev/null || true
  cp "$here/setup.sh" "$MNT/setup.sh"
  chmod +x "$MNT/nvidia.sh" "$MNT/setup.sh" 2>/dev/null || true
  arch-chroot "$MNT" /setup.sh
}
main() {
  configure_dnf
  partition_disk
  encrypt_linux
  setup_lvm
  format_filesystems
  mount_filesystems
  mount_api_filesystems
  bootstrap
  write_cmdline_and_crypttab
  configure_chroot
}

main "$@"
