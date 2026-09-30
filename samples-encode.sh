#!/bin/bash
# samples-encode.sh — prevede samples/raw/*.wav na samples/*.opus, coz je
# jedina forma samplu, ktera je v gitu.
#
# Opacny smer nez samples-decode.sh: tam se Opus prevadi na WAV pro box,
# tady se originaly prevadi do gitu. Puvodni stereo 44.1 kHz WAV maji
# dohromady 642 MB, coz se do gitu nevejde — GitHub odmita soubor nad
# 100 MB a dva z tehle originalu maji kazdy 117 MB. Po prevodu na mono
# Opus je to ~102 MB a nejvetsi soubor ma 23 MB, takze se limit neblizi.
# Originály zustavaji na disku v samples/raw/ (v .gitignore) a zaloha
# lezi na pesek.com v ~/ABC38-raw-backup/.
#
# Proč mono 24 kHz: sampler otevira SDL_mixer na 24 kHz (MIX_RATE) a
# SDL_mixer stejný format použije pro všechny kanály, takže vrstva
# zabírá v RAM 96 kB/s místo 176 kB/s. Cokoli nad 24 kHz šířku pásma a
# cokoliv stereo se zahodí ještě před reproduktory, takže to neukládáme.
# 24 kHz je jedna z rate, ktere umi libopus (22050 umi jen ffmpeg).
#
# Proč 256 kbit/s a ne výš: to je maximum, které libopus přijme pro mono.
# `-b:a 320k` skončí chybou "The bit rate 320000 bps is unsupported.
# Please choose a value between 500 and 256000" a nevytvoří vůbec nic.
# Script proto bitrate předem zkontroluje a řekne, co je moc, místo toho
# aby nechal ffmpeg vyplavat na každý soubor zvlášť. Nad 256k už stejně
# není co přidat — mixer zpracovává jen 24 kHz mono.
#
# Sokol(1).wav se preskakuje: ma stejny md5 jako Sokol.wav
# (757490687a473101494b482176179d16), takze by do gitu prisel jeden
# zbytecny opus s 11.6 minuty zvuku navic.
#
#   usage: ./samples-encode.sh [--force]
#
#   --force     prevede vsechno znovu, jinak se preskakne to, co je
#               uz cerstve (opus novy nez zdrojovy wav)
#
# Testovatelnost (viz tests/test-samples-encode.sh):
#   FFMPEG      default ffmpeg
#   RAW_DIR     default $SCRIPT_DIR/samples/raw
#   SAMPLES_DIR default $SCRIPT_DIR/samples
#   BITRATE     default 256k (neprijde v proto)
#
# Skript je idemponentni: pusteni dvakrat za sebou podruhe jen zkontroluje
# casy souboru a nic neprevede.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FFMPEG="${FFMPEG:-ffmpeg}"
RAW_DIR="${RAW_DIR:-$SCRIPT_DIR/samples/raw}"
SAMPLES_DIR="${SAMPLES_DIR:-$SCRIPT_DIR/samples}"
RATE=24000
BITRATE="${BITRATE:-256k}"

# libopus prijima pro mono 500..256000 bit/s. Kdyby to nekontroloval,
# ffmpeg by u kazdeho souboru vyplaval "Error while opening encoder".
BITRATE_MIN=500
BITRATE_MAX=256000

# Preskoceny zdroje: nazev -> duvod. Sokol(1) je bajtove stejny jako
# Sokol, ne jen podobny.
declare -A SKIP_REASON=(
    ["Sokol(1).wav"]="byte-identical duplicate of Sokol.wav (same md5 757490687a473101494b482176179d16)"
)

FORCE=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option '$a'" >&2; exit 1 ;;
    esac
done

command -v "$FFMPEG" >/dev/null 2>&1 || {
    echo "ERROR: $FFMPEG not found (set FFMPEG=... to the real binary)" >&2
    exit 1
}
[ -d "$RAW_DIR" ] || {
    echo "ERROR: no raw dir: $RAW_DIR" >&2
    echo "  Originaly stereo WAV tu byt nemaji. Lezi na lokalnim disku" >&2
    echo "  (samples/raw/, mimo git) a v zaloze na pesek.com v" >&2
    echo "  ~/ABC38-raw-backup/. Bez nich se do gitu neda nic vytvorit." >&2
    exit 1
}
[ -d "$SAMPLES_DIR" ] || { echo "ERROR: no samples dir: $SAMPLES_DIR" >&2; exit 1; }

# BITRATE muze prijit jako 256k, 256K nebo 256000.
bitrate_bps() {
    local v="$1"
    case "$v" in
        *k|*K) echo $(( ${v%[kK]} * 1000 )) ;;
        *[!0-9]*|'') echo -1 ;;   # necislo, at to nesahne na aritmetiku
        *) echo "$v" ;;
    esac
}
bps="$(bitrate_bps "$BITRATE")"
if [ "$bps" -lt "$BITRATE_MIN" ] || [ "$bps" -gt "$BITRATE_MAX" ]; then
    echo "ERROR: BITRATE=$BITRATE is $bps bit/s; libopus accepts" \
         "$BITRATE_MIN..$BITRATE_MAX for mono" >&2
    echo "  320k by skoncilo: 'The bit rate 320000 bps is unsupported'." >&2
    echo "  Vic uz neni co pridat — mixer hraje mono 24 kHz." >&2
    exit 1
fi

# Nulove pripony, aby se vyslo z retezu s mezerami v nazvu ("Sokol(2).wav").
shopt -s nullglob
srcs=("$RAW_DIR"/*.wav)
shopt -u nullglob

[ "${#srcs[@]}" -gt 0 ] || { echo "no *.wav in $RAW_DIR — nothing to do"; exit 0; }

done_n=0
skip_n=0
dup_n=0
fail_n=0

for src in "${srcs[@]}"; do
    base="${src##*/}"
    reason="${SKIP_REASON[$base]:-}"
    if [ -n "$reason" ]; then
        echo "  dup   $base ($reason)"
        dup_n=$((dup_n + 1))
        continue
    fi
    dst="$SAMPLES_DIR/${base%.wav}.opus"
    if [ "$FORCE" -eq 0 ] && [ -f "$dst" ] && [ "$dst" -nt "$src" ]; then
        echo "  skip  ${dst##*/} (fresh)"
        skip_n=$((skip_n + 1))
        continue
    fi
    # -y prepise, -nostdin a -loglevel error nechce ffmpeg bordel do logu
    # sestavy. -ac 1 mono, -ar 24000 rate, ktery umi jak SDL_mixer tak
    # libopus. -b:a + -vbr on drzi prumernou kvalitou; 256k je strop,
    # ktery libopus pro mono prijima.
    if "$FFMPEG" -nostdin -loglevel error -y -i "$src" \
            -ac 1 -ar "$RATE" -c:a libopus -b:a "$BITRATE" -vbr on \
            -application audio "$dst"; then
        echo "  ok    ${dst##*/} ($(du -h "$dst" | cut -f1))"
        done_n=$((done_n + 1))
    else
        echo "ERROR: ffmpeg failed for $base" >&2
        fail_n=$((fail_n + 1))
    fi
done

echo "encoded $done_n, skipped $skip_n, duplicates $dup_n, failed $fail_n"
[ "$fail_n" -eq 0 ] || exit 1
