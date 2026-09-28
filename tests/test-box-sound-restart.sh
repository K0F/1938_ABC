#!/bin/bash
# tests/test-box-sound-restart.sh — reakce na (re)objevení zvukové karty.
#
# Pustí se na hostu bez systemd i bez hardware, za pár sekund:
#   * karta se objeví/zmizí -> pustí se box-alsa-setup.sh a restartuje se služba
#   * restartované služby jdou z proměnné (Box A = tracker, Box B = sampler)
#   * prázdná RESTART_UNITS = nikoho nerestartovat (služba vypnutá)
#   * chybějící /proc/asound/cards nesmí skript zastavit, jen to nahlásit
#   * selhání restartu se nahlásí, ale ne shodí celý průběh
#
#   usage: ./tests/test-box-sound-restart.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-sound-restart.sh"
SETUP="$ROOT/box-alsa-setup.sh"

[ -x "$SCRIPT" ] || { echo "chybí $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

SYS="$TMPROOT/sys/class/sound"
PROC="$TMPROOT/proc/asound"
CONF="$TMPROOT/asound.conf"
RESTARTLOG="$TMPROOT/restart.log"
export RESTARTLOG
OUTLOG="$TMPROOT/out.log"

# ── falešný strom: headphonová karta 0 (platform) + AXAGON 3 (usb) ─────
add_card() {
    local n="$1" kind="$2" id="$3"; shift 3
    local target
    case "$kind" in
        usb)      target="$SYS/../../devices/pci0000:00/usb1/1-$n/sound/card$n" ;;
        platform) target="$SYS/../../devices/platform/soc/bcm2835-audio/sound/card$n" ;;
    esac
    mkdir -p "$target" "$SYS/card$n" "$PROC/card$n"
    ln -sfn "$target" "$SYS/card$n/device"
    printf '%s\n' "$id" > "$PROC/card$n/id"
    local p
    for p in "$@"; do : > "$PROC/card$n/$p"; done
}

# /proc/asound/cards — jen pro výpis v logu
write_cards() {
    cat > "$PROC/cards" <<'EOF'
 0 [Headphones     ]: bcm2835_headpho - bcm2835 Headphones
 3 [Adapter        ]: USB-Audio - AXAGON USB Audio Adapter
EOF
}

# Náhrada systemctl: jen zapisuje, koho by restartovala
cat > "$TMPROOT/fake-restart.sh" <<'EOF'
#!/bin/bash
echo "restart $*" >> "$RESTARTLOG"
exit "${FAKE_RESTART_RC:-0}"
EOF
chmod 755 "$TMPROOT/fake-restart.sh"
RESTARTCMD="$TMPROOT/fake-restart.sh"

FAKE_RC=0
run_watch() {
    : > "$RESTARTLOG"
    : > "$OUTLOG"
    rm -f "$CONF"
    export FAKE_RESTART_RC="$FAKE_RC"
    env ABC38_SOUND_SYSFS="$SYS" \
        ABC38_ASOUND_PROC="$PROC" \
        ABC38_ASOUND_CONF="$CONF" \
        BOX_ALSA_SETUP="$SETUP" \
        RESTART_CMD="$RESTARTCMD" \
        SKIP_SETTLE=1 \
        RESTART_UNITS="$1" \
            bash "$SCRIPT" >"$OUTLOG" 2>&1
    RC=$?
}

assert_restarted() { grep -qx "restart $1" "$RESTARTLOG" && ok "$2" || bad "$2  [$(tr '\n' '|' <"$RESTARTLOG")]"; }
assert_not()       { grep -q "$1" "$RESTARTLOG" && bad "$2  [$(tr '\n' '|' <"$RESTARTLOG")]" || ok "$2"; }
assert_log()       { grep -qE "$1" "$OUTLOG" && ok "$2" || bad "$2  [$(tr '\n' ' ' <"$OUTLOG")]"; }
assert_cfg()       { grep -qE "$1" "$CONF" && ok "$2" || bad "$2  [$(tr '\n' ' ' <"$CONF" 2>/dev/null)]"; }
assert_rc0()       { [ "$RC" -eq 0 ] && ok "$1" || bad "$1  (rc=$RC) [$(tr '\n' ' ' <"$OUTLOG")]"; }

echo "== 1) karta přibyde: přenastaví se ALSA a restartuje se tracker =="
mkdir -p "$SYS" "$PROC"
add_card 0 platform Headphones pcm0p pcm0c
add_card 3 usb      Adapter    pcm3p pcm3c
write_cards
run_watch "tracker.service"
assert_rc0        "skript skončí 0"
assert_cfg        '^pcm\.usb \{ type plug; slave\.pcm "hw:CARD=Adapter,DEV=0" \}' "asound.conf míří na kartu podle jména"
assert_cfg        '^pcm\.!default' "default ukazuje na usb"
assert_restarted  "tracker.service" "tracker.service restartován"
assert_log        'karty: ' "vypíše, co vidí v /proc"
assert_not        'POZOR' "bez varování"

echo "== 2) Box B: restartuje se sampler, ne tracker =="
run_watch "sampler.service"
assert_rc0        "skript skončí 0"
assert_restarted  "sampler.service" "sampler.service restartován"
assert_not        "tracker"         "tracker se nereskuje"

echo "== 3) obě služby najednou (tracker + sampler) =="
run_watch "tracker.service sampler.service"
assert_restarted  "tracker.service"  "tracker.service restartován"
assert_restarted  "sampler.service"  "sampler.service restartován"
assert_rc0        "skript skončí 0"

echo "== 4) RESTART_UNITS prázdné = nikoho nerestartovat =="
run_watch ""
assert_rc0        "skript skončí 0"
assert_not        'restart' "žádný restart se nepovolí"
assert_cfg        '^pcm\.usb' "asound.conf se stejně přegeneruje"

echo "== 5) /proc/asound/cards chybí =="
mv "$PROC/cards" "$PROC/cards.hidden"
run_watch "tracker.service"
assert_rc0        "skript skončí 0 (nepadá)"
assert_log        'POZOR' "nahlásí, že karty nevidí"
assert_restarted  "tracker.service" "restart se stejně pokusí"
mv "$PROC/cards.hidden" "$PROC/cards"

echo "== 6) restart selhne =="
FAKE_RC=1 run_watch "tracker.service"
assert_rc0        "skript skončí 0 (selhání restartu neshodí běh)"
# v hlášce je ten příkaz, kterým se to zkusilo, ať je poznat, co selhalo
assert_log        'tracker.service selhal' "selhání se nahlásí"
assert_log        'restart' "a je v něm použitý příkaz"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
