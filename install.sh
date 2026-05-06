#!/usr/bin/env bash
# Установщик Arch Linux + Hyprland с оптимизациями (стабильная версия)
set -euo pipefail
trap 'echo "Ошибка на строке $LINENO. Выход."; exit 1' ERR

if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo)."
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "Система загружена не в UEFI-режиме. Установка прервана."
    exit 1
fi

if ! ping -c1 archlinux.org &>/dev/null; then
    echo "Нет интернет-соединения. Настройте сеть и перезапустите скрипт."
    exit 1
fi

echo "==> Выберите диск для установки (например, /dev/sda):"
lsblk -d -o NAME,SIZE,MODEL | grep -vE "loop|sr" | tail -n +2
read -rp "Диск: " DISK
if [[ ! -b "$DISK" ]]; then
    echo "Ошибка: $DISK не является блочным устройством."
    exit 1
fi

read -rp "Имя хоста (по умолчанию arch): " HOSTNAME
HOSTNAME=${HOSTNAME:-arch}

read -rp "Имя пользователя (по умолчанию user): " USERNAME
USERNAME=${USERNAME:-user}

while true; do
    read -rsp "Пароль root: " ROOT_PASS
    echo
    read -rsp "Подтвердите пароль root: " ROOT_PASS_CONFIRM
    echo
    [[ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ]] && break
    echo "Пароли не совпадают, попробуйте снова."
done

while true; do
    read -rsp "Пароль пользователя $USERNAME: " USER_PASS
    echo
    read -rsp "Подтвердите пароль: " USER_PASS_CONFIRM
    echo
    [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]] && break
    echo "Пароли не совпадают, попробуйте снова."
done

read -rp "Часовой пояс (например Europe/Moscow) [по умолчанию Europe/Moscow]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Moscow}

echo ""
echo "----------------------------------------"
echo "Установка на: $DISK"
echo "Хост: $HOSTNAME"
echo "Пользователь: $USERNAME"
echo "Часовой пояс: $TIMEZONE"
echo "----------------------------------------"
read -rp "Всё верно? Нажмите Enter для старта, Ctrl+C для отмены."

if [[ "$DISK" =~ [0-9]$ ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

echo "==> Размечаем диск $DISK"
sgdisk -og "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK"
sleep 1

mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "==> Обновление зеркал"
command -v reflector &>/dev/null || pacman -Sy --noconfirm reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $NF}')
MICROCODE=""
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE="intel-ucode" ;;
    AuthenticAMD) MICROCODE="amd-ucode" ;;
esac

pacstrap /mnt base linux linux-firmware base-devel \
    vim nano sudo man-db man-pages \
    networkmanager reflector $MICROCODE

genfstab -U /mnt > /mnt/etc/fstab
awk -i inplace '$2 == "/" && !/noatime/ {sub(/defaults/, "defaults,noatime"); if (!/noatime/) $4 = $4 ",noatime"} 1' /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/'   /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf

pacman -Syu --noconfirm
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

pacman -S --noconfirm \
    hyprland waybar kitty \
    sddm \
    polkit-gnome \
    qt5-wayland qt6-wayland \
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    dunst rofi \
    network-manager-applet \
    mesa libva-mesa-driver vulkan-intel vulkan-radeon \
    xf86-input-libinput \
    git wget curl unzip \
    pipewire pipewire-pulse pipewire-alsa wireplumber \
    noto-fonts noto-fonts-emoji ttf-dejavu

pacman -S --noconfirm \
    earlyoom \
    zram-generator \
    power-profiles-daemon \
    fwupd

systemctl enable NetworkManager sddm earlyoom fstrim.timer power-profiles-daemon

if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
    cat > /etc/systemd/zram-generator.conf <<ZRAMCFG
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAMCFG
fi

mkinitcpio -P

bootctl install
cat > /boot/loader/entries/arch.conf <<BOOTENTRY
title   Arch Linux
linux   /vmlinuz-linux
$( [[ -n "$MICROCODE" ]] && echo "initrd  /${MICROCODE}.img" )
initrd  /initramfs-linux.img
options root=UUID=$(blkid -s UUID -o value $ROOT_PART) rw quiet
BOOTENTRY
echo "default arch" > /boot/loader/loader.conf
EOF

umount -R /mnt
echo "Установка завершена. Перезагрузитесь: reboot"
