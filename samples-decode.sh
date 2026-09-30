#!/bin/bash
# samples-decode.sh — prevede samples/*.opus na WAV, ze kterych zivi sampler.
#
# V gitu jsou samply ulozene jako mono Opus (32 kbit/s) — 524 MB raw stereo
# prevedenych na 13 MB, coz se vejde do limitu GitHubu i do gitu, ktery se
# neposila po siti. SDL_mixer umi jen WAV (Mix_Chunk nema typovy tag, takze
# hudbu umi hrat jen Mix_PlayMusic — jednou globalne, ne na kazdem kanalu
# zvlast), a box ma mit v RAM jen par vrstev, ne vsechny samply najednou.
# Proto se tady, na hostu s ffmpeg, udelaji z Opus WAV a do image se
# rsyncne uz hotovy WAV. Na boxu se ffmpeg nepotrebuje.
#
# Vystup je mono 24 kHz s16le: sampler otevira mixer na 24 kHz a SDL_mixer
# stejny format pouzije pro vsechny kanaly, takze vrstva zabira v RAM
# 96 kB/s misto 176 kB/s pri 44.1 kHz. 24 kHz je jedna z rate, ktere umi
# libopus (22050 umi jen ffmpeg, ne libopus).
#
#   usage: ./samples-decode.sh [--force]
#
#   --force     prevede vsechno znovu, jinak se preskakne to, co je
#               uz cerstve (wav novy nez opus)
#
# Testovatelnost (viz tests/test-samples-decode.sh):
#   FFMPEG      default ffmpeg
#   SAMPLES_DIR default $SCRIPT_DIR/samples
#
# Skript je idemponentni: pusteni dvakrat za sebou podruhe jen zkontroluje
# casy souboru a nic neprevede.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FFMPEG="${FFMPEG:-ffmpeg}"
SAMPLES_DIR="${SAMPLES_DIR:-$SCRIPT_DIR/samples}"
RATE=24000

FORCE=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option '$a'" >&2; exit 1 ;;
    esac
done

command -v "$FFMPEG" >/dev/null 2>&1 || {
    echo "ERROR: $FFMPEG not found (set FFMPEG=... to the real binary)" >&2
    exit 1
}
[ -d "$SAMPLES_DIR" ] || { echo "ERROR: no samples dir: $SAMPLES_DIR" >&2; exit 1; }

# Nulove pripony, aby se vyslo z retezu s mezerami v nazvu ("Sokol(2).opus").
shopt -s nullglob
srcs=("$SAMPLES_DIR"/*.opus)
shopt -u nullglob

[ "${#srcs[@]}" -gt 0 ] || { echo "no *.opus in $SAMPLES_DIR — nothing to do"; exit 0; }

done_n=0
skip_n=0
fail_n=0

for src in "${srcs[@]}"; do
    base="${src%.opus}"
    dst="$base.wav"
    if [ "$FORCE" -eq 0 ] && [ -f "$dst" ] && [ "$dst" -nt "$src" ]; then
        echo "  skip  ${dst##*/} (fresh)"
        skip_n=$((skip_n + 1))
        continue
    fi
    # -y prepise, -loglerror nechce vypisovat normalni ffmpeg bordel do logu
    # sestavy. -ac 1 mono, -ar 24000 rate, ktery umi jak SDL_mixer tak
    # libopus; pcm_s16le je MIX_DEFAULT_FORMAT (AUDIO_S16SYS).
    if "$FFMPEG" -nostdin -loglevel error -y -i "$src" \
            -ac 1 -ar "$RATE" -c:a pcm_s16le "$dst"; then
        echo "  ok    ${dst##*/} ($(du -h "$dst" | cut -f1))"
        done_n=$((done_n + 1))
    else
        echo "ERROR: ffmpeg failed for ${src##*/}" >&2
        fail_n=$((fail_n + 1))
    fi
done

echo "decoded $done_n, skipped $skip_n, failed $fail_n"
[ "$fail_n" -eq 0 ] || exit 1
