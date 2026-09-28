#!/bin/bash
# tests/test-sampler-433.sh — dekódování 433 MHz tlačítek a readout kódů.
#
# Pustí se na hostu bez GPIO i bez zvukové karty: EV1527 rámce si sampler
# sám vyrobí (--simulate-rf) a pustí je přes stejný interní dekodér, jaký
# čte GPIO22. Kód, který dekodér ztratí nebo poplete, se v --listen prozradí
# ve výpisu; ve hře se navíc objeví v logu, podle kterého se na bezhlavém
# boxu pozná, že tlačítka chytí.
#
#   usage: ./tests/test-sampler-433.sh
#
# Bez SDL2 / libgpiod se sampler sestaví s -DHAVE_GPIOD=0 (simulace gpio nepotřebuje).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/sampler"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

# EV1527 má 24 bitů, takže 16777215 je nejvyšší možný kód (0xffffff).
# Kdyby dekodér počítal jinak, poslední bit by se ztratil.
CODES=(12200123 12200124 16777215 1)

skip() {
    echo "$1"
    exit 77
}

# Cesty ke knihovnám ze sysrootu; prázdné, když SDL2 je v systému
SYS_LIBS=""

# Binář musí opravdu naběhnout. V pracovním stromu leží hostovský `sampler`
# sestavený třeba proti SDL2 z jiného sysrootu — pak hlásí "error while loading
# shared libraries" a každý assert níže by selhal jen kvůli chybějící knihovně.
# RUNPATH sampleru se na závislosti jeho závislostí (libxmp uvnitř
# libSDL2_mixer) nešíře, proto se knihovny musí najít přes LD_LIBRARY_PATH,
# ne jen přes -Wl,-rpath.
runnable() {
    [ -x "$BIN" ] && LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:}$SYS_LIBS" \
        "$BIN" --version >/dev/null 2>&1
}

build() {
    local cc="${CXX:-g++}"
    # SDL2 nemusí být v systému. Když je jen v cross/sysrootu (stažené .deb
    # nebo vlastní build), nasměruj sem ABC38_SYSROOT a test poběží i bez root
    # práv. Jen přidáváme include/lib cestu — --sysroot by schoval systémové
    # hlavičky glibc a překlep by se projevil jako chybějící sys/types.h.
    local cflags ldflags
    if [ -n "${ABC38_SYSROOT:-}" ]; then
        local trip="${ABC38_TRIPLET:-$(gcc -dumpmachine)}"
        # Debian multiarch: část hlaviček (SDL2/_real_SDL_config.h) leží
        # v /usr/include/$trip, ne v /usr/include
        cflags="-isystem $ABC38_SYSROOT/usr/include
                -isystem $ABC38_SYSROOT/usr/include/$trip"
        ldflags="-L$ABC38_SYSROOT/usr/lib/$trip -L$ABC38_SYSROOT/usr/lib
                 -Wl,-rpath,$ABC38_SYSROOT/usr/lib/$trip
                 -Wl,-rpath,$ABC38_SYSROOT/usr/lib"
        SYS_LIBS="$ABC38_SYSROOT/usr/lib/$trip:$ABC38_SYSROOT/usr/lib"
    fi
    if [ -x "$BIN" ] && [ "$BIN" -nt "$ROOT/sampler.c" ] && runnable; then
        return 0
    fi
    echo "== build sampleru =="
    rm -f "$BIN"
    # shellcheck disable=SC2086   # cflags/ldflags jsou víceslovné
    if ! "$cc" $cflags "$ROOT/sampler.c" -o "$BIN" -DHAVE_GPIOD=0 $ldflags -lSDL2 -lSDL2_mixer \
            2>"$TMP/build.log"; then
        echo "    sampler se tu nepovede sestavit (chybí SDL2?):"
        sed 's/^/      /' "$TMP/build.log" | head -5
        skip "  SKIP — nainstaluj libsdl2-dev libsdl2-mixer-dev, nebo pust na Pi"
    fi
    runnable || skip "  SKIP — sestavený sampler nenaběhne (chybí SDL2 runtime?)"
}

build
[ -x "$BIN" ] || { echo "chybí $BIN" >&2; exit 1; }

# spuštění bináře s knihovnami ze sysrootu, jestli nějaký je
smp() {
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}${LD_LIBRARY_PATH:+:}$SYS_LIBS" "$BIN" "$@"
}

echo "== 1) --simulate-rf: dekodér převezme syntetický EV1527 rámec =="
OUT="$(smp --box b --listen --lcd-addr off --simulate-rf "${CODES[@]}" 2>"$TMP/err.log")"
for c in "${CODES[@]}"; do
    if printf '%s\n' "$OUT" | grep -q "code=$c,"; then
        ok "kód $c dekódován"
    else
        bad "kód $c se nenačetl  [$(printf '%s' "$OUT" | tr '\n' '|')]"
    fi
done

echo "== 2) readout rozliší ID a klávesu (id<<4 | key) =="
# 12200123 = 762507<<4 | 11 — kdyby dekodér poskládal bity obráceně, id/key
# by vyšly jiné a mapa by se nikdy neshodla
if printf '%s\n' "$OUT" | grep -q "code=12200123, id=762507, key=11"; then
    ok "id/key rozpad správně"
else
    bad "id/key nesouhlasí  [$(printf '%s\n' "$OUT" | grep -m1 12200123)]"
fi

echo "== 3) bez kódu se nevyplácí ani jedna chyba =="
if grep -qiE 'error|warning|not in map' "$TMP/err.log"; then
    bad "stderr nečistý  [$(tr '\n' '|' <"$TMP/err.log")]"
else
    ok "stderr čistý"
fi

echo "== 4) hra bez zvukové karty: kód v mapě, ale bez načteného samplu =="
mkdir -p "$TMP/samples"
printf '12200123, chybi_soubor.wav\n' > "$TMP/mapa.csv"
OUT="$(smp --box b --lcd-addr off --map "$TMP/mapa.csv" --samples-dir "$TMP/samples" \
        --simulate-rf 12200123 2>"$TMP/err2.log")"
if grep -q 'cannot load sample' "$TMP/err2.log"; then
    ok "chybějící sampl oznámen"
else
    bad "chybějící sampl prošel tiše  [$(tr '\n' '|' <"$TMP/err2.log")]"
fi
# stisk se nesmí ztratit jen proto, že sampl nehraje — bez toho se na boxu
# nepozná, že tlačítko funguje
if printf '%s\n' "$OUT" | grep -q 'code=12200123.*VZOREK NENACHRANY'; then
    ok "stisk je v logu i bez hratelného samplu"
else
    bad "stisk v logu chybí  [$(printf '%s' "$OUT" | tr '\n' '|')]"
fi

echo "== 5) kód, který v mapě není, se jen oznámí =="
OUT="$(smp --box b --lcd-addr off --map "$TMP/mapa.csv" --samples-dir "$TMP/samples" \
        --simulate-rf 999 2>"$TMP/err3.log")"
if grep -q 'code=999 not in map' "$TMP/err3.log"; then
    ok "nezmapovaný kód nahlášen"
else
    bad "nezmapovaný kód prošel  [$(tr '\n' '|' <"$TMP/err3.log")]"
fi

echo "== 5b) jeden stisk = jeden řádek, i když sampl chybí =="
# 433 MHz tlačítko pošle rámec víckrát (odrazky, dvě rychlé stisknutí).
# Bez debounce by jeden stisk naplnil journal desítkami řádků a #N by
# počítalo i zahozžené opakování — pak nelze poznat, kolikrát se
# skutečně stisklo.
OUT="$(smp --box b --lcd-addr off --debounce 300 --map "$TMP/mapa.csv" \
        --samples-dir "$TMP/samples" --simulate-rf 12200123 12200123 2>&1)"
N="$(printf '%s\n' "$OUT" | grep -c 'code=12200123 ->')"
[ "$N" = 1 ] && ok "dva rámce po sobě = jeden řádek" || bad "vypsalo se to $N× místo jednou"
printf '%s\n' "$OUT" | grep -q '#1)' && ok "počet stisků je 1" || bad "počet stisků je jiný: $(printf '%s' "$OUT" | tr '\n' '|')"

echo "== 5c) dva různé kódy se počítají zvlášť =="
# oba kódy musejí být v mapě, jinak by druhý skončil jako "not in map"
printf '12200123, chybi_soubor.wav\n12200124, chybi_soubor.wav\n' > "$TMP/mapa2.csv"
OUT="$(smp --box b --lcd-addr off --debounce 300 --map "$TMP/mapa2.csv" \
        --samples-dir "$TMP/samples" --simulate-rf 12200123 12200124 2>&1)"
printf '%s\n' "$OUT" | grep -q 'code=12200123.*#1)' && ok "první stisk #1" || bad "první stisk nemá #1: $(printf '%s' "$OUT" | tr '\n' '|')"
printf '%s\n' "$OUT" | grep -q 'code=12200124.*#2)' && ok "druhý stisk #2" || bad "druhý stisk nemá #2: $(printf '%s' "$OUT" | tr '\n' '|')"

echo "== 6) --simulate ze stdin: stejný readout jako u skutečného tlačítka =="
OUT="$(printf '12200123\n' | smp --box b --listen --lcd-addr off --simulate 2>&1)"
if printf '%s\n' "$OUT" | grep -q 'code=12200123,'; then
    ok "kód ze stdin dekódován"
else
    bad "stdin kód chybí  [$(printf '%s' "$OUT" | tr '\n' '|')]"
fi

echo "== 7) --simulate-rf bez kódů je chyba, ne tichý průchod =="
if smp --box b --listen --simulate-rf 2>/dev/null; then
    bad "prázdné --simulate-rf prošlo bez chyby"
else
    ok "chybí kód = nenulový návrat"
fi

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
