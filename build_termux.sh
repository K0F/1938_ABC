#!/bin/bash
# build_termux.sh — Zero-dependency setup & build for Termux on Android
# Run from a fresh Termux session: bash build_termux.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Tracker — Termux Build Script ==="

# ── 1. Enable x11-repo (needed for raylib, sdl2-mixer) ──
if ! pkg list-installed 2>/dev/null | grep -q x11-repo; then
    echo "[1/4] Installing x11-repo..."
    pkg install -y x11-repo || true
else
    echo "[1/4] x11-repo already installed"
fi

# ── 2. Install base dependencies ──
echo "[2/4] Installing base dependencies..."
pkg update -y >/dev/null 2>&1 || true
for pkg in clang make git pkg-config raylib sdl2 sdl2-mixer; do
    pkg install -y "$pkg" >/dev/null 2>&1 || true
done

SDL2_CFLAGS=$(pkg-config --cflags sdl2 2>/dev/null || echo "")
SDL2_LIBS=$(pkg-config --libs sdl2 SDL2_mixer 2>/dev/null || echo "-lSDL2 -lSDL2_mixer")

# ── 3. Build tracker ──
# Android/Termux nemá V4L2 -> HAVE_V4L2=0 (kamera se neotevře, zvuk a RF
# tlačítka jedou dál). Vision (grayskull) je header-only ve third_party/, takže
# žádné OpenCV ani libjpeg nejsou potřeba.
echo "[3/4] Building tracker..."
GIT_VERSION=$(cd "$SCRIPT_DIR" && git describe --tags --abbrev=0 2>/dev/null || echo dev)
g++ "$SCRIPT_DIR/main.c" "$SCRIPT_DIR/buttons.c" "$SCRIPT_DIR/v4l2_cam.c" \
    -o "$SCRIPT_DIR/tracker" \
    -DGIT_VERSION="\"$GIT_VERSION\"" \
    -DHAVE_V4L2=0 \
    -I"$SCRIPT_DIR/third_party" \
    ${SDL2_CFLAGS} \
    -L"$PREFIX/lib" \
    ${SDL2_LIBS} \
    -lraylib \
    -lGL -lm -lpthread -ldl

echo "[4/4] Build successful!"
echo ""
echo "Run with:  ./tracker [options]"
echo ""
echo "Note: Android/Termux has no V4L2 camera; tracker runs audio + RF buttons only."
echo "      Display requires a VNC or X11 session (termux-x11)."
