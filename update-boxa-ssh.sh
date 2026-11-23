#!/bin/bash
# update-boxa-ssh.sh — Rychlá aktualizace běžícího Boxu A přes síť / SSH z t520
#
# Použití:
#   ./update-boxa-ssh.sh [IP_NEBO_HOSTNAME]
#
# Výchozí cíl:
#   192.168.88.104 (boxa-abc v síti kavárny/divadla)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-192.168.88.104}"
USER="pi"

echo "== Spouštím síťovou aktualizaci Boxu A na $TARGET =="

# 1. Test dostupnosti
if ! ping -c 1 -W 2 "$TARGET" >/dev/null 2>&1; then
    echo "Varování: $TARGET neodpovídá na ping, zkouším rovnou SSH..."
fi

SSH_CMD="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
SCP_CMD="scp -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# 2. Cílový adresář na Boxu A
APP_DIR="/home/pi/tracker"
$SSH_CMD "$USER@$TARGET" "mkdir -p $APP_DIR/samples"

# 3. Synchronizace konfigurace map.csv a zdrojových kódů
echo "  Kopíruji map.csv a zdrojové kódy..."
$SCP_CMD "$SCRIPT_DIR/map.csv" "$USER@$TARGET:$APP_DIR/map.csv"
$SCP_CMD "$SCRIPT_DIR"/*.c "$SCRIPT_DIR"/*.h "$SCRIPT_DIR"/Makefile "$SCRIPT_DIR"/samples-decode.sh "$USER@$TARGET:$APP_DIR/"

# 4. Synchronizace vzorků (samples)
echo "  Synchronizuji vzorky (samples)..."
$SCP_CMD "$SCRIPT_DIR"/samples/*.opus "$USER@$TARGET:$APP_DIR/samples/" 2>/dev/null || true
$SCP_CMD "$SCRIPT_DIR"/samples/*.wav "$USER@$TARGET:$APP_DIR/samples/" 2>/dev/null || true

# 5. Instalace reverzního autossh tunelu
echo "  Zajišťuji klíč a službu pro reverzní tunel (pesek.com:2224)..."
$SCP_CMD "$SCRIPT_DIR/box-autossh.sh" "$USER@$TARGET:/tmp/box-autossh.sh"
$SCP_CMD "$SCRIPT_DIR/box-autossh.service" "$USER@$TARGET:/tmp/box-autossh.service"
$SCP_CMD "$SCRIPT_DIR/99-box-autossh.sh" "$USER@$TARGET:/tmp/99-box-autossh.sh"
$SCP_CMD "$SCRIPT_DIR/box_tunnel_key" "$USER@$TARGET:~/.ssh/id_ed25519"

$SSH_CMD "$USER@$TARGET" '
    chmod 600 ~/.ssh/id_ed25519
    echo "A" | sudo tee /etc/box-identity >/dev/null
    sudo install -m 0755 /tmp/box-autossh.sh /usr/local/sbin/box-autossh.sh
    sudo install -m 0644 /tmp/box-autossh.service /etc/systemd/system/box-autossh.service
    sudo mkdir -p /etc/NetworkManager/dispatcher.d
    sudo install -m 0755 /tmp/99-box-autossh.sh /etc/NetworkManager/dispatcher.d/99-box-autossh.sh
    sudo systemctl daemon-reload
    sudo systemctl enable box-autossh.service
    sudo systemctl restart box-autossh.service || true
'

# 6. Kompilace trackeru a restart služby
echo "  Kompiluji tracker na Boxu A a restartuji službu..."
$SSH_CMD "$USER@$TARGET" "
    cd $APP_DIR
    ./samples-decode.sh || true
    make tracker
    sudo systemctl restart tracker.service || true
    echo '--- Stav služby tracker.service ---'
    sudo systemctl status tracker.service --no-pager -l || true
"

echo "== Aktualizace Boxu A přes síť je HOTOVA! =="
