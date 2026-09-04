#!/bin/bash
# build_termux.sh — Zero-dependency setup & build for Termux on Android
# Run from a fresh Termux session: bash build_termux.sh
set -e

echo "=== Tracker — Termux Build Script ==="

# ── 1. Enable x11-repo (needed for opencv, raylib, sdl2-mixer) ──
if ! pkg list-installed 2>/dev/null | grep -q x11-repo; then
    echo "[1/4] Installing x11-repo..."
    pkg install -y x11-repo
else
    echo "[1/4] x11-repo already installed"
fi

# ── 2. Install all dependencies ──
echo "[2/4] Installing dependencies..."
pkg update -y
pkg install -y \
    clang \
    make \
    pkg-config \
    opencv \
    raylib \
    sdl2 \
    sdl2-mixer

# ── 3. Build ──
echo "[3/4] Building tracker..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect OpenCV library names (4.x vs 5.x differ)
if pkg-config --exists opencv4 2>/dev/null; then
    OPENCV_CFLAGS=$(pkg-config --cflags opencv4)
    OPENCV_LIBS=$(pkg-config --libs opencv4)
elif pkg-config --exists opencv 2>/dev/null; then
    OPENCV_CFLAGS=$(pkg-config --cflags opencv)
    OPENCV_LIBS=$(pkg-config --libs opencv)
else
    # Fallback: try both naming conventions
    OPENCV_CFLAGS="-I${PREFIX}/include/opencv4"
    if [ -f "${PREFIX}/lib/libopencv_calib3d.so" ]; then
        OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_geometry -lopencv_tracking"
    else
        OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib -lopencv_geometry -lopencv_tracking"
    fi
fi

SDL2_CFLAGS=$(pkg-config --cflags sdl2 2>/dev/null || echo "")
SDL2_LIBS=$(pkg-config --libs sdl2 SDL2_mixer 2>/dev/null || echo "-lSDL2 -lSDL2_mixer")

g++ "$SCRIPT_DIR/main.c" \
    -o "$SCRIPT_DIR/tracker" \
    ${OPENCV_CFLAGS} ${SDL2_CFLAGS} \
    -L"${PREFIX}/lib" \
    ${SDL2_LIBS} \
    -lraylib \
    ${OPENCV_LIBS} \
    -lGL -lm -lpthread -ldl

echo "[4/4] Build successful!"
echo ""
echo "Run with:  ./tracker [ball_count]"
echo ""
echo "Note: Camera access requires termux-api + camera permission."
echo "      Display requires a VNC or X11 session (termux-x11)."
