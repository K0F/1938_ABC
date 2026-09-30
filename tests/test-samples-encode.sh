#!/bin/bash
# tests/test-samples-encode.sh — samples-encode.sh převádí samples/raw/*.wav na samples/*.opus.
#
# Pustí se na hostu bez ffmpeg: FFMPEG se přesměruje na falešný skript,
# který jen vytvoří výstupní soubor. Jde tedy ověřit logiku (které soubory
# se převedou, co se přeskočí, jak se hlásí chyby), ne samotný převod.
#
#   usage: ./tests/test-samples-encode.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/samples-encode.sh"

[ -x "$SCRIPT" ] || { echo "chybí $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAW="$TMP/samples/raw"
DST="$TMP/samples"
mkdir -p "$RAW" "$DST"

# Falešný ffmpeg. Poslední argument je výstup (tak to posílá i samples-encode.sh),
# zapisuje se do logu, aby šlo poznat, kolikrát a co se převedlo.
#
# FAKE_FAIL_ON se vyhodnocuje PŘED zápisem do logu: kdyby se zapsalo napřed,
# log by hlásil 3 pokusy i u souboru, který selhal a nevznikl. Počítá se
# proto jen to, co ffmpeg skutečně dokončilo.
FAKE="$TMP/ffmpeg"
cat > "$FAKE" <<'FAKEEOF'
#!/bin/sh
eval "out=\${$#}"
[ -n "${FAKE_FAIL_ON:-}" ] && case "$out" in
    *"$FAKE_FAIL_ON"*) echo "fake ffmpeg: záměrná chyba" >&2; exit 1 ;;
esac
[ -n "${FAKE_LOG:-}" ] && echo "$out" >> "$FAKE_LOG"
: > "$out"
FAKEEOF
chmod +x "$FAKE"

# Prázdný adresář není chyba, stejně jako v samples-decode.sh: není co dělat,
# skončí to nulovým návratem. Chybou je až chybějící adresář (viz 7).
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" "$SCRIPT" >/dev/null 2>&1 \
    && ok "prázdný raw/ projde (není co převádět)" \
    || bad "prázdný raw/ hlásí chybu"

touch "$RAW/track1.wav"
touch "$RAW/Sokol(2).wav"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" FAKE_LOG="$TMP/log1" "$SCRIPT" >/dev/null 2>&1
[ -f "$DST/track1.opus" ] && ok "vznikl track1.opus" || bad "chybí track1.opus"
[ -f "$DST/Sokol(2).opus" ] && ok "vznikl Sokol(2).opus" || bad "chybí Sokol(2).opus"
c1="$(wc -l < "$TMP/log1")"
[ "$c1" -eq 2 ] && ok "převedl 2 soubory" || bad "převedl $c1 místo 2"

echo "== 2) --force vždy převede =="
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" FAKE_LOG="$TMP/log2" "$SCRIPT" --force >/dev/null 2>&1
c2="$(wc -l < "$TMP/log2")"
[ "$c2" -eq 2 ] && ok "--force pustil ffmpeg 2×" || bad "--force pustil ffmpeg $c2× místo 2×"

echo "== 3) druhý běh bez --force nic nepřevede =="
# Log si založíme dopředu, ať ho nemusíme číst, když ffmpeg nepoběhne vůbec —
# jinak by `wc -l < log` skončilo chybou a proměnná zůstala prázdná.
: > "$TMP/log3"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" FAKE_LOG="$TMP/log3" "$SCRIPT" >/dev/null 2>&1
c3="$(wc -l < "$TMP/log3")"
[ "$c3" -eq 0 ] && ok "druhý běh nic nepřevádí" || bad "druhý běh znovu převádí ($c3)"
[ -s "$TMP/log3" ] && bad "převáděl, i když neměl" || ok "ffmpeg se vůbec nepustil"

echo "== 4) Sokol(1).wav se přeskakuje jako duplikát =="
rm -rf "$RAW" "$DST"; mkdir -p "$RAW" "$DST"
touch "$RAW/Sokol.wav"
touch "$RAW/Sokol(1).wav"
touch "$RAW/Teskno.wav"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" FAKE_LOG="$TMP/log4" "$SCRIPT" >/dev/null 2>&1
c4="$(wc -l < "$TMP/log4")"
[ "$c4" -eq 2 ] && ok "Sokol(1) přeskočen, převedeny 2 soubory" || bad "převedeny $c4 místo 2 (Sokol(1) měl být přeskočen)"
[ ! -f "$DST/Sokol(1).opus" ] && ok "Sokol(1).opus nevznikl" || bad "Sokol(1).opus vznikl (duplicitní)"
[ -f "$DST/Sokol.opus" ] && ok "Sokol.opus vznikl" || bad "Sokol.opus chybí"
[ -f "$DST/Teskno.opus" ] && ok "Teskno.opus vznikl" || bad "Teskno.opus chybí"

echo "== 5) chybující ffmpeg je jasná chyba =="
# RC se musí vzít hned po skriptu. Kdyby se vzalo až po `ok`/`bad`, byla by
# to vratová hodnota té funkce, ne skriptu, a test by nic neověřoval.
FFMPEG="/neexistuje/ffmpeg" RAW_DIR="$RAW" SAMPLES_DIR="$DST" "$SCRIPT" >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "chybějící ffmpeg: nenulový návrat ($RC)" || bad "chybějící ffmpeg skončil 0"

# --help musí vypsat použití a skončit 0, ne jako chyba.
OUT="$("$SCRIPT" --help 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--help skončí 0" || bad "--help skončil $RC"
printf '%s' "$OUT" | grep -q -- "--force" && ok "--help vypíše --force" \
    || bad "--help nepopíše --force"
printf '%s' "$OUT" | grep -qi "256000\|256k" && ok "--help vypíše bitrate limit" \
    || bad "--help nezmíní bitrate limit"

echo "== 6) nesmyslný přepínač =="
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" "$SCRIPT" --nesmysl >/dev/null 2>&1 && bad "--nesmysl prošel" || ok "--nesmysl = chyba"

echo "== 7) RAW_DIR neexistuje =="
FFMPEG="$FAKE" RAW_DIR="$TMP/neni" SAMPLES_DIR="$DST" "$SCRIPT" >/dev/null 2>&1 && bad "neexistující raw prošel" || ok "neexistující raw hlásí chybu"

echo "== 8) bitrate mimo rozsah =="
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" BITRATE=320k "$SCRIPT" >/dev/null 2>&1 && bad "320k prošel" || ok "320k odmítnut (guard)"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" BITRATE=300000 "$SCRIPT" >/dev/null 2>&1 && bad "300000 prošel" || ok "300000 odmítnut (guard)"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" BITRATE=256000 "$SCRIPT" >/dev/null 2>&1 && ok "256000 prošel guardem" || bad "256000 neprošel guardem"

echo "== 9) izolace selhání =="
rm -rf "$RAW" "$DST"; mkdir -p "$RAW" "$DST"
touch "$RAW/a.wav"
touch "$RAW/b.wav"
touch "$RAW/c.wav"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" FAKE_LOG="$TMP/logfail" FAKE_FAIL_ON="c.opus" "$SCRIPT" >/dev/null 2>&1 && bad "selhání neprošlo jako chyba" || ok "selhání se započítá"
c_fail="$(wc -l < "$TMP/logfail")"
[ "$c_fail" -eq 2 ] && ok "převedly se jen a,b (c selhal)" || bad "převedeno $c_fail místo 2 (očekáváno 2)"

echo "== 10) index invariant: žádný soubor >100 MB =="
rm -rf "$RAW" "$DST"; mkdir -p "$RAW" "$DST"
touch "$RAW/x.wav"
FFMPEG="$FAKE" RAW_DIR="$RAW" SAMPLES_DIR="$DST" "$SCRIPT" >/dev/null 2>&1
HUGE="$(git -C "$ROOT" ls-files -s samples/ 2>/dev/null | while read -r _ h _ f; do
            s=$(git -C "$ROOT" cat-file -s "$h" 2>/dev/null) || continue
            [ "$s" -gt 104857600 ] && echo "$f"
          done | wc -l)"
[ "$HUGE" -eq 0 ] && ok "žádný vzorek v indexu nepřesahuje 100 MB" || bad "$HUGE vzorků přesahuje 100 MB"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
