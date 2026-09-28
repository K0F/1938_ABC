#!/bin/bash
# tests/test-box-alsa-setup.sh — logika detekce zvukové karty nad falešným sysfs.
#
# Pustí se na hostu bez QEMU, za pár sekund, a pokrývá případy, které se na
# skutečném boxu vyskytnou jen náhodou:
#   * USB zvukovka bez playbacku (webkamera C920) se NESMÍ vybrat jako usb
#   * dvě USB karty s playbackem — vyhrává první v pořadí
#   * chybějící USB karta / chybějící vestavěný jack — nesmí to spadnout
#   * v configu nesmí být nikdy "device 0" a pcm.usb musí být vždy type plug
#   * karta se odvolává JMENEM, takže přehození USB portu (změna čísla) nesmí
#     změnit, kam config ukazuje
#
#   usage: ./tests/test-box-alsa-setup.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-alsa-setup.sh"

[ -x "$SCRIPT" ] || { echo "chybí $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

SYS=""
PROC=""
OUT=""
LOG=""
RC=0

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

case_dir() {
    SYS="$TMPROOT/$1/sys/class/sound"
    PROC="$TMPROOT/$1/proc/asound"
    OUT="$TMPROOT/$1/asound.conf"
    LOG="$TMPROOT/$1/out.log"
    mkdir -p "$SYS" "$PROC" "$TMPROOT/$1"
    : > "$LOG"
}

# add_card <číslo> <usb|platform> <pcm soubory...>
add_card() {
    local n="$1" kind="$2"; shift 2
    local target
    case "$kind" in
        usb)      target="$SYS/../../devices/pci0000:00/usb1/1-$n/1-$n:1.0/sound/card$n" ;;
        platform) target="$SYS/../../devices/platform/soc/bcm2835-audio/sound/card$n" ;;
        *) echo "neznamy typ $kind" >&2; exit 1 ;;
    esac
    mkdir -p "$target" "$SYS/card$n"
    ln -sfn "$target" "$SYS/card$n/device"
    mkdir -p "$PROC/card$n"
    # id = jméno karty, podle kterého se config odvolává (hw:CARD=<id>,DEV=0)
    printf '%s\n' "$(card_id_name "$n")" > "$PROC/card$n/id"
    local p
    for p in "$@"; do : > "$PROC/card$n/$p"; done
}

# Jména jako na skutečném Boxu A. Karta, která má v /proc jméno "Adapter",
# dostane stejné jméno i pod jiným číslem — to je případ 7).
card_id_name() {
    case "$1" in
        0) echo "Headphones" ;;
        3|5) echo "Adapter" ;;
        4|6) echo "C920" ;;
        *) echo "card$1" ;;
    esac
}
run_script() {
    ABC38_SOUND_SYSFS="$SYS" \
    ABC38_ASOUND_PROC="$PROC" \
    ABC38_ASOUND_CONF="$OUT" \
        bash "$SCRIPT" >"$LOG" 2>&1
    RC=$?
}

assert_cfg()    { grep -qE "$1" "$OUT" && ok "$2" || bad "$2  [$(tr '\n' ' ' <"$OUT")]"; }
assert_no_cfg() { grep -qE "$1" "$OUT" && bad "$2  [$(tr '\n' ' ' <"$OUT")]" || ok "$2"; }
assert_log()    { grep -qE "$1" "$LOG" && ok "$2" || bad "$2  [$(tr '\n' ' ' <"$LOG")]"; }
assert_rc0()    { [ "$RC" -eq 0 ] && ok "$1" || bad "$1  (rc=$RC) [$(tr '\n' ' ' <"$LOG")]"; }

# invarianty platné pro KAŽDÝ vygenerovaný config
assert_invariants() {
    assert_no_cfg '(^|[[:space:]])device[[:space:]]+[0-9]' "config neobsahuje 'device N' (pcm by se neregistroval)"
    if grep -qE '^pcm\.usb' "$OUT"; then
        grep -qE '^pcm\.usb \{ type plug;' "$OUT" \
            && ok "pcm.usb je type plug (mono samply projdou)" \
            || bad "pcm.usb neni type plug"
    fi
}

echo "== 1) vestavěný jack + USB zvukovka (ideální případ) =="
case_dir c1
add_card 0 platform pcm0p pcm0c      # bcm2835 Headphones
add_card 3 usb      pcm3p pcm3c      # AXAGON ADA-17
run_script
assert_rc0       "skript skončí 0"
assert_log       'usb=card3 builtin=card0' "vybráno usb=card3, builtin=card0"
assert_cfg       '^pcm\.builtin \{ type plug; slave\.pcm "hw:CARD=Headphones,DEV=0" \}' "pcm.builtin -> jméno karty"
assert_cfg       '^pcm\.usb \{ type plug; slave\.pcm "hw:CARD=Adapter,DEV=0" \}'     "pcm.usb -> jméno karty"
assert_cfg       '^pcm\.!default \{ type plug; slave\.pcm usb \}'                     "pcm.!default -> usb"
assert_cfg       '^ctl\.!default \{ type hw; card 3 \}'                               "ctl.!default -> číslo karty (ctl jméno neumí)"
assert_invariants

echo "== 2a) C920 (jen capture) vyložená PŘED zvukovkou — musí být přeskočena =="
case_dir c2a
add_card 2 usb pcm2c                 # C920 — capture only, nižší číslo než zvukovka
add_card 3 usb pcm3p pcm3c           # AXAGON ADA-17
run_script
assert_rc0     "skript skončí 0"
assert_log     'usb=card3' "capture-only card2 přeskočena, vybrán card3"
assert_cfg     'hw:CARD=Adapter' "pcm.usb míří na zvukovku"
assert_no_cfg  'CARD=card2'   "webkamera se v configu nevyskytuje"
assert_invariants

echo "== 2b) zvukovka vyložená před C920 =="
case_dir c2b
add_card 3 usb pcm3p pcm3c           # AXAGON
add_card 4 usb pcm4c                 # C920 — capture only
run_script
assert_rc0     "skript skončí 0"
assert_log     'usb=card3' "vybrán card3"
assert_no_cfg  'CARD=C920'  "capture-only C920 se v configu nevyskytuje"
assert_invariants

echo "== 3) dvě USB karty s playbackem =="
case_dir c3
add_card 1 usb pcm1p pcm1c
add_card 2 usb pcm2p pcm2c
run_script
assert_rc0 "skript skončí 0"
assert_log 'usb=card1' "vyhrává první karta v pořadí (card1)"

echo "== 4) žádná USB zvukovka =="
case_dir c4
add_card 0 platform pcm0p pcm0c
run_script
assert_rc0        "skript skončí 0"
assert_log        'USB zvuková karta nenalezena' "varuje chybějící USB kartu"
assert_cfg        '^pcm\.builtin'                "pcm.builtin se stejně zapíše"
assert_no_cfg     '^pcm\.usb'                    "pcm.usb se nepíše"
assert_no_cfg     '^pcm\.!default'               "pcm.!default se nepíše"
assert_invariants

echo "== 5) USB karta, ale žádný vestavěný jack =="
case_dir c5
add_card 3 usb pcm3p pcm3c
run_script
assert_rc0     "skript skončí 0"
assert_log     'vestavěný jack Raspberry Pi nenalezen' "varuje chybějící vestavěný jack"
assert_cfg     '^pcm\.usb'                              "pcm.usb se zapíše"
assert_cfg     '^pcm\.!default \{ type plug; slave\.pcm usb \}' "default míří na usb"
assert_no_cfg  '^pcm\.builtin'                          "pcm.builtin se nepíše"
assert_invariants

echo "== 6) žádná zvuková zařízení vůbec =="
case_dir c6
run_script
assert_rc0     "skript skončí 0 (nepadá)"
assert_log     'USB zvuková karta nenalezena'   "varuje chybějící USB kartu"
assert_log     'vestavěný jack Raspberry Pi nenalezen' "varuje chybějící vestavěný jack"
assert_no_cfg  '^pcm\.' "žádný pcm nevznikne"
assert_invariants

echo "== 7) zvukovka se přehodila na jiný USB port (změna čísla karty) =="
case_dir c7
add_card 0 platform pcm0p pcm0c      # Headphones
add_card 5 usb      pcm5p pcm5c      # tatáž AXAGON, ale vyložená jako card5
add_card 6 usb      pcm6c             # C920
run_script
assert_rc0     "skript skončí 0"
assert_log     'usb=card5' "nové číslo karty poznané"
assert_cfg     'hw:CARD=Adapter,DEV=0' "pcm.ukazuje na AXAGON pořád, ne na číslo"
assert_cfg     '^ctl\.!default \{ type hw; card 5 \}'  "ctl sleduje nové číslo"
assert_invariants

echo "== 8) karta bez /proc/asound/cardN/id (fallback na číslo) =="
case_dir c8
add_card 0 platform pcm0p pcm0c
add_card 3 usb      pcm3p pcm3c
rm -f "$PROC/card3/id" "$PROC/card0/id"
run_script
assert_rc0     "skript skončí 0"
assert_cfg     '^pcm\.usb \{ type plug; slave\.pcm "hw:3,0" \}' "bez id se použije číslo"
assert_invariants

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
