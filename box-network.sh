#!/bin/bash
# box-network.sh — statická adresa boxu v Raspberry Pi OS (NetworkManager).
#
#   usage: sudo ./box-network.sh <BOX>          # A nebo B
#          BOX_IP=192.168.8.103 BOX_WIFI_SSID=... sudo ./box-network.sh B
#
# Jestli existuje box-network.defaults (gitignored, vzor je
# box-network.defaults.example), načte se jako výchozí WiFi. Proměnná
# z prostředí má vždy přednost, takže jednorázový override jde i s profilem
# v repu.
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
#   ABC38_NET_ROOT   default /     (kořen, do nějž se zapisuje)
#   ABC38_NET_DEFAULTS              soubor s výchozími hodnotami, default
#                    box-network.defaults vedle skriptu; prázdné = vypnuto
#   BOX_IP           default 192.168.8.103 pro B, 192.168.8.104 pro A
#                    (dva boxy v jedné síti musí mít různé adresy; .102
#                    patří notebooku, ze kterého se image připravuje).
#                    PRÁZDNÉ = DHCP (method=auto) — cizí síť, kde neznáme
#                    subnet, si adresu vezme sama
#   BOX_PREFIX       default 24
#   BOX_GATEWAY      default 192.168.8.1
#   BOX_DNS          default 192.168.8.1 (prázdné = bez DNS, box jen v lokální síti)
#   BOX_IFACE        default wlan0 když je zadané SSID, jinak eth0
#   BOX_WIFI_SSID    prázdné = WiFi profil nevytvářet
#   BOX_WIFI_PSK     WPA2 heslo; prázdné = otevřená síť
#   BOX_WIFI_HIDDEN  1 = skrytá síť
#   BOX_CONN_NAME    default "box-<BOX>"
#
# Druhá síť (proměnné s indexem 2) — box jede domů i do kavárny a nemusí se
# přepisovat konfigurace pokaždé. Každá síť je jiný subnet, proto má druhý
# profil vlastní adresu i gateway; jinak by profil pro kavárnu vezl domácí
# 192.168.8.1 a box by se nikam nedostal. Obě sítě mají jiné SSID, takže
# NetworkManager připojí tu, která je v dosahu.
#
# Když je první profil na DHCP (BOX_IP= prázdné, například kavárna), druhý si
# bez nastavení BOX_WIFI2_IP vezme stejnou statickou adresu boxu jako první —
# jen u jiné sítě, kde je ta adresa volná. Proto stačí v box-network.defaults
# jednou napsat SSID obou sítí a oba boxy dostanou své .103/.104 v domácí síti.
#   BOX_WIFI2_SSID   prázdné = druhý profil nevytvářet (výchozí stav)
#   BOX_WIFI2_PSK    heslo; prázdné = otevřená síť
#   BOX_WIFI2_HIDDEN 1 = skrytá síť
#   BOX_WIFI2_IP     adresa ve druhé síti; NEUVEDENÁ = stejná jako BOX_IP boxu
#                    (192.168.8.103/104), prázdné = DHCP (method=auto)
#   BOX_WIFI2_PREFIX default 24
#   BOX_WIFI2_GATEWAY default BOX_GATEWAY (u DHCP si gateway vezme DHCP)
#   BOX_WIFI2_DNS    default BOX_DNS
#   BOX_CONN_NAME2   default "box-<BOX>-2"

set -e

# Vychozi WiFi z box-network.defaults (gitignored, viz .example). Cteno PRED
# spocitanim vychozich hodnot nize, ale s obranou: promenna, kterou uz poslal
# okoli (BOX_WIFI_SSID=... ./box-network.sh B), se po nacteni vrati. Bez toho
# by profil v repu tiše prepsal jednorazovy override na prikazce.
#
# ABC38_NET_DEFAULTS  cesta k souboru s vychozimi hodnotami, default
#                     <skript>/box-network.defaults. Prazdne = vypnuto
#                     (pouzivaji testy, aby si nevezly WiFi z lokalnih souboru).
HERE="$(cd "$(dirname "$0")" && pwd)"
DEFAULTS="${ABC38_NET_DEFAULTS-$HERE/box-network.defaults}"
if [ -n "$DEFAULTS" ] && [ -f "$DEFAULTS" ]; then
    # hodnoty, které poslalo okolí, schováme a po nactení vrátíme. `-n`
    # rozliší "nastaveno na prázdné" (BOX_IP= = DHCP) od "nenastaveno vůbec",
    # kdy má přednost soubor. Bez toho by BOX_IP= v defaults tiše přepsalo
    # --ip na příkazce a box by skončil na DHCP.
    declare -A _env_was=()
    for _v in BOX_IP BOX_PREFIX BOX_GATEWAY BOX_DNS BOX_IFACE \
              BOX_WIFI_SSID BOX_WIFI_PSK BOX_WIFI_HIDDEN BOX_CONN_NAME \
              BOX_WIFI2_SSID BOX_WIFI2_PSK BOX_WIFI2_HIDDEN BOX_WIFI2_IP \
              BOX_WIFI2_PREFIX BOX_WIFI2_GATEWAY BOX_WIFI2_DNS \
              BOX_IFACE2 BOX_CONN_NAME2; do
        [ -n "${!_v+set}" ] && _env_was["$_v"]="${!_v}"
    done
    # shellcheck disable=SC1090
    . "$DEFAULTS"
    for _v in "${!_env_was[@]}"; do
        printf -v "$_v" '%s' "${_env_was[$_v]}"
    done
    unset _env_was _v
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
IP="${BOX_IP-$DEFAULT_IP}"
PREFIX="${BOX_PREFIX:-24}"
GATEWAY="${BOX_GATEWAY:-192.168.8.1}"
DNS="${BOX_DNS-192.168.8.1}"
SSID="${BOX_WIFI_SSID:-}"
PSK="${BOX_WIFI_PSK:-}"
HIDDEN="${BOX_WIFI_HIDDEN:-0}"
IP2="${BOX_WIFI2_IP-$DEFAULT_IP}"
PREFIX2="${BOX_WIFI2_PREFIX:-24}"
GATEWAY2="${BOX_WIFI2_GATEWAY-$GATEWAY}"
DNS2="${BOX_WIFI2_DNS-$DNS}"
SSID2="${BOX_WIFI2_SSID:-}"
PSK2="${BOX_WIFI2_PSK:-}"
HIDDEN2="${BOX_WIFI2_HIDDEN:-0}"
[ -n "$BOX_IFACE" ] && IFACE="$BOX_IFACE" || { [ -n "$SSID" ] && IFACE=wlan0 || IFACE=eth0; }
IFACE2="${BOX_IFACE2:-wlan0}"
CONN_NAME="${BOX_CONN_NAME:-box-$BOX}"
CONN_NAME2="${BOX_CONN_NAME2:-box-$BOX-2}"

if [ -n "$IP" ] && ! printf '%s' "$IP" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    echo "ERROR: BOX_IP is not an IPv4 address: $IP" >&2
    exit 1
fi
if [ -n "$IP2" ] && ! printf '%s' "$IP2" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    echo "ERROR: BOX_WIFI2_IP is not an IPv4 address: $IP2" >&2
    exit 1
fi

mkdir -p "$CONN_DIR"

# UUID z odvozeného jména: stejný box + stejná síť = stejný profil, NM odmítne
# duplicitní uuid, takže druhá síť musí mít jiný klíč.
uuid_for() {
    python3 -c "import uuid;print(uuid.uuid5(uuid.NAMESPACE_DNS,'$1'))" 2>/dev/null \
        || cat /proc/sys/kernel/random/uuid
}

# write_profile NÁZEV UUID-KEY TYP IFACE ADRESA PREFIX GATEWAY DNS SSID PSK HIDDEN
# Prázdná ADRESA = DHCP (method=auto). Pro wifi je interface wlan0, pro eth0
# fallback ethernet profil bez SSID.
write_profile() {
    local name="$1" uuid_key="$2" type="$3" iface="$4" ip="$5" prefix="$6"
    local gw="$7" dns="$8" ssid="$9"
    local psk="${10}" hidden="${11}"
    local out="$CONN_DIR/$name.$SUFFIX"

    {
        echo "# generated by box-network.sh — Box $BOX"
        echo "# statická adresa, aby na box nebylo potřeba hledat DHCP"
        echo "[connection]"
        echo "id=$name"
        echo "uuid=$(uuid_for "$uuid_key")"
        echo "type=$type"
        echo "interface-name=$iface"
        echo "autoconnect=true"
        echo "autoconnect-retries=0"
        echo ""
        if [ "$type" = wifi ]; then
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
            echo "[ethernet]"
            echo ""
        fi
        echo "[ipv4]"
        if [ -n "$ip" ]; then
            echo "method=manual"
            echo "addresses=$ip/$prefix"
            if [ -n "$gw" ]; then
                echo "gateway=$gw"
            fi
            if [ -n "$dns" ]; then
                echo "dns=$dns;"
            fi
            echo "never-default=false"
        else
            echo "method=auto"
        fi
        echo ""
        echo "[ipv6]"
        echo "method=auto"
        echo ""
        echo "[proxy]"
    } > "$out"

    chmod 600 "$out"

    if [ -n "$ip" ]; then
        echo "network: Box $BOX -> $name ($iface, $ip/$prefix, gw ${gw:-none})"
    else
        echo "network: Box $BOX -> $name ($iface, DHCP)"
    fi
    echo "  keyfile $out (600)"
}

if [ -n "$SSID" ]; then
    write_profile "$CONN_NAME" "box-$BOX" wifi "$IFACE" \
        "$IP" "$PREFIX" "$GATEWAY" "$DNS" "$SSID" "$PSK" "$HIDDEN"
else
    write_profile "$CONN_NAME" "box-$BOX" ethernet "$IFACE" \
        "$IP" "$PREFIX" "$GATEWAY" "$DNS" "" "" 0
fi

if [ -n "$SSID2" ]; then
    write_profile "$CONN_NAME2" "box-$BOX-2" wifi "$IFACE2" \
        "$IP2" "$PREFIX2" "$GATEWAY2" "$DNS2" "$SSID2" "$PSK2" "$HIDDEN2"
else
    # Druhý profil jen přepsal, box by držel profil cizí síti.
    rm -f "$CONN_DIR/$CONN_NAME2.$SUFFIX"
fi
