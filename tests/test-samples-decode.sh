#!/bin/bash
# tests/test-samples-decode.sh — samples-decode.sh převádí samples/*.opus na WAV.
#
# Pustí se na hostu bez ffmpeg: FFMPEG se přesměruje na falešný skript,
# který jen vytvoří výstupní soubor. Jde tedy ověřit logika (které soubory
# se převedou, co se přeskočí, jak se hlásí chyby), ne samotný převod.
#
#   usage: ./tests/test-samples-decode.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/samples-decode.sh"

[ -x "$SCRIPT" ] || { echo "chybí $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

S="$TMP/samples"
mkdir -p "$S"

# Falešný ffmpeg. Poslední argument je výstup (tak to posílá i samples-decode.sh),
# zapisuje se do logu, aby šlo poznat, kolikrát a co se převedlo.
FAKE="$TMP/ffmpeg"
cat > "$FAKE" <<'FAKEEOF'
#!/bin/sh
eval "out=\${$#}"
[ -n "${FAKE_LOG:-}" ] && echo "$out" >> "$FAKE_LOG"
[ -n "${FAKE_FAIL_ON:-}" ] && case "$out" in
    *"$FAKE_FAIL_ON"*) echo "fake ffmpeg: záměrná chyba" >&2; exit 1 ;;
esac
: > "$out"
FAKEEOF
chmod +x "$FAKE"

run() { FAKE_LOG="$TMP/log" "$SCRIPT" "$@"; }

echo "== 1) prázdný adresář bez *.opus není chyba =="
OUT="$(SAMPLES_DIR="$S" FFMPEG="$FAKE" "$SCRIPT" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'nothing to do' \
    && ok "prázdné samples/ projde" \
    || bad "prázdné samples/ hlásí chybu  [$(printf '%s' "$OUT" | tr '\n' '|')]"

echo "== 2) každý .opus dostane .wav se stejným jménem =="
# Názvy s mezerou a závorkou jsou tu schválně — "Sokol(2).opus" je v repu
# reálně a právě na nich padalo naivní ${f%.opus} bez nullglobu.
: > "$S/Teskno.opus"
: > "$S/Sokol(2).opus"
: > "$S/Gro Teskno.opus"
OUT="$(SAMPLES_DIR="$S" FFMPEG="$FAKE" "$SCRIPT" 2>&1)"
for w in Teskno.wav "Sokol(2).wav" "Gro Teskno.wav"; do
    [ -f "$S/$w" ] && ok "vznikl $w" || bad "chybí $w"
done
printf '%s\n' "$OUT" | grep -q 'decoded 3' \
    && ok "hlásí decoded 3" \
    || bad "špatný součet  [$(printf '%s' "$OUT" | tr '\n' '|')]"

echo "== 3) --samples s .wav starším než .opus se převede znovu =="
# Převod musí jít spustit kdykoliv, ne jen v čistém stromu — po novém
# .opus z gitu musí starý WAV zůstat na disku přepsaný, jinak by box
# přehrával starou verzi vrstvy.
touch -d '2020-01-01' "$S/Teskno.wav" "$S/Sokol(2).wav" "$S/Gro Teskno.wav"
OUT="$(SAMPLES_DIR="$S" FFMPEG="$FAKE" "$SCRIPT" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'decoded 3' \
    && ok "zastaralý WAV se přepíše" \
    || bad "zastaralý WAV prošel  [$(printf '%s' "$OUT" | tr '\n' '|')]"

echo "== 4) čerstvý WAV se přeskočí (idempotence) =="
: > "$TMP/log"
OUT="$(FAKE_LOG="$TMP/log" SAMPLES_DIR="$S" FFMPEG="$FAKE" "$SCRIPT" 2>&1)"
printf '%s\n' "$OUT" | grep -q 'decoded 0, skipped 3' \
    && ok "druhý běh nic nepřevádí" \
    || bad "druhý běh znovu převádí  [$(printf '%s' "$OUT" | tr '\n' '|')]"
[ -s "$TMP/log" ] && bad "převáděl, i když neměl" || ok "ffmpeg se vůbec nepustil"

echo "== 5) --force převede všechno =="
: > "$TMP/log"
OUT="$(FAKE_LOG="$TMP/log" SAMPLES_DIR="$S" FFMPEG="$FAKE" "$SCRIPT" --force 2>&1)"
[ "$(wc -l < "$TMP/log")" = 3 ] \
    && ok "--force pustil ffmpeg třikrát" \
    || bad "--force pustil ffmpeg $(wc -l < "$TMP/log")× místo 3×"

echo "== 6) selhání ffmpeg je vidět a shodí skript =="
OUT="$(FAKE_FAIL_ON='Sokol(2).wav' SAMPLES_DIR="$S" FFMPEG="$FAKE" \
        "$SCRIPT" --force 2>&1)"
RC=$?
printf '%s\n' "$OUT" | grep -q 'failed 1' \
    && ok "selhání se započítá" \
    || bad "selhání nevidět  [$(printf '%s' "$OUT" | tr '\n' '|')]"
[ "$RC" -ne 0 ] && ok "nulový návrat? ne — není" || bad "skript skončil 0 při chybě"
# ostatní WAVy se převést mají, jinak by jeden rozbitý vzorek zabil celou
# sadu vrstev a box by neměl zvuk vůbec
[ -f "$S/Teskno.wav" ] && ok "rozbitý vzorek nezabil ostatní" \
                       || bad "jeden rozbitý vzorek shodil všechny"

echo "== 7) chybějící ffmpeg =="
OUT="$(SAMPLES_DIR="$S" FFMPEG="$TMP/neexistuje" "$SCRIPT" 2>&1)"
RC=$?
printf '%s\n' "$OUT" | grep -q 'not found' \
    && ok "chybějící ffmpeg je jasná chyba" \
    || bad "chybějící ffmpeg prošel tiše  [$(printf '%s' "$OUT" | tr '\n' '|')]"
[ "$RC" -ne 0 ] && ok "nenulový návrat" || bad "nulový návrat bez ffmpeg"

echo "== 8) nesmyslný přepínač =="
"$SCRIPT" --nesmysl >/dev/null 2>&1 && bad "--nesmysl prošel" \
                                 || ok "--nesmysl = chyba"

echo "== 9) v repu je samples/*.opus a žádný velký WAV =="
# Bez toho by byl v gitu jen zvuk, který sampler nehraje. Kontrola nad
# skutečným indexem: co je commitnuté, musí být Opus, a z WAV smí být
# jen ty malé placeholdery. Kdyby se do gitu vrátily samply od Matouse
# (524 MB stereo), push na GitHub by spadl na 100 MB/soubor.
TRACKED="$(git -C "$ROOT" ls-files samples/ 2>/dev/null)"
OPUS="$(printf '%s\n' "$TRACKED" | grep -c '\.opus$')"
[ "$OPUS" -gt 0 ] \
    && ok "v indexu je $OPUS opus souborů" \
    || bad "v indexu není žádný .opus — samply nejsou kde čokat"
# Malé 0B placeholdery (chybi_soubor.wav, sample_b_*.wav) v indexu být
# smějí — --learn do nich zapisuje a testy je používají jako "chybějící
# vzorek". Zakázané jsou jen WAV vrstev, tedy stejné jméno jako u .opus.
DUP=0
for o in $(printf '%s\n' "$TRACKED" | grep '\.opus$'); do
    w="${o%.opus}.wav"
    printf '%s\n' "$TRACKED" | grep -qxF "$w" && DUP=$((DUP + 1))
done
[ "$DUP" -eq 0 ] \
    && ok "v indexu není žádný WAV převedené vrstvy" \
    || bad "$DUP WAV souborů v indexu — push na GitHub by narazil na limit"
# A nic z toho nesmí být nad 100 MB, co je GitHubův strop na jeden soubor.
HUGE="$(git -C "$ROOT" ls-files -s samples/ 2>/dev/null | while read -r _ h _ f; do
            s=$(git -C "$ROOT" cat-file -s "$h" 2>/dev/null) || continue
            [ "$s" -gt 104857600 ] && echo "$f"
         done | wc -l)"
[ "$HUGE" -eq 0 ] \
    && ok "žádný vzorek v indexu nepřesahuje 100 MB" \
    || bad "$HUGE vzorků v indexu přesahuje 100 MB (limit GitHubu)"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
