#!/bin/bash
# update-boxa-sd.sh — Offline aktualizace SD karty Boxu A ze čtečky (t520 / phaser)
#
# Použití:
#   sudo ./update-boxa-sd.sh [MOUNT_POINT_NEBO_DEVICE]
#
# Příklad:
#   sudo ./update-boxa-sd.sh
#   sudo ./update-boxa-sd.sh /run/media/kof/rootfs
#   sudo ./update-boxa-sd.sh /dev/sda2

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Skript vyžaduje práva roota, spouštím přes sudo..."
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"

# Ochrana proti přepsání kořenového disku hostitele (např. /dev/mmcblk0p2 eMMC na phaser)
HOST_ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
HOST_ROOT_DISK="$(lsblk -no PKNAME "$HOST_ROOT_DEV" 2>/dev/null | head -n1 || true)"
is_host_root_dev() {
    local dev="$1"
    local pk
    [ -n "$HOST_ROOT_DEV" ] && [ "$dev" = "$HOST_ROOT_DEV" ] && return 0
    pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)"
    [ -n "$HOST_ROOT_DISK" ] && [ -n "$pk" ] && [ "$pk" = "$HOST_ROOT_DISK" ] && return 0
    return 1
}

# 1. Hledání přípojného bodu rootfs SD karty
ROOTFS=""
CLEANUP_UMOUNT=""

if [ -n "$TARGET" ]; then
    if [ -d "$TARGET" ]; then
        REAL_TARGET="$(readlink -f "$TARGET" 2>/dev/null || echo "$TARGET")"
        if [ "$REAL_TARGET" = "/" ]; then
            echo "ERROR: Odmítám aktualizovat kořenový systém hostitele ('/')!" >&2
            exit 1
        fi
        if [ -d "$TARGET/etc" ]; then
            ROOTFS="$TARGET"
        else
            echo "ERROR: Zadaný adresář '$TARGET' nevypadá jako rootfs (chybí etc/)!" >&2
            exit 1
        fi
    elif [ -b "$TARGET" ]; then
        if is_host_root_dev "$TARGET"; then
            echo "ERROR: Odmítám zapsat na systémový disk hostitele '$TARGET'!" >&2
            exit 1
        fi
        MNT="/tmp/mnt_boxa_sd_$$"
        mkdir -p "$MNT"
        mount "$TARGET" "$MNT"
        ROOTFS="$MNT"
        CLEANUP_UMOUNT="$MNT"
    else
        echo "ERROR: Zadaný cíl '$TARGET' není adresář rootfs ani blokové zařízení!" >&2
        exit 1
    fi
else
    # Automatická detekce: 1) připojené rootfs
    for candidate in /run/media/*/rootfs /media/*/rootfs /mnt/*/rootfs; do
        if [ -d "$candidate/etc" ]; then
            ROOTFS="$candidate"
            break
        fi
    done

    # 2) Nepřipojený oddíl s LABEL=rootfs mimo kořenový disk hostitele (např. USB čtečka /dev/sda2)
    if [ -z "$ROOTFS" ]; then
        while read -r dev label _pk; do
            [ "$label" = "rootfs" ] || continue
            is_host_root_dev "$dev" && continue
            MNT="/tmp/mnt_boxa_sd_$$"
            mkdir -p "$MNT"
            mount "$dev" "$MNT"
            ROOTFS="$MNT"
            CLEANUP_UMOUNT="$MNT"
            break
        done < <(lsblk -nrpo NAME,LABEL,PKNAME 2>/dev/null || true)
    fi

    # 3) Záložní fallback /dev/mmcblk0p2 pouze pokud NEPATŘÍ kořenovému disku hostitele
    if [ -z "$ROOTFS" ] && [ -b /dev/mmcblk0p2 ] && ! is_host_root_dev /dev/mmcblk0p2; then
        MNT="/tmp/mnt_boxa_sd_$$"
        mkdir -p "$MNT"
        mount /dev/mmcblk0p2 "$MNT"
        ROOTFS="$MNT"
        CLEANUP_UMOUNT="$MNT"
    fi
fi

if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS/etc" ]; then
    echo "ERROR: Nelze nalézt rootfs SD karty!" >&2
    echo "Zasuň SD kartu do čtečky nebo zadej přípojný bod:" >&2
    echo "  sudo ./update-boxa-sd.sh /cesta/k/rootfs" >&2
    exit 1
fi

echo "== Aktualizace SD karty Boxu A na $ROOTFS =="

cleanup() {
    if [ -n "$CLEANUP_UMOUNT" ] && [ -d "$CLEANUP_UMOUNT" ]; then
        echo "Odpojuji dočasný přípojný bod $CLEANUP_UMOUNT..."
        umount "$CLEANUP_UMOUNT" || true
        rmdir "$CLEANUP_UMOUNT" || true
    fi
}
trap cleanup EXIT

# 2. Cílový adresář aplikace na SD kartě
APP_DIR=""
for cand in "$ROOTFS/home/pi/tracker" "$ROOTFS/home/kof/src/1938ABC"; do
    if [ -d "$cand" ]; then
        APP_DIR="$cand"
        break
    fi
done

if [ -z "$APP_DIR" ]; then
    APP_DIR="$ROOTFS/home/pi/tracker"
    mkdir -p "$APP_DIR"
fi
echo "  Cílový adresář aplikace: $APP_DIR"

# 3. Kopírování konfigurace map.csv (obsahuje 3458577, Sokol_D.wav)
echo "  Kopíruji aktualizovaný map.csv..."
cp -f "$SCRIPT_DIR/map.csv" "$APP_DIR/map.csv"
chmod 644 "$APP_DIR/map.csv"

# 4. Kopírování a synchronizace zdrojových kódů
echo "  Kopíruji zdrojové kódy, third_party a skripty..."
cp -f "$SCRIPT_DIR"/*.c "$SCRIPT_DIR"/*.h "$SCRIPT_DIR"/Makefile "$APP_DIR/" 2>/dev/null || true
cp -rf "$SCRIPT_DIR/third_party" "$APP_DIR/" 2>/dev/null || true
cp -f "$SCRIPT_DIR"/samples-decode.sh "$APP_DIR/samples-decode.sh"
chmod 755 "$APP_DIR/samples-decode.sh"

# 5. Synchronizace vzorků (samples): nejdříve zajistit čerstvé WAV z Opus na hostu
echo "  Dekóduji a synchronizuji samples/ (Opus i WAV)..."
"$SCRIPT_DIR/samples-decode.sh" || true
mkdir -p "$APP_DIR/samples"
# Zkopírovat všechny .opus vzorky
cp -f "$SCRIPT_DIR"/samples/*.opus "$APP_DIR/samples/" 2>/dev/null || true
# Zkopírovat hotové .wav vzorky (včetně nových Inter_Samply_*)
cp -f "$SCRIPT_DIR"/samples/*.wav "$APP_DIR/samples/" 2>/dev/null || true

# Spustit decode skript uvnitř cíle pro vytvoření správných symlinků s diakritikou
(cd "$APP_DIR" && ./samples-decode.sh || true)

# 6. Reverzní SSH tunel (box-autossh) a SSH autorizace pro updater
echo "  Instaluji a povoluji box-autossh reverzní tunel (port 2224 na pesek.com)..."
echo "A" > "$ROOTFS/etc/box-identity"
if [ -f "$SCRIPT_DIR/box-autossh.sh" ]; then
    cp -f "$SCRIPT_DIR/box-autossh.sh" "$ROOTFS/usr/local/sbin/box-autossh.sh"
    chmod 755 "$ROOTFS/usr/local/sbin/box-autossh.sh"
fi
if [ -f "$SCRIPT_DIR/box-autossh.service" ]; then
    cp -f "$SCRIPT_DIR/box-autossh.service" "$ROOTFS/etc/systemd/system/box-autossh.service"
    mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sf "/etc/systemd/system/box-autossh.service" "$ROOTFS/etc/systemd/system/multi-user.target.wants/box-autossh.service"
fi
if [ -f "$SCRIPT_DIR/99-box-autossh.sh" ]; then
    mkdir -p "$ROOTFS/etc/NetworkManager/dispatcher.d"
    cp -f "$SCRIPT_DIR/99-box-autossh.sh" "$ROOTFS/etc/NetworkManager/dispatcher.d/99-box-autossh.sh"
    chmod 755 "$ROOTFS/etc/NetworkManager/dispatcher.d/99-box-autossh.sh"
fi
if [ -f "$SCRIPT_DIR/box_tunnel_key" ]; then
    mkdir -p "$ROOTFS/home/pi/.ssh"
    cp -f "$SCRIPT_DIR/box_tunnel_key" "$ROOTFS/home/pi/.ssh/id_ed25519"
    chmod 600 "$ROOTFS/home/pi/.ssh/id_ed25519"
    chmod 700 "$ROOTFS/home/pi/.ssh"
    chown -R 1000:1000 "$ROOTFS/home/pi/.ssh" 2>/dev/null || true
fi

USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$USER_HOME" ] || USER_HOME="${HOME:-/home/kof}"
if [ -f "$USER_HOME/.ssh/id_ed25519.pub" ]; then
    mkdir -p "$ROOTFS/home/pi/.ssh"
    touch "$ROOTFS/home/pi/.ssh/authorized_keys"
    PUBKEY="$(cat "$USER_HOME/.ssh/id_ed25519.pub")"
    grep -qxF "$PUBKEY" "$ROOTFS/home/pi/.ssh/authorized_keys" || printf '%s\n' "$PUBKEY" >> "$ROOTFS/home/pi/.ssh/authorized_keys"
    chmod 700 "$ROOTFS/home/pi/.ssh"
    chmod 600 "$ROOTFS/home/pi/.ssh/authorized_keys"
    chown -R 1000:1000 "$ROOTFS/home/pi/.ssh" 2>/dev/null || true
fi

# 7. WiFi síť a statická IP přes box-network.sh (Box A = .104 v kavárně, přepíše .103 z defaults)
echo "  Generuji WiFi profily pro divadlo (cafe) a domov (HUAWEI)..."
if [ -x "$SCRIPT_DIR/box-network.sh" ]; then
    BOX_IP=192.168.88.104 ABC38_NET_ROOT="$ROOTFS" "$SCRIPT_DIR/box-network.sh" A
fi

# 8. Nastavení vlastnictví pro uživatele pi (UID 1000)
chown -R 1000:1000 "$APP_DIR" 2>/dev/null || true

# 9. Bezpečný zápis na disk
echo "  Provádím sync disku..."
sync

echo "== Aktualizace SD karty Boxu A je HOTOVA! =="
echo "Karta je připravena k vložení do Boxu A v divadle."
