#!/bin/bash
# box-network.sh — síť boxu v Raspberry Pi OS (NetworkManager): statická adresa
# a až dvě WiFi sítě (hlavní + záložní, na kterou box přepne sám).
#
#   usage: sudo ./box-network.sh <BOX>          # A nebo B
#          BOX_IP=192.168.8.103 BOX_WIFI_SSID=... sudo ./box-network.sh B
#
# Jestli existuje box-network.defaults (gitignored, vzor je
# box-network.defaults.example), načte se jako výchozí WiFi. Proměnná
# z prostředí má vždy přednost, takže jednorázově lze přepsat i profil
# v repu:
#
# Proč NetworkManager a ne dhcpcd: RPi OS od 2023 vede síť přes NetworkManager
# (v /etc/NetworkManager/system-connections/), takže /etc/dhcpcd.conf box nikdy
# nečte. Statická adresa je proto keyfile, ne řádek v konfiguraci daemona.
#
# Klíčové nastavení, které musí být v keyfilu správně:
#   * mode 0600 a vlastník root — NetworkManager odmítne keyfile s jinými
#     právy (kvůli WiFi heslu) a profil se tiše nezapojí.
#   * ipv4.method=manual — "auto" by nechalo DHCP přepsat adresu, pokud by jí
#     síť nabídla jinou.
#   * wifi.band=2.4 GHz? nepíšeme: Solight tlačítka jdou na 433 MHz, které je
#     mimo WiFi pásmo, a 5 GHz box nepotřebuje.
#
# ZÁLOŽNÍ SÍŤ (BOX_WIFI_SSID2): druhý keyfile, box na něj přepne sám, když
# hlavní není v dosahu. Rozhoduje connection.autoconnect-priority (hlavní
# 100, záložní -100) a oba mají autoconnect-retries=0, aby NetworkManager po
# selhání nečakal donekonečna. Záložní síť typicky patří jiné síti (např.
# hotspot), proto když se nezadá BOX_IP2, jde backup po DHCP — vzít jí
# adresu hlavní sítě by box dostal nedosažitelnou.
#
#   ABC38_NET_ROOT   default /     (kořen, do nějž se zapisuje)
#   ABC38_NET_DEFAULTS              soubor s výchozími hodnotami, default
#                    box-network.defaults vedle skriptu; prázdné = vypnuto
#   BOX_IP           default 192.168.8.103 pro B, 192.168.8.104 pro A
#                    (dva boxy v jedné síti musí mít různé adresy; .102
#                    patří notebooku, ze kterého se image připravuje)
#   BOX_PREFIX       default 24
#   BOX_GATEWAY      default 192.168.8.1
#   BOX_DNS          default 192.168.8.1 (prázdné = bez DNS, box jen v lokální síti)
#   BOX_IFACE        default wlan0 když je zadané SSID, jinak eth0
#   BOX_WIFI_SSID    prázdné = WiFi profil nevytvářet
#   BOX_WIFI_PSK     WPA2 heslo; prázdné = otevřená síť
#   BOX_WIFI_HIDDEN  1 = skrytá síť
#   BOX_CONN_NAME    default "box-<BOX>"
#
#   BOX_WIFI_SSID2   záložní síť; prázdné = druhý profil se nevytváří
#   BOX_WIFI_PSK2    její WPA2 heslo
#   BOX_WIFI_HIDDEN2 1 = skrytá
#   BOX_IP2          prázdné = záložní po DHCP (viz výše)
#   BOX_PREFIX2      default 24
#   BOX_GATEWAY2     default 192.168.8.1
#   BOX_DNS2         default 192.168.8.1 (prázdné = bez DNS)
#   BOX_IFACE2       default wlan0

set -e

# Vychozi WiFi z box-network.defaults (gitignored, viz .example). Cteno PRED
# spocitanim vychozich hodnot nize, ale s obranou: promenna, kterou uz poslal
# okoli (BOX_WIFI_SSID=... ./box-network.sh B), se po nacteni vrati. Bez toho
# by profil v repu tiše prepsal jednorazovy override na prikazce.
#
# ABC38_NET_DEFAULTS  cesta k souboru s vychozimi hodnotami, default
#                     <skript>/box-network.defaults. Prazdne = vypnuto
#                     (pouzivaji testy, aby se nevezly WiFi z lokalniho souboru).
HERE="$(cd "$(dirname "$0")" && pwd)"
DEFAULTS="${ABC38_NET_DEFAULTS-$HERE/box-network.defaults}"
if [ -n "$DEFAULTS" ] && [ -f "$DEFAULTS" ]; then
    # hodnoty, které poslalo okolí, schováme, po nactení vrátíme. `-n`
    # rozliší "nastaveno na prázdné" (BOX_DNS=) od "nenastaveno vůbec".
    _ssid_was="${BOX_WIFI_SSID-__unset__}"
    _psk_was="${BOX_WIFI_PSK-__unset__}"
    _hid_was="${BOX_WIFI_HIDDEN-__unset__}"
    _ssid2_was="${BOX_WIFI_SSID2-__unset__}"
    _psk2_was="${BOX_WIFI_PSK2-__unset__}"
    _hid2_was="${BOX_WIFI_HIDDEN2-__unset__}"
    # shellcheck disable=SC1090
    . "$DEFAULTS"
    [ "$_ssid_was" != __unset__ ] && BOX_WIFI_SSID="$_ssid_was"
    [ "$_psk_was"  != __unset__ ] && BOX_WIFI_PSK="$_psk_was"
    [ "$_hid_was"  != __unset__ ] && BOX_WIFI_HIDDEN="$_hid_was"
    [ "$_ssid2_was" != __unset__ ] && BOX_WIFI_SSID2="$_ssid2_was"
    [ "$_psk2_was"  != __unset__ ] && BOX_WIFI_PSK2="$_psk2_was"
    [ "$_hid2_was"  != __unset__ ] && BOX_WIFI_HIDDEN2="$_hid2_was"
    unset _ssid_was _psk_was _hid_was _ssid2_was _psk2_was _hid2_was
    echo "network: vychozi z $DEFAULTS"
fi

ROOT="${ABC38_NET_ROOT:-/}"
CONN_DIR="$ROOT/etc/NetworkManager/system-connections"
SUFFIX="${CONN_NAME_SUFFIX:-nmconnection}"

BOX="${1:-B}"
case "$BOX" in
    A|B) ;;
    *) echo "ERROR: box must be A or B" >&2; exit 1 ;;
esac

case "$BOX" in
    A) DEFAULT_IP=192.168.8.104 ;;
    B) DEFAULT_IP=192.168.8.103 ;;
esac

mkdir -p "$CONN_DIR"

# UUID z CONN_NAME, ne z písmena boxu. Dva profily na jednom boxu (hlavní +
# záložní) by se stejným uuid5("box-B") dostaly shodné uuid a NetworkManager
# by druhý tiše odmítl — záložní síť by nikdy nenaskočila.
conn_uuid() {
    python3 -c 'import uuid,sys;print(uuid.uuid5(uuid.NAMESPACE_DNS,sys.argv[1]))' "$1" 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid
}

# write_profile NÁZEV SSID PSK SKRÝTÁ IFACE ADRESA PREFIX BRÁNA DNS PRIORITA
#
# Prázdná ADRESA = DHCP (method=auto), jinak staticky (manual).
write_profile() {
    local name="$1" ssid="$2" psk="$3" hidden="$4" iface="$5" \
          ip="$6" prefix="$7" gateway="$8" dns="$9" prio="${10}"
    local out="$CONN_DIR/$name.$SUFFIX"

    {
        echo "# generated by box-network.sh — Box $BOX"
        echo "# statická adresa, aby na box nebylo potřeba hledat DHCP"
        if [ -n "$ssid" ]; then
            echo "[connection]"
            echo "id=$name"
            echo "uuid=$(conn_uuid "$name")"
            echo "type=wifi"
            echo "interface-name=$iface"
            echo "autoconnect=true"
            # retries=0: po selhání radši zkusit druhou síť než čekat donekonečna.
            echo "autoconnect-retries=0"
            # Která síť má přednost při současném dosahu obou.
            echo "autoconnect-priority=$prio"
            echo ""
            echo "[wifi]"
            echo "mode=infrastructure"
            echo "ssid=$ssid"
            echo "hidden=$hidden"
            echo ""
            if [ -n "$psk" ]; then
                echo "[wifi-security]"
                echo "key-mgmt=wpa-psk"
                echo "psk=$psk"
                echo ""
            fi
        else
            echo "[connection]"
            echo "id=$name"
            echo "uuid=$(conn_uuid "$name")"
            echo "type=ethernet"
            echo "interface-name=$iface"
            echo "autoconnect=true"
            echo "autoconnect-retries=0"
            echo "autoconnect-priority=$prio"
            echo ""
            echo "[ethernet]"
            echo ""
        fi
        echo "[ipv4]"
        if [ -n "$ip" ]; then
            if ! printf '%s' "$ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
                echo "ERROR: $name: BOX_IP is not an IPv4 address: $ip" >&2
                return 1
            fi
            echo "method=manual"
            echo "addresses=$ip/$prefix"
            [ -n "$gateway" ] && echo "gateway=$gateway"
            [ -n "$dns" ]     && echo "dns=$dns;"
        else
            # Bez BOX_IP2 jde záložní síť po DHCP. Vzít jí adresu hlavní sítě
            # by box dostal adresu, kterou na té síti nikdo neposlouchá.
            echo "method=auto"
        fi
        echo "never-default=false"
        echo ""
        echo "[ipv6]"
        echo "method=auto"
        echo ""
        echo "[proxy]"
    } > "$out"

    chmod 600 "$out"
    if [ -n "$ip" ]; then
        echo "network: $name -> $ssid ($iface, $ip/$prefix, gw ${gateway:-none})"
    else
        echo "network: $name -> $ssid ($iface, DHCP)"
    fi
    echo "  keyfile $out (600)"
}

# ── hlavní síť ────────────────────────────────────────────────
IP="${BOX_IP:-$DEFAULT_IP}"
PREFIX="${BOX_PREFIX:-24}"
GATEWAY="${BOX_GATEWAY:-192.168.8.1}"
DNS="${BOX_DNS-192.168.8.1}"
SSID="${BOX_WIFI_SSID:-}"
PSK="${BOX_WIFI_PSK:-}"
HIDDEN="${BOX_WIFI_HIDDEN:-0}"
[ -n "$BOX_IFACE" ] && IFACE="$BOX_IFACE" || { [ -n "$SSID" ] && IFACE=wlan0 || IFACE=eth0; }
CONN_NAME="${BOX_CONN_NAME:-box-$BOX}"

write_profile "$CONN_NAME" "$SSID" "$PSK" "$HIDDEN" "$IFACE" \
    "$IP" "$PREFIX" "$GATEWAY" "$DNS" 100

# ── záložní síť (když je zadaná) ───────────────────────────────
SSID2="${BOX_WIFI_SSID2:-}"
if [ -n "$SSID2" ]; then
    PSK2="${BOX_WIFI_PSK2:-}"
    HIDDEN2="${BOX_WIFI_HIDDEN2:-0}"
    IP2="${BOX_IP2-}"
    PREFIX2="${BOX_PREFIX2:-24}"
    GATEWAY2="${BOX_GATEWAY2-192.168.8.1}"
    DNS2="${BOX_DNS2-192.168.8.1}"
    [ -n "$BOX_IFACE2" ] && IFACE2="$BOX_IFACE2" || IFACE2=wlan0

    # -100: hlavní síť má přednost, backup se zkusí až když hlavní není.
    write_profile "${CONN_NAME}-backup" "$SSID2" "$PSK2" "$HIDDEN2" "$IFACE2" \
        "$IP2" "$PREFIX2" "$GATEWAY2" "$DNS2" -100
fi