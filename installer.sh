#!/usr/bin/env bash

set -Eeuo pipefail

LOG=/tmp/void-installer.log
TARGET=/mnt

KEYMAP=us
HOSTNAME=voidlinux
LOCALE=en_US.UTF-8
TIMEZONE=UTC
ROOT_PART=
EFI_PART=
SWAP_PART=
DISK=
DESKTOP=
INSTALL_XLIBRE=no

exec 3>&1

die() {
    local msg=${1:-"Unknown error"}
    dialog --msgbox "$msg\n\nSee log: $LOG" 14 76 || true
    exit 1
}

run() {
    local out rc=0
    out=$(mktemp)
    "$@" >"$out" 2>&1 || rc=$?
    cat "$out" >>"$LOG"
    if ((rc != 0)); then
        local tail_output
        tail_output=$(tail -n 20 "$out")
        rm -f "$out"
        die "Command failed (exit $rc): $*\n\n--- last output ---\n${tail_output:-(no output; re-run this command by hand and check: echo $?)}"
    fi
    rm -f "$out"
}

fetch_file() {
    local url=$1 dest=$2
    if command -v curl >/dev/null 2>&1; then
        run curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        run wget -O "$dest" "$url"
    else
        die "Neither curl nor wget is available on the live system."
    fi
}

mount_chroot_fs() {
    local d
    for d in dev proc sys; do
        run mkdir -p "$TARGET/$d"
        mountpoint -q "$TARGET/$d" || run mount --rbind "/$d" "$TARGET/$d"
        run mount --make-rslave "$TARGET/$d"
    done
}

umount_chroot_fs() {
    local d
    for d in dev proc sys; do
        umount -R "$TARGET/$d" >>"$LOG" 2>&1 || true
    done
}

# Run a chroot command interactively (prompts must be visible), no capture.
chroot_interactive() {
    clear
    chroot "$TARGET" "$@" || die "Command failed: chroot $TARGET $*"
}

msgbox() {
    dialog --msgbox "$1" "${2:-10}" "${3:-70}"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

require_tools() {
    local missing=()
    local tools=(dialog xbps-install lsblk findmnt mkfs.btrfs mkfs.vfat mkswap swapon mount umount chroot parted wipefs btrfs blkid)
    local t
    for t in "${tools[@]}"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "Missing required tools:\n${missing[*]}"
}

init_log() {
    : >"$LOG"
}

confirm_start() {
    dialog --yesno "This installer will modify disks and install Void Linux. Continue?" 10 70 || exit 0
}

select_keymap() {
    local common
    common=$(dialog --stdout --menu "Select keyboard layout" 18 60 10 \
        "us" "US English" \
        "uk" "United Kingdom" \
        "de" "German" \
        "fr" "French" \
        "es" "Spanish" \
        "it" "Italian" \
        "br-abnt2" "Brazil ABNT2" \
        "jp106" "Japanese 106" \
        "Other" "Type another keymap") || exit 1

    if [[ $common == Other ]]; then
        KEYMAP=$(dialog --stdout --inputbox "Enter keymap name, for example us, de, fr, colemak:" 10 70 "us") || exit 1
    else
        KEYMAP=$common
    fi

    loadkeys "$KEYMAP" >>"$LOG" 2>&1 || msgbox "Could not load keymap '$KEYMAP' on the live ISO. It will still be written to the installed system." 9 70
}

select_hostname() {
    HOSTNAME=$(dialog --stdout --inputbox "Enter hostname" 10 60 "$HOSTNAME") || exit 1
    [[ -n $HOSTNAME ]] || die "Hostname cannot be empty."
}

select_locale() {
    local locale_file=/usr/share/i18n/SUPPORTED
    local options=()
    local line

    if [[ ! -f $locale_file ]]; then
        LOCALE=$(dialog --stdout --inputbox "Locale list not found. Enter locale manually:" 10 70 "$LOCALE") || exit 1
        return
    fi

    while read -r line; do
        [[ -z $line ]] && continue
        line=${line%% *}
        options+=("$line" "")
    done < <(awk '{print $1}' "$locale_file" | grep -E 'UTF-8$' | sort -u | head -n 200)

    options+=("Other" "Type manually")
    local pick
    pick=$(dialog --stdout --menu "Select locale" 22 70 14 "${options[@]}") || exit 1
    if [[ $pick == Other ]]; then
        LOCALE=$(dialog --stdout --inputbox "Enter locale (e.g. en_US.UTF-8)" 10 70 "$LOCALE") || exit 1
    else
        LOCALE=$pick
    fi
}

select_timezone() {
    local regions=()
    local cities=()
    local region city entry

    while read -r entry; do
        regions+=("$entry" "")
    done < <(find /usr/share/zoneinfo -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)

    region=$(dialog --stdout --menu "Select timezone region" 20 60 12 "${regions[@]}") || exit 1

    while read -r entry; do
        cities+=("$entry" "")
    done < <(find "/usr/share/zoneinfo/$region" -maxdepth 1 -type f -printf '%f\n' | sort)

    ((${#cities[@]} > 0)) || die "No timezone cities found for $region."
    city=$(dialog --stdout --menu "Select timezone city" 20 60 12 "${cities[@]}") || exit 1
    TIMEZONE="$region/$city"
}

network_step() {
    local mode
    mode=$(dialog --stdout --menu "Network setup" 14 70 5 \
        "dhcp" "Use DHCP now" \
        "manual" "I already configured networking" \
        "skip" "Skip connectivity test") || exit 1

    case "$mode" in
        dhcp)
            if command -v dhcpcd >/dev/null 2>&1; then
                run dhcpcd
            fi
            ;;
        manual|skip)
            ;;
    esac

    if [[ $mode != skip ]]; then
        ping -c 1 -W 3 repo-default.voidlinux.org >>"$LOG" 2>&1 || msgbox "Network check failed. You can continue, but package install may fail." 10 70
    fi
}

pick_disk() {
    local options=()
    local name size model type

    while read -r name size type model; do
        [[ $type == disk ]] || continue
        [[ $name == *loop* || $name == *sr0* ]] && continue
        options+=("$name" "${size} ${model:-disk}")
    done < <(lsblk -dnp -o NAME,SIZE,TYPE,MODEL | tail -n +2)

    ((${#options[@]} > 0)) || die "No installation disks found."
    DISK=$(dialog --stdout --menu "Select installation disk" 18 76 10 "${options[@]}") || exit 1

    PART_PREFIX=
    if [[ $DISK == *nvme* || $DISK == *mmcblk* || $DISK == *loop* ]]; then
        PART_PREFIX=p
    fi
}

auto_partition_btrfs() {
    local answer
    answer=$(dialog --stdout --menu "Auto partition options" 15 70 5 \
        "noswap" "EFI + Btrfs root/home (no swap partition)" \
        "swap" "EFI + swap + Btrfs root/home") || exit 1

    dialog --yesno "This will ERASE all data on $DISK. Continue?" 10 70 || exit 1

    if findmnt -rn -M "$TARGET" >/dev/null 2>&1; then
        run umount -R "$TARGET"
    fi
    swapoff -a >>"$LOG" 2>&1 || true
    for part in $(lsblk -lnp -o NAME "$DISK" | tail -n +2); do
        umount -R "$part" >>"$LOG" 2>&1 || true
    done
    run wipefs -a "$DISK"
    run parted -s "$DISK" mklabel gpt
    run parted -s "$DISK" mkpart ESP fat32 1MiB 551MiB
    run parted -s "$DISK" set 1 esp on

    if [[ $answer == swap ]]; then
        run parted -s "$DISK" mkpart primary linux-swap 551MiB 4647MiB
        run parted -s "$DISK" mkpart primary btrfs 4647MiB 100%
        EFI_PART="${DISK}1"
        SWAP_PART="${DISK}2"
        ROOT_PART="${DISK}3"
    else
        run parted -s "$DISK" mkpart primary btrfs 551MiB 100%
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
        SWAP_PART=
    fi

    run mkfs.vfat -F32 "$EFI_PART"
    run mkfs.btrfs -f "$ROOT_PART"
    if [[ -n ${SWAP_PART:-} ]]; then
        run mkswap "$SWAP_PART"
        run swapon "$SWAP_PART"
    fi

    run mount "$ROOT_PART" "$TARGET"
    run btrfs subvolume create "$TARGET/@"
    run btrfs subvolume create "$TARGET/@home"
    run btrfs subvolume create "$TARGET/@cache"
    run btrfs subvolume create "$TARGET/@log"
    run btrfs subvolume create "$TARGET/@snapshots"
    run umount "$TARGET"

    run mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" "$TARGET"
    run mkdir -p "$TARGET"/{home,var/cache,var/log,.snapshots,boot/efi}
    run mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" "$TARGET/home"
    run mount -o noatime,compress=zstd,subvol=@cache "$ROOT_PART" "$TARGET/var/cache"
    run mount -o noatime,compress=zstd,subvol=@log "$ROOT_PART" "$TARGET/var/log"
    run mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_PART" "$TARGET/.snapshots"
    run mount "$EFI_PART" "$TARGET/boot/efi"
}

manual_partition() {
    msgbox "Manual mode selected.\n\nCreate partitions in another terminal if needed, then provide partition paths." 12 72

    ROOT_PART=$(dialog --stdout --inputbox "Root partition (will be formatted ext4)" 10 70 "/dev/sda2") || exit 1
    EFI_PART=$(dialog --stdout --inputbox "EFI partition (leave blank for BIOS install)" 10 70 "/dev/sda1") || exit 1
    SWAP_PART=$(dialog --stdout --inputbox "Swap partition (optional)" 10 70 "") || exit 1

    [[ -b $ROOT_PART ]] || die "Root partition does not exist: $ROOT_PART"

    dialog --yesno "Format root partition $ROOT_PART as ext4?" 9 70 || die "Manual install requires formatting root in this script."
    run mkfs.ext4 -F "$ROOT_PART"
    run mount "$ROOT_PART" "$TARGET"
    run mkdir -p "$TARGET/boot/efi"

    if [[ -n $EFI_PART ]]; then
        [[ -b $EFI_PART ]] || die "EFI partition does not exist: $EFI_PART"
        run mkfs.vfat -F32 "$EFI_PART"
        run mount "$EFI_PART" "$TARGET/boot/efi"
    fi

    if [[ -n $SWAP_PART ]]; then
        [[ -b $SWAP_PART ]] || die "Swap partition does not exist: $SWAP_PART"
        run mkswap "$SWAP_PART"
        run swapon "$SWAP_PART"
    fi
}

disk_setup() {
    pick_disk
    local mode
    mode=$(dialog --stdout --menu "Disk setup mode" 15 70 6 \
        "auto-btrfs" "Automatic Btrfs (Timeshift-friendly)" \
        "manual" "Manual partition selection") || exit 1

    case "$mode" in
        auto-btrfs) auto_partition_btrfs ;;
        manual) manual_partition ;;
        *) die "Unknown disk mode: $mode" ;;
    esac
}

select_desktop() {
    DESKTOP=$(dialog --stdout --menu "Optional desktop environment" 16 72 7 \
        "none" "No desktop install" \
        "mate" "MATE desktop" \
        "xfce" "Xfce desktop" \
        "lxqt" "LXQt desktop" \
        "cinnamon" "Cinnamon desktop") || exit 1
}

select_xlibre() {
    if dialog --yesno "Install XLibre repository configuration?" 9 60; then
        INSTALL_XLIBRE=yes
    else
        INSTALL_XLIBRE=no
    fi
}

gen_fstab() {
    local out="$TARGET/etc/fstab"
    : >"$out"
    local src tgt fstype opts uuid
    while read -r src tgt fstype opts; do
        [[ $tgt == "$TARGET" || $tgt == "$TARGET"/* ]] || continue
        uuid=$(blkid -s UUID -o value "${src%%[*}") || continue
        tgt=${tgt#"$TARGET"}
        [[ -n $tgt ]] || tgt=/
        local pass=0
        [[ $tgt == / ]] && pass=1
        printf 'UUID=%s %s %s %s 0 %s\n' "$uuid" "$tgt" "$fstype" "$opts" "$pass" >>"$out"
    done < <(findmnt -Rrn -o SOURCE,TARGET,FSTYPE,OPTIONS "$TARGET")
    if [[ -n ${SWAP_PART:-} ]]; then
        printf 'UUID=%s none swap defaults 0 0\n' "$(blkid -s UUID -o value "$SWAP_PART")" >>"$out"
    fi
    printf 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0\n' >>"$out"
}

install_base() {
    run mkdir -p "$TARGET/etc" "$TARGET/var/db/xbps/keys"

    # resolv.conf may be a symlink on the live ISO; copy the real content.
    run rm -f "$TARGET/etc/resolv.conf"
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" 2>>"$LOG" || true
    if [[ ! -s "$TARGET/etc/resolv.conf" ]]; then
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$TARGET/etc/resolv.conf"
    fi

    # The live ISO's xbps is often outdated, and xbps refuses every other
    # transaction until it is updated. Update it first (also syncs repos).
    run xbps-install -Syu xbps

    # With `-r $TARGET`, xbps reads its repo config from $TARGET/etc/xbps.d,
    # NOT from the live ISO. If that is empty xbps has no repositories and
    # silently installs nothing. Copy the live system's repo config over.
    run mkdir -p "$TARGET/etc/xbps.d"
    local f
    for f in /usr/share/xbps.d/*.conf /etc/xbps.d/*.conf; do
        [[ -f $f ]] && cp -L "$f" "$TARGET/etc/xbps.d/" 2>>"$LOG"
    done
    if ! grep -qsh '^repository=' "$TARGET"/etc/xbps.d/*.conf; then
        echo 'repository=https://repo-default.voidlinux.org/current' >"$TARGET/etc/xbps.d/00-repository-main.conf"
    fi

    # Reuse the live system's trusted repo keys for the new root.
    cp -a /var/db/xbps/keys/. "$TARGET/var/db/xbps/keys/" 2>>"$LOG" || true

    local pkgs=(base-system linux linux-firmware grub efibootmgr dialog sudo)
    pkgs+=(grub-x86_64-efi btrfs-progs dhcpcd)

    run xbps-install -Sy -r "$TARGET" "${pkgs[@]}"
    gen_fstab
    run xbps-reconfigure -r "$TARGET" -fa
}

configure_system() {
    echo "$HOSTNAME" >"$TARGET/etc/hostname"
    cat >"$TARGET/etc/locale.conf" <<EOF
LANG=$LOCALE
EOF

    if grep -q '^#\?KEYMAP=' "$TARGET/etc/rc.conf" 2>/dev/null; then
        sed -i "s/^#\?KEYMAP=.*/KEYMAP=\"$KEYMAP\"/" "$TARGET/etc/rc.conf"
    else
        echo "KEYMAP=\"$KEYMAP\"" >>"$TARGET/etc/rc.conf"
    fi

    cat >"$TARGET/etc/default/libc-locales" <<EOF
$LOCALE UTF-8
EOF

    run ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"

    if [[ -e "$TARGET/etc/sv/dhcpcd" ]]; then
        run ln -sf /etc/sv/dhcpcd "$TARGET/etc/runit/runsvdir/default/"
    fi

    run chroot "$TARGET" xbps-reconfigure -f glibc-locales
}

install_optional_components() {
    if [[ $INSTALL_XLIBRE == yes ]]; then
        run mkdir -p "$TARGET/var/db/xbps/keys"
        fetch_file "https://github.com/xlibre-void/xlibre/raw/refs/heads/main/repo-keys/x86_64/00:ca:42:57:c9:c0:9a:ec:94:b4:7d:97:e5:a9:aa:1e.plist" \
            "$TARGET/var/db/xbps/keys/00:ca:42:57:c9:c0:9a:ec:94:b4:7d:97:e5:a9:aa:1e.plist"
        run chroot "$TARGET" mkdir -p /etc/xbps.d
        cat >"$TARGET/etc/xbps.d/99-repository-xlibre.conf" <<EOF
repository=https://github.com/xlibre-void/xlibre/releases/latest/download
EOF
        run chroot "$TARGET" xbps-install -Sy
    fi

    case "$DESKTOP" in
        mate)
            run chroot "$TARGET" xbps-install -Sy xorg mate mate-extra lightdm lightdm-gtk3-greeter octoxbps
            ;;
        xfce)
            run chroot "$TARGET" xbps-install -Sy xorg xfce4 xfce4-goodies lightdm lightdm-gtk3-greeter octoxbps
            ;;
        lxqt)
            run chroot "$TARGET" xbps-install -Sy xorg lxqt sddm octoxbps
            ;;
        cinnamon)
            run chroot "$TARGET" xbps-install -Sy xorg cinnamon lightdm lightdm-gtk3-greeter octoxbps
            ;;
        none)
            ;;
    esac

    if [[ $DESKTOP != none ]]; then
        if [[ -e "$TARGET/etc/sv/dbus" ]]; then
            run ln -sf /etc/sv/dbus "$TARGET/etc/runit/runsvdir/default/"
        fi
        if [[ -e "$TARGET/etc/sv/lightdm" ]]; then
            run ln -sf /etc/sv/lightdm "$TARGET/etc/runit/runsvdir/default/"
        fi
        if [[ -e "$TARGET/etc/sv/sddm" ]]; then
            run ln -sf /etc/sv/sddm "$TARGET/etc/runit/runsvdir/default/"
        fi
    fi
}

setup_bootloader() {
    if [[ -n $EFI_PART && -d /sys/firmware/efi ]]; then
        run chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="VoidLinux"
    else
        [[ -n $DISK ]] || DISK=$(dialog --stdout --inputbox "Enter disk for BIOS grub install (e.g. /dev/sda)" 10 70 "/dev/sda")
        run chroot "$TARGET" grub-install "$DISK"
    fi
    run chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg
}

set_passwords_and_users() {
    msgbox "Set root password in the next prompt." 7 55
    chroot_interactive passwd

    if dialog --yesno "Create a regular user?" 8 50; then
        local user
        user=$(dialog --stdout --inputbox "Username" 10 50 "user") || exit 1
        [[ -n $user ]] || die "Username cannot be empty."
        run chroot "$TARGET" useradd -m -G wheel,audio,video,input "$user"
        msgbox "Set password for user '$user' in the next prompt." 8 60
        chroot_interactive passwd "$user"
        run chroot "$TARGET" sh -c "echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel"
        run chroot "$TARGET" chmod 440 /etc/sudoers.d/10-wheel
    fi
}

finalize() {
    umount_chroot_fs
    msgbox "Installation complete.\n\nYou can reboot after reviewing $LOG." 10 70
}

main_menu_summary() {
    msgbox "Summary:\n\nKeymap: $KEYMAP\nHostname: $HOSTNAME\nLocale: $LOCALE\nTimezone: $TIMEZONE\nDesktop: $DESKTOP\nXLibre: $INSTALL_XLIBRE" 15 70
}

main() {
    require_root
    require_tools
    init_log
    confirm_start

    select_keymap
    network_step
    select_hostname
    select_locale
    select_timezone
    disk_setup
    select_xlibre
    select_desktop
    main_menu_summary

    install_base
    mount_chroot_fs
    configure_system
    install_optional_components
    setup_bootloader
    set_passwords_and_users
    finalize
}

trap 'die "Unexpected error at line $LINENO"' ERR

main "$@"