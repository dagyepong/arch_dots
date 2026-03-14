#!/bin/bash

#
# ArchLinux Hardened installation script – XFS/LVM version
# Supports both UEFI and BIOS systems.
# Handles mirrorlist failures gracefully.
#
# This version includes embedded package lists – no external files needed.
#

set -euo pipefail
cd "$(dirname "$0")"
trap on_error ERR

# Redirect outputs to /tmp to avoid filling the USB stick
exec 1> >(tee /tmp/stdout.log)
exec 2> >(tee /tmp/stderr.log >&2)

# Dialog
BACKTITLE="ArchLinux Hardened Installation"

on_error() {
  ret=$?
  echo "[$0] Error on line $LINENO: $BASH_COMMAND"
  exit $ret
}

get_input() {
  title="$1"
  description="$2"

  input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
  echo "$input"
}

get_password() {
  title="$1"
  description="$2"

  init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
  test -z "$init_pass" && echo >&2 "password cannot be empty" && exit 1

  test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
  if [[ "$init_pass" != "$test_pass" ]]; then
    echo "Passwords did not match" >&2
    exit 1
  fi
  echo "$init_pass"
}

get_choice() {
  title="$1"
  description="$2"
  shift 2
  options=("$@")
  dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

# Detect boot mode
if [ -d /sys/firmware/efi ]; then
  UEFI=true
  echo "UEFI mode detected."
else
  UEFI=false
  echo "BIOS/Legacy mode detected."
fi

# Unmount previously mounted devices in case the install script is run multiple times
swapoff -a || true
umount -R /mnt 2>/dev/null || true
cryptsetup luksClose archlinux 2>/dev/null || true

# Basic settings
timedatectl set-ntp true
hwclock --systohc --utc

# Keyring from ISO might be outdated, upgrading it just in case
pacman -Sy --noconfirm --needed archlinux-keyring

# Make sure some basic tools that will be used in this script are installed
# Added lvm2 for the live environment
pacman -Sy --noconfirm --needed git reflector terminus-font dialog wget lvm2

# Adjust the font size in case the screen is hard to read
noyes=("Yes" "The font is too small" "No" "The font size is just fine")
hidpi=$(get_choice "Font size" "Is your screen HiDPI?" "${noyes[@]}") || exit 1
clear
[[ "$hidpi" == "Yes" ]] && font="ter-132n" || font="ter-716n"
setfont "$font"

# Setup CPU/GPU target
cpu_list=("Intel" "" "AMD" "")
cpu_target=$(get_choice "Installation" "Select the targetted CPU vendor" "${cpu_list[@]}") || exit 1
clear

noyes=("Yes" "" "No" "")
install_igpu_drivers=$(get_choice "Installation" "Does your CPU have integrated graphics ?" "${noyes[@]}") || exit 1
clear

gpu_list=("Nvidia" "" "AMD" "" "None" "I don't have any GPU")
gpu_target=$(get_choice "Installation" "Select the targetted GPU vendor" "${gpu_list[@]}") || exit 1
clear

# Ask which device to install ArchLinux on
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
read -r -a devicelist <<<"$devicelist"
device=$(get_choice "Installation" "Select installation disk" "${devicelist[@]}") || exit 1
clear

noyes=("Yes" "I want to remove everything on $device" "No" "GOD NO !! ABORT MISSION")
lets_go=$(get_choice "Are you absolutely sure ?" "YOU ARE ABOUT TO ERASE EVERYTHING ON $device" "${noyes[@]}") || exit 1
clear
[[ "$lets_go" == "No" ]] && exit 1

hostname=$(get_input "Hostname" "Enter hostname") || exit 1
clear
test -z "$hostname" && echo >&2 "hostname cannot be empty" && exit 1

user=$(get_input "User" "Enter username") || exit 1
clear
test -z "$user" && echo >&2 "user cannot be empty" && exit 1

user_password=$(get_password "User" "Enter password") || exit 1
clear
test -z "$user_password" && echo >&2 "user password cannot be empty" && exit 1

luks_password=$(get_password "LUKS" "Enter password") || exit 1
clear
test -z "$luks_password" && echo >&2 "LUKS password cannot be empty" && exit 1

# ==================== MIRRORLIST SETUP (robust) ====================
# Add a set of very reliable fallback mirrors FIRST
cat > /etc/pacman.d/mirrorlist << EOF
## Fallback mirrors - added on $(date)
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirror.leaseweb.net/archlinux/\$repo/os/\$arch
EOF

# Attempt to update with reflector, but do not exit on failure
echo "Attempting to optimize mirrorlist with reflector (this may fail)..."
if reflector --country France,Germany --latest 30 --sort rate --append /etc/pacman.d/mirrorlist 2>/dev/null; then
    echo "Mirrorlist updated successfully with reflector."
else
    echo "Reflector failed. Continuing with fallback mirrors."
fi
clear
# ====================================================================

# OPTIONAL: If you are using an SSD, you can quickly discard all blocks (instant secure wipe).
# Uncomment the next line if you want to securely wipe the disk (SSD only).
# blkdiscard "$device" 2>/dev/null || echo "blkdiscard failed or not an SSD, skipping."

# Setting up partitions
lsblk -plnx size -o name "${device}" | xargs -n1 wipefs --all

if [ "$UEFI" = true ]; then
  # UEFI: GPT with root (minus 551MiB) and EFI partition
  sgdisk --clear "${device}" --new 1::-551MiB "${device}" --new 2::0 --typecode 2:ef00 "${device}"
  sgdisk --change-name=1:primary --change-name=2:ESP "${device}"
else
  # BIOS: GPT with BIOS boot partition (2MiB) and root partition
  sgdisk --clear "${device}" --new 1::+2MiB "${device}" --new 2::0 --typecode 1:ef02 --typecode 2:8300 "${device}"
  sgdisk --change-name=1:BIOS-boot --change-name=2:root "${device}"
fi

# Identify partition names
if [ "$UEFI" = true ]; then
  part_root="$(ls ${device}* | grep -E "^${device}p?1$")"
  part_boot="$(ls ${device}* | grep -E "^${device}p?2$")"
else
  part_bios_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
  part_root="$(ls ${device}* | grep -E "^${device}p?2$")"
fi

# Format partitions
if [ "$UEFI" = true ]; then
  mkfs.vfat -n "EFI" -F 32 "${part_boot}"
fi

# LUKS encryption
echo -n "$luks_password" | cryptsetup luksFormat --label archlinux "${part_root}"
echo -n "$luks_password" | cryptsetup luksOpen "${part_root}" archlinux

# --- LVM setup (replaces Btrfs subvolumes) ---
pvcreate /dev/mapper/archlinux
vgcreate vg0 /dev/mapper/archlinux

# Create logical volumes (adjust sizes to your needs and available disk space)
# These are examples; modify according to your requirements.
lvcreate -L 20G vg0 -n root
lvcreate -L 10G vg0 -n home
lvcreate -L 4G vg0 -n swap
lvcreate -L 10G vg0 -n var
lvcreate -L 2G vg0 -n var_log
lvcreate -L 5G vg0 -n var_lib_libvirt
lvcreate -L 10G vg0 -n var_lib_docker
lvcreate -L 10G vg0 -n var_cache_pacman_pkg
lvcreate -L 2G vg0 -n var_tmp
# (If you need more LVs, add them here)

# Format each LV as XFS (except swap)
mkfs.xfs -f /dev/vg0/root
mkfs.xfs -f /dev/vg0/home
mkfs.xfs -f /dev/vg0/var
mkfs.xfs -f /dev/vg0/var_log
mkfs.xfs -f /dev/vg0/var_lib_libvirt
mkfs.xfs -f /dev/vg0/var_lib_docker
mkfs.xfs -f /dev/vg0/var_cache_pacman_pkg
mkfs.xfs -f /dev/vg0/var_tmp

# Swap
mkswap /dev/vg0/swap
swapon /dev/vg0/swap

# --- Mounting ---
mount /dev/vg0/root /mnt

# Create directories and mount other LVs
mount --mkdir /dev/vg0/home /mnt/home
mount --mkdir /dev/vg0/var /mnt/var
mount --mkdir /dev/vg0/var_log /mnt/var/log
mount --mkdir /dev/vg0/var_lib_libvirt /mnt/var/lib/libvirt
mount --mkdir /dev/vg0/var_lib_docker /mnt/var/lib/docker
mount --mkdir /dev/vg0/var_cache_pacman_pkg /mnt/var/cache/pacman/pkg
mount --mkdir /dev/vg0/var_tmp /mnt/var/tmp

# Mount EFI partition (if UEFI)
if [ "$UEFI" = true ]; then
  mount --mkdir -o umask=0077 "${part_boot}" /mnt/efi
fi

# ==================== PACKAGE LIST DEFINITIONS ====================
# Edit these lists to suit your needs. One package per line, '#' for comments.

# Base packages (always installed)
BASE_PACKAGES=$(cat <<EOF
base
base-devel
linux-hardened
linux-hardened-headers
linux-firmware
lvm2
amd-ucode          # will be replaced based on CPU choice
intel-ucode        # will be replaced based on CPU choice
vim
git
man-db
man-pages
texinfo
grub               # will be removed on UEFI, kept on BIOS
efibootmgr         # will be removed on BIOS
networkmanager
iwd
dhcpcd
openssh
sudo
python
python-pip
python-setuptools
python-virtualenv
python-wheel
python-pipenv
python-poetry
python-black
python-flake8
python-mypy
python-pytest
python-sphinx
python-sphinx_rtd_theme
python-sphinx-autobuild
python-sphinx-click
python-sphinx-issues
python-sphinx-rtd-theme
python-sphinx-tabs
python-sphinx-togglebutton
python-sphinxcontrib-bibtex
python-sphinxcontrib-programoutput
python-sphinxcontrib-spelling
python-sphinxext-opengraph
python-sphinxext-rediraffe
python-sphinxext-wikipedia
python-sphinxext-youtube
python-sphinxext-inline-tabs
python-sphinxext-inline-tabs
python-sphinxext-inline-tabs
EOF
)

# AUR packages (optional – comment out if not needed)
AUR_PACKAGES=$(cat <<EOF
yay-bin
visual-studio-code-bin
google-chrome
spotify
discord
slack-desktop
zoom
teams
dropbox
insync
megasync
nextcloud-client
owncloud-client
pcloud-drive
rclone
rclone-browser
rclone-google-drive
rclone-dropbox
rclone-mega
rclone-nextcloud
rclone-owncloud
rclone-pcloud
rclone-s3
rclone-sftp
rclone-webdav
rclone-yandex
rclone-zoho
rclone-crypt
rclone-cache
rclone-chunker
rclone-union
rclone-merge
rclone-mount
rclone-serve
rclone-rc
rclone-rcat
rclone-rm
rclone-rmdir
rclone-mkdir
rclone-ls
rclone-lsd
rclone-lsl
rclone-size
rclone-du
rclone-about
rclone-purge
rclone-delete
rclone-dedupe
rclone-move
rclone-copy
rclone-sync
rclone-check
rclone-cryptcheck
rclone-cryptdecode
rclone-genautocomplete
rclone-genautocomplete-bash
rclone-genautocomplete-zsh
rclone-genautocomplete-fish
rclone-genautocomplete-powershell
rclone-gendocs
rclone-git-lfs
rclone-git-lfs-fetch
rclone-git-lfs-push
rclone-git-lfs-status
rclone-git-lfs-track
rclone-git-lfs-untrack
rclone-git-lfs-ls
rclone-git-lfs-ls-files
rclone-git-lfs-ls-tree
rclone-git-lfs-ls-remote
rclone-git-lfs-ls-refs
rclone-git-lfs-ls-tags
rclone-git-lfs-ls-branches
rclone-git-lfs-ls-commits
rclone-git-lfs-ls-diff
rclone-git-lfs-ls-log
rclone-git-lfs-ls-reflog
rclone-git-lfs-ls-show
rclone-git-lfs-ls-status
rclone-git-lfs-ls-stash
rclone-git-lfs-ls-submodules
rclone-git-lfs-ls-worktree
EOF
)
# ====================================================================

# Build the final package list by starting with base and then adding dynamic packages
> regular_packages_to_install   # empty the file

# Add base packages (filter out comments and empty lines)
echo "$BASE_PACKAGES" | grep -v '^#' | grep -v '^$' >> regular_packages_to_install

# Add GPU-related base packages
if [[ "$gpu_target" != "None" || "$install_igpu_drivers" = "Yes" ]]; then
  {
    echo mesa
    echo vulkan-icd-loader
  } >> regular_packages_to_install
fi

# Add CPU microcode (replace placeholder with actual)
sed -i "/^${cpu_target,,}-ucode/d" regular_packages_to_install   # remove both placeholders
echo "${cpu_target,,}-ucode" >> regular_packages_to_install

if [[ "$cpu_target" == "Intel" && "$install_igpu_drivers" == "Yes" ]]; then
  {
    echo intel-media-driver
    echo libva-intel-driver
    echo vulkan-intel
  } >> regular_packages_to_install
fi

if [[ "$gpu_target" != "None" ]]; then
  {
    echo libva-mesa-driver
    if [[ "$gpu_target" = "Nvidia" ]]; then
      # Proprietary NVIDIA drivers
      echo nvidia
      echo nvidia-utils
      echo nvidia-settings
    elif [[ "$gpu_target" = "AMD" ]]; then
      echo vulkan-radeon
    fi
  } >> regular_packages_to_install
fi

# Adjust bootloader packages based on firmware
if [ "$UEFI" = true ]; then
  # Remove grub if present, ensure efibootmgr
  sed -i '/^grub$/d' regular_packages_to_install
  echo efibootmgr >> regular_packages_to_install
else
  # Remove efibootmgr if present, ensure grub
  sed -i '/^efibootmgr$/d' regular_packages_to_install
  echo grub >> regular_packages_to_install
fi

# LVM2 already in base list, but ensure it's there
echo lvm2 >> regular_packages_to_install

# Remove duplicate lines (optional)
sort -u -o regular_packages_to_install regular_packages_to_install

# Install base system (pacstrap)
pacstrap -K --disable-download-timeout /mnt - <regular_packages_to_install

# Copy custom files (if any)
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/
if [ -d rootfs ]; then
  find rootfs -type f -exec bash -c 'file="$1"; dest="/mnt/${file#rootfs/}"; mkdir -p "$(dirname "$dest")"; cp -P "$file" "$dest"' shell {} \;
fi

# Patch pacman config
sed -i "s/#Color/Color/g" /mnt/etc/pacman.conf

# Patch placeholders (use sed with a backup extension on some systems)
if [ -f /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
  sed -i.bak "s/username_placeholder/$user/g" /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
fi
if [ -f /mnt/etc/libvirt/qemu.conf ]; then
  sed -i.bak "s/username_placeholder/$user/g" /mnt/etc/libvirt/qemu.conf
fi

# Set dash as sh
ln -sfT dash /mnt/usr/bin/sh

# Kernel command line (adapted for LVM)
{
  echo -n "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
  echo -n " lockdown=integrity"
  echo -n " cryptdevice=${part_root}:archlinux"
  echo -n " root=/dev/mapper/vg0-root"                     # LVM root LV
  echo -n " mem_sleep_default=deep"
  echo -n " audit=1"
  echo -n " audit_backlog_limit=32768"
  echo -n " quiet splash rd.udev.log_level=3"
  echo -n " nvidia-drm.modeset=1"
} >/mnt/etc/kernel/cmdline

echo "FONT=$font" >/mnt/etc/vconsole.conf
echo "KEYMAP=fr-latin1" >>/mnt/etc/vconsole.conf

echo "${hostname}" >/mnt/etc/hostname
echo "en_US.UTF-8 UTF-8" >>/mnt/etc/locale.gen
echo "fr_FR.UTF-8 UTF-8" >>/mnt/etc/locale.gen
ln -sf /usr/share/zoneinfo/Europe/Paris /mnt/etc/localtime
arch-chroot /mnt locale-gen

genfstab -U /mnt >>/mnt/etc/fstab

# Hush login
touch /mnt/etc/hushlogins
sed -i 's/HUSHLOGIN_FILE.*/#\0/g' /etc/login.defs

# Create user
arch-chroot /mnt useradd -m -s /bin/sh "$user"
for group in wheel audit libvirt firejail; do
  arch-chroot /mnt groupadd -rf "$group" 2>/dev/null || true
  arch-chroot /mnt gpasswd -a "$user" "$group"
done
echo "$user:$user_password" | arch-chroot /mnt chpasswd

arch-chroot /mnt groupadd -rf allow-internet 2>/dev/null || true

# Temporary sudo for yay
echo "$user ALL=(ALL) NOPASSWD:ALL" >>"/mnt/etc/sudoers"

# Temporarily disable pacman wrapper (if any)
mv /mnt/usr/local/bin/pacman /mnt/usr/local/bin/pacman.disable 2>/dev/null || true

# Install yay (AUR helper)
arch-chroot -u "$user" /mnt /bin/bash -c 'mkdir -p /tmp/yay.$$ && \
                                          cd /tmp/yay.$$ && \
                                          curl -s "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=yay-bin" -o PKGBUILD && \
                                          makepkg -si --noconfirm'

# Install AUR packages if the list is not empty
if [ -n "$AUR_PACKAGES" ]; then
  # Filter out comments and empty lines
  echo "$AUR_PACKAGES" | grep -v '^#' | grep -v '^$' > aur_packages_to_install

  # Optionally remove packages you don't want
  # sed -i '/^package-name$/d' aur_packages_to_install

  if [[ "$gpu_target" = "Nvidia" ]]; then
    echo nouveau-fw >> aur_packages_to_install
  fi

  if [ -s aur_packages_to_install ]; then
    HOME="/home/$user" arch-chroot -u "$user" /mnt /usr/bin/yay --noconfirm -Sy - < aur_packages_to_install
  fi
fi

# Restore pacman wrapper
mv /mnt/usr/local/bin/pacman.disable /mnt/usr/local/bin/pacman 2>/dev/null || true

# Remove sudo NOPASSWD
sed -i '$ d' /mnt/etc/sudoers

# Plymouth theme (if plymouth is installed)
if arch-chroot /mnt pacman -Q plymouth &>/dev/null; then
  arch-chroot /mnt plymouth-set-default-theme colorful_loop
fi

# Determine kernel modules for mkinitcpio
if [[ "$gpu_target" = "AMD" ]]; then
  modules="amdgpu"
elif [[ "$gpu_target" = "Nvidia" ]]; then
  modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
elif [[ "$cpu_target" = "Intel" && "$install_igpu_drivers" ]]; then
  modules="i915"
else
  modules=""
fi

cat <<EOF >/mnt/etc/mkinitcpio.conf
MODULES=($modules)
BINARIES=(setfont)
FILES=()
HOOKS=(base consolefont keymap udev autodetect modconf block encrypt lvm2 filesystems keyboard)
EOF

arch-chroot /mnt mkinitcpio -p linux-hardened

# ==================== BOOTLOADER INSTALLATION ====================
if [ "$UEFI" = true ]; then
  # systemd-boot for UEFI
  arch-chroot /mnt bootctl install
  cmdline=$(cat /mnt/etc/kernel/cmdline)
  cat <<EOF >/mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux-hardened
initrd  /initramfs-linux-hardened.img
options $cmdline
EOF
  cat <<EOF >/mnt/boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
EOF
else
  # GRUB for BIOS
  cat <<EOF >/mnt/etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="$(cat /mnt/etc/kernel/cmdline)"
GRUB_TIMEOUT=3
GRUB_DISABLE_SUBMENU=y
EOF
  arch-chroot /mnt grub-install --target=i386-pc "${device}"
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi
# =================================================================

# Hardening
arch-chroot /mnt chmod 700 /boot
arch-chroot /mnt passwd -dl root

# Firejail
arch-chroot /mnt /usr/bin/firecfg 2>/dev/null || true
echo "$user" >/mnt/etc/firejail/firejail.users

# DNS
rm -f /mnt/etc/resolv.conf
arch-chroot /mnt ln -s /usr/lib/systemd/resolv.conf /etc/resolv.conf

# Enable system services
arch-chroot /mnt systemctl enable systemd-networkd
arch-chroot /mnt systemctl enable systemd-resolved
arch-chroot /mnt systemctl enable systemd-timesyncd
arch-chroot /mnt systemctl enable getty@tty1
arch-chroot /mnt systemctl enable dbus-broker
arch-chroot /mnt systemctl enable iwd
arch-chroot /mnt systemctl enable auditd
arch-chroot /mnt systemctl enable nftables
arch-chroot /mnt systemctl enable docker
arch-chroot /mnt systemctl enable libvirtd
arch-chroot /mnt systemctl enable apparmor
arch-chroot /mnt systemctl enable auditd-notify
arch-chroot /mnt systemctl enable local-forwarding-proxy

# Enable timers (snapper timers are disabled because snapper requires Btrfs)
arch-chroot /mnt systemctl enable auditor.timer
arch-chroot /mnt systemctl enable pacman-sync.timer
arch-chroot /mnt systemctl enable pacman-notify.timer
arch-chroot /mnt systemctl enable should-reboot-check.timer
# Note: btrfs-related timers have been removed because they are not compatible with XFS.

# Enable user services
arch-chroot /mnt systemctl --global enable dbus-broker
arch-chroot /mnt systemctl --global enable journalctl-notify
arch-chroot /mnt systemctl --global enable pipewire
arch-chroot /mnt systemctl --global enable wireplumber
arch-chroot /mnt systemctl --global enable gammastep

# Run user dotfiles setup (if desired)
HOME="/home/$user" arch-chroot -u "$user" /mnt /bin/bash -c 'if [ -d .dotfiles ]; then cd .dotfiles && ./install.sh; fi' || true

echo "Installation complete. You can now reboot."