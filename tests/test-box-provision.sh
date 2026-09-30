#!/bin/bash
# tests/test-box-provision.sh — první boot boxu (provisioning) nad falešným stromem.
#
# Provisioning běží na čerstvém Raspberry Pi OS a dělá netriviální věci
# (apt, build, systemd, ALSA). Tady se pustí nad prázdným adresářem s falešnými
# příkazy, aby se ověřilo, že pro box A a box B vzniknou správné soubory a
# služby — bez sítě, bez GPIO a bez systemd.
#
#   usage: ./tests/test-box-provision.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-provision.sh"
[ -x "$SCRIPT" ] || { echo "chybi $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

# falešný systemctl: jen zapisuje, kdo byl zapnutý/spuštěný
cat > "$TMP/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
exit 0
EOF
chmod 755 "$TMP/systemctl"
SYSTEMCTL_LOG="$TMP/systemctl.log"
export SYSTEMCTL_LOG

# falešný make v PATH: "sestaví" prázdný skript, aby se dalo ověřit, že se
# binárka instaluje. Skutečný make by v testu chtěl SDL2/OpenCV a by selhal.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/make" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        clean)   rm -f tracker sampler ;;
        sampler) printf '#!/bin/sh\necho "sampler test"\n' > sampler; chmod 755 sampler ;;
        tracker) printf '#!/bin/sh\necho "tracker test"\n' > tracker; chmod 755 tracker ;;
    esac
done
EOF
chmod 755 "$FAKEBIN/make"

# zdroje v kořenu, aby se box-provision.sh nemusel opírat o /home/pi
STAGE="$TMP/stage"
mkdir -p "$STAGE"
# všechno, co provisioning instaluje — chybějící souroj by ho zastavil (set -e)
cp "$ROOT"/box-{alsa-setup,sound-restart,network,provision}.sh "$STAGE/"
cp "$ROOT"/{sampler,tracker,box-sound-restart}.service "$STAGE/"
cp "$ROOT"/99-box-sound.rules "$ROOT"/map.csv.example "$ROOT"/install-deps.sh "$STAGE/"

# Box A jde přes install-deps.sh (raylib se staví z Gitu) — v testu to musí být
# náhrada, jinak by provisioning sáhl na síť
cat > "$STAGE/install-deps.sh" <<'EOF'
#!/bin/bash
echo "fake install-deps"
make all
EOF
chmod 755 "$STAGE/install-deps.sh"

# box-alsa-setup.sh se pustí opravdu — proti prázdnému fake stromu v rootu
# (ABC38_SOUND_SYSFS / ABC38_ASOUND_PROC / ABC38_ASOUND_CONF, které provisioning
# nastavuje na kořen image). Bez USB karty jen napíše, že ji nenašlo, a
# vygeneruje config, který test pak zkontroluje.

run_box() {
    local box="$1"
    local root="$TMP/root-$box"
    rm -rf "$root"
    mkdir -p "$root/etc/systemd/system" "$root/etc/udev/rules.d" \
             "$root/etc/NetworkManager/system-connections" \
             "$root/usr/local/sbin" "$root/usr/local/bin" \
             "$root/var/lib" "$root/sys/class/sound" "$root/proc/asound"

    # USB zvukovka ve fake stromu, jinak by box-alsa-setup.sh psal jen
    # "karta nenalezena" a asound.conf by zůstal bez pcm.usb
    CARD="$root/sys/class/sound/card3"
    mkdir -p "$root/sys/devices/pci0000:00/usb1/1-3/sound" "$CARD" \
             "$root/proc/asound/card3"
    ln -sfn "$root/sys/devices/pci0000:00/usb1/1-3/sound" "$CARD/device"
    printf 'Adapter\n' > "$root/proc/asound/card3/id"
    : > "$root/proc/asound/card3/pcm3p"
    : > "$root/proc/asound/card3/pcm3c"

    : > "$SYSTEMCTL_LOG"
    BOX="$box" \
    ABC38_ROOT="$root" \
    ABC38_APT="true" \
    ABC38_CMD="$TMP/systemctl" \
    ABC38_SRC="$STAGE" \
    ABC38_DEPS=0 \
    ABC38_SUDO="" \
    PATH="$FAKEBIN:$PATH" \
        bash "$SCRIPT" >"$TMP/out-$box.log" 2>&1
    echo "$root"
}

cmds()  { cat "$SYSTEMCTL_LOG"; }
unit()  { cat "$TMP/root-$1/etc/systemd/system/$2" 2>/dev/null || true; }
has()   { grep -qE "$1" "$2" && ok "$3" || bad "$3  [$(tr '\n' '|' <"$2" | head -c 200)]"; }
hasnt() { ! grep -qE "$1" "$2" && ok "$3" || bad "$3  [$(tr '\n' '|' <"$2" | head -c 200)]"; }

echo "== 1) Box A: tracker.service, žádný sampler =="
RA="$(run_box A)"
has '^enable tracker\.service$'    "$SYSTEMCTL_LOG" "tracker.service zapnutá"
has '^start tracker\.service$'     "$SYSTEMCTL_LOG" "tracker.service spuštěná"
[ -e "$RA/usr/local/bin/sampler" ] && bad "nainstaloval se i sampler" || ok "sampler se netýká"
has 'Environment=RESTART_UNITS=tracker\.service' "$RA/etc/systemd/system/box-sound-restart.service" \
    "box-sound-restart restartuje tracker"
[ -f "$RA/var/lib/box-provisioned" ] && ok "znamení /var/lib/box-provisioned" || bad "chybí znamení"
has '^disable box-firstboot\.service$' "$SYSTEMCTL_LOG" "firstboot se sám vypne"

echo "== 2) Box B: sampler.service, identita b, restartuje se sampler =="
RB="$(run_box B)"
has '^enable sampler\.service$'    "$SYSTEMCTL_LOG" "sampler.service zapnutá"
has '^start sampler\.service$'     "$SYSTEMCTL_LOG" "sampler.service spuštěná"
has 'Environment=RESTART_UNITS=sampler\.service' "$RB/etc/systemd/system/box-sound-restart.service" \
    "box-sound-restart restartuje sampler"
has 'ExecStart=/usr/local/bin/sampler --box b --allow-restart$' \
    "$RB/etc/systemd/system/sampler.service" \
    "sampler.service spuštěný s --box b a --allow-restart"
# Náhrada písmena za --box nesmí spadnout i na zbytek ExecStart řádku:
# dřívější sed "s/--box .*/.../" zahodil --allow-restart a akční tlačítko
# F tiše přestalo restartovat.
hasnt 'sampler --box b$'  "$RB/etc/systemd/system/sampler.service" \
    "ExecStart nemá jen --box b bez --allow-restart"
[ -x "$RB/usr/local/bin/sampler" ] && ok "binárka samplera nainstalovaná" || bad "binárka chybí"
[ -e "$RB/etc/systemd/system/tracker.service" ] && bad "nainstaloval se i tracker.service" \
    || ok "tracker se netýká"

echo "== 3) map.csv vznikne z příkladu, když na boxu žádná není =="
[ -f "$STAGE/map.csv" ] && ok "map.csv vytvořena" || bad "map.csv nevznikla"
grep -q 'map.csv vytvořena' "$TMP/out-B.log" && ok "o tom řekne v logu" || bad "chybí hláška o map.csv"

echo "== 4) statická adresa se zapíše do image =="
NMKEY="$RB/etc/NetworkManager/system-connections/box-B.nmconnection"
[ -f "$NMKEY" ] && ok "NetworkManager keyfile v image" || bad "keyfile chybí"
has '^addresses=192\.168\.8\.103/24$' "$NMKEY" "adresa 192.168.8.103/24"
[ "$(stat -c '%a' "$NMKEY")" = "600" ] && ok "práva 0600" || bad "práva nejsou 0600"

echo "== 4b) WiFi profil z image se prvním bootem nepřepíše na eth0 =="
RB2="$TMP/root-B2"
rm -rf "$RB2"; mkdir -p "$RB2/etc/systemd/system" "$RB2/etc/udev/rules.d" \
    "$RB2/usr/local/sbin" "$RB2/usr/local/bin" "$RB2/var/lib" \
    "$RB2/etc/NetworkManager/system-connections"
SSID=testovaci BOX_WIFI_SSID=testovaci BOX_WIFI_PSK=tajneheslo \
    ABC38_NET_ROOT="$RB2" bash "$ROOT/box-network.sh" B >/dev/null
grep -q '^type=wifi$' "$RB2/etc/NetworkManager/system-connections/box-B.nmconnection" \
    && ok "v image je WiFi profil" || bad "v image není WiFi profil"
LOGF="$TMP/cmd2.log" BOX=B ABC38_ROOT="$RB2" ABC38_APT=true ABC38_CMD="$TMP/systemctl" \
    ABC38_SRC="$STAGE" ABC38_DEPS=0 PATH="$TMP/fakebin:$PATH" \
    bash "$ROOT/box-provision.sh" >"$TMP/out-B2.log" 2>&1 \
    || bad "provisioning selhal: $(tail -3 "$TMP/out-B2.log")"
F="$RB2/etc/NetworkManager/system-connections/box-B.nmconnection"
grep -q '^type=wifi$' "$F" && ok "první boot profil nezkalil" || bad "WiFi profil se přepsal na eth0"
grep -q '^ssid=testovaci$' "$F" && ok "SSID přežil" || bad "SSID zmizel"
grep -q 'síť už z image' "$TMP/out-B2.log" && ok "hlásí, že síť je z image" || bad "neví, že profil je z image"

echo "== 5) druhý boot už nic neinstaluje (znamení) =="
: > "$SYSTEMCTL_LOG"
BOX=B ABC38_ROOT="$RB" ABC38_APT="true" ABC38_CMD="$TMP/systemctl" \
    ABC38_SRC="$STAGE" ABC38_DEPS=0 ABC38_SUDO="" PATH="$FAKEBIN:$PATH" \
    bash "$SCRIPT" >"$TMP/again.log" 2>&1
grep -q 'už provisionované' "$TMP/again.log" && ok "druhý běh se vynechá" || bad "druhý běh nepoznal znamení"
[ ! -s "$SYSTEMCTL_LOG" ] && ok "systemctl nedostal žádný příkaz" || bad "znovu něco zapínal"

echo "== 6) BOX mimo A/B je chyba =="
if BOX=C ABC38_ROOT="$TMP/x" ABC38_DEPS=0 bash "$SCRIPT" >/dev/null 2>&1; then
    bad "box C prošel"
else
    ok "box C odmítnut"
fi

echo "== 7) ALSA default se propíše do image, ne do hosta =="
has '^pcm\.usb \{' "$RB/etc/asound.conf" "asound.conf v image má pcm.usb"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
