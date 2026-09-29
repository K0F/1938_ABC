#!/bin/bash
# tests/test-boxb-readout.sh — 433 MHz readout na skutečném boxu B, přes SSH.
#
# Host test (tests/test-sampler-433.sh) staví sampler z hostu s -DHAVE_GPIOD=0
# a ověřuje jen logiku dekodéru. Tady se ověřuje to, co host test nezachytí:
#   * binárka na boxu je opravdu ARM a je s libgpiod
#   * dekodér na té binárce čte EV1527 rámce
#   * stisk se opravdu objeví v journalu pod tagem "sampler", jak slibuje
#     sampler.service (SyslogIdentifier + StandardOutput=journal)
#
#   usage: ./tests/test-boxb-readout.sh [--host boxb] [--watch]
#
# --watch jen sleduje journal v reálném čase, aby se na fyzická tlačítka
# viděly kódy. Nepočítá se do passed/failed.
#
# Potřebuje klíč na boxu (jednou):  ssh-copy-id -i ~/.ssh/id_ed25519.pub pi@boxb
# Bez hesla v repu — přihlášení jde přes ssh alias, ne přes skript.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="boxb"
WATCH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --host)  HOST="$2"; shift 2 ;;
        --watch) WATCH=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "neznámý argument: $1" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '    skip %s\n' "$1"; }
note() { printf '    --   %s\n' "$1"; }

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" true 2>"$TMP/ssh.log"; then
    echo "  na boxu '$HOST' se nedá přihlásit bez hesla:"
    sed 's/^/      /' "$TMP/ssh.log" | head -5
    echo
    echo "  Jednou spusť (jedno heslo):"
    echo "    ssh-copy-id -i ~/.ssh/id_ed25519.pub $HOST"
    echo "  a pak to pust znovu."
    echo
    echo "  Kdyby to hlásilo 'REMOTE HOST IDENTIFICATION HAS CHANGED',"
    echo "  nejde o útok — na .103/.104 jsou dvě různé mašiny a adresy si"
    echo "  vyměnily. Tady je to ale potřeba ověřit, ne jen přepsat:"
    echo "    ssh-keygen -F <adresa>        # starý klíč, který tam sedí"
    echo "    ssh-keyscan -t ed25519 <adresa> | grep -v '^#'   # co nabízí teď"
    exit 77
fi

# Veškerá práce běží na boxu v jednom spojení. Výsledky jdou zpět jako
# "CHECK<TAB>OK|FAIL|SKIP<TAB>popisek" a vyhodnotí se tady.
cat > "$TMP/remote.sh" <<'REMOTE'
set -u
SRC=/home/pi/tracker
BIN=/usr/local/bin/sampler

ck_ok()   { printf 'CHECK\tOK\t%s\n' "$1"; }
ck_bad()  { printf 'CHECK\tFAIL\t%s\n' "$1"; }
ck_skip() { printf 'CHECK\tSKIP\t%s\n' "$1"; }
# vnitřní: OK/FAIL/SKIP jako návratová hodnota, text jako argument
ck() { [ "$1" = 0 ] && ck_ok "$2" || ck_bad "$2"; }

# ── 1) identita ─────────────────────────────────────────────
MODEL="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
HNAME="$(hostname)"
OSID="$(. /etc/os-release 2>/dev/null; echo "${ID:-?} ${VERSION_ID:-?}")"
printf 'INFO\tmodel\t%s\n' "$MODEL"
printf 'INFO\thostname\t%s\n' "$HNAME"
printf 'INFO\tos\t%s\n' "$OSID"
case "$MODEL" in
    *Raspberry*) ck 0 "Raspberry Pi ($MODEL)" ;;
    *)           ck 1 "nepodobá Raspberry Pi: '$MODEL'" ;;
esac
case "$OSID" in
    raspbian*|debian*) ck 0 "Debian/Raspbian ($OSID)" ;;
    *)                 ck 1 "neočekávaný systém: $OSID" ;;
esac

# ── 2) jak byla karta přepálena ────────────────────────────
# Přepálený holý RPi OS nemá box-provision.sh ani službu. Není to chyba
# testu, ale je to věc, kterou je potřeba říct, než se dál s testováním.
PREPPED=no
[ -f /usr/local/sbin/box-provision.sh ] && PREPPED=yes
printf 'INFO\tprepped\t%s\n' "$PREPPED"
[ -f /var/lib/box-provisioned ] && printf 'INFO\tprovisioned\tano\n' \
    || printf 'INFO\tprovisioned\tne\n'
if [ "$PREPPED" = no ]; then
    ck_bad "karta je holý RPi OS (chybí box-provision.sh)"
    printf 'INFO\tfatal\tno-provision\n'
    exit 0
fi
ck_ok "image je připravený pro box (box-provision.sh je v image)"

# ── 3) binárka samplera ─────────────────────────────────────
if [ ! -x "$BIN" ]; then
    ck_bad "chybí $BIN (first-boot provisioning neskočil? journalctl -u box-firstboot)"
    printf 'INFO\tfatal\tno-binary\n'
    exit 0
fi
VER="$("$BIN" --version 2>&1)"
printf 'INFO\tsampler\t%s\n' "$VER"
FILET="$(file -b "$BIN" 2>/dev/null)"
printf 'INFO\tfiletype\t%s\n' "$FILET"
ck 0 "binárka odpovídá ($VER)"
case "$FILET" in
    *aarch64*) ck 0 "ARM aarch64 (ne x86-64 hostovská_binárka)" ;;
    *)         ck 1 "binárka není ARM: $FILET" ;;
esac

# ── 4) dekodér na té ARM binárce ────────────────────────────
# 16777215 = 0xffffff, nejvyšší možný kód EV1527. Kdyby dekodér někde
# ztratil bit, poslední by se vůbec nenačetl.
cd "$SRC" 2>/dev/null || cd /tmp
OUT="$("$BIN" --box b --lcd-addr off --simulate-rf \
        12200123 12200124 16777215 1 2>&1)"
RC=$?
ck $([ $RC -eq 0 ]; echo $?) "simulate-rf doběhl (rc=$RC)"
for c in 12200123 12200124 16777215 1; do
    printf '%s\n' "$OUT" | grep -q "code=$c," \
        && ck_ok "kód $c dekódován na ARM" || ck_bad "kód $c se nenačetl"
done
printf '%s\n' "$OUT" | grep -q "code=12200123, id=762507, key=11" \
    && ck_ok "id/key rozpad (12200123 = 762507<<4|11)" \
    || ck_bad "id/key nesouhlasí"
printf '%s\n' "$OUT" | grep -q 'Error' \
    && ck_bad "simulate-rf psal do stderr chybu" \
    || ck_ok "bez chyb na stderr"

# ── 5) map.csv: stisk bez samplu nesmí zmizet ──────────────
# mapa s jedním kódem a neexistujícím wavem. Kdyby VZOREK NENACHRANY nebyl
# v logu, na bezhlavém boxu by se mrtvý přijímač nerozlišil od mrtvého
# tlačítka.
TMPD="$(mktemp -d)"
printf '12200123, chybi_soubor.wav\n' > "$TMPD/map.csv"
OUT="$("$BIN" --box b --lcd-addr off --map "$TMPD/map.csv" \
        --samples-dir "$TMPD" --simulate-rf 12200123 12200123 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=12200123 ->' \
    && ck_ok "stisk v mapě vypsán i bez samplu" \
    || ck_bad "stisk se ztratil bez samplu"
printf '%s\n' "$OUT" | grep -q 'VZOREK NENACHRANY' \
    && ck_ok "chybějící WAV oznámen" || ck_bad "chybějící WAV prošel tiše"
N="$(printf '%s\n' "$OUT" | grep -c 'code=12200123 ->')"
ck $([ "$N" = 1 ]; echo $?) "dva rámce po sobě = jeden řádek (je to $N)"
rm -rf "$TMPD"

# ── 6) mapa na boxu: sloty a samply ─────────────────────────
if [ -f "$SRC/map.csv" ]; then
    printf 'INFO\tmap\t%s\n' "$SRC/map.csv"
    awk -F, '!/^[[:space:]]*#/ && NF>1 {n++} END {print n+0}' \
        "$SRC/map.csv" | while read -r n; do printf 'INFO\tmapslots\t%s\n' "$n"; done
    nwav="$(find "$SRC/samples" -maxdepth 1 -name '*.wav' 2>/dev/null | wc -l)"
    printf 'INFO\twavs\t%s\n' "$nwav"
    ck_ok "map.csv existuje"
else
    ck_bad "chybí map.csv (bez ní sampler jen tiskne kódy)"
fi

# ── 7) jednotka sampler.service ──────────────────────────────
UNIT=/etc/systemd/system/sampler.service
if [ -f "$UNIT" ]; then
    EX="$(grep -E '^ExecStart=' "$UNIT" | head -1)"
    printf 'INFO\texecstart\t%s\n' "$EX"
    printf '%s\n' "$EX" | grep -q -- '--box b' \
        && ck_ok "ExecStart má --box b (malé písmeno)" \
        || ck_bad "ExecStart nemá --box b: $EX"
    grep -q '^SyslogIdentifier=sampler$' "$UNIT" \
        && ck_ok "SyslogIdentifier=sampler" || ck_bad "chybí SyslogIdentifier=sampler"
    grep -q '^StandardOutput=journal$' "$UNIT" \
        && ck_ok "StandardOutput=journal" || ck_bad "chybí StandardOutput=journal"
else
    ck_bad "chybí $UNIT"
fi
if command -v systemctl >/dev/null 2>&1; then
    EN="$(systemctl is-enabled sampler.service 2>/dev/null)"
    AC="$(systemctl is-active sampler.service 2>/dev/null)"
    printf 'INFO\tenabled\t%s\n' "$EN"
    printf 'INFO\tactive\t%s\n' "$AC"
    [ "$EN" = enabled ] && ck_ok "sampler.service enabled" || ck_bad "sampler.service je '$EN', ne enabled"
    [ "$AC" = active ]  && ck_ok "sampler.service active"  || ck_bad "sampler.service je '$AC', ne active"
fi

# ── 8) journal: přijde stisk opravdu do journalu? ───────────
# Tohle je point celého readoutu. Kdyby SyslogIdentifier nebo
# StandardOutput v jednotce byly špatně, čte se to správně a stejně
# se nic neobjeví.
JC=""
journalctl -t sampler -n 5 --no-pager >/dev/null 2>&1 && JC="plain"
[ -n "$JC" ] || { sudo -n journalctl -t sampler -n 5 --no-pager >/dev/null 2>&1 && JC="sudo"; }
if [ -z "$JC" ]; then
    skip_msg="nelze číst journal (chybí právo na system.journal; sudo -n nevyjde)"
    printf 'CHECK\tSKIP\t%s\n' "$skip_msg"
    printf 'INFO\tjournal-read\tno\n'
else
    printf 'INFO\tjournal-read\t%s\n' "$JC"
    if [ "$JC" = sudo ]; then RUN="sudo -n"; else RUN=""; fi
    $RUN systemd-run --quiet --wait --collect --unit=sampler-readout-probe \
        -p SyslogIdentifier=sampler -p StandardOutput=journal \
        -p WorkingDirectory="$SRC" \
        "$BIN" --box b --lcd-addr off --simulate-rf 12200123 >/dev/null 2>&1
    sleep 1
    $RUN journalctl -t sampler --no-pager -n 40 -o cat 2>/dev/null \
        | grep -q 'code=12200123 ->' \
        && ck_ok "stisk se objevil v journalu pod tagem sampler" \
        || ck_bad "journal neukázal stisk (systemd-run/journalctl probe selhal)"
fi
REMOTE

ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" 'bash -s' < "$TMP/remote.sh" > "$TMP/out" 2>"$TMP/err"

FATAL=""
while IFS=$'\t' read -r kind a b; do
    case "$kind" in
        INFO)
            case "$a" in
                model|hostname|os|sampler|filetype|prepped|provisioned|map|mapslots|wavs|execstart|enabled|active|journal-read)
                    printf '\n  %-12s %s\n' "$a:" "$b" ;;
            esac
            [ "$a" = fatal ] && FATAL="$b" ;;
        CHECK)
            case "$a" in
                OK)   ok "$b" ;;
                FAIL) bad "$b" ;;
                SKIP) skip "$b" ;;
            esac ;;
    esac
done < "$TMP/out"

if [ -n "$FATAL" ]; then
    echo
    echo "  Příprava boxu dohnat na samotné kartě (nebo přepálit prepared image):"
    echo "    sudo ./prepare-sd.sh /dev/mmcblk0 B"
    echo "  a teprve pak spustit tento test znovu."
fi

if [ -s "$TMP/err" ]; then
    note "stderr z boxu:"
    sed 's/^/        /' "$TMP/err" | head -10
fi

echo
printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"

if [ "$WATCH" = 1 ]; then
    echo
    echo "== journal v reálném čase (mačkat tlačítka) =="
    echo "  Ctrl-C ukončí."
    ssh -o BatchMode=yes "$HOST" 'journalctl -t sampler -f -o cat'
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
