#!/bin/bash
# remote_update.sh — pull + rebuild the tracker on the Android device over SSH
set -e

HOST="${1:-android}"

echo "=== Updating tracker on $HOST ==="
ssh "$HOST" "cd ~/tracker && git pull && bash build_termux.sh"
echo ""
echo "Done. On the device:  cd ~/tracker && ./tracker"
