#!/bin/bash
# box-provision.sh — co se musí stát při prvním bootu boxu (A = tracker, B = sampler).
#
# Instaluje se do image (offline) na /usr/local/sbin/box-provision.sh a běží
# jednou po prvním bootu z box-firstboot.service. Připravuje image, takže tady
# nic nevadí s boxem A: běží na čerstvě nainstalovaném Raspberry Pi OS.
#
#   BOX=A|B   identita boxu (default: A)
#
# Běží jako root (systemd oneshot). Po sobě se sám vypne (systemctl disable
# box-firstboot.service) a nechá znamení /var/lib/box-provisioned.
#
# Testovatelnost: kořenové cesty a příkazy jdou přesměrovat proměnnými, aby se
# průběh pustil nad falešným stromem bez systemd a bez sítě.
#   BOX              A | B
#   ABC38_ROOT       default /
#   ABC38_SUDO       default "" (testy: odpadne, vše běží pod aktuálním uživatelem)
#   ABC38_APT        default apt-get      (testy: true)
#   ABC38_CMD        default systemctl    (testy: zapisovací náhrada)
#   ABC38_SRC        default /home/pi/tracker
#                    (make se hledá v PATH, testy strkají do PATH svou náhradu)
#   ABC38_DEPS       default 1 (testy: 0 = žádný apt)

set -eu

BOX="${BOX:-A}"
case "$BOX" in
    A|B) ;;
    *) echo "ERROR: BOX must be A or B, got '$BOX'" >&2; exit 1 ;;
esac

R="${ABC38_ROOT:-/}"
SUDO="${ABC38_SUDO:-}"
APT="${ABC38_APT:-apt-get}"
CMD="${ABC38_CMD:-systemctl}"
SRC="${ABC38_SRC:-/home/pi/tracker}"
DEPS="${ABC38_DEPS:-1}"

STAMP="$R/var/lib/box-provisioned"

if [ -f "$STAMP" ]; then
    echo "[box$BOX] už provisionované ($STAMP) — nic nedělám"
    exit 0
fi

echo "[box$BOX] == first-boot provisioning =="
logger "box$BOX provisioning start" 2>/dev/null || true

# ── závislosti a build ────────────────────────────────────────────
if [ "$DEPS" = 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO $APT update
    if [ "$BOX" = "A" ]; then
        $SUDO $APT install -y --no-install-recommends \
            g++ make pkg-config git ca-certificates \
            libopencv-dev libopencv-contrib-dev libx11-dev libgl-dev \
            libsdl2-dev libsdl2-mixer-dev libxrandr-dev
        # X + mesa zůstávají v image: kalibrace přes HDMI ručně (startx na tty1,
        # ./tracker s oknem a klávesou S) a volitelná HDMI konzole
        # (box-console.sh on), která autologuje na tty1 a plní TV oknem trackeru.
        # Nic se nespouští graficky automaticky.
        $SUDO $APT install -y --no-install-recommends \
            xinit xserver-xorg xserver-xorg-video-fbdev x11-xserver-utils libgl1-mesa-dri
    else
        $SUDO $APT install -y --no-install-recommends \
            g++ make pkg-config git ca-certificates \
            libsdl2-dev libsdl2-mixer-dev libgpiod-dev
    fi
fi

cd "$SRC"

# ── Box A: tracker ────────────────────────────────────────────────
if [ "$BOX" = "A" ]; then
    # skupiny pro kameru a zvuk — jen na skutečném boxu (testy běží nad
    # falešným kořenem, kde by to člověka nebylo kam přidat)
    [ "$R" = "/" ] && $SUDO usermod -aG audio,video "${SUDO_USER:-pi}"
    # raylib není v repu, musí se zkompilovat — install-deps.sh to umí
    # (klone z Gitu a staví raylib + obě binárky)
    bash install-deps.sh
    install -m 0755 tracker.service "$R/etc/systemd/system/tracker.service"
    UNIT=tracker.service
    START=1
fi

# ── Box B: sampler ────────────────────────────────────────────────
if [ "$BOX" = "B" ]; then
    make clean
    make sampler
    # Kdyby do zdrojů přešla binárka jiné architektury, selže to tady a
    # provisioning skončí (set -e) — ne až na exec, kde by systemd jen
    # doneckonal v kruhu restartu.
    ./sampler --version
    install -m 0755 sampler "$R/usr/local/bin/sampler"
    # mapa.csv bez ní sampler jen tiskne kódy a nic nehraje (viz README)
    if [ -f mapa.csv ]; then
        echo "[box$BOX] mapa.csv je na place"
    else
        cp -n mapa.csv.example mapa.csv
        echo "[box$BOX] mapa.csv vytvořena z příkladu (kódy se doplní --listen)"
    fi
    install -m 0644 sampler.service "$R/etc/systemd/system/sampler.service"
    # identita boxu do jednotky. Malé písmeno, ať to odpovídá tomu, co sampler
    # vypisuje do --help i čemu se řídí mapa.csv; BOX přichází jako A/B.
    sed -i "s/--box .*/--box $(printf '%s' "$BOX" | tr 'A-Z' 'a-z')/" \
        "$R/etc/systemd/system/sampler.service"
    UNIT=sampler.service
    START=1
fi

# ── ALSA a zvuková karta (oba boxy) ───────────────────────────────
# Zařízení se musí pojmenovat a default nastavit dřív, než služba otevře kartu.
install -m 0755 box-alsa-setup.sh "$R/usr/local/sbin/box-alsa-setup.sh"
ABC38_ASOUND_CONF="$R/etc/asound.conf" \
ABC38_SOUND_SYSFS="$R/sys/class/sound" \
ABC38_ASOUND_PROC="$R/proc/asound" \
    "$R/usr/local/sbin/box-alsa-setup.sh" || \
    echo "[box$BOX] POZOR: box-alsa-setup.sh selhal" >&2

# Přehodí/připojení USB zvukové karty: služba drží starý PCM, který SDL už
# znovu neotevře, a zvuk by zmlčel do rána. udev pravidlo to pozná a službu
# restartuje.
install -m 0755 box-sound-restart.sh "$R/usr/local/sbin/box-sound-restart.sh"
install -m 0644 box-sound-restart.service "$R/etc/systemd/system/box-sound-restart.service"
sed -i "s/^Environment=RESTART_UNITS=.*/Environment=RESTART_UNITS=$UNIT/" \
    "$R/etc/systemd/system/box-sound-restart.service"
install -m 0644 99-box-sound.rules "$R/etc/udev/rules.d/99-box-sound.rules"
$CMD daemon-reload

# ── síť: statická adresa (aby na box nebylo potřeba hledat DHCP) ──
# Profil z prepare-sd.sh / qemu_raspi4.sh prepare už v image je a obsahuje
# SSID i heslo z doby přípravy. Kdyby se tu přepsal výchozím (bez SSID), box by
# po prvním bootu skončil na eth0 a WiFi by se vůbec nevytvořilo. Proto se
# doplňuje jen tehdy, když v image žádný profil není.
CONN="$R/etc/NetworkManager/system-connections/box-$BOX.nmconnection"
if [ -e "$CONN" ]; then
    echo "[box$BOX] síť už z image (box-$BOX), nechávám jak je"
elif [ -x box-network.sh ]; then
    ABC38_NET_ROOT="$R" $SUDO ./box-network.sh "$BOX" || \
        echo "[box$BOX] POZOR: box-network.sh selhal" >&2
fi

# ── start služby ──────────────────────────────────────────────────
$CMD enable "$UNIT"
if [ "${START:-0}" = 1 ]; then
    $CMD start "$UNIT"
fi

mkdir -p "$R/var/lib"
touch "$STAMP"
$CMD disable box-firstboot.service 2>/dev/null || true
logger "box$BOX provisioning complete" 2>/dev/null || true
echo "[box$BOX] provisioning hotová"
