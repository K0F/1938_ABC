#!/bin/bash
# box-button-test.sh — testovací režim boxu A: čeká na 433 MHz tlačítko
# a přehrává vzorek přes zesilovač.
#
# Přijímač SRX882S je na GPIO15 a na boxu A, ale zesilovač (ALSA karta
# `usb` = AXAGON, /dev/snd/pcmC4D0p) drží tracker. `hw:` je exkluzivní —
# dvě aplikace ho neotevřou současně. Proto tenhle režim bere zesilovač
# trackeru a vrací ho zpát při `stop`.
#
#   usage: sudo ./box-button-test.sh start
#          sudo ./box-button-test.sh stop
#          sudo ./box-button-test.sh status
#
# Testovatelnost (viz tests/test-box-button-test.sh): každý externí
# příkaz i cesta jde přepsat, aby se pustil nad falešným stromem.
#   SYSTEMCTL     default systemctl
#   SYSTEMD_RUN   default systemd-run
#   MAKE          default make
#   AMP_PCM       default odhadnuto z `card N` v /etc/asound.conf
#                 (příp. BOX_ASOUND_CONF, BOX_SOUND_SYSFS)
#   LOG           default $SCRIPT_DIR/btn.log
#   BIN           default $SCRIPT_DIR/sampler
#   MAP           default $SCRIPT_DIR/map.csv
#   RF_PIN        default 15        (BCM linka DATA přijímače)
#   BOX_LETTER    default b        (jen nápis na LCD; sampler zná b|c)
#   SKIP_WAIT=1   nekontrolovat uvolnění karty
#   SKIP_BUILD=1  nepřepisovat binárku
#   WAIT_SEC=N    čekání na uvolnění karty (default 5)
#   TRACKER_WAIT_SEC=N  čekání na tracker po stop (default 15)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SYSTEMD_RUN="${SYSTEMD_RUN:-systemd-run}"
MAKE="${MAKE:-make}"
BOX_ASOUND_CONF="${BOX_ASOUND_CONF:-/etc/asound.conf}"
AMP_PCM="${AMP_PCM:-}"
LOG="${LOG:-$SCRIPT_DIR/btn.log}"
BIN="${BIN:-$SCRIPT_DIR/sampler}"
MAP="${MAP:-$SCRIPT_DIR/map.csv}"
RF_PIN="${RF_PIN:-15}"
BOX_LETTER="${BOX_LETTER:-b}"
WAIT_SEC="${WAIT_SEC:-5}"
# Kolik čekat na tracker po vrácení karty. Padá jednou na kameře, pak
# systemd restartuje; 15 s schová i ten restart.
TRACKER_WAIT_SEC="${TRACKER_WAIT_SEC:-15}"
SKIP_WAIT="${SKIP_WAIT:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

TRACKER_UNIT="${TRACKER_UNIT:-tracker.service}"
# Transientní jednotka, ne nohup: sampler musí přežít zavření ssh relace
# i sudo. setsid/nohup nestačí (relace to občas zabila), systemd to
# řeší z definice. --collect smaže jednotku po skončení, aby se
# nezalagovala jako "failed" do dalšího startu.
TEST_UNIT="${TEST_UNIT:-box-button-test}"

die() { printf 'chyba: %s\n' "$*" >&2; exit 1; }

# Karta, kterou drží /etc/asound.conf (ctl.!default { card N }). Bez ní
# se jen ptáme, kdo drží pcmC0D0p, což by u jiného boxu klamalo.
guess_amp_pcm() {
    [ -n "$AMP_PCM" ] && { printf '%s' "$AMP_PCM"; return; }
    local n
    n="$(sed -n 's/.*card[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' \
         "$BOX_ASOUND_CONF" 2>/dev/null | head -1)"
    [ -n "$n" ] || { printf '/dev/snd/pcmC0D0p'; return; }
    printf '/dev/snd/pcmC%sD0p' "$n"
}
AMP_PCM="$(guess_amp_pcm)"

# Kdo drží zařízení? fuser píše na stderr:
#   /dev/snd/pcmC4D0p:   root   13356 F.... sampler
# Vec: sampler běží jako root (systemd transientní jednotka) a `fuser`
# bez práv ukáže jen procesy vlastního uživatele — status by pak tvrdil
# "volný", i když kartu drží. Proto bezpečně zkusíme sudo -n.
fuser_pcm() {
    if [ "$(id -u)" = 0 ]; then
        fuser "$AMP_PCM" 2>&1
    else
        sudo -n fuser "$AMP_PCM" 2>&1 || fuser "$AMP_PCM" 2>&1
    fi
}

amp_holder() {
    # ^ kotva je schválně: `fuser` na neexistující zařízení vypíše
    # "does not exist." a to by se tu vyřadilo jako falešný držitel.
    fuser_pcm | grep -E "^${AMP_PCM}" \
        | sed -E "s#^.*${AMP_PCM}:?[[:space:]]*##" | tr -s ' ' | sed 's/^ //;s/ $//'
}

sampler_running() { [ "$($SYSTEMCTL is-active "$TEST_UNIT" 2>/dev/null)" = active ]; }

tracker_active() { [ "$($SYSTEMCTL is-active "$TRACKER_UNIT" 2>/dev/null)" = active ]; }

# is-active vypíše "inactive"/"unknown" a vrátí nenulově; bez toho || echo
# by se na řádek přidal druhý text.
tracker_state() { $SYSTEMCTL is-active "$TRACKER_UNIT" 2>/dev/null || true; }

do_start() {
    if sampler_running; then
        echo "sampler už běží (test režim je aktivní)"; show_status; return 0
    fi

    if [ "$SKIP_WAIT" = 0 ] && [ -e "$AMP_PCM" ]; then
        local holder
        holder="$(amp_holder)"
        if [ -n "$holder" ]; then
            echo "zesilovač drží: $holder"
        fi
    fi

    echo "zastavuji $TRACKER_UNIT (bere si zesilovač)"
    $SYSTEMCTL stop "$TRACKER_UNIT" || true

    if [ "$SKIP_WAIT" = 0 ] && [ -e "$AMP_PCM" ]; then
        local i=0
        while [ "$i" -lt "$WAIT_SEC" ]; do
            [ -z "$(amp_holder)" ] && break
            i=$((i + 1)); sleep 1
        done
        if [ -n "$(amp_holder)" ]; then
            die "zesilovač pořád drží $(amp_holder) — nešlo uvolnit.
Něco ho drží dál, nejvíc samotný tracker. Zkus:
  sudo fuser -v $AMP_PCM"
        fi
        echo "zesilovač volný"
    fi

    if [ "$SKIP_BUILD" = 0 ]; then
        echo "sestavuji sampler"
        $MAKE -C "$SCRIPT_DIR" sampler || die "sestavení samplera selhalo"
    fi
    [ -x "$BIN" ] || die "chybí binárka samplera: $BIN"
    [ -f "$MAP" ]  || die "chybí mapa tlačítek: $MAP"

    # --lcd-addr off: box A nemá I2C displej. --box b: sampler umí jen
    # b|c (A je v návrhu tracker) a je to jen nápis na LCD.
    # Bez --allow-restart: kláč F je na boxu A nefunkční (viz README).
    # Transientní jednotka místo nohup/setsid: musí přežít zavření ssh
    # relace i sudo. Výstup jde do LOGu, aby šel číst i bez journalu.
    # --lcd-addr off: box A nemá I2C displej. --box b: sampler umí jen
    # b|c (A je v návrhu tracker) a je to jen nápis na LCD.
    # Bez --allow-restart: kláč F je na boxu A nefunkční (viz README).
    # Log při startu přepisujeme, jinak se po několika pokusech v něm
    # hromadí startovní bannery a není poznat, který běží. (StandardOutput
    # =write: tu není, tenhle systemd umí jen append:/file:.)
    : > "$LOG"
    echo "spouštím sampler jako $TEST_UNIT (rf=gpio$RF_PIN, log: $LOG)"
    $SYSTEMD_RUN --unit="$TEST_UNIT" --collect \
        -p WorkingDirectory="$SCRIPT_DIR" \
        -p StandardOutput="append:$LOG" \
        -p StandardError="append:$LOG" \
        -- "$BIN" --box "$BOX_LETTER" --lcd-addr off \
           --rf-pin "$RF_PIN" --map "$MAP" >/dev/null 2>&1 \
        || die "systemd-run selhal"
    sleep 2

    if ! sampler_running; then
        echo "--- log ---"; cat "$LOG" >&2
        die "sampler se nespustil; uvedený tracker zůstává zastavený.
 vrať ho:  sudo $SYSTEMCTL start $TRACKER_UNIT"
    fi
    echo
    show_status
    cat <<EOF

Test režim běží. Stiskni tlačítka A-E, výpisy jdou do:
  $LOG
  tail -f $LOG

Zpátky na sledování kuličky:
  sudo ./box-button-test.sh stop
EOF
}

do_stop() {
    if sampler_running; then
        echo "zastavuji sampler (vrátím zesilovač trackeru)"
        $SYSTEMCTL stop "$TEST_UNIT" || true
        # než dáme kartu trackeru, počkáme až sampler fakt uvolní
        local i=0
        while [ "$i" -lt 3 ] && [ -n "$(amp_holder)" ]; do
            i=$((i + 1)); sleep 1
        done
    fi
    # Pořadí je důležité: sampler musí pustit kartu, jinak tracker
    # Mix_OpenAudio selže a služba se cykluje (viz StartLimitIntervalSec=0
    # v tracker.service).
    echo "spouštím $TRACKER_UNIT"
    $SYSTEMCTL start "$TRACKER_UNIT" || die "$TRACKER_UNIT se nespustil"
    # Ne pevný sleep: karta po sampleru bývá chvíli nedostupná a tracker
    # padá na kameře při prvním startu, takže systemd ho jednou restartuje.
    # (viz StartLimitIntervalSec=0 v tracker.service). Musíme čekat na
    # 'active', ne na výstup systemctl start.
    local i=0
    while [ "$i" -lt "$TRACKER_WAIT_SEC" ] && ! tracker_active; do
        i=$((i + 1)); sleep 1
    done
    if tracker_active; then
        echo "$TRACKER_UNIT: active"
    else
        die "$TRACKER_UNIT po startu není active — mrkni do journalu:
  journalctl -u $TRACKER_UNIT -n 20"
    fi
}

show_status() {
    printf 'tracker : %s\n' "$(tracker_state)"
    if sampler_running; then
        printf 'sampler : běží (test režim, rf=gpio%s)\n' "$RF_PIN"
    else
        printf 'sampler : neběží\n'
    fi
    local holder
    holder="$(amp_holder)"
    if [ -n "$holder" ]; then
        printf 'zesilovač: drží %s\n' "$holder"
    else
        printf 'zesilovač: volný\n'
    fi
}

case "${1:-status}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) show_status ;;
    restart) do_stop; do_start ;;
    *) echo "usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
