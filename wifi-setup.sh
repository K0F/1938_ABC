#!/bin/bash
# wifi-setup.sh — automatické a trvalé připojení Raspberry Pi ke konkrétní WiFi
#
# Funguje na moderním Raspberry Pi OS (Bookworm / Debian 12 s NetworkManagerem)
# i starších verzích (Bullseye s wpa_supplicant).
#
# Použití:
#   sudo ./wifi-setup.sh "NAZEV_WIFI" "HESLO" [PRIORITA]
# nebo interaktivně (bez parametrů):
#   sudo ./wifi-setup.sh
#
# Vlastnosti:
#   - autoconnect=true (připojí se hned po startu / restartu)
#   - autoconnect-retries=0 (nekonečné pokusy při výpadku signálu)
#   - autoconnect-priority=100 (vysoká priorita oproti jiným sítím)
#   - automatické odblokování rfkill a nastavení regionu CZ

set -euo pipefail

# Automatické povýšení na root (sudo), pokud skript neběží jako root
if [ "$EUID" -ne 0 ]; then
    echo "Skript vyžaduje práva roota, spouštím přes sudo..."
    exec sudo "$0" "$@"
fi

SSID="${1:-}"
PSK="${2:-}"
PRIORITY="${3:-100}"

# Interaktivní dotaz, pokud nebyly předány argumenty
if [ -z "$SSID" ]; then
    read -rp "Zadej název WiFi sítě (SSID): " SSID
fi

if [ -z "$SSID" ]; then
    echo "Chyba: Název sítě (SSID) nesmí být prázdný!" >&2
    exit 1
fi

if [ -z "$PSK" ]; then
    read -rsp "Zadej heslo k WiFi (nech prázdné pro otevřenou síť): " PSK
    echo
fi

echo "=== Konfigurace WiFi: '$SSID' (priorita $PRIORITY) ==="

# 1. Odblokování WiFi rádia a nastavení regionu CZ
echo "[1/4] Kontrola a odblokování WiFi rádia..."
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi || true
if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country CZ 2>/dev/null || true
fi
if command -v iw >/dev/null 2>&1; then
    iw reg set CZ 2>/dev/null || true
fi

# Zjištění WiFi rozhraní (typicky wlan0)
IFACE="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}' || echo "wlan0")"
[ -z "$IFACE" ] && IFACE="wlan0"

# 2. NetworkManager (Bookworm / Debian 12)
if command -v nmcli >/dev/null 2>&1 || [ -d /etc/NetworkManager/system-connections ]; then
    echo "[2/4] Zjištěn NetworkManager (moderní Raspberry Pi OS)..."
    
    # Vygenerování bezpečného názvu souboru
    SAFE_NAME="$(echo "$SSID" | tr -c 'a-zA-Z0-9_-' '_')"
    CON_FILE="/etc/NetworkManager/system-connections/${SAFE_NAME}.nmconnection"
    
    # Generování UUID
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "19380000-0000-4000-8000-$(date +%s%N | cut -c 1-12)")"
    
    mkdir -p /etc/NetworkManager/system-connections
    
    cat > "$CON_FILE" <<EOF
[connection]
id=$SSID
uuid=$UUID
type=wifi
interface-name=$IFACE
autoconnect=true
autoconnect-priority=$PRIORITY
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=$SSID

EOF

    if [ -n "$PSK" ]; then
        cat >> "$CON_FILE" <<EOF
[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

EOF
    fi

    cat >> "$CON_FILE" <<EOF
[ipv4]
method=auto

[ipv6]
method=auto
EOF

    # Striktní práva 0600 — jinak NetworkManager soubor zahodí!
    chmod 600 "$CON_FILE"
    chown root:root "$CON_FILE"
    echo "  -> Profil zapsán do $CON_FILE (práva 0600 OK)"

    # Načtení profilu do NetworkManageru
    if command -v nmcli >/dev/null 2>&1; then
        echo "[3/4] Načítám profil přes nmcli..."
        nmcli connection reload || true
        echo "  -> Pokus o okamžité připojení k '$SSID'..."
        nmcli connection up "$SSID" || true
    fi

# 3. Fallback: wpa_supplicant (starší Bullseye / Buster)
elif [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    echo "[2/4] Zjištěn wpa_supplicant (starší Raspberry Pi OS)..."
    WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
    
    # Záloha
    cp "$WPA_CONF" "${WPA_CONF}.bak"
    
    # Přidání nebo aktualizace bloku
    if [ -n "$PSK" ]; then
        wpa_passphrase "$SSID" "$PSK" | grep -v '^[[:space:]]*#psk=' >> "$WPA_CONF"
    else
        cat >> "$WPA_CONF" <<EOF
network={
    ssid="$SSID"
    key_mgmt=NONE
    priority=$PRIORITY
}
EOF
    fi
    echo "[3/4] Konfigurace zapsána do $WPA_CONF"
    command -v wpa_cli >/dev/null 2>&1 && wpa_cli -i "$IFACE" reconfigure || true
fi

# 4. Kontrola stavu připojení
echo "[4/4] Ověřuji stav WiFi připojení..."
sleep 3
IP=""
for _ in {1..10}; do
    IP="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
    if [ -n "$IP" ]; then
        break
    fi
    sleep 1
done

if [ -n "$IP" ]; then
    echo "=========================================================="
    echo "  ÚSPĚCH! Raspberry Pi je připojeno k WiFi '$SSID'"
    echo "  Rozhraní : $IFACE"
    echo "  IP adresa: $IP"
    echo "  Režim    : Automatické připojení zapnuto (retries=0, priority=$PRIORITY)"
    echo "=========================================================="
else
    echo "=========================================================="
    echo "  Profil byl úspěšně uložen s automatickým připojením."
    echo "  (IP adresa zatím nebyla přidělena — buď je síť mimo dosah,"
    echo "   nebo DHCP server ještě neodpověděl. Jakmile bude síť v"
    echo "   dosahu, Raspberry Pi se připojí samo)."
    echo "=========================================================="
fi
