#!/bin/bash
# prepare-sd.sh — offline prepare of a flashed Raspberry Pi OS SD card for a tracker box.
#
#   usage:  sudo ./prepare-sd.sh [DEVICE] [A|B] [--console-login]
#
#   --console-login  nainstaluje autologin na tty1 (login shell uživatele pi
#                    bez hesla). Pro box B, kde je sampler headless: k přípravě
#                    a ladění u TV s klávesnicí. X relace se NEinstaluje —
#                    box B nemá binárku tracker (viz box-provision.sh).
#
#   A -> Tracker (webcam, headless): tracker.service, no X autostart
#        (pro obraz na připojené TV až na boxu: sudo ./box-console.sh on)
#   B -> Sampler (headless RF sample player, 433 MHz) via systemd service
#
# Box C was removed (2-box system: A + B).
#
# For every box: hostname = box letter, SSH enabled, user pi/raspberry,
# first-boot provisioning auto-installs deps and self-disables.
# Requires: sudo. Run on the same laptop after dd-burning the base image.
#
# Statická adresa a WiFi se zapisují rovnou do image (box-network.sh), ať na
# boxu netřeba hledat DHCP:
#   BOX_WIFI_SSID=... BOX_WIFI_PSK=... sudo ./prepare-sd.sh /dev/mmcblk0 B
# Výchozí IP je 192.168.8.103 (B) / 192.168.8.104 (A), gateway 192.168.8.1.
# POZOR: .102 nedávat — to je bazina, notebook, ze kterého tohle připravuješ.
#
# Chceš-li stejný image pustit napřed v QEMU, použij místo toho
# ./qemu_raspi4.sh prepare --box B --wifi ... a pak burn.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

DEV="${1:-/dev/mmcblk0}"
BOX="${2:-A}"
# --console-login je až třetí poziční argument (případně mezi nimi), aby se
# pořadí DEVICE BOX nepřepsalo.
shift $(( $# >= 2 ? 2 : $# )) 2>/dev/null || true
CONSOLE_LOGIN=0
for a in "$@"; do
    case "$a" in
        --console-login) CONSOLE_LOGIN=1 ;;
        *) die "unknown option: $a" ;;
    esac
done
case "$BOX" in
    A|B) ;;
    C) echo "ERROR: Box C was removed — only A (tracker) or B (sampler) exists" >&2; exit 1 ;;
    *) echo "ERROR: box must be A or B" >&2; exit 1 ;;
esac
HOSTNAME="$BOX"
USER="pi"
PASS="raspberry"

[ "$(id -u)" -eq 0 ] || die "Run with sudo"
[ -b "$DEV" ] || die "$DEV is not a block device"

BOOTP="$DEV"p1
ROOTP="$DEV"p2
[ -b "$BOOTP" ] && [ -b "$ROOTP" ] || die "Expected partitions ${DEV}p1 (bootfs) and ${DEV}p2 (rootfs)"

MNT="/mnt/box-prep"
BOOT="$MNT/boot"
ROOT="$MNT/root"

echo; echo "=== Preparing $(basename "$DEV") for Box $BOX (hostname: $HOSTNAME) ==="

for mnt in $(mount | awk -v d="$DEV" '$1 ~ "^"d"p[0-9]+$" {print $3}'); do
    echo "  Unmounting $mnt ..."
    umount "$mnt"
done
mkdir -p "$BOOT" "$ROOT"

trap 'sync; umount "$ROOT" 2>/dev/null || true; umount "$BOOT" 2>/dev/null || true; rmdir "$BOOT" "$ROOT" 2>/dev/null || true' EXIT

step() { echo; echo "== $* =="; }

# ── Common: boot partition (SSH + user) ─────────────────────────────
step "Mounting boot partition"
mount "$BOOTP" "$BOOT"

step "Enabling SSH + user $USER (password $PASS)"
touch "$BOOT/ssh"
HASH=$(openssl passwd -6 -stdin <<< "$PASS")
printf '%s:%s\n' "$USER" "$HASH" > "$BOOT/userconf.txt"
echo "  ssh + userconf.txt ready"

# Box B only: the sampler drives a 16x2 PCF8574 LCD over I2C on GPIO2/3 (/dev/i2c-1).
# Bookworm enables this by default, but state it so the LCD cannot be lost to a
# future image default change.
if [ "$BOX" = "B" ]; then
    step "Enabling I2C (LCD on GPIO2/3 -> /dev/i2c-1)"
    if grep -q '^dtparam=i2c_arm=on' "$BOOT/config.txt" 2>/dev/null; then
        echo "  dtparam=i2c_arm=on already present"
    else
        printf '\n# Box B: I2C LCD (PCF8574) on GPIO2/3\ndtparam=i2c_arm=on\n' >> "$BOOT/config.txt"
        echo "  dtparam=i2c_arm=on appended to config.txt"
    fi
fi

# ── Common: root partition ──────────────────────────────────────────
step "Mounting root partition"
mount "$ROOTP" "$ROOT"

step "Setting pi password directly in /etc/shadow (no wizard dependency)"
if grep -q "^$USER:" "$ROOT/etc/shadow"; then
    sed -i "s|^$USER:[^:]*:|$USER:$HASH:|" "$ROOT/etc/shadow"
    echo "  /etc/shadow pi password set"
else
    echo "  WARNING: no '$USER' in /etc/shadow — userconf.txt will handle it on first boot"
fi

step "Setting hostname to '$HOSTNAME'"
echo "$HOSTNAME" > "$ROOT/etc/hostname"
if grep -q '^127\.0\.1\.1' "$ROOT/etc/hosts"; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" "$ROOT/etc/hosts"
else
    printf '127.0.1.1\t%s\n' "$HOSTNAME" >> "$ROOT/etc/hosts"
fi
echo "  hostname -> $HOSTNAME"

step "Copying tracker source into image"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/home/$USER/tracker"
# samples/*.opus se prevadi na WAV jeste tady, na hostu — box pak nepotrebuje
# ffmpeg a pri startu neceka na nic. Prevod bezi pred rsyncem, aby se do
# image dostal uz hotovy WAV; jinak by tam byl samotny Opus, ktery
# SDL_mixer v Mix_LoadWAV nerozluje. Box A samply nehraje, takze se to
# preskakuje.
if [ "$BOX" = "B" ]; then
    sh "$SCRIPT_DIR/samples-decode.sh"
fi
# NOTE: host-built binaries MUST NOT be copied. `sampler`/`tracker` are gitignored
# but present in the working tree; rsync -a preserves their mtimes, so `make sampler`
# on the Pi would report "up to date" and install the x86-64 host binary.
# box-network.defaults je gitignorovaný, ale rsync -a ho bez výslovného
# vyloučení přenese do image. WiFi heslo by pak leželo v /home/$USER/tracker,
# čitelné uživatelem pi. Vzor (.example) v repu být smí.
rsync -a --delete \
      --exclude=rom/ --exclude=.git/ \
      --exclude=/sampler --exclude=/tracker \
      --exclude=/box-network.defaults \
      "$SCRIPT_DIR"/ "$ROOT/home/$USER/tracker/"
chown -R 1000:1000 "$ROOT/home/$USER/tracker"
if [ -e "$ROOT/home/$USER/tracker/sampler" ] || [ -e "$ROOT/home/$USER/tracker/tracker" ]; then
    die "host binary leaked into the image (rsync exclude broken)"
fi
# --exclude zabrání novému kopírování, ale starší image už v sobě ten soubor
# mělo (rsync s --delete by ho sice uklidil, jen pro jistotu a aby to loudně
# selhalo, kdyby se to změnilo).
if [ -e "$ROOT/home/$USER/tracker/box-network.defaults" ]; then
    die "WiFi heslo (box-network.defaults) prosaklo do image"
fi
echo "  source -> /home/$USER/tracker"

step "Cleaning previous box artifacts"
rm -f "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
rm -f "$ROOT/home/$USER/.bash_profile" "$ROOT/home/$USER/.xinitrc" "$ROOT/home/$USER/.tracker.log"
rm -f "$ROOT/etc/systemd/system/box-firstboot.service" "$ROOT/etc/systemd/system/boxa-firstboot.service"
rm -f "$ROOT/etc/systemd/system/box@firstboot.service"
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service" \
      "$ROOT/etc/systemd/system/multi-user.target.wants/boxa-firstboot.service"
rm -f "$ROOT/usr/local/sbin/box-provision.sh" "$ROOT/usr/local/sbin/boxa-provision.sh" \
      "$ROOT/usr/local/sbin/box-alsa-setup.sh" "$ROOT/usr/local/sbin/box-sound-restart.sh"
# WiFi profil z předchozího boxu by box držel na cizí síti / cizí adrese
rm -f "$ROOT"/etc/NetworkManager/system-connections/box-*.nmconnection
rm -f "$ROOT/etc/systemd/system/sampler.service" "$ROOT/usr/local/bin/sampler"
rm -f "$ROOT/etc/systemd/system/tracker.service" \
      "$ROOT/etc/systemd/system/multi-user.target.wants/tracker.service"
rm -f "$ROOT/etc/systemd/system/box-sound-restart.service" \
      "$ROOT/etc/udev/rules.d/99-box-sound.rules"
rm -f "$ROOT/var/lib/box-provisioned" "$ROOT/var/lib/boxa-provisioned"
echo "  removed stale autostart/provision/sampler/tracker files"

# Autologin na tty1 se instaluje AZ tady — výše ho tenhle blok právě smazal
# jako artefakt předchozího boxu. Bez posunu pořadí by si skript smazal to,
# co před chvílí nainstaloval.
if [ "$CONSOLE_LOGIN" = 1 ]; then
    step "Autologin na tty1 (login shell bez hesla)"
    install -d "$ROOT/etc/systemd/system/getty@tty1.service.d"
    install -m 0644 "$SCRIPT_DIR/getty-tty1-autologin.conf" \
        "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    echo "  getty@tty1.service.d/autologin.conf -> autologin pi"
    echo "  jen login shell: X relace se NEinstaluje, box B nemá tracker"
fi

step "Static IP + WiFi (NetworkManager keyfile)"
ABC38_NET_ROOT="$ROOT" "$SCRIPT_DIR/box-network.sh" "$BOX"

step "Headless autostart ($([ "$BOX" = A ] && echo 'tracker --headless' || echo "sampler --box $BOX"), systemd)"

# Provisioning je jeden skript pro oba boxy (box-provision.sh) — tady se jen
# kopíruje do image a zapíná se jako oneshot. Testy: tests/test-box-provision.sh
install -m 0755 box-provision.sh "$ROOT/usr/local/sbin/box-provision.sh"
cat > "$ROOT/etc/systemd/system/box-firstboot.service" <<EOF
[Unit]
Description=Box $BOX first-boot provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=BOX=$BOX
ExecStart=/usr/local/sbin/box-provision.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl --root "$ROOT" enable box-firstboot.service >/dev/null 2>&1 || \
    ln -s /etc/systemd/system/box-firstboot.service \
         "$ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service"
echo "  box-firstboot.service -> enabled (runs once on first boot, BOX=$BOX)"
case "$BOX" in
    A) echo "  tracker.service -> installed + enabled on first boot (headless, no X autostart)" ;;
    B) echo "  sampler.service -> installed + enabled on first boot (headless, 433 MHz)" ;;
esac

echo
echo "=== Done. Safely eject:  sudo eject /dev/mmcblk0  (or  sync && unmount) ==="
case "$BOX" in
    A) echo "  First boot: ~10-40 min auto-install, then tracker.service runs headless (no HDMI needed)." ;;
    B) echo "  First boot: ~5-15 min auto-install, then sampler --box b runs headless." ;;
esac
case "$BOX" in
    A) echo "  Box A: calibrate once over HDMI before playing — startx on tty1, drag corners, press S, then power-cycle." ;;
    B) echo "  Box B: 433 MHz codes -> journal:  journalctl -u sampler -f"
       echo "  Box B: naplánovat samply:          sudo ./sampler --box b --listen" ;;
esac
echo "  Requires: network (ether/wifi) for apt, USB sound card."