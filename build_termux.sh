#!/bin/bash
# build_termux.sh — Zero-dependency setup & build for Termux on Android
# Run from a fresh Termux session: bash build_termux.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCV_SRC_DIR="$SCRIPT_DIR/.opencv-build"

echo "=== Tracker — Termux Build Script ==="

# ── 1. Enable x11-repo (needed for opencv, raylib, sdl2-mixer) ──
if ! pkg list-installed 2>/dev/null | grep -q x11-repo; then
    echo "[1/6] Installing x11-repo..."
    pkg install -y x11-repo || true
else
    echo "[1/6] x11-repo already installed"
fi

# ── 2. Install base dependencies (ignore Qt6/dpkg configure failures) ──
echo "[2/6] Installing base dependencies..."
pkg update -y >/dev/null 2>&1 || true
for pkg in clang make cmake git pkg-config raylib sdl2 sdl2-mixer; do
    pkg install -y "$pkg" >/dev/null 2>&1 || true
done

# ── 3. Ensure OpenCV (package OR source) ──
echo "[3/6] Checking OpenCV..."
has_opencv() {
    [ -f "$PREFIX/lib/libopencv_core.so" ] &&
    [ -f "$PREFIX/lib/libopencv_videoio.so" ] &&
    [ -f "$PREFIX/lib/libopencv_tracking.so" ] &&
    { [ -f "$PREFIX/lib/libopencv_calib3d.so" ] || [ -f "$PREFIX/lib/libopencv_calib.so" ]; }
}

if has_opencv; then
    echo "    OpenCV already installed"
elif pkg install -y opencv >/dev/null 2>&1 && has_opencv; then
    echo "    OpenCV installed from package"
else
    echo "    OpenCV package failed (Qt6/xdg-utils broken), building from source..."
    pkg install -y libjpeg-turbo libpng libwebp zlib >/dev/null 2>&1 || true

    OPENCV_VERSION="4.14.0"
    rm -rf "$OPENCV_SRC_DIR"
    mkdir -p "$OPENCV_SRC_DIR"
    cd "$OPENCV_SRC_DIR"

    echo "    Downloading OpenCV $OPENCV_VERSION..."
    git clone --depth 1 --branch "$OPENCV_VERSION" \
        https://github.com/opencv/opencv.git opencv >/dev/null 2>&1

    echo "    Configuring OpenCV (no Qt, minimal build)..."
    mkdir -p opencv/build
    cd opencv/build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_QT=OFF -DWITH_GTK=OFF -DWITH_GSTREAMER=OFF \
        -DBUILD_PERF_TESTS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
        -DBUILD_opencv_apps=OFF -DBUILD_opencv_python3=OFF -DBUILD_opencv_java=OFF \
        -DOPENCV_GENERATE_PKGCONFIG=ON -DCMAKE_INSTALL_LIBDIR=lib

    echo "    Building OpenCV (15-25 min on a phone)..."
    MAKEFLAGS="-j$(nproc)" cmake --build . --config Release
    cmake --install .

    cd "$SCRIPT_DIR"
    rm -rf "$OPENCV_SRC_DIR"
    echo "    OpenCV built and installed"
fi

# ── 4. Resolve OpenCV build flags (4.x vs 5.x) ──
echo "[4/6] Resolving OpenCV flags..."
OPENCV_CFLAGS=""
OPENCV_LIBS=""
if pkg-config --exists opencv4 2>/dev/null; then
    OPENCV_CFLAGS=$(pkg-config --cflags opencv4)
    OPENCV_LIBS=$(pkg-config --libs opencv4)
elif pkg-config --exists opencv 2>/dev/null; then
    OPENCV_CFLAGS=$(pkg-config --cflags opencv)
    OPENCV_LIBS=$(pkg-config --libs opencv)
else
    for p in "$PREFIX/include/opencv4" "$PREFIX/include/opencv5"; do
        [ -d "$p" ] && OPENCV_CFLAGS="-I$p" && break
    done
    if [ -f "$PREFIX/lib/libopencv_calib3d.so" ]; then
        OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_geometry -lopencv_tracking"
    else
        OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib -lopencv_geometry -lopencv_tracking"
    fi
fi
[ -n "$OPENCV_LIBS" ] || OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_tracking"

SDL2_CFLAGS=$(pkg-config --cflags sdl2 2>/dev/null || echo "")
SDL2_LIBS=$(pkg-config --libs sdl2 SDL2_mixer 2>/dev/null || echo "-lSDL2 -lSDL2_mixer")

# ── 5. Build tracker ──
echo "[5/6] Building tracker..."
g++ "$SCRIPT_DIR/main.c" \
    -o "$SCRIPT_DIR/tracker" \
    ${OPENCV_CFLAGS} ${SDL2_CFLAGS} \
    -L"$PREFIX/lib" \
    ${SDL2_LIBS} \
    -lraylib \
    ${OPENCV_LIBS} \
    -lGL -lm -lpthread -ldl

echo "[6/6] Build successful!"
echo ""
echo "Run with:  ./tracker [ball_count]"
echo ""
echo "Note: Camera access requires termux-api + camera permission."
echo "      Display requires a VNC or X11 session (termux-x11)."
