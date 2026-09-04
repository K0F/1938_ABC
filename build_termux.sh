#!/bin/bash
# build_termux.sh — Zero-dependency setup & build for Termux on Android
# Run from a fresh Termux session: bash build_termux.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCV_SRC_DIR="$SCRIPT_DIR/.opencv-build"

echo "=== Tracker — Termux Build Script ==="

# ── 1. Fix any broken packages first ──
echo "[1/6] Fixing broken packages..."
pkg upgrade -y 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true

# ── 2. Enable x11-repo (needed for opencv, raylib, sdl2-mixer) ──
if ! pkg list-installed 2>/dev/null | grep -q x11-repo; then
    echo "[2/6] Installing x11-repo..."
    pkg install -y x11-repo
else
    echo "[2/6] x11-repo already installed"
fi

# ── 3. Install base dependencies ──
echo "[3/6] Installing base dependencies..."
pkg update -y
pkg install -y \
    clang \
    make \
    cmake \
    git \
    pkg-config \
    raylib \
    sdl2 \
    sdl2-mixer

# ── 4. Install OpenCV (try package first, fall back to source) ──
OPENCV_BUILT_FROM_SOURCE=false

if pkg install -y opencv 2>/dev/null; then
    echo "[4/6] OpenCV installed from package"
else
    echo "[4/6] OpenCV package failed (Qt6 broken), building from source..."
    OPENCV_BUILT_FROM_SOURCE=true

    # Install build deps for OpenCV from source
    pkg install -y libjpeg-turbo libpng libwebp zlib

    OPENCV_VERSION="4.14.0"
    rm -rf "$OPENCV_SRC_DIR"
    mkdir -p "$OPENCV_SRC_DIR"
    cd "$OPENCV_SRC_DIR"

    echo "    Downloading OpenCV $OPENCV_VERSION..."
    git clone --depth 1 --branch "$OPENCV_VERSION" \
        https://github.com/opencv/opencv.git opencv
    git clone --depth 1 --branch "$OPENCV_VERSION" \
        https://github.com/opencv/opencv_contrib.git opencv_contrib

    echo "    Configuring OpenCV (no Qt, minimal build)..."
    mkdir -p opencv/build
    cd opencv/build
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_QT=OFF \
        -DWITH_GTK=OFF \
        -DWITH_GSTREAMER=OFF \
        -DWITH_OPENEXR=OFF \
        -DWITH_OPENCL=OFF \
        -DWITH_CUDA=OFF \
        -DBUILD_PERF_TESTS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_opencv_apps=OFF \
        -DOPENCV_EXTRA_MODULES_PATH="$OPENCV_SRC_DIR/opencv_contrib/modules" \
        -DBUILD_opencv_python3=OFF \
        -DBUILD_opencv_java=OFF \
        -DOPENCV_GENERATE_PKGCONFIG=ON \
        -DCMAKE_INSTALL_LIBDIR=lib

    echo "    Building OpenCV (this may take 15-25 min on a phone)..."
    MAKEFLAGS="-j$(nproc)" cmake --build . --config Release
    echo "    Installing OpenCV..."
    cmake --install .

    cd "$SCRIPT_DIR"
    rm -rf "$OPENCV_SRC_DIR"
    echo "    OpenCV built and installed to $PREFIX"
fi

# ── 5. Build tracker ──
echo "[5/6] Building tracker..."

# Detect OpenCV include path
OPENCV_CFLAGS=""
for p in "$PREFIX/include/opencv4" "$PREFIX/include/opencv5" "$PREFIX/include/opencv2"; do
    if [ -d "$p" ]; then
        OPENCV_CFLAGS="-I$p"
        break
    fi
done

# Detect OpenCV library names (4.x uses calib3d, 5.x uses calib)
if [ -f "$PREFIX/lib/libopencv_calib3d.so" ]; then
    OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_geometry -lopencv_tracking"
elif [ -f "$PREFIX/lib/libopencv_calib.so" ]; then
    OPENCV_LIBS="-lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib -lopencv_geometry -lopencv_tracking"
else
    # Try pkg-config
    if pkg-config --exists opencv4 2>/dev/null; then
        OPENCV_CFLAGS=$(pkg-config --cflags opencv4)
        OPENCV_LIBS=$(pkg-config --libs opencv4)
    elif pkg-config --exists opencv 2>/dev/null; then
        OPENCV_CFLAGS=$(pkg-config --cflags opencv)
        OPENCV_LIBS=$(pkg-config --libs opencv)
    else
        echo "ERROR: Cannot find OpenCV libraries" >&2
        exit 1
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

echo "[6/6] Build successful!"
echo ""
echo "Run with:  ./tracker [ball_count]"
echo ""
echo "Note: Camera access requires termux-api + camera permission."
echo "      Display requires a VNC or X11 session (termux-x11)."
