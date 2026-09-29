#!/bin/bash
# tests/test-box-button-test.sh — testovací režim na boxu A nad falešnými příkazy.
#
# Skript staví sampler jako transientní jednotku a bere trackeru zvukovač,
# takže se na hostu nedá spustit (chybí GPIO, systemd transientní jednotky
# a root). Tady se pustí nad prázdným stromem s falešnými systemctl/systemd-run,
# aby se ověřilo pořadí kroků a předávané parametry — bez GPIO a bez zvuku.
#
# Pravidlo, které se tu láme na zúžku: sampler musí jet jako root v
# transientní jednotce, protože plain nohup/setsid umírel s ssh relací
# a `fuser` bez práv nevidí cizí (root) procesy, takže status lhal,
# že je zařízení volné, a tracker.start pak dostal obsazenou kartu.
#
#   usage: ./tests/test-box-button-test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-button-test.sh"
[ -f "$SCRIPT" ] || { echo "chybi $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

# Stav testovací jednotky se řídí souborem, ať šel ověřit i start->stop.
UNITS="$TMP/units"
mkdir -p "$UNITS"

cat > "$TMP/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-active)
        # is-active vrací 3 pro inactive/failed, 4 pro "unit not found";
        # bez toho by testy nemohly rozlišit "běží" od "neznámá jednotka".
        if [ -f "$UNITS/$2" ]; then echo active; exit 0
        else echo inactive; exit 3; fi
        ;;
    stop)
        # stop musí jednotku opravdu sundat, jinak by po do_stop byl
        # sampler_running stále true a start si postesoval.
        rm -f "$UNITS/$2"
        ;;
    start)
        # start naopak musí jednotku založit, jinak by do_stop skončil
        # na "tracker po startu není active" a vše za ním by umřelo.
        : > "$UNITS/$2"
        ;;
esac
exit 0
EOF
chmod 755 "$TMP/systemctl"

# systemd-run zapíše jednotku jako "běžící" a uloží argv, podle kterého se
# pak dá ověřit, že sampler dostal správné parametry.
cat > "$TMP/systemd-run" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMD_RUN_LOG"
args=(); unit=""
while [ $# -gt 0 ]; do
    case "$1" in
        --unit=*) unit="${1#--unit=}" ;;
        --) shift; args=("$@"); break ;;
    esac
    shift
done
[ -n "$unit" ] && : > "$UNITS/$unit"
printf '%s\n' "${args[@]}" > "$UNITS/$unit.argv"
exit 0
EOF
chmod 755 "$TMP/systemd-run"

# Skutečný make by v testu chtěl SDL2/OpenCV a selhal. Falešný make
# vyrobí prázdnou binárku, aby prošel i test [ -x "$BIN" ] v skriptu.
cat > "$TMP/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$MAKE_LOG"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN"
chmod 755 "$FAKE_BIN"
exit 0
EOF
chmod 755 "$TMP/make"

# fuser vrací držitele jen podle FAKE_HOLDER (ať šel ověřit sdílení karty).
cat > "$TMP/fuser" <<'EOF'
#!/bin/bash
[ -n "${FAKE_HOLDER:-}" ] || exit 1
echo "$FAKE_DEV  ${FAKE_HOLDER}  F....  sampler"
exit 0
EOF
chmod 755 "$TMP/fuser"

# Skript zkouší `sudo -n fuser` (drží to cizí root proces), a teprve když
# to selže, tečkový fuser. Tady chceme, aby selhalo schválně a šel přes
# fallback, takže fake sudo jen zahodí -n a spustí zbytek.
cat > "$TMP/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && shift
exec "$@"
EOF
chmod 755 "$TMP/sudo"

export SYSTEMCTL_LOG="$TMP/systemctl.log"
export SYSTEMD_RUN_LOG="$TMP/systemd-run.log"
export MAKE_LOG="$TMP/make.log"
export UNITS
export FAKE_DEV=""

run() {   # run start|stop|restart|status; stav fake fuseru přes FAKE_HOLDER
    FAKE_DEV="/dev/snd/pcmC4D0p" PATH="$TMP:$PATH" \
    SYSTEMCTL="$TMP/systemctl" SYSTEMD_RUN="$TMP/systemd-run" MAKE="$TMP/make" \
    BIN="$TMP/sampler" MAP="$TMP/map.csv" LOG="$TMP/btn.log" \
    AMP_PCM="/dev/snd/pcmC4D0p" RF_PIN=15 BOX_LETTER=b \
    FAKE_BIN="$TMP/sampler" SKIP_WAIT=1 \
    bash "$SCRIPT" "$@"
}

reset() { : > "$SYSTEMCTL_LOG"; : > "$SYSTEMD_RUN_LOG"; : > "$MAKE_LOG"; }

echo "== 1) start: zastaví tracker, spustí sampler jako transientní jednotku =="
reset
: > "$TMP/map.csv"
out="$(run start 2>&1)"
grep -q "stop tracker.service" "$SYSTEMCTL_LOG" \
    && ok "tracker zastaven (bere si zesilovač)" || bad "tracker nezastaven"
grep -q "start tracker.service" "$SYSTEMCTL_LOG" \
    && bad "start shodil tracker hned zpět" || ok "tracker zůstal stát"
grep -q -- "--unit=box-button-test" "$SYSTEMD_RUN_LOG" \
    && ok "sampler běží jako transientní jednotka" || bad "nejde o transientní jednotku"
grep -q -- "--collect" "$SYSTEMD_RUN_LOG" \
    && ok "jednotka se po skončení uklidí" || bad "chybí --collect"
# F je na boxu A nefunkční a bez --allow-restart by ho mapa odmítla;
# zároveň nesmí prosáknout do B, kde je F funkční.
grep -q -- "--allow-restart" "$UNITS/box-button-test.argv" \
    && bad "na boxu A prosákl --allow-restart (F by si myslel, že funguje)" \
    || ok "bez --allow-restart, jak má být na A"
# argv je po řádcích, takže se hledá v příkazovém řádku systemd-run
grep -q -- "--lcd-addr off" "$SYSTEMD_RUN_LOG" \
    && ok "LCD vypnuté (box A nemá displej)" || bad "chybí --lcd-addr off"
grep -q -- "--box b" "$SYSTEMD_RUN_LOG" \
    && ok "sampler dostal --box b" || bad "chybí --box b"
grep -q -- "--rf-pin 15" "$SYSTEMD_RUN_LOG" \
    && ok "RF na GPIO15" || bad "chybí --rf-pin 15"
grep -q -- "--map $TMP/map.csv" "$SYSTEMD_RUN_LOG" \
    && ok "sampler čte mapu" || bad "chybí --map"
grep -q "make" "$MAKE_LOG" \
    && ok "binárka se sestaví" || bad "binárka se nesestavila"

echo "== 2) start: nepřepíše log starými bannery =="
rm -f "$UNITS/box-button-test"      # jinak by start jen postesoval
printf 'starý banner\n' > "$TMP/btn.log"
run start >/dev/null 2>&1
grep -q 'starý banner' "$TMP/btn.log" \
    && bad "log se při startu nevyprázdnil" || ok "log se při startu přepíše"

echo "== 3) start: nepustí, když už sampler běží =="
: > "$UNITS/box-button-test"
reset
out="$(run start 2>&1)"
grep -q 'už běží' <<<"$out" && ok "druhý start si postesuje" || bad "druhý start startuje znovu"
[ -s "$SYSTEMD_RUN_LOG" ] && bad "zbytečně spustil druhou jednotku" \
    || ok "žádná druhá jednotka"

echo "== 4) stop: zastaví sampler, vrátí kartu, nastartuje tracker =="
reset
out="$(FAKE_HOLDER=4242 run stop 2>&1)"
grep -q "stop box-button-test" "$SYSTEMCTL_LOG" \
    && ok "sampler zastaven" || bad "sampler nezastaven"
grep -q "start tracker.service" "$SYSTEMCTL_LOG" \
    && ok "tracker znovu běží" || bad "tracker nenastartoval"
# Tracker nesmí dostat obsazenou kartu: čekáme na uvolnění (fuser drží,
# dokud FAKE_HOLDER nezmizí).
grep -q 'zesilovač' <<<"$out" && ok "hlásí stav zesilovače" || bad "nehlásí stav zesilovače"

echo "== 5) stop: čeká, až sampler uvolní kartu, teprve pak tracker =="
: > "$UNITS/box-button-test"
reset
# fuser drží, dokud jednotka existuje (= sampler neuhonil kartu). Kdyby
# skript čekal jinak, tracker.start by šel dřív než uvolnění.
cat > "$TMP/fuser" <<'EOF'
#!/bin/bash
[ -f "$UNITS/box-button-test" ] || exit 1
echo "$FAKE_DEV  root  999  F....  sampler"
exit 0
EOF
chmod 755 "$TMP/fuser"
out="$(run stop 2>&1)"
grep -q 'start tracker.service' "$SYSTEMCTL_LOG" \
    && ok "tracker nakonec nastartovan" || bad "tracker nenastartoval"
[ -f "$UNITS/box-button-test" ] \
    && bad "stop jednotku neukončil" || ok "stop jednotku ukončil"
# vrátit výchozí fuser pro test 6
cat > "$TMP/fuser" <<'EOF'
#!/bin/bash
[ -n "${FAKE_HOLDER:-}" ] || exit 1
echo "$FAKE_DEV  ${FAKE_HOLDER}  F....  sampler"
exit 0
EOF
chmod 755 "$TMP/fuser"

echo "== 5b) stop: vyčká na tracker, i když se jednou restartne (kamera) =="
# Reálná chyba z provozu: pevný 'sleep 2' + kontrola selhal, protože
# tracker padá na kameře a systemd ho restartuje (~4 s). Musí čekat na
# opakovaný is-active, ne na jediný po dvou sekundách.
cat > "$TMP/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-active)
        # Před prvním startem dvakrát inactive (padá na kameře), pak active.
        if [ -f "$UNITS/$2" ]; then echo active; exit 0
        fi
        n=$(( $(cat "$UNITS/.poc" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$UNITS/.poc"
        [ "$n" -ge 3 ] && { : > "$UNITS/$2"; echo active; exit 0; }
        echo inactive; exit 3
        ;;
    stop) rm -f "$UNITS/$2" ;;
    start) : > "$UNITS/$2" ;;
esac
exit 0
EOF
chmod 755 "$TMP/systemctl"
rm -f "$UNITS"/*
: > "$UNITS/box-button-test"
reset
out="$(TRACKER_WAIT_SEC=8 run stop 2>&1)"
grep -q 'tracker.service: active' <<<"$out" \
    && ok "stop vyčkal na restart trackeru" || bad "stop se na tohle nedotklal: $out"
grep -q 'není active' <<<"$out" \
    && bad "hodil chybu, i když tracker nakonec běží" \
    || ok "nevyhodil chybu, tracker běží"
# a opačně: když tracker nenastoupí vůbec, chyba zůstane
cat > "$TMP/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-active) echo inactive; exit 3 ;;
esac
exit 0
EOF
chmod 755 "$TMP/systemctl"
rm -f "$UNITS"/*
: > "$UNITS/box-button-test"
out="$(TRACKER_WAIT_SEC=1 run stop 2>&1)"
grep -q 'není active' <<<"$out" \
    && ok "když tracker nenastoupí, hlásí to" || bad "mlčí, i když tracker běží"
# vrátit původní fake systemctl pro testy 6-9
cat > "$TMP/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-active)
        if [ -f "$UNITS/$2" ]; then echo active; exit 0
        else echo inactive; exit 3; fi
        ;;
    stop)  rm -f "$UNITS/$2" ;;
    start) : > "$UNITS/$2" ;;
esac
exit 0
EOF
chmod 755 "$TMP/systemctl"

echo "== 6) status: nesmí lhát o root držiteli =="
# Každý test začíná z čistého stavu: jinak by zdědil jednotky
# z předchozího (např. tracker.service nastartovaný v testu 5).
rm -f "$UNITS"/*
reset
out="$(FAKE_HOLDER=7777 run status 2>&1)"
grep -q 'sampler : neběží' <<<"$out" \
    && ok "bez jednotky hlásí, že sampler neběží" || bad "špatný stav sampleru"
grep -q '7777' <<<"$out" \
    && ok "ukáže cizího (root) držitele, ne 'volný'" \
    || bad "držitele nevidí a lže, že je karta volná"
grep -q 'tracker : inactive' <<<"$out" \
    && ok "tracker inactive, bez duplicitního řádku" || bad "špatný stav trackeru"
[ "$(wc -l <<<"$out")" -eq 3 ] \
    && ok "status má 3 řádky" || bad "status má $(wc -l <<<"$out") řádků, ne 3"
grep -qE 'unknown' <<<"$out" \
    && bad "duplicitní 'unknown' z is-active" || ok "bez zdvojeného 'unknown'"

echo "== 7) restart =="
: > "$UNITS/box-button-test"
reset
run restart >/dev/null 2>&1
grep -q "stop box-button-test" "$SYSTEMCTL_LOG" \
    && ok "restart zastavil starý sampler" || bad "restart nezastavil starý"
grep -q -- "--unit=box-button-test" "$SYSTEMD_RUN_LOG" \
    && ok "restart spustil nový" || bad "restart nespustil nový"

echo "== 8) systemd-run selhal -> jasná chyba, ne tichý start =="
cat > "$TMP/systemd-run" <<'EOF'
#!/bin/bash
echo "Failed to start transient service unit: Invalid StandardOutput setting" >&2
exit 1
EOF
chmod 755 "$TMP/systemd-run"
rm -f "$UNITS/box-button-test"
if run start >/dev/null 2>&1; then
    bad "selhání systemd-run prošlo bez chyby"
else
    ok "selhání systemd-run je chyba"
fi

echo "== 9) nesmyslný podpříkaz je chyba, ale bez argumentu jen status =="
if run nesmysl >/dev/null 2>&1; then
    bad "nesmyslný podpříkaz prošlo"
else
    ok "nesmyslný podpříkaz vyhlásí chybu"
fi
run >/dev/null 2>&1 && ok "bez argumentu vypíše stav" || bad "bez argumentu spadne"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
