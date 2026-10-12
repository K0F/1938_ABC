#!/bin/bash
# tests/test-tracker-buttons.sh — RF tlačítka (map.csv -> vzorky) ve sloučeném
# trackeru na boxu A.
#
# Tracker má teď v sobě i sampler: jedno SDL_mixer a jedno GPIO15. Tenhle test
# jede bez kamery, bez GPIO a bez zvukové karty — kódy posílá přes --simulate
# (stdin) a ověřuje, že se z mapy vybere správný vzorek, že debounce potlačí
# retransmise tlačítka a že akční sloty @stopall/@interact fungují (@stopall
# bez --allow-restart se jen ohlásí, @interact root needá). Simulace nepotřebuje raylib okno ani OpenCV video backend,
# ale binárka je linkovaná proti nim, takže se test skipne, když nejsou.
#
#   usage: ./tests/test-tracker-buttons.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/tracker"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

skip() { echo "$1"; exit 77; }

runnable() { [ -x "$BIN" ] && "$BIN" --version >/dev/null 2>&1; }

build() {
    if [ -x "$BIN" ] && [ "$BIN" -nt "$ROOT/main.c" ] && [ "$BIN" -nt "$ROOT/buttons.c" ] && runnable; then
        return 0
    fi
    echo "== build trackeru =="
    rm -f "$BIN"
    if ! make -C "$ROOT" tracker >"$TMP/build.log" 2>&1; then
        echo "    tracker se tu nepovede sestavit (chybí OpenCV/raylib/SDL2?):"
        sed 's/^/      /' "$TMP/build.log" | tail -8
        skip "  SKIP — nainstaluj libopencv-dev libraylib-dev libsdl2-mixer-dev, nebo pust na Pi"
    fi
    runnable || skip "  SKIP — sestavený tracker nenaběhne (chybí runtime knihovna?)"
}

build

# Spuštění bez kamery/zvuku/GPIO; kódy lezou po stdin.
trk() {
    "$BIN" --headless --no-rf --no-audio --simulate "$@"
}

echo "== 1) mapa se načte a ohlásí počet slotů =="
mkdir -p "$TMP/samples"
: > "$TMP/samples/a.wav"
: > "$TMP/samples/b.wav"
printf '1111, a.wav\n2222, b.wav\n' > "$TMP/map.csv"
OUT="$(trk --map "$TMP/map.csv" --samples-dir "$TMP/samples" </dev/null 2>&1)"
printf '%s\n' "$OUT" | grep -q 'map: 2 slot(s)' \
    && ok "2 slot(y) z mapy" \
    || bad "počet slotů nesedí: $(printf '%s' "$OUT" | tr '\n' '|')"

echo "== 2) kód z mapy spustí svůj vzorek =="
# Bez zvukové karty (--no-audio) se vzorek nepřehraje, ale dispatch musí
# proběhnout a v logu je vidět, který sampl by hrál — právě podle toho se
# na bezhlavém boxu pozná, že tlačítko chytí.
OUT="$(printf '1111\n' | trk --map "$TMP/map.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=1111 -> a.wav (S01, #1)' \
    && ok "kód 1111 -> a.wav" \
    || bad "dispatch nesedí: $(printf '%s' "$OUT" | tr '\n' '|')"
# a.wav je prázdný soubor -> sampl nejde načíst; stisk se přesto nesmí ztratit
printf '%s\n' "$OUT" | grep -qE '\[no-audio\]|one-shot|NENACHRANY' \
    && ok "stisk neztracen i bez hratelného samplu" \
    || bad "chybí marker v logu"

echo "== 3) debounce: retransmise tlačítka = jeden stisk =="
# 433 MHz tlačítko posílá rámec víckrát; default debounce 2000 ms musí
# sloučit dva rychlé stisky do jednoho řádku, jinak journal zaplaví #N.
OUT="$(printf '1111\n1111\n1111\n' | trk --map "$TMP/map.csv" --samples-dir "$TMP/samples" 2>&1)"
N="$(printf '%s\n' "$OUT" | grep -c 'code=1111 ->')"
[ "$N" = 1 ] && ok "tři rámce po sobě = jeden řádek" || bad "vypsalo se to $N× místo jednou"
printf '%s\n' "$OUT" | grep -q '#1)' && ok "počet stisků je 1" || bad "počet stisků je jiný"

echo "== 4) dva různé kódy se počítají zvlášť =="
OUT="$(printf '1111\n2222\n' | trk --map "$TMP/map.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=1111.*#1)' && ok "první stisk #1" || bad "první stisk nemá #1"
printf '%s\n' "$OUT" | grep -q 'code=2222.*#2)' && ok "druhý stisk #2" || bad "druhý stisk nemá #2"

echo "== 5) kód mimo mapu se jen ohlásí =="
OUT="$(printf '9999\n' | trk --map "$TMP/map.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=9999 not in map' \
    && ok "nezmapovaný kód nahlášen" \
    || bad "nezmapovaný kód prošel tiše: $(printf '%s' "$OUT" | tr '\n' '|')"

echo "== 6) @stopall: bez --allow-restart se ignoruje (s varováním) =="
printf '1111, a.wav\n5089457, @stopall\n' > "$TMP/map-stop.csv"
OUT="$(printf '5089457\n' | trk --map "$TMP/map-stop.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -qi 'allow-restart' \
    && ok "varování o --allow-restart" \
    || bad "chybí varování: $(printf '%s' "$OUT" | tr '\n' '|')"
printf '%s\n' "$OUT" | grep -q 'code=5089457 not in map' \
    && ok "@stopall mimo mapu bez rootu" \
    || bad "@stopall se přesto provedl: $(printf '%s' "$OUT" | tr '\n' '|')"

echo "== 6b) @stopall s --allow-restart umlčí vrstvy =="
OUT="$(printf '1111\n5089457\n' | trk --allow-restart --map "$TMP/map-stop.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=5089457 -> @stopall' \
    && ok "@stopall dispatchován" \
    || bad "@stopall nedispatchován: $(printf '%s' "$OUT" | tr '\n' '|')"
printf '%s\n' "$OUT" | grep -q '@stopall:.*umlceno' \
    && ok "vrstvy umlčeny" \
    || bad "chybí hlášení o umlčení"

echo "== 6c) @interact funguje i bez --allow-restart (nepotřebuje root) =="
# F teď v mapě není @stopall, ale @interact: umlčí vzorky a přepne
# interaction (smyčky). Na rozdíl od @stopall/@restart needá root, takže
# se nesmí zahodit jako @stopall bez --allow-restart.
printf '1111, a.wav\n5089457, @interact\n' > "$TMP/map-int.csv"
OUT="$(printf '5089457\n' | trk --map "$TMP/map-int.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=5089457 -> @interact (S02' \
    && ok "@interact dispatchován bez rootu" \
    || bad "@interact nedispatchován: $(printf '%s' "$OUT" | tr '\n' '|')"
printf '%s\n' "$OUT" | grep -qi 'allow-restart' \
    && bad "@interact zbytečně varuje o --allow-restart" \
    || ok "žádné varování o --allow-restart"

echo "== 6d) @interact dvakrát přepne interaction on -> off =="
OUT="$(printf '5089457\n5089457\n' | trk --debounce-ms 0 --map "$TMP/map-int.csv" --samples-dir "$TMP/samples" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'interaction: on' \
    && ok "první stisk = interaction on" \
    || bad "chybí 'interaction: on': $(printf '%s' "$OUT" | tr '\n' '|')"
printf '%s\n' "$OUT" | grep -q 'interaction: off' \
    && ok "druhý stisk = interaction off" \
    || bad "chybí 'interaction: off'"

echo "== 7) --help vypíše nové volby sloučeného trackeru =="
OUT="$("$BIN" --help 2>&1)"
for opt in --map --samples-dir --allow-restart --fade-ms --stop-fade-ms --debounce-ms --te-us --no-audio --simulate; do
    printf '%s\n' "$OUT" | grep -q -- "$opt" || bad "--help nezná $opt"
done
printf '%s\n' "$OUT" | grep -q -- '--allow-restart' && ok "--help zná nové volby"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
