#!/bin/bash
# box-autossh.sh — trvalý reverzní SSH tunel z boxu (A = tracker, B = sampler)
# na centrální server pesek.com / xn--peek-h6a.com (boxC).
#
# Porty reverzního tunelu na pesek.com:
#   Box A -> port 2224  (127.0.0.1:2224 na pesek.com -> port 22 na Box A)
#   Box B -> port 2225  (127.0.0.1:2225 na pesek.com -> port 22 na Box B)
#
# S boxy se v divadle manipuluje (výpadky napájení, chůze s boxem, kolísání WiFi).
# Tento skript a přidružená systemd služba box-autossh.service zajišťují:
#   1. Agresivní detekci výpadku spojení (ServerAliveInterval=10, ServerAliveCountMax=3).
#   2. Neomezený počet restartů v systemd (StartLimitIntervalSec=0, RestartSec=5).
#   3. Okamžité obnovení tunelu při návratu WiFi (NetworkManager dispatcher).
#   4. Fallback: funguje s /usr/bin/autossh i s čistým /usr/bin/ssh.
#
# Použití:
#   box-autossh.sh run [A|B]     # běh pod systemd
#   box-autossh.sh status        # stav tunelu a test spojení
#   box-autossh.sh test [A|B]    # jednorázový pokus o spojení

set -u

# Zjištění identity boxu (A nebo B)
detect_box() {
    if [ -n "${1:-}" ]; then
        echo "$1" | tr '[:lower:]' '[:upper:]'
        return
    fi
    if [ -n "${BOX:-}" ]; then
        echo "$BOX" | tr '[:lower:]' '[:upper:]'
        return
    fi
    if [ -f /etc/box-identity ]; then
        tr -d ' \t\r\n' < /etc/box-identity | tr '[:lower:]' '[:upper:]'
        return
    fi
    local h
    h="$(hostname 2>/dev/null | tr -d ' \t\r\n' | tr '[:lower:]' '[:upper:]')"
    case "$h" in
        A|B) echo "$h"; return ;;
    esac
    echo "B"  # výchozí fallback
}

CMD="${1:-run}"
shift 2>/dev/null || true
BOX="$(detect_box "${1:-}")"

case "$BOX" in
    A) DEFAULT_REMOTE_PORT=2224 ;;
    B) DEFAULT_REMOTE_PORT=2225 ;;
    *) DEFAULT_REMOTE_PORT=2225 ;;
esac

REMOTE_HOST="${BOX_REMOTE_HOST:-pesek.com}"
REMOTE_PORT="${BOX_REMOTE_PORT:-$DEFAULT_REMOTE_PORT}"
REMOTE_SSH_PORT="${BOX_REMOTE_SSH_PORT:-2222}"
REMOTE_USER="${BOX_REMOTE_USER:-kof}"

# Umístění privátního klíče
KEY_FILE="${BOX_SSH_KEY:-}"
if [ -z "$KEY_FILE" ]; then
    if [ -f "/home/pi/.ssh/id_ed25519" ]; then
        KEY_FILE="/home/pi/.ssh/id_ed25519"
    elif [ -f "$(dirname "$0")/box_tunnel_key" ]; then
        KEY_FILE="$(dirname "$0")/box_tunnel_key"
    elif [ -f "$HOME/.ssh/id_ed25519" ]; then
        KEY_FILE="$HOME/.ssh/id_ed25519"
    else
        KEY_FILE="/home/pi/.ssh/id_ed25519"
    fi
fi

case "$CMD" in
    run)
        logger -t box-autossh "Starting reverse tunnel: Box $BOX -> 127.0.0.1:${REMOTE_PORT} on ${REMOTE_HOST}:${REMOTE_SSH_PORT}" 2>/dev/null || true
        echo "[box-autossh] Box $BOX -> ${REMOTE_HOST}:${REMOTE_SSH_PORT} (remote port ${REMOTE_PORT})"

        if [ ! -f "$KEY_FILE" ]; then
            echo "[box-autossh] ERROR: Key file $KEY_FILE not found!" >&2
            logger -t box-autossh "ERROR: Key file $KEY_FILE not found!" 2>/dev/null || true
            sleep "${BOX_RETRY_SLEEP:-2}"
            exit 1
        fi

        export AUTOSSH_GATETIME=0
        export AUTOSSH_POLL=10
        export AUTOSSH_FIRST_POLL=10
        export AUTOSSH_PORT=0

        SSH_ARGS=(
            -N
            -p "$REMOTE_SSH_PORT"
            -i "$KEY_FILE"
            -o ConnectTimeout=10
            -o ServerAliveInterval=10
            -o ServerAliveCountMax=3
            -o ExitOnForwardFailure=yes
            -o StrictHostKeyChecking=accept-new
            -o TCPKeepAlive=yes
            -R "127.0.0.1:${REMOTE_PORT}:localhost:22"
            "${REMOTE_USER}@${REMOTE_HOST}"
        )

        if command -v autossh >/dev/null 2>&1; then
            echo "[box-autossh] Using /usr/bin/autossh"
            exec autossh -M 0 "${SSH_ARGS[@]}"
        else
            echo "[box-autossh] autossh not found, falling back to ssh with systemd supervision"
            exec ssh "${SSH_ARGS[@]}"
        fi
        ;;

    test)
        echo "[box-autossh] Testing connection to ${REMOTE_HOST}:${REMOTE_SSH_PORT} with key $KEY_FILE ..."
        ssh -p "$REMOTE_SSH_PORT" -i "$KEY_FILE" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "${REMOTE_USER}@${REMOTE_HOST}" "echo 'Connected successfully to central server' && hostname"
        ;;

    status)
        echo "Box identity: $BOX"
        echo "Target host:  $REMOTE_HOST:$REMOTE_SSH_PORT"
        echo "Remote port:  $REMOTE_PORT"
        echo "Key file:     $KEY_FILE"
        if systemctl is-active box-autossh.service >/dev/null 2>&1; then
            echo "Service:      ACTIVE (running)"
        else
            echo "Service:      INACTIVE / STOPPED"
        fi
        ;;

    *)
        echo "Usage: $0 {run|test|status} [A|B]" >&2
        exit 1
        ;;
esac
