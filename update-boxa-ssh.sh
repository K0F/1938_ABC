#!/bin/bash
# update-boxa-ssh.sh — Rychlá aktualizace běžícího Boxu A přes síť / SSH (t520 / phaser)
#
# Použití:
#   ./update-boxa-ssh.sh [IP_NEBO_SSH_ALIAS]
#
# Výchozí cíl:
#   192.168.88.104 (boxa-abc v síti kavárny/divadla)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-192.168.88.104}"
USER="pi"

case "$TARGET" in
    *@*|boxa*|boxb*) SSH_DEST="$TARGET" ;;
    *) SSH_DEST="${USER}@${TARGET}" ;;
esac

echo "== Spouštím síťovou aktualizaci Boxu A na $SSH_DEST =="

# 1. Test dostupnosti (přímá IP)
if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if ! ping -c 1 -W 2 "$TARGET" >/dev/null 2>&1; then
        echo "Varování: $TARGET neodpovídá na ping, zkouším rovnou SSH..."
    fi
fi

SSH_CMD="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
SCP_CMD="scp -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# 2. Detekce cílového adresáře na Boxu A a přidání SSH klíče
APP_DIR="$($SSH_CMD "$SSH_DEST" '
    if [ -d /home/pi/tracker ]; then
        echo /home/pi/tracker
    else
        wd="$(sed -n "s/^WorkingDirectory=//p" /etc/systemd/system/tracker.service 2>/dev/null | head -n1)"
        if [ -n "$wd" ] && [ -d "$wd" ]; then
            echo "$wd"
        else
            echo /home/pi/tracker
        fi
    fi
')"
$SSH_CMD "$SSH_DEST" "mkdir -p '$APP_DIR/samples'"

if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
    $SSH_CMD "$SSH_DEST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$PUBKEY' ~/.ssh/authorized_keys || printf '%s\n' '$PUBKEY' >> ~/.ssh/authorized_keys"
fi

# 3. Synchronizace konfigurace map.csv a zdrojových kódů
echo "  Kopíruji map.csv, zdrojové kódy a third_party..."
$SCP_CMD "$SCRIPT_DIR/map.csv" "$SSH_DEST:$APP_DIR/map.csv"
$SCP_CMD "$SCRIPT_DIR"/*.c "$SCRIPT_DIR"/*.h "$SCRIPT_DIR"/Makefile "$SCRIPT_DIR"/samples-decode.sh "$SSH_DEST:$APP_DIR/"
if [ -d "$SCRIPT_DIR/third_party" ]; then
    $SCP_CMD -r "$SCRIPT_DIR/third_party" "$SSH_DEST:$APP_DIR/"
fi

# 4. Synchronizace vzorků (samples)
echo "  Synchronizuji vzorky (samples)..."
"$SCRIPT_DIR/samples-decode.sh" || true
$SCP_CMD "$SCRIPT_DIR"/samples/*.opus "$SSH_DEST:$APP_DIR/samples/" 2>/dev/null || true
$SCP_CMD "$SCRIPT_DIR"/samples/*.wav "$SSH_DEST:$APP_DIR/samples/" 2>/dev/null || true

# 5. Instalace reverzního autossh tunelu
echo "  Zajišťuji klíč a službu pro reverzní tunel (pesek.com:2224)..."
$SCP_CMD "$SCRIPT_DIR/box-autossh.sh" "$SSH_DEST:/tmp/box-autossh.sh"
$SCP_CMD "$SCRIPT_DIR/box-autossh.service" "$SSH_DEST:/tmp/box-autossh.service"
$SCP_CMD "$SCRIPT_DIR/99-box-autossh.sh" "$SSH_DEST:/tmp/99-box-autossh.sh"
$SCP_CMD "$SCRIPT_DIR/box_tunnel_key" "$SSH_DEST:~/.ssh/id_ed25519"

$SSH_CMD "$SSH_DEST" '
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
$SSH_CMD "$SSH_DEST" "
    cd '$APP_DIR'
    ./samples-decode.sh || true
    make tracker
    sudo systemctl restart tracker.service || true
    echo '--- Stav služby tracker.service ---'
    sudo systemctl status tracker.service --no-pager -l || true
"

echo "== Aktualizace Boxu A přes síť je HOTOVA! =="
