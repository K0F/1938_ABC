#!/bin/sh
# /etc/NetworkManager/dispatcher.d/99-box-autossh.sh
# Při každém obnovení síťového rozhraní (wlan0 / eth0) okamžitě probudí / restartuje
# box-autossh.service, aby se po manipulaci s boxem v divadle nečekalo na restart timeout.

IFACE="$1"
ACTION="$2"

case "$ACTION" in
    up|connectivity-change)
        logger -t nm-box-autossh "Network event ($ACTION on $IFACE) -> restarting box-autossh.service"
        systemctl try-restart box-autossh.service 2>/dev/null || true
        ;;
esac
