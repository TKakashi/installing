#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════╗
# ║   Универсальный установщик Arch Linux + Окружение      ║
# ║   Hyprland | GNOME | KDE Plasma | XFCE | Sway | Cinnamon║
# ║                  + Noctalia Shell (AUR)                  ║
# ╚══════════════════════════════════════════════════════════╝
set -euo pipefail

# ---------- Проверки и подготовка ----------
if [[ $EUID -ne 0 ]]; then
    echo "Запустите от root (sudo)." >&2
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    echo "Ошибка: система загружена не в UEFI-режиме." >&2
    exit 1
fi

if ! command -v dialog &>/dev/null; then
    pacman -Sy --noconfirm dialog &>/dev/null
fi

update_gauge() {
    echo "$1"
    echo "### $2"
}

# ---------- Сбор параметров через dialog ----------
dialog --backtitle "Arch Linux Installer" \
       --title "Добро пожаловать" \
       --msgbox "Данный мастер поможет установить Arch Linux с одним из популярных окружений рабочего стола.\n\nВам потребуется:\n• Чистый диск (все данные на нём будут удалены)\n• Работающее интернет-соединение\n• Имя компьютера, имя пользователя и пароли\n\nВыберите нужные параметры на следующих экранах." 14 60

# ---------- Выбор диска ----------
while true; do
    mapfile -t disk_list < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep -vE "loop|sr" | awk '{print $1" "$2" "$4}')
    disk_menu=()
    for disk in "${disk_list[@]}"; do
        name=$(echo "$disk" | awk '{print $1}')
        size=$(echo "$disk" | awk '{print $2}')
        model=$(echo "$disk" | awk '{print substr($0, index($0,$3))}')
        disk_menu+=("/dev/$name" "$size $model")
    done

    DISK=$(dialog --backtitle "Arch Linux Installer" \
                  --title "Выбор диска" \
                  --menu "Выберите ДИСК для установки (все данные на нём будут УНИЧТОЖЕНЫ).\nУбедитесь, что это целый диск, а не раздел." 0 0 0 "${disk_menu[@]}" 3>&1 1>&2 2>&3)
    if [[ -z "$DISK" ]]; then
        dialog --msgbox "Установка отменена." 6 30
        exit 0
    fi
    if [[ $(lsblk -no TYPE "$DISK" 2>/dev/null) != "disk" ]]; then
        dialog --msgbox "Ошибка: $DISK не является целым диском. Пожалуйста, выберите диск без цифр." 6 50
        continue
    fi
    if mount | grep -q "^${DISK}"; then
        dialog --msgbox "Ошибка: на диске $DISK есть примонтированные разделы. Отмонтируйте их перед установкой." 6 50
        continue
    fi
    break
done

# ---------- Имя хоста ----------
HOSTNAME=$(dialog --backtitle "Arch Linux Installer" \
                  --title "Имя компьютера" \
                  --inputbox "Введите имя хоста (например, myarch):" 8 40 "arch" 3>&1 1>&2 2>&3)
HOSTNAME=${HOSTNAME:-arch}

# ---------- Имя пользователя ----------
USERNAME=$(dialog --backtitle "Arch Linux Installer" \
                  --title "Имя пользователя" \
                  --inputbox "Введите имя основного пользователя (только строчные буквы):" 8 40 "user" 3>&1 1>&2 2>&3)
USERNAME=${USERNAME:-user}

# ---------- Пароли ----------
while true; do
    ROOT_PASS=$(dialog --backtitle "Arch Linux Installer" \
                       --title "Пароль администратора (root)" \
                       --insecure --passwordbox "Придумайте пароль для root (не менее 1 символа):" 8 40 3>&1 1>&2 2>&3)
    if [[ -z "$ROOT_PASS" ]]; then
        dialog --msgbox "Пароль не может быть пустым. Повторите попытку." 6 40
        continue
    fi
    ROOT_PASS_CONFIRM=$(dialog --backtitle "Arch Linux Installer" \
                               --title "Подтверждение пароля root" \
                               --insecure --passwordbox "Повторите пароль root:" 8 40 3>&1 1>&2 2>&3)
    if [[ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ]]; then
        break
    else
        dialog --msgbox "Пароли не совпадают. Попробуйте снова." 6 40
    fi
done

while true; do
    USER_PASS=$(dialog --backtitle "Arch Linux Installer" \
                       --title "Пароль пользователя $USERNAME" \
                       --insecure --passwordbox "Придумайте пароль для $USERNAME (не менее 1 символа):" 8 40 3>&1 1>&2 2>&3)
    if [[ -z "$USER_PASS" ]]; then
        dialog --msgbox "Пароль не может быть пустым." 6 40
        continue
    fi
    USER_PASS_CONFIRM=$(dialog --backtitle "Arch Linux Installer" \
                               --title "Подтверждение пароля" \
                               --insecure --passwordbox "Повторите пароль для $USERNAME:" 8 40 3>&1 1>&2 2>&3)
    if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]]; then
        break
    else
        dialog --msgbox "Пароли не совпадают." 6 40
    fi
done

# ---------- Часовой пояс ----------
TZ_LIST=(
    "Europe/Moscow" "Москва, Россия"
    "Europe/Kyiv" "Киев, Украина"
    "Europe/Berlin" "Берлин, Германия"
    "Europe/London" "Лондон, Великобритания"
    "America/New_York" "Нью-Йорк, США"
    "America/Chicago" "Чикаго, США"
    "America/Los_Angeles" "Лос-Анджелес, США"
    "Asia/Tokyo" "Токио, Япония"
    "Asia/Shanghai" "Шанхай, Китай"
    "other" "Ввести вручную..."
)
TZ_CHOICE=$(dialog --backtitle "Arch Linux Installer" \
                   --title "Часовой пояс" \
                   --menu "Выберите часовой пояс или пункт 'Ввести вручную' для нестандартного:" 0 0 0 "${TZ_LIST[@]}" 3>&1 1>&2 2>&3)
if [[ -z "$TZ_CHOICE" ]]; then
    TIMEZONE="Europe/Moscow"
elif [[ "$TZ_CHOICE" == "other" ]]; then
    TIMEZONE=$(dialog --backtitle "Arch Linux Installer" \
                      --title "Ввод часового пояса" \
                      --inputbox "Введите часовой пояс в формате Регион/Город (например, Asia/Yekaterinburg):" 8 50 "Europe/Moscow" 3>&1 1>&2 2>&3)
    TIMEZONE=${TIMEZONE:-Europe/Moscow}
else
    TIMEZONE="$TZ_CHOICE"
fi

# ---------- Выбор окружения ----------
DESKTOP=$(dialog --backtitle "Arch Linux Installer" \
                 --title "Выбор окружения" \
                 --radiolist "Выберите окружение рабочего стола.\n\nПодсказка: Hyprland/Sway – для опытных (тайлинг),\nGNOME/Plasma/Cinnamon – современные рабочие столы,\nXFCE – лёгкий и быстрый." 0 0 0 \
                 "hyprland" "Hyprland – динамический тайлинг (Wayland)" ON \
                 "gnome" "GNOME – полнофункциональный (Wayland)" OFF \
                 "plasma" "KDE Plasma – настраиваемый (Wayland)" OFF \
                 "xfce" "XFCE – легковесный (X11)" OFF \
                 "sway" "Sway – i3-совместимый тайлинг (Wayland)" OFF \
                 "cinnamon" "Cinnamon – классический (X11)" OFF \
                 3>&1 1>&2 2>&3)
if [[ -z "$DESKTOP" ]]; then
    dialog --msgbox "Окружение не выбрано. Установка отменена." 6 30
    exit 0
fi

case "$DESKTOP" in
    hyprland)   DESC="Современный тайлинговый оконный менеджер с красивыми эффектами." ;;
    gnome)      DESC="Полнофункциональное окружение с оболочкой GNOME Shell." ;;
    plasma)     DESC="Мощное и гибко настраиваемое окружение KDE Plasma." ;;
    xfce)       DESC="Лёгкое, стабильное и нетребовательное к ресурсам окружение." ;;
    sway)       DESC="Тайлинговый Wayland-аналог i3 для опытных пользователей." ;;
    cinnamon)   DESC="Классический рабочий стол в стиле GNOME 2 от Linux Mint." ;;
esac

dialog --backtitle "Arch Linux Installer" \
       --title "Подтверждение окружения" \
       --yesno "Вы выбрали: $DESKTOP\n\n$DESC\n\nПродолжить установку?" 10 60
if [[ $? -ne 0 ]]; then
    dialog --msgbox "Установка отменена." 6 30
    exit 0
fi

# ---------- Вопрос о Noctalia Shell ----------
USE_NOCTALIA="n"
dialog --backtitle "Arch Linux Installer" \
       --title "Noctalia Shell" \
       --yesno "Хотите ли вы использовать Noctalia Shell?\n\nNoctalia — это современная минималистичная оболочка для Wayland, которая заменяет стандартные панели и уведомления.\n\nБудет установлена из AUR." 10 60
if [[ $? -eq 0 ]]; then
    USE_NOCTALIA="y"
fi

# ---------- Финальное подтверждение ----------
EXTRA_MSG=""
if [[ "$USE_NOCTALIA" == "y" ]]; then
    EXTRA_MSG="\nОболочка: Noctalia Shell (AUR)"
fi
dialog --backtitle "Arch Linux Installer" \
       --title "Начало установки" \
       --yesno "Всё готово для установки:\n\nДиск: $DISK\nХост: $HOSTNAME\nПользователь: $USERNAME\nЧасовой пояс: $TIMEZONE\nОкружение: $DESKTOP${EXTRA_MSG}\n\nНажмите «Да» для старта." 0 0
if [[ $? -ne 0 ]]; then
    dialog --msgbox "Установка отменена." 6 30
    exit 0
fi

# ---------- Определение пакетов и менеджера входа ----------
case "$DESKTOP" in
    hyprland)
        DESKTOP_PKGS="hyprland waybar kitty polkit-gnome xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dunst rofi qt5-wayland qt6-wayland"
        DM_PKG="sddm"
        DM_SERVICE="sddm"
        ;;
    gnome)
        DESKTOP_PKGS="gnome gnome-tweaks"
        DM_PKG="gdm"
        DM_SERVICE="gdm"
        ;;
    plasma)
        DESKTOP_PKGS="plasma-meta konsole"
        DM_PKG="sddm"
        DM_SERVICE="sddm"
        ;;
    xfce)
        DESKTOP_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
        DM_PKG=""
        DM_SERVICE="lightdm"
        ;;
    sway)
        DESKTOP_PKGS="sway swaybg swaylock waybar foot polkit-gnome xdg-desktop-portal-wlr xdg-desktop-portal-gtk"
        DM_PKG="sddm"
        DM_SERVICE="sddm"
        ;;
    cinnamon)
        DESKTOP_PKGS="cinnamon lightdm lightdm-gtk-greeter"
        DM_PKG=""
        DM_SERVICE="lightdm"
        ;;
esac

# ---------- Установка с прогресс-баром ----------
(
update_gauge 0 "Подготовка разделов..."
if [[ "$DISK" =~ [0-9]$ ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

sgdisk -og "$DISK" &>/dev/null
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK" &>/dev/null
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK" &>/dev/null
partprobe "$DISK" &>/dev/null
sleep 1
update_gauge 10 "Форматирование разделов..."
mkfs.fat -F32 "$EFI_PART" &>/dev/null
mkfs.ext4 -F "$ROOT_PART" &>/dev/null

update_gauge 15 "Монтирование..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

update_gauge 20 "Обновление зеркал..."
command -v reflector &>/dev/null || pacman -Sy --noconfirm reflector &>/dev/null
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist &>/dev/null

CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $NF}')
MICROCODE=""
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE="intel-ucode" ;;
    AuthenticAMD) MICROCODE="amd-ucode" ;;
esac

update_gauge 30 "Установка базовых пакетов (ядро, microcode)..."
pacstrap /mnt base linux linux-firmware base-devel \
    vim nano sudo man-db man-pages \
    networkmanager reflector $MICROCODE &>/dev/null

update_gauge 45 "Генерация fstab и оптимизация (noatime)..."
genfstab -U /mnt > /mnt/etc/fstab
awk -i inplace '$2 == "/" && !/noatime/ {sub(/defaults/, "defaults,noatime"); if (!/noatime/) $4 = $4 ",noatime"} 1' /mnt/etc/fstab

update_gauge 50 "Базовая настройка системы (локали, пользователи)..."
# Передаём переменные в chroot как аргументы
arch-chroot /mnt /bin/bash -s "$ROOT_PASS" "$USER_PASS" "$HOSTNAME" "$USERNAME" "$TIMEZONE" <<'EOF'
ROOT_PASS=$1
USER_PASS=$2
HOSTNAME=$3
USERNAME=$4
TIMEZONE=$5

set -euo pipefail
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/'   /etc/locale.gen
locale-gen &>/dev/null
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS
printf '%s:%s\n' 'root' "$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf
pacman -Syu --noconfirm &>/dev/null
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist &>/dev/null
EOF

update_gauge 60 "Установка окружения $DESKTOP и драйверов..."
arch-chroot /mnt pacman -S --noconfirm \
    $DESKTOP_PKGS \
    $DM_PKG \
    network-manager-applet \
    mesa libva-mesa-driver vulkan-intel vulkan-radeon \
    xf86-input-libinput \
    git wget curl unzip \
    pipewire pipewire-pulse pipewire-alsa wireplumber \
    noto-fonts noto-fonts-emoji ttf-dejavu &>/dev/null

update_gauge 75 "Установка оптимизаций (zram, earlyoom, power-profiles)..."
arch-chroot /mnt pacman -S --noconfirm \
    earlyoom \
    zram-generator \
    power-profiles-daemon \
    fwupd &>/dev/null

arch-chroot /mnt systemctl enable NetworkManager earlyoom fstrim.timer power-profiles-daemon &>/dev/null
arch-chroot /mnt systemctl enable $DM_SERVICE &>/dev/null

cat > /tmp/zram-generator.conf <<ZRAMCFG
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAMCFG
mkdir -p /mnt/etc/systemd
cp /tmp/zram-generator.conf /mnt/etc/systemd/zram-generator.conf

# ---------- Установка Noctalia Shell (если выбрано) ----------
if [[ "$USE_NOCTALIA" == "y" ]]; then
    update_gauge 80 "Установка Noctalia Shell (AUR)..."

    # Временный sudo без пароля для установки AUR-пакетов
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /mnt/etc/sudoers.d/temp_install
    chmod 0440 /mnt/etc/sudoers.d/temp_install

    # Установка paru (AUR helper) от имени пользователя
    arch-chroot /mnt bash -c "
        runuser -u \"$USERNAME\" -- git clone https://aur.archlinux.org/paru.git \"/home/$USERNAME/paru\"
        runuser -u \"$USERNAME\" -- bash -c \"cd /home/$USERNAME/paru && makepkg -si --noconfirm\"
        rm -rf \"/home/$USERNAME/paru\"
    "

    # Установка noctalia-shell через paru
    arch-chroot /mnt bash -c "runuser -u \"$USERNAME\" -- paru -S --noconfirm noctalia-shell"

    # Удаление временного sudoers
    rm -f /mnt/etc/sudoers.d/temp_install

    # Настройка запуска Noctalia Shell в Hyprland или Sway
    case "$DESKTOP" in
        hyprland)
            arch-chroot /mnt bash -c "
                mkdir -p \"/home/$USERNAME/.config/hypr\"
                cat > \"/home/$USERNAME/.config/hypr/hyprland.conf\" <<'HYPRCONF'
# =======================================================
# Базовая конфигурация Hyprland + Noctalia Shell
# =======================================================

# --- Мониторы ---
monitor=,preferred,auto,1

# --- Основные программы ---
exec-once = noctalia-qs -c noctalia-shell
exec-once = dunst
exec-once = nm-applet
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# --- Ввод ---
input {
    kb_layout = us,ru
    kb_options = grp:win_space_toggle
    follow_mouse = 1
}

# --- Оформление ---
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33CCFFEE) rgba(00FF99EE) 45deg
    col.inactive_border = rgba(595959AA)
}

# --- Горячие клавиши ---
bind = SUPER, Return, exec, kitty
bind = SUPER, Q, killactive,
bind = SUPER, F, fullscreen,
bind = SUPER, Space, togglefloating,
bind = SUPER, D, exec, noctalia-shell ipc call launcher toggle

# --- Перемещение фокуса ---
bind = SUPER, h, movefocus, l
bind = SUPER, l, movefocus, r
bind = SUPER, k, movefocus, u
bind = SUPER, j, movefocus, d

# --- Выход ---
bind = SUPER, Escape, exec, noctalia-shell ipc call powermenu open
HYPRCONF
                chown -R \"$USERNAME:$USERNAME\" \"/home/$USERNAME/.config\"
            "
            ;;
        sway)
            arch-chroot /mnt bash -c "
                mkdir -p \"/home/$USERNAME/.config/sway\"
                cat > \"/home/$USERNAME/.config/sway/config\" <<'SWAYCONF'
# =======================================================
# Базовая конфигурация Sway + Noctalia Shell
# =======================================================

# --- Основные программы ---
exec noctalia-qs -c noctalia-shell
exec nm-applet
exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# --- Ввод ---
input * {
    xkb_layout us,ru
    xkb_options grp:win_space_toggle
}

# --- Оформление ---
gaps inner 5
gaps outer 10
default_border pixel 2

# --- Горячие клавиши ---
bindsym Mod4+Return exec foot
bindsym Mod4+q kill
bindsym Mod4+f fullscreen
bindsym Mod4+space floating toggle
bindsym Mod4+d exec noctalia-shell ipc call launcher toggle

# --- Перемещение фокуса ---
bindsym Mod4+h focus left
bindsym Mod4+l focus right
bindsym Mod4+k focus up
bindsym Mod4+j focus down

# --- Выход ---
bindsym Mod4+Escape exec noctalia-shell ipc call powermenu open
SWAYCONF
                chown -R \"$USERNAME:$USERNAME\" \"/home/$USERNAME/.config\"
            "
            ;;
    esac
fi

update_gauge 85 "Сборка initramfs и установка загрузчика..."
arch-chroot /mnt mkinitcpio -P &>/dev/null
arch-chroot /mnt bootctl install &>/dev/null

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
    echo "title   Arch Linux"
    echo "linux   /vmlinuz-linux"
    [[ -n "$MICROCODE" ]] && echo "initrd  /${MICROCODE}.img"
    echo "initrd  /initramfs-linux.img"
    echo "options root=UUID=$ROOT_UUID rw quiet"
} > /tmp/arch.conf
cp /tmp/arch.conf /mnt/boot/loader/entries/arch.conf
echo "default arch" > /mnt/boot/loader/loader.conf

update_gauge 95 "Синхронизация и размонтирование..."
sync
umount -R /mnt
update_gauge 100 "Установка завершена!"
) | dialog --backtitle "Arch Linux Installer" \
           --title "Установка" \
           --gauge "Пожалуйста, подождите..." 10 70 0

# ---------- Финальное сообщение ----------
FINAL_MSG="Arch Linux с окружением $DESKTOP успешно установлен!\n\n• Для перезагрузки выполните: reboot\n• После загрузки вы попадёте в $DESKTOP"
if [[ "$USE_NOCTALIA" == "y" ]]; then
    FINAL_MSG="${FINAL_MSG}\n• Оболочка Noctalia Shell настроена и запустится автоматически"
fi
FINAL_MSG="${FINAL_MSG}\n• Сеть настроится автоматически (NetworkManager)\n• Дополнительная справка: Arch Wiki\n\nПриятного использования!"

dialog --backtitle "Arch Linux Installer" \
       --title "Готово!" \
       --msgbox "$FINAL_MSG" 16 70
clear
