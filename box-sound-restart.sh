#!/bin/bash
# box-sound-restart.sh — zvuková karta se právě objevila: přenastavit ALSA
# a restartovat službu, která drží otevřený PCM.
#
# Spouští se z udev pravidla (99-box-sound.rules) přes SYSTEMD_WANTS, ne ručně.
# Důvod: když se USB zvukovka přehodí nebo připojí, starý PCM v trackeru umře
# ("ALSA write failed (unrecoverable): No such device") a SDL už ho znovu
# neotevře — služba pak běží dál celý den v tichu. Nový proces si otevře čerstvé
# zařízení, takže se zvuk sám vrací bez zásahu.
#
# Testovatelnost (viz tests/test-box-sound-restart.sh): kořeny i příkaz pro
# restart lze přesměrovat, aby se pustil nad falešným stromem bez systemd.
#   ABC38_ASOUND_PROC  default /proc/asound      (jen kvůli výpisu karty)
#   ABC38_ASOUND_CONF  default /etc/asound.conf  (propisuje se do setupu)
#   BOX_ALSA_SETUP     default /usr/local/sbin/box-alsa-setup.sh
#   RESTART_UNITS      default "tracker.service" (Box B: "sampler.service",
#                      prázdné = restartovat nic)
#   RESTART_CMD        default "systemctl restart"
#                      (ne try-restart-or-restart — to umí až systemd 254,
#                       Raspberry Pi OS bookworm má 252)
#   SETTLE_SEC         default 3  (karty se v /proc objeví postupně)
#   SKIP_SETTLE=1      čekat přeskočit (testy)

set -u

PROC="${ABC38_ASOUND_PROC:-/proc/asound}"
CONF="${ABC38_ASOUND_CONF:-/etc/asound.conf}"
SETTLE_SEC="${SETTLE_SEC:-3}"
RESTART_UNITS="${RESTART_UNITS-tracker.service}"
RESTART_CMD="${RESTART_CMD:-systemctl restart}"

SETUP="${BOX_ALSA_SETUP:-/usr/local/sbin/box-alsa-setup.sh}"
if [ ! -x "$SETUP" ]; then
    SETUP="$(cd "$(dirname "$0")" && pwd)/box-alsa-setup.sh"
fi

# stderr jedou do journalu (SyslogIdentifier v unitu), logger by je zdvojil
log() { echo "box-sound-restart: $*" >&2; }

# Bez chvilky čekání by se ptal na stav karty dřív, než se v /proc objeví celá.
[ "${SKIP_SETTLE:-0}" = 1 ] || sleep "$SETTLE_SEC"

if [ -r "$PROC/cards" ]; then
    log "karty: $(tr '\n' ';' < "$PROC/cards" | tr -s ' ')"
else
    log "POZOR: $PROC/cards nečitelný — karta možná teprve vytočí"
fi

if [ -x "$SETUP" ]; then
    if ! ABC38_ASOUND_CONF="$CONF" "$SETUP"; then
        log "box-alsa-setup.sh selhal"
    fi
else
    log "POZOR: $SETUP není spustitelný, $CONF zůstává beze změny"
fi

for unit in $RESTART_UNITS; do
    if $RESTART_CMD "$unit"; then
        log "restartováno: $unit"
    else
        log "restart $unit selhal (nainstalovaná?)"
    fi
done
