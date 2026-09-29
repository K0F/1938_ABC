#!/bin/bash
# qemu_raspi4.sh — Test Raspberry Pi 4 image in QEMU before burning to SD card
#
# Usage:
#   ./qemu_raspi4.sh setup              Install prerequisites + download assets
#   ./qemu_raspi4.sh prepare [image]    Configure image (SSH, user, box setup)
#   ./qemu_raspi4.sh run    [image]     Boot image in QEMU
#   ./qemu_raspi4.sh burn   <device>    Write prepared image to SD card
#
# Box identity (what the box is when it boots):
#   prepare --box A     tracker: tracker.service, camera, no X autostart
#   prepare --box B     sampler: sampler.service + 433 MHz EV1527 readout
#                       (bez --box se naprosto nic boxového neinstaluje —
#                        jen SSH, uživatel, zdrojáky a alsa-utils)
#
# Statická adresa boxu (jde i do QEMU testu):
#   prepare --box B --ip 192.168.8.103
#   prepare --box B --wifi SSID --wifi-pass HESLO --wifi-hidden
#   (bez --ip se adresa nechá DHCP; výchozí pro box B je 192.168.8.103)
#
# Test zvukové karty:
#   ./qemu_raspi4.sh audiotest          prepare --audio-test + run --audio
#   ./qemu_raspi4.sh report  [image]    Vypsat report z posledního běhu
#                                         (samostatný krok — run() končí exec)
#
# Flags:
#   prepare --audio-test   Navíc nainstalovat a zapnout oneshot, který po
#                          bootu pustí box-audio-test.sh a vypne stroj.
#                          Bez toho se image po bootu NEVYPNE.
#   run --audio            Přidat emulovanou USB zvukovku (QEMU usb-audio)
#                          a zapisovat hraný zvuk do rom/guest-audio.wav
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

# arm64 image je chrootitel jen když host umí spustit aarch64 binárky
check_binfmt() {
    local strict="${1:-warn}"
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && return 0
    local msg="binfmt_misc nezná aarch64 — chroot do arm64 image nebude fungovat"
    [ "$strict" = "strict" ] && die "$msg (je potřeba qemu-user-static a systemd-binfmt, nebo: sudo update-binfmts --enable qemu-aarch64)"
    echo "  POZOR: $msg" >&2
}

# ─────────────────────────────────────────────────────────────
# Image mount helpers
# ─────────────────────────────────────────────────────────────
IMG=""; IMG_LOOP=""; MOUNT_BOOT=""; MOUNT_ROOT=""

img_mount() {
    IMG="$(find_image "$1")"
    IMG="$(readlink -f "$IMG")"
    IMG_LOOP="$(losetup -f --show -P "$IMG")"
    MOUNT_BOOT="$(mktemp -d)"
    MOUNT_ROOT="$(mktemp -d)"
}

img_umount() {
    mountpoint -q "$MOUNT_BOOT" 2>/dev/null && umount "$MOUNT_BOOT"
    mountpoint -q "$MOUNT_ROOT" 2>/dev/null && umount "$MOUNT_ROOT"
    [ -n "$IMG_LOOP" ] && losetup -d "$IMG_LOOP"
    rmdir "$MOUNT_BOOT" "$MOUNT_ROOT" 2>/dev/null || true
    IMG=""; IMG_LOOP=""; MOUNT_BOOT=""; MOUNT_ROOT=""
}
trap img_umount EXIT

# apt uvnitř arm64 image — guest v QEMU nemá síť, takže jedeme přes host
chroot_apt() {
    local root="$1"; shift
    check_binfmt strict
    [ -d /proc/sys/fs/binfmt_misc ] || die "binfmt_misc neni namontovan: sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc"

    local saved_resolv=""
    if [ -f "$root/etc/resolv.conf" ]; then
        saved_resolv="$(mktemp)"
        cp -L "$root/etc/resolv.conf" "$saved_resolv"
    fi
    cp -L /etc/resolv.conf "$root/etc/resolv.conf"

    mount --bind /dev "$root/dev"
    mount -t proc proc "$root/proc"
    chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 update
    chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    chroot "$root" sh -c 'apt-get clean; rm -rf /var/lib/apt/lists/*'

    umount "$root/proc"; umount "$root/dev"
    if [ -n "$saved_resolv" ]; then
        mv "$saved_resolv" "$root/etc/resolv.conf"
        rm -f "$saved_resolv"
    fi
}

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
    local pkgs=()
    command -v qemu-system-aarch64 >/dev/null || pkgs+=(qemu-system-aarch64)
    command -v qemu-aarch64-static   >/dev/null || pkgs+=(qemu-user-static)
    command -v qemu-img              >/dev/null || pkgs+=(qemu-img)
    if [ ${#pkgs[@]} -gt 0 ]; then
        sudo pacman -S --noconfirm "${pkgs[@]}"
    else
        echo "qemu packages already installed"
    fi
    for c in wget unxz qemu-img fdtoverlay openssl; do
        command -v "$c" >/dev/null || die "Missing required tool: $c"
    done
    # qemu-user-static je potřeba jen na chroot do arm64 image (alsa-utils)
    check_binfmt warn

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
# 1b. BOX — identita boxu: hostname, first-boot provisioning, statická adresa
# ─────────────────────────────────────────────────────────────
# Box A = tracker (webkamera, headless), Box B = sampler (433 MHz tlačítka).
# Provisioning se do image instaluje jako oneshot (box-firstboot.service) a
# pustí se až na skutečném boxu — QEMU nemá síť, takže by apt/build stejně
# selhal. Image je tím připravený stejně jako u prepare-sd.sh, jen ho QEMU
# pustí naprázdno.
prepare_box() {
    if [ -z "$BOX" ]; then
        step "Box identity: žádná (jen SSH, uživatel, zdrojáky, alsa-utils)"
        echo "  pro box A/B použij:  $0 prepare --box A|B"
        return 0
    fi

    step "Box $BOX ($([ "$BOX" = A ] && echo tracker || echo sampler, 433 MHz))"

    # hostname = písmeno boxu, ať se na routeru pozná
    echo "$BOX" > "$MOUNT_ROOT/etc/hostname"
    if grep -q '^127\.0\.1\.1' "$MOUNT_ROOT/etc/hosts"; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$BOX/" "$MOUNT_ROOT/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$BOX" >> "$MOUNT_ROOT/etc/hosts"
    fi
    echo "  hostname -> $BOX"

    # pi heslo rovnou v /etc/shadow (první boot wizard tím nemusí řešit)
    local HASH2
    HASH2=$(openssl passwd -6 -stdin <<< "$RPI_PASS")
    if grep -q "^$RPI_USER:" "$MOUNT_ROOT/etc/shadow"; then
        sed -i "s|^$RPI_USER:[^:]*:|$RPI_USER:$HASH2:|" "$MOUNT_ROOT/etc/shadow"
        echo "  /etc/shadow: heslo $RPI_USER nastaveno"
    fi

    # staré boxové artefakty z jiného použití image
    rm -f "$MOUNT_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    rm -f "$MOUNT_ROOT/home/$RPI_USER/.bash_profile" "$MOUNT_ROOT/home/$RPI_USER/.xinitrc"
    rm -f "$MOUNT_ROOT/home/$RPI_USER/.tracker.log"
    rm -f "$MOUNT_ROOT/usr/local/sbin/box-provision.sh"
    rm -f "$MOUNT_ROOT/etc/systemd/system/box-firstboot.service"
    rm -f "$MOUNT_ROOT/etc/systemd/system/boxa-firstboot.service"
    rm -f "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service"
    rm -f "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/boxa-firstboot.service"
    rm -f "$MOUNT_ROOT/etc/systemd/system/sampler.service" "$MOUNT_ROOT/usr/local/bin/sampler"
    rm -f "$MOUNT_ROOT/etc/systemd/system/tracker.service" \
          "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/tracker.service"
    rm -f "$MOUNT_ROOT/etc/systemd/system/box-sound-restart.service" \
          "$MOUNT_ROOT/etc/udev/rules.d/99-box-sound.rules"
    rm -f "$MOUNT_ROOT/usr/local/sbin/box-alsa-setup.sh" \
          "$MOUNT_ROOT/usr/local/sbin/box-sound-restart.sh"
    rm -f "$MOUNT_ROOT/var/lib/box-provisioned" "$MOUNT_ROOT/var/lib/boxa-provisioned"
    # WiFi profil jiného boxu by držel box na staré síti / staré adrese
    rm -f "$MOUNT_ROOT"/etc/NetworkManager/system-connections/box-*.nmconnection
    echo "  staré boxové artefakty odstraněny"

    install -d "$MOUNT_ROOT/usr/local/sbin"
    install -m 0755 "$SCRIPT_DIR/box-provision.sh" "$MOUNT_ROOT/usr/local/sbin/box-provision.sh"

    cat > "$MOUNT_ROOT/etc/systemd/system/box-firstboot.service" <<EOF
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
    systemctl --root "$MOUNT_ROOT" enable box-firstboot.service >/dev/null 2>&1 || \
        ln -sf /etc/systemd/system/box-firstboot.service \
               "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/box-firstboot.service"
    echo "  box-firstboot.service -> enabled (BOX=$BOX)"

    # Proměnné, které už nejsou nastavené, se NEODEVZDÁVAJÍ — prázdné
    # BOX_WIFI_SSID= by v box-network.sh přepsalo profil z
    # box-network.defaults prázdnem, a box by skončil na eth0. Navíc se
    # box-network.sh volá i když je adresa prázdná a WiFi jen v defaults.
    local netenv=(
        "ABC38_NET_ROOT=$MOUNT_ROOT"
        "BOX_CONN_NAME=box-$BOX"
    )
    [ -n "$BOXIP" ]       && netenv+=("BOX_IP=$BOXIP")
    [ -n "$WIFI_SSID" ]   && netenv+=("BOX_WIFI_SSID=$WIFI_SSID")
    [ -n "$WIFI_PASS" ]   && netenv+=("BOX_WIFI_PSK=$WIFI_PASS")
    [ "$WIFI_HIDDEN" = 1 ] && netenv+=("BOX_WIFI_HIDDEN=$WIFI_HIDDEN")

    if [ -n "$BOXIP" ] || [ -n "$WIFI_SSID" ] || \
       [ -n "${ABC38_NET_DEFAULTS-}" ] || \
       [ -f "$SCRIPT_DIR/box-network.defaults" ]; then
        step "Statická adresa boxu"
        env "${netenv[@]}" "$SCRIPT_DIR/box-network.sh" "$BOX"
        echo "  QEMU síť nesimuluje, takže to ověříš až na skutečném boxu:"
        echo "    ip -4 addr show $([ -n "$WIFI_SSID" ] && echo wlan0 || \
              { grep -qs '^BOX_WIFI_SSID=.' "$SCRIPT_DIR/box-network.defaults" \
                2>/dev/null && echo wlan0 || echo eth0; })"
    fi
}

# ─────────────────────────────────────────────────────────────
# 2. PREPARE — enable SSH, create user, copy tracker source
# ─────────────────────────────────────────────────────────────
# shellcheck disable=SC2154   # BOX/BOXIP/... se nastavují v dispatchi na konci
prepare() {
    need_root
    img_mount "$1"

    step "Preparing image: $(basename "$IMG")"

    step "Enabling SSH + creating user $RPI_USER"
    mount "${IMG_LOOP}p1" "$MOUNT_BOOT"
    touch "$MOUNT_BOOT/ssh"
    echo "  SSH enabled on boot partition"

    local HASH
    HASH=$(openssl passwd -6 -stdin <<< "$RPI_PASS")
    printf '%s:%s\n' "$RPI_USER" "$HASH" > "$MOUNT_BOOT/userconf.txt"
    echo "  User created: $RPI_USER / $RPI_PASS"

    # Box B only: sampler jede na 16x2 LCD přes PCF8574 (I2C, GPIO2/3 ->
    # /dev/i2c-1). Bookworm to má zapnuté default, ale ať to nespadne kvůli
    # změně defaultu v nějakém budoucím image.
    if [ "$BOX" = "B" ]; then
        if grep -q '^dtparam=i2c_arm=on' "$MOUNT_BOOT/config.txt" 2>/dev/null; then
            echo "  I2C: dtparam=i2c_arm=on already in config.txt"
        else
            printf '\n# Box B: I2C LCD (PCF8574) on GPIO2/3\ndtparam=i2c_arm=on\n' \
                >> "$MOUNT_BOOT/config.txt"
            echo "  I2C: dtparam=i2c_arm=on appended to config.txt (LCD readout)"
        fi
    fi
    umount "$MOUNT_BOOT"

    step "Copying tracker source into image"
    mount "${IMG_LOOP}p2" "$MOUNT_ROOT"
    mkdir -p "$MOUNT_ROOT/home/$RPI_USER/tracker"
    # hostem sestavené binárky se do image nesmějí dostat: rsync -a jim nechá
    # mtime, takže "make sampler" na Pi by hlásil "up to date" a nainstaloval
    # x86-64 binárku, kterou systemd nespustí.
    # box-network.defaults je gitignorovaný, ale rsync -a ho bez výslovného
    # vyloučení přenese do image. WiFi heslo by pak bylo v /home/pi/tracker
    # čitelné na každým. Vzor (.example) v repu být smí.
    rsync -a --exclude=rom/ --exclude=.git/ \
          --exclude=/sampler --exclude=/tracker \
          --exclude=/box-network.defaults \
          "$SCRIPT_DIR"/ "$MOUNT_ROOT/home/$RPI_USER/tracker/"
    chown -R 1000:1000 "$MOUNT_ROOT/home/$RPI_USER/tracker"
    chmod +x "$MOUNT_ROOT/home/$RPI_USER/tracker"/*.sh
    # --exclude zabrání novému kopírování, ale starší image už v sobě ten
    # soubor mohl mít (rsync bez --delete by ho nechal ležet).
    rm -f "$MOUNT_ROOT/home/$RPI_USER/tracker/box-network.defaults"
    if [ -e "$MOUNT_ROOT/home/$RPI_USER/tracker/sampler" ] || \
       [ -e "$MOUNT_ROOT/home/$RPI_USER/tracker/tracker" ]; then
        die "host binary leaked into the image (rsync exclude broken)"
    fi
    if [ -e "$MOUNT_ROOT/home/$RPI_USER/tracker/box-network.defaults" ]; then
        die "WiFi heslo (box-network.defaults) prosaklo do image"
    fi
    echo "  Source synced to /home/$RPI_USER/tracker"

    step "Installing alsa-utils (aplay, speaker-test)"
    echo "  (guest v QEMU nemá síť, instalujeme přes chroot z hostu — chvíli to trvá)"
    chroot_apt "$MOUNT_ROOT" alsa-utils

    prepare_box

    if [ "$AUDIO_TEST" -eq 1 ]; then
        step "Enabling audio test oneshot"
        install -d "$MOUNT_ROOT/etc/systemd/system"
        cat > "$MOUNT_ROOT/etc/systemd/system/abc38-audio-test.service" <<EOF
[Unit]
Description=ABC38 sound card test (QEMU) — po testu vypne stroj
After=multi-user.target sound.target
Requires=multi-user.target

[Service]
Type=oneshot
WorkingDirectory=/home/$RPI_USER/tracker
Environment=REPORT=/home/$RPI_USER/tracker/audio-test-report.txt
ExecStart=/home/$RPI_USER/tracker/box-audio-test.sh
ExecStartPost=/bin/sync
ExecStartPost=/bin/systemctl poweroff
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
        ln -sf /etc/systemd/system/abc38-audio-test.service \
            "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/abc38-audio-test.service"
        echo "  abc38-audio-test.service zapnutý (stroj se po testu vypne)"
    fi

    umount "$MOUNT_ROOT"
    img_umount

    echo "  Done. Boot with:  ./qemu_raspi4.sh run"
    if [ "$AUDIO_TEST" -eq 1 ]; then
        echo "  Audio test:  ./qemu_raspi4.sh run --audio"
    fi
    return 0
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
    echo

    local AUDIO_ARGS=()
    if [ "$AUDIO" -eq 1 ]; then
        rm -f "$ROM_DIR/guest-audio.wav"
        # wav backend zahazuje vystup, ale zapisuje ho — muzeme tak overit,
        # ze host opravdu neco hral, neze aplay jen skoncil s 0.
        AUDIO_ARGS=(
            -audiodev "wav,id=snd0,path=$ROM_DIR/guest-audio.wav"
            -device "usb-audio,audiodev=snd0"
        )
        echo "  USB zvukovka: QEMU usb-audio (card host string 'QEMU USB Audio Interface')"
        echo "  hraný zvuk: $ROM_DIR/guest-audio.wav"
    fi

    echo "  NOTE: qemu's raspi4b has no working NIC (usb-net RNDIS fails)."
    echo "  No SSH/apt inside the VM; install build deps with 'provision'."
    echo "  NOTE: raspi4b neemuluje bcm2835 audio kodec, takže v testu chybí"
    echo "        vestavěný jack (pcm.builtin) — to je očekávané, ne chyba."
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
        ${AUDIO_ARGS[@]+"${AUDIO_ARGS[@]}"} \
        -append "root=/dev/mmcblk1p2 rootwait rw console=ttyAMA0,115200 earlycon=pl011,0xfe201000"
}

# ─────────────────────────────────────────────────────────────
# 3b. REPORT — vypsat výsledek audio testu z image
# ─────────────────────────────────────────────────────────────
report() {
    need_root
    img_mount "$1"
    mount -o ro "${IMG_LOOP}p2" "$MOUNT_ROOT"

    step "Audio test report: $(basename "$IMG")"
    local R="$MOUNT_ROOT/home/$RPI_USER/tracker/audio-test-report.txt"
    if [ -f "$R" ]; then
        cat "$R"
    else
        echo "  Report zatim neni: /home/$RPI_USER/tracker/audio-test-report.txt"
        echo "  Spust:  ./qemu_raspi4.sh audiotest"
    fi

    umount "$MOUNT_ROOT"
    img_umount

    step "Zaznamany zvuk z hostu"
    if [ -f "$ROM_DIR/guest-audio.wav" ]; then
        echo "  $ROM_DIR/guest-audio.wav ($(stat -c%s "$ROM_DIR/guest-audio.wav") B)"
    else
        echo "  chybi $ROM_DIR/guest-audio.wav (host nic nehrál, nebo bez --audio)"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# 3c. AUDIOTEST — prepare s testem, pak boot
# ─────────────────────────────────────────────────────────────
audiotest() {
    step "Priprava image s audio testem"
    AUDIO_TEST=1 prepare "${1:-}"

    step "Boot s emulovanou USB zvukovkou (stroj se po testu vypne)"
    echo "  Prvni boot pod TCG je pomaly, bez KVM. Po odhlaseni QEMU pujde se dal."
    echo
    echo "  Po tom, co QEMU skonci, spust pro vysledek:"
    echo "      $(basename "$0") report"
    echo
    # run() konci exec(), takže report se nestihne — musí ho spustit uzivatel
    # rucne po tom, co QEMU skonci.
    AUDIO=1 run "${1:-}"
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
    echo "Usage: $(basename "$0") {setup|prepare|run|burn|report|audiotest} [image] [flags]"
    echo
    echo "  setup                Install qemu + download kernel/DTB/RPi OS image into rom/"
    echo "  prepare   [image]    Enable SSH, create user, sync source, install alsa-utils"
    echo "  run       [image]    Boot image in QEMU (SSH on port $SSH_PORT)"
    echo "  burn      <device>   Write prepared image to SD card (e.g. /dev/mmcblk0)"
    echo "  report    [image]    Print audio-test-report.txt from a booted image"
    echo "  audiotest [image]    prepare --audio-test + run --audio, pak rucne 'report'"
    echo
    echo "Flags (prepare):"
    echo "  --box A|B            box identity — A = tracker, B = sampler + 433 MHz."
    echo "                       Bez toho se do image nedostane nic boxoveho."
    echo "  --ip A.B.C.D         staticka adresa boxu (B defaultne 192.168.8.103)"
    echo "  --wifi SSID          WiFi profil v NetworkManageru (wlan0)"
    echo "  --wifi-pass HESLO    WPA2 heslo; bez nej otevrena sit"
    echo "  --wifi-hidden        skryta WiFi sit"
    echo "  --audio-test         install + enable the oneshot that runs"
    echo "                       box-audio-test.sh and powers the machine off"
    echo
    echo "Flags (run):"
    echo "  --audio              emulate a USB sound card (usb-audio), record to"
    echo "                       rom/guest-audio.wav"
    echo
    echo "Priklad — box B na 192.168.8.103, pak burn na kartu:"
    echo "  sudo $0 prepare --box B --ip 192.168.8.103 --wifi MOJE_SIT --wifi-pass HESLO"
    echo "  sudo $0 burn /dev/mmcblk0"
}

CMD="${1:-}"
shift 2>/dev/null || true

# flagy projdeme pred zbytkem, zbytek je pozicni argument (cesta k image / zarizeni)
AUDIO=0
AUDIO_TEST=0
BOX=""
BOXIP=""
WIFI_SSID=""
WIFI_PASS=""
WIFI_HIDDEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --audio)      AUDIO=1; shift ;;
        --audio-test) AUDIO_TEST=1; shift ;;
        --box)        BOX="${2:-}"; shift 2 ;;
        --ip)         BOXIP="${2:-}"; shift 2 ;;
        --wifi)       WIFI_SSID="${2:-}"; shift 2 ;;
        --wifi-pass)  WIFI_PASS="${2:-}"; shift 2 ;;
        --wifi-hidden) WIFI_HIDDEN=1; shift ;;
        *) break ;;
    esac
done

if [ -n "$BOX" ]; then
    case "$BOX" in
        A|B) ;;
        *) die "--box must be A or B, got '$BOX'" ;;
    esac
fi

case "$CMD" in
    setup)     setup ;;
    prepare)   prepare "$@" ;;
    run)       run "$@" ;;
    report)    report "$@" ;;
    audiotest) audiotest "$@" ;;
    burn)      burn "$@" ;;
    *) usage ;;
esac
