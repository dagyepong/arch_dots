#!/bin/bash

#
# ArchLinux Hardened installation script.
# Supports both UEFI and BIOS systems.
# Handles mirrorlist failures gracefully.
#

set -euo pipefail
cd "$(dirname "$0")"
trap on_error ERR

# Redirect outputs to files for easier debugging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

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
pacman -Sy --noconfirm --needed git reflector terminus-font dialog wget

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

echo "Writing random bytes to $device, go grab some coffee it might take a while"
dd bs=1M if=/dev/urandom of="$device" status=progress || true

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

echo -n "$luks_password" | cryptsetup luksFormat --label archlinux "${part_root}"
echo -n "$luks_password" | cryptsetup luksOpen "${part_root}" archlinux
mkfs.btrfs --label archlinux /dev/mapper/archlinux

# Create btrfs subvolumes
mount /dev/mapper/archlinux /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home-snapshots
btrfs subvolume create /mnt/@libvirt
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@cache-pacman-pkgs
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@var-log
btrfs subvolume create /mnt/@var-tmp
umount /mnt

mount_opt="defaults,noatime,nodiratime,compress=zstd,space_cache=v2"
mount -o subvol=@,$mount_opt /dev/mapper/archlinux /mnt

if [ "$UEFI" = true ]; then
  mount --mkdir -o umask=0077 "${part_boot}" /mnt/efi
fi

mount --mkdir -o subvol=@home,$mount_opt /dev/mapper/archlinux /mnt/home
mount --mkdir -o subvol=@swap,$mount_opt /dev/mapper/archlinux /mnt/.swap
mount --mkdir -o subvol=@snapshots,$mount_opt /dev/mapper/archlinux /mnt/.snapshots
mount --mkdir -o subvol=@home-snapshots,$mount_opt /dev/mapper/archlinux /mnt/home/.snapshots

# Copy-on-Write is no good for big files that are written multiple times.
# This includes: logs, containers, virtual machines, databases, etc.
# They usually lie in /var, therefore CoW will be disabled for everything in /var
mount --mkdir -o subvol=@var,$mount_opt /dev/mapper/archlinux /mnt/var
chattr +C /mnt/var # Disable Copy-on-Write for /var
mount --mkdir -o subvol=@var-log,$mount_opt /dev/mapper/archlinux /mnt/var/log
mount --mkdir -o subvol=@libvirt,$mount_opt /dev/mapper/archlinux /mnt/var/lib/libvirt
mount --mkdir -o subvol=@docker,$mount_opt /dev/mapper/archlinux /mnt/var/lib/docker
mount --mkdir -o subvol=@cache-pacman-pkgs,$mount_opt /dev/mapper/archlinux /mnt/var/cache/pacman/pkg
mount --mkdir -o subvol=@var-tmp,$mount_opt /dev/mapper/archlinux /mnt/var/tmp

# Create swapfile
btrfs filesystem mkswapfile /mnt/.swap/swapfile
mkswap /mnt/.swap/swapfile
swapon /mnt/.swap/swapfile

# Install all packages listed in packages/regular
grep -o '^[^ *#]*' packages/regular >regular_packages_to_install

if [[ "$gpu_target" != "None" || "$install_igpu_drivers" = "Yes" ]]; then
  {
    echo mesa
    echo vulkan-icd-loader
  } >>regular_packages_to_install
fi

if [[ "$cpu_target" == "Intel" ]]; then
  echo intel-ucode >>regular_packages_to_install
  if [[ "$install_igpu_drivers" == "Yes" ]]; then
    {
      echo intel-media-driver
      echo libva-intel-driver
      echo vulkan-intel
    } >>regular_packages_to_install
  fi
elif [[ "$cpu_target" == "AMD" ]]; then
  echo amd-ucode >>regular_packages_to_install
else
  echo "Unsupported CPU"
  exit 1
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
  } >>regular_packages_to_install
fi

# Add GRUB if BIOS
if [ "$UEFI" = false ]; then
  echo grub >>regular_packages_to_install
fi

# Install base system with timeout resilience
pacstrap -K --disable-download-timeout /mnt - <regular_packages_to_install

# Copy custom files
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/
find rootfs -type f -exec bash -c 'file="$1"; dest="/mnt/${file#rootfs/}"; mkdir -p "$(dirname "$dest")"; cp -P "$file" "$dest"' shell {} \;

# Patch pacman config
sed -i "s/#Color/Color/g" /mnt/etc/pacman.conf

# Patch placeholders
sed -i "s/username_placeholder/$user/g" /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
sed -i "s/username_placeholder/$user/g" /mnt/etc/libvirt/qemu.conf

# Set dash as sh
ln -sfT dash /mnt/usr/bin/sh

# Kernel command line
{
  echo -n "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
  echo -n " lockdown=integrity"
  echo -n " cryptdevice=${part_root}:archlinux"
  echo -n " root=/dev/mapper/archlinux"
  echo -n " rootflags=subvol=@"
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
  arch-chroot /mnt groupadd -rf "$group"
  arch-chroot /mnt gpasswd -a "$user" "$group"
done
echo "$user:$user_password" | arch-chroot /mnt chpasswd

arch-chroot /mnt groupadd -rf allow-internet

# Temporary sudo for yay
echo "$user ALL=(ALL) NOPASSWD:ALL" >>"/mnt/etc/sudoers"

# Temporarily disable pacman wrapper
mv /mnt/usr/local/bin/pacman /mnt/usr/local/bin/pacman.disable || true

# Install yay (AUR helper)
arch-chroot -u "$user" /mnt /bin/bash -c 'mkdir /tmp/yay.$$ && \
                                          cd /tmp/yay.$$ && \
                                          curl "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=yay-bin" -o PKGBUILD && \
                                          makepkg -si --noconfirm'

# Install AUR packages
grep -o '^[^ *#]*' packages/aur >aur_packages_to_install
sed -i '/^arch-secure-boot$/d' aur_packages_to_install   # Remove Secure Boot package

if [[ "$gpu_target" = "Nvidia" ]]; then
  echo nouveau-fw >>aur_packages_to_install
fi

HOME="/home/$user" arch-chroot -u "$user" /mnt /usr/bin/yay --noconfirm -Sy - <aur_packages_to_install

# Restore pacman wrapper
mv /mnt/usr/local/bin/pacman.disable /mnt/usr/local/bin/pacman || true

# Remove sudo NOPASSWD
sed -i '$ d' /mnt/etc/sudoers

# Plymouth theme
arch-chroot /mnt plymouth-set-default-theme colorful_loop

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
HOOKS=(base consolefont keymap udev autodetect modconf block plymouth encrypt filesystems keyboard)
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
  # Create GRUB default configuration with kernel command line
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
arch-chroot /mnt /usr/bin/firecfg
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

# Enable timers
arch-chroot /mnt systemctl enable snapper-timeline.timer
arch-chroot /mnt systemctl enable snapper-cleanup.timer
arch-chroot /mnt systemctl enable auditor.timer
arch-chroot /mnt systemctl enable btrfs-scrub@-.timer
arch-chroot /mnt systemctl enable btrfs-balance.timer
arch-chroot /mnt systemctl enable pacman-sync.timer
arch-chroot /mnt systemctl enable pacman-notify.timer
arch-chroot /mnt systemctl enable should-reboot-check.timer

# Enable user services
arch-chroot /mnt systemctl --global enable dbus-broker
arch-chroot /mnt systemctl --global enable journalctl-notify
arch-chroot /mnt systemctl --global enable pipewire
arch-chroot /mnt systemctl --global enable wireplumber
arch-chroot /mnt systemctl --global enable gammastep

# Run user dotfiles setup
HOME="/home/$user" arch-chroot -u "$user" /mnt /bin/bash -c 'cd && \
                                                             git clone https://github.com/ShellCode33/.dotfiles && \
                                                             .dotfiles/install.sh'

echo "Installation complete. You can now reboot."