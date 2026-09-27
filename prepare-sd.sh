#!/bin/bash
# prepare-sd.sh — offline prepare of a flashed Raspberry Pi OS SD card for a tracker box.
#
#   usage:  sudo ./prepare-sd.sh [DEVICE] [A|B]
#
#   A -> Tracker (webcam, headless): tracker.service, no X autostart
#   B -> Sampler (headless RF sample player) via systemd service
#
# Box C was removed (2-box system: A + B).
#
# For every box: hostname = box letter, SSH enabled, user pi/raspberry,
# first-boot provisioning auto-installs deps and self-disables.
# Requires: sudo. Run on the same laptop after dd-burning the base image.

set -euo pipefail

DEV="${1:-/dev/mmcblk0}"
BOX="${2:-A}"
case "$BOX" in
    A|B) ;;
    C) echo "ERROR: Box C was removed — only A (tracker) or B (sampler) exists" >&2; exit 1 ;;
    *) echo "ERROR: box must be A or B" >&2; exit 1 ;;
esac
HOSTNAME="$BOX"
USER="pi"
PASS="raspberry"

die() { echo "ERROR: $*" >&2; exit 1; }
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
rsync -a --delete --exclude=rom/ --exclude=.git/ "$SCRIPT_DIR"/ "$ROOT/home/$USER/tracker/"
chown -R 1000:1000 "$ROOT/home/$USER/tracker"
echo "  source -> /home/$USER/tracker"

step "Cleaning previous box artifacts"
rm -f "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
rm -f "$ROOT/home/$USER/.bash_profile" "$ROOT/home/$USER/.xinitrc" "$ROOT/home/$USER/.tracker.log"
rm -f "$ROOT/etc/systemd/system/box-firstboot.service" "$ROOT/etc/systemd/system/boxa-firstboot.service"
rm -f "$ROOT/etc/systemd/system/box@firstboot.service"
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service" \
      "$ROOT/etc/systemd/system/multi-user.target.wants/boxa-firstboot.service"
rm -f "$ROOT/usr/local/sbin/box-provision.sh" "$ROOT/usr/local/sbin/boxa-provision.sh" \
      "$ROOT/usr/local/sbin/box-alsa-setup.sh"
rm -f "$ROOT/etc/systemd/system/sampler.service" "$ROOT/usr/local/bin/sampler"
rm -f "$ROOT/etc/systemd/system/tracker.service" \
      "$ROOT/etc/systemd/system/multi-user.target.wants/tracker.service"
rm -f "$ROOT/var/lib/box-provisioned" "$ROOT/var/lib/boxa-provisioned"
echo "  removed stale autostart/provision/sampler/tracker files"

provision_box_a() {
    step "Headless autostart (tracker --headless, systemd)"
    cat > "$ROOT/usr/local/sbin/box-provision.sh" <<'EOF'
#!/bin/bash
set -e
echo "[boxa] == first-boot provisioning =="
logger "boxa provisioning start"
cd /home/pi/tracker
bash install-deps.sh
# X + mesa stay installed so calibration can still be run over HDMI by hand
# (startx on tty1, then ./tracker with a window and the S key). Nothing starts
# the GUI automatically any more.
apt-get install -y --no-install-recommends \
    xinit xserver-xorg xserver-xorg-video-fbdev x11-xserver-utils libgl1-mesa-dri >/dev/null
usermod -aG audio,video $USER
# ALSA devices must be named and the default set before the service opens the card
install -m 0755 box-alsa-setup.sh /usr/local/sbin/box-alsa-setup.sh
/usr/local/sbin/box-alsa-setup.sh
install -m 0644 tracker.service /etc/systemd/system/tracker.service
systemctl daemon-reload
systemctl enable tracker.service
systemctl start tracker.service
touch /var/lib/box-provisioned
systemctl disable box-firstboot.service
logger "boxa provisioning complete"
EOF
    chmod 755 "$ROOT/usr/local/sbin/box-provision.sh"
    cat > "$ROOT/etc/systemd/system/box-firstboot.service" <<'EOF'
[Unit]
Description=Box A first-boot provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/box-provision.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl --root "$ROOT" enable box-firstboot.service >/dev/null 2>&1 || \
        ln -s /etc/systemd/system/box-firstboot.service \
             "$ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service"
    echo "  box-firstboot.service -> enabled (runs once on first boot)"
    echo "  tracker.service -> installed + enabled (headless, no X autostart)"
}

provision_box_sampler() {
    step "Headless autostart (sampler --box $BOX, systemd)"
    cat > "$ROOT/usr/local/sbin/box-provision.sh" <<EOF
#!/bin/bash
set -e
echo "[box$BOX] == first-boot provisioning (sampler) =="
logger "box$BOX provisioning start"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    g++ make pkg-config git ca-certificates \
    libsdl2-dev libsdl2-mixer-dev libgpiod-dev
cd /home/pi/tracker
make sampler
install -m 0755 sampler /usr/local/bin/sampler
[ -f mapa.csv ] || cp -n mapa.csv.example mapa.csv
install -m 0644 sampler.service /etc/systemd/system/sampler.service
sed -i 's/--box .*/--box $BOX/' /etc/systemd/system/sampler.service
systemctl daemon-reload
# ALSA devices must be named and the default set before the service opens the card
install -m 0755 box-alsa-setup.sh /usr/local/sbin/box-alsa-setup.sh
/usr/local/sbin/box-alsa-setup.sh
systemctl enable sampler.service
systemctl start sampler.service
touch /var/lib/box-provisioned
systemctl disable box-firstboot.service
logger "box$BOX provisioning complete"
EOF
    chmod 755 "$ROOT/usr/local/sbin/box-provision.sh"
    cat > "$ROOT/etc/systemd/system/box-firstboot.service" <<'EOF'
[Unit]
Description=Box first-boot provisioning (sampler build)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/box-provision.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl --root "$ROOT" enable box-firstboot.service >/dev/null 2>&1 || \
        ln -s /etc/systemd/system/box-firstboot.service \
             "$ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service"
    echo "  box-firstboot.service -> enabled (builds + starts sampler on first boot)"
}

case "$BOX" in
    A) provision_box_a ;;
    B) provision_box_sampler ;;
esac

echo
echo "=== Done. Safely eject:  sudo eject /dev/mmcblk0  (or  sync && unmount) ==="
case "$BOX" in
    A) echo "  First boot: ~10-40 min auto-install, then tracker.service runs headless (no HDMI needed)." ;;
    B) echo "  First boot: ~5-15 min auto-install, then sampler --box B runs headless." ;;
esac
echo "  Box A: calibrate once over HDMI before playing — startx on tty1, drag corners, press S, then power-cycle."
echo "  Requires: network (ether/wifi) for apt, USB sound card."