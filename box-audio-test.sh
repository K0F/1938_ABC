#!/bin/bash
# box-audio-test.sh — test zvukové karty běžící uvnitř boxu.
#
# Přesně opakuje postup z README.md ("Ověření zvuku"), ale bez dohledu:
#   ./box-alsa-setup.sh  →  pcm.usb / pcm.builtin / default
#   aplay -L             →  vidět usb a default
#   aplay -D usb track1  →  MONO samply projdou (regrese: type hw padá)
#   speaker-test -D usb  →  levý/pravý kanál se střídají
#
# Běží v QEMU (usb-audio) i na skutečném boxu. Report jde do
# audio-test-report.txt vedle skriptu, ať se dá z hosta vytaženout.
#
#   usage: sudo ./box-audio-test.sh
#          REPORT=/cesta/report.txt ./box-audio-test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="${REPORT:-$SCRIPT_DIR/audio-test-report.txt}"
CONF="${ABC38_ASOUND_CONF:-/etc/asound.conf}"
WAV="${WAV:-$SCRIPT_DIR/samples/track1.wav}"

mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
: > "$REPORT"

PASS=0
FAIL=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
ok()  { PASS=$((PASS + 1)); log "  ok    $*"; }
bad() { FAIL=$((FAIL + 1)); log "  FAIL  $*"; }
info(){ log "  --    $*"; }

log "== test zvukové karty: $(date -Is 2>/dev/null || date) =="
log "   skript: $SCRIPT_DIR"
log "   report: $REPORT"
log ""

# ── 0. Služba drží kartu → EBUSY. Zastavíme ji, pokud běží ─────────────
if command -v systemctl >/dev/null && systemctl is-active --quiet tracker.service; then
    systemctl stop tracker.service
    info "tracker.service zastaven (jinak karta vrací EBUSY)"
fi

# ── 1. Předpoklady ────────────────────────────────────────────────────
for tool in aplay speaker-test; do
    command -v "$tool" >/dev/null || { log "  FAIL  chybí $tool (balík alsa-utils)"; exit 1; }
done
[ -x "$SCRIPT_DIR/box-alsa-setup.sh" ] || { log "  FAIL  chybí box-alsa-setup.sh"; exit 1; }
[ -f "$WAV" ] || { log "  FAIL  chybí $WAV (mono sampl — bez něj netestujeme type plug)"; exit 1; }

# ── 2. Necháme skript pojmenovat zařízení ──────────────────────────────
log "== box-alsa-setup.sh =="
if ! SETUP_OUT="$(bash "$SCRIPT_DIR/box-alsa-setup.sh" 2>&1)"; then
    bad "box-alsa-setup.sh selhal"
    printf '%s\n' "$SETUP_OUT" | sed 's/^/        /' | tee -a "$REPORT"
    log ""
    log "passed $PASS, failed $FAIL"
    exit 1
fi
printf '%s\n' "$SETUP_OUT" | sed 's/^/        /' | tee -a "$REPORT"

USB_CARD="$(printf '%s' "$SETUP_OUT" | sed -n 's/.*usb=card\([0-9]\+\).*/\1/p' | head -1)"
BUILTIN_CARD="$(printf '%s' "$SETUP_OUT" | sed -n 's/.*builtin=card\([0-9]\+\).*/\1/p' | head -1)"

if [ -n "$USB_CARD" ]; then
    ok "USB zvuková karta nalezena: card$USB_CARD"
else
    bad "USB zvuková karta nenalezena — v QEMU zkontroluj '-device usb-audio'"
fi
if [ -n "$BUILTIN_CARD" ]; then
    ok "vestavěný jack nalezena: card$BUILTIN_CARD"
else
    # QEMU raspi4b neemuluje bcm2835 audio kodec, takže tady chybí být musí.
    info "vestavěný jack (bcm2835) chybí — v QEMU normální, mimo QEMU zkontroluj kabel"
fi
log ""

# ── 3. /proc/asound pro člověka ───────────────────────────────────────
if [ -r /proc/asound/cards ]; then
    log "== /proc/asound/cards =="
    sed 's/^/        /' /proc/asound/cards | tee -a "$REPORT"
    log ""
fi

# ── 4. Config: nesmí být 'device N', pcm.usb musí být type plug ───────
log "== $CONF =="
if [ -r "$CONF" ]; then
    if grep -qE '(^|[[:space:]])device[[:space:]]+[0-9]' "$CONF"; then
        bad "config obsahuje 'device N' — alsa-lib pak pcm neregistruje"
    else
        ok "config neobsahuje 'device N'"
    fi
    if grep -qE '^pcm\.usb \{ type plug;' "$CONF"; then
        ok "pcm.usb je type plug (mono projde)"
    elif grep -qE '^pcm\.usb' "$CONF"; then
        bad "pcm.usb není type plug — mono samply skončí 'Channels count non available'"
    else
        info "pcm.usb v configu není (není USB karta)"
    fi
    grep -qE '^pcm\.!default \{ type plug; slave\.pcm usb;? ?\}' "$CONF" \
        && ok "pcm.!default míří na usb" \
        || info "pcm.!default není nastaven na usb"
else
    bad "$CONF neexistuje nebo není čitelný"
fi
log ""

# ── 5. aplay -L: zařízení jsou registrovaná pod jménem ─────────────────
log "== aplay -L =="
APLAY_L="$(aplay -L 2>&1)"
if printf '%s' "$APLAY_L" | grep -qE '^[[:space:]]*usb[[:space:]]*$'; then
    ok "aplay -L vypisuje usb"
else
    bad "aplay -L nevypisuje usb"
fi
if printf '%s' "$APLAY_L" | grep -qE '^[[:space:]]*default[[:space:]]*$'; then
    ok "aplay -L vypisuje default"
else
    bad "aplay -L nevypisuje default"
fi
printf '%s' "$APLAY_L" | grep -E '^[[:space:]]*(usb|builtin|default)[[:space:]]*$' \
    | sed 's/^/        /' | tee -a "$REPORT"
log ""

# ── 6. MONO sampl — to je ta regrese ───────────────────────────────────
log "== aplay -D usb (mono sampl) =="
if ERR="$(aplay -D usb "$WAV" 2>&1)"; then
    ok "mono sampl přehrán přes usb"
else
    bad "mono sampl selhal"
    printf '%s\n' "$ERR" | sed 's/^/        /' | tee -a "$REPORT"
fi
log ""

# ── 7. speaker-test: střídání levého a pravého ────────────────────────
log "== speaker-test -D usb (L/R) =="
if ERR="$(speaker-test -D usb -c 2 -t sine -f 440 -l 1 2>&1)"; then
    ok "speaker-test prošel (TIP=L, RING=R)"
else
    bad "speaker-test selhal"
    printf '%s\n' "$ERR" | sed 's/^/        /' | tee -a "$REPORT"
fi
log ""

log "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
