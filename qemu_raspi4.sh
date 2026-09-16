#!/bin/bash
# qemu_raspi4.sh — Test Raspberry Pi 4 image in QEMU before burning to SD card
#
# Usage:
#   ./qemu_raspi4.sh setup              Install prerequisites + download assets
#   ./qemu_raspi4.sh prepare [image]    Configure image (SSH, user, tracker source)
#   ./qemu_raspi4.sh run    [image]     Boot image in QEMU
#   ./qemu_raspi4.sh burn   <device>    Write prepared image to SD card
#
# All downloaded assets live in rom/ (gitignored).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROM_DIR="$SCRIPT_DIR/rom"
IMG_PATTERN="$ROM_DIR/raspios-*.img"

FIRMWARE_BASE="https://github.com/raspberrypi/firmware/raw/master/boot"
OVERLAY_BASE="$FIRMWARE_BASE/overlays"
RPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz"
KERNEL_IMG="kernel8.img"
DTB_FILE="bcm2711-rpi-4-b.dtb"
DTB_PATCHED="bcm2711-rpi-4-b-patched.dtb"
OVERLAYS="disable-bt.dtbo dwc-otg-deprecated.dtbo"
SSH_PORT=2222
RPI_USER="pi"
RPI_PASS="raspberry"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "This step requires root. Run with sudo."; }

step() { echo; echo "=== $* ==="; }

find_image() {
    local img
    if [ -n "$1" ]; then img="$1"; else img=$(ls $IMG_PATTERN 2>/dev/null | head -1); fi
    [ "$(basename "$img")" = "$KERNEL_IMG" ] && die "Refusing to use $KERNEL_IMG (kernel, not a disk image)."
    [ -n "$img" ] && [ -f "$img" ] || die "No image found. Run 'setup' first or pass an image path."
    echo "$img"
}

# ─────────────────────────────────────────────────────────────
# 1. SETUP — install prerequisites and download assets
# ─────────────────────────────────────────────────────────────
setup() {
    step "Installing prerequisites (Manjaro/Arch)"
    if ! command -v qemu-system-aarch64 >/dev/null; then
        sudo pacman -S --noconfirm qemu-system-aarch64
    else
        echo "qemu-system-aarch64 already installed"
    fi
    for c in wget unxz qemu-img fdtoverlay openssl; do
        command -v "$c" >/dev/null || die "Missing required tool: $c"
    done

    mkdir -p "$ROM_DIR"

    step "Downloading RPi 4 kernel and firmware"
    for f in "$KERNEL_IMG" "$DTB_FILE"; do
        if [ ! -f "$ROM_DIR/$f" ]; then
            echo "  Fetching $f ..."
            wget -q --show-progress -O "$ROM_DIR/$f" "$FIRMWARE_BASE/$f"
        else
            echo "  $f already present"
        fi
    done
    for f in $OVERLAYS; do
        if [ ! -f "$ROM_DIR/$f" ]; then
            echo "  Fetching overlays/$f ..."
            wget -q --show-progress -O "$ROM_DIR/$f" "$OVERLAY_BASE/$f"
        else
            echo "  $f already present"
        fi
    done

    step "Patching DTB for QEMU (USB + bluetooth)"
    if [ ! -f "$ROM_DIR/$DTB_PATCHED" ]; then
        for o in $OVERLAYS; do
            [ -f "$ROM_DIR/$o" ] || die "Missing overlay: $o"
        done
        fdtoverlay -i "$ROM_DIR/$DTB_FILE" -o "$ROM_DIR/$DTB_PATCHED" \
            $(for o in $OVERLAYS; do echo "$ROM_DIR/$o"; done)
        echo "  Patched -> $DTB_PATCHED"
    else
        echo "  $DTB_PATCHED already present"
    fi

    step "Downloading Raspberry Pi OS Lite (arm64)"
    local XZ="$ROM_DIR/raspios-bookworm-arm64-lite.img.xz"
    local IMG="$ROM_DIR/raspios-bookworm-arm64-lite.img"
    if [ ! -f "$IMG" ]; then
        if [ ! -f "$XZ" ]; then
            echo "  Fetching RPi OS Lite (Bookworm arm64) ..."
            wget --show-progress -O "$XZ" "$RPIOS_URL"
        fi
        echo "  Decompressing (~1-2 min) ..."
        unxz -k "$XZ"
    else
        echo "  Image already present"
    fi

    local SIZE_MB
    SIZE_MB=$(qemu-img info "$IMG" | awk '/disk size/{print $3}')
    step "Resizing image to 8G (was ${SIZE_MB}M)"
    qemu-img resize "$IMG" 8G
    echo "  Done. Use:  ./qemu_raspi4.sh prepare"
}

# ─────────────────────────────────────────────────────────────
# 2. PREPARE — enable SSH, create user, copy tracker source
# ─────────────────────────────────────────────────────────────
prepare() {
    need_root
    local IMG IMG_ABS
    IMG=$(find_image "$1")
    IMG_ABS=$(readlink -f "$IMG")

    step "Preparing image: $(basename "$IMG")"

    local BOOT_MNT=$(mktemp -d)
    local ROOT_MNT=$(mktemp -d)
    local LOOP=""

    # Attach loop device with partition mapping
    LOOP=$(losetup -f --show -P "$IMG_ABS")

    step "Enabling SSH + creating user $RPI_USER"
    mount "${LOOP}p1" "$BOOT_MNT"
    touch "$BOOT_MNT/ssh"
    echo "  SSH enabled on boot partition"

    local HASH
    HASH=$(openssl passwd -6 -stdin <<< "$RPI_PASS")
    printf '%s:%s\n' "$RPI_USER" "$HASH" > "$BOOT_MNT/userconf.txt"
    echo "  User created: $RPI_USER / $RPI_PASS"
    umount "$BOOT_MNT"

    step "Copying tracker source into image"
    mount "${LOOP}p2" "$ROOT_MNT"
    mkdir -p "$ROOT_MNT/home/$RPI_USER/tracker"
    rsync -a --exclude=rom/ "$SCRIPT_DIR"/ "$ROOT_MNT/home/$RPI_USER/tracker/"
    chown -R 1000:1000 "$ROOT_MNT/home/$RPI_USER/tracker"
    umount "$ROOT_MNT"

    losetup -d "$LOOP"
    rmdir "$BOOT_MNT" "$ROOT_MNT"

    echo "  Done. Boot with:  ./qemu_raspi4.sh run"
}

# ─────────────────────────────────────────────────────────────
# 3. RUN — boot the image in QEMU
# ─────────────────────────────────────────────────────────────
run() {
    local IMG
    IMG=$(find_image "$1")
    [ -f "$ROM_DIR/$KERNEL_IMG" ] || die "Missing $KERNEL_IMG. Run setup first."
    [ -f "$ROM_DIR/$DTB_PATCHED" ] || die "Missing $DTB_PATCHED. Run setup first."

    step "Booting $(basename "$IMG") in QEMU (raspi4b)"
    echo "  Ctrl-A X  to quit QEMU"
    echo "  SSH:      ssh -p $SSH_PORT $RPI_USER@localhost  (pass: $RPI_PASS)"
    echo

    exec qemu-system-aarch64 \
        -machine raspi4b \
        -m 2G \
        -smp 4 \
        -kernel "$ROM_DIR/$KERNEL_IMG" \
        -dtb "$ROM_DIR/$DTB_PATCHED" \
        -drive if=sd,format=raw,file="$IMG" \
        -nographic \
        -serial mon:stdio \
        -no-reboot \
        -usb \
        -device usb-kbd \
        -device usb-net,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -append "root=/dev/mmcblk1p2 rootwait rw console=ttyAMA1,115200"
}

# ─────────────────────────────────────────────────────────────
# 4. BURN — write image to SD card
# ─────────────────────────────────────────────────────────────
burn() {
    need_root
    local DEV="$1"
    local IMG
    IMG=$(find_image "")
    [ -b "$DEV" ] || die "Device $DEV is not a block device"
    [ "${DEV:0:5}" = "/dev/" ] || die "Expected a /dev/ device, got: $DEV"

    step "Burning $(basename "$IMG") to $DEV"
    echo "  !!! This will DESTROY all data on $DEV !!!"
    read -r -p "Type YES to continue: " REPLY
    [ "$REPLY" = "YES" ] || die "Aborted."

    dd if="$IMG" of="$DEV" bs=4M status=progress conv=fsync
    sync
    echo "  Done — SD card ready."
}

# ─────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $(basename "$0") {setup|prepare|run|burn}"
    echo
    echo "  setup              Install qemu + download kernel/DTB/RPi OS image into rom/"
    echo "  prepare [image]    Enable SSH, create user, copy tracker source into image"
    echo "  run    [image]     Boot image in QEMU (SSH on port $SSH_PORT)"
    echo "  burn   <device>    Write prepared image to SD card (e.g. /dev/sdX)"
}

CMD="${1:-}"
shift 2>/dev/null || true
case "$CMD" in
    setup)   setup ;;
    prepare) prepare "$@" ;;
    run)     run "$@" ;;
    burn)    burn "$@" ;;
    *) usage ;;
esac