#!/bin/bash
# install-deps.sh — Install build dependencies and compile tracker+sampler
# Run as pi on Raspberry Pi 4 (or in QEMU if network available).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing build dependencies ==="
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    g++ make pkg-config git ca-certificates \
    libsdl2-dev libsdl2-mixer-dev libgpiod-dev \
    libopencv-dev libx11-dev libgl-dev

echo "=== Building raylib 5.5 ==="
cd /tmp
[ -d raylib ] || git clone --depth 1 --branch 5.5 https://github.com/raysan5/raylib.git
cd raylib/src
make PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=SHARED
sudo make install RAYLIB_INSTALL_PATH=/usr/lib

echo "=== Building tracker + sampler ==="
cd "$SCRIPT_DIR"
make clean
make all

echo
echo "=== Build complete ==="
ls -lh tracker sampler
