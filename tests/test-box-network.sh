#!/bin/bash
# tests/test-box-network.sh — statická adresa boxu v NetworkManageru.
#
# Klíčový problém, který tu jde chytit: RPi OS vede síť přes NetworkManager,
# takže adresa musí být keyfile v /etc/NetworkManager/system-connections/ se
# správnými právy (0600) a method=manual. Špatná práva znamenají, že NetworkManager
# profil tiše odmákne a box skončí na DHCP — nebo vůbec bez adresy.
#
#   usage: ./tests/test-box-network.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-network.sh"
[ -x "$SCRIPT" ] || { echo "chybi $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

gen() {
    local r="$TMP/$1"; shift
    rm -rf "$r"
    ABC38_NET_ROOT="$r" "$@" bash "$SCRIPT" "$@" >/dev/null 2>&1 || true
    echo "$r"
}

# gen N BOX [BOX_* ...] — vygeneruje profil do TMP/N a vrátí cestu k souboru
# ABC38_NET_DEFAULTS= vypne čtení box-network.defaults: jinak by si testy tahly
# WiFi z lokalního (gitignorovaného) souboru a chovaly by se jinak než v CI.
gen() {
    local name="$1" box="$2"; shift 2
    local r="$TMP/$name"
    rm -rf "$r"
    env ABC38_NET_ROOT="$r" ABC38_NET_DEFAULTS= "$@" bash "$SCRIPT" "$box" >"$TMP/$name.log" 2>&1
    echo "$r/etc/NetworkManager/system-connections/box-$box.nmconnection"
}

conf() { grep -E "$1" "$2" || true; }

echo "== 1) WiFi profil: 192.168.8.103 na wlan0, WPA2, otevřená cesta k NM =="
F="$(gen wifi B BOX_WIFI_SSID=pece BOX_WIFI_PSK=heslo123)"
[ -f "$F" ] && ok "keyfile vznikl" || bad "keyfile chybí"
grep -q '^type=wifi$'      "$F" && ok "type=wifi"          || bad "type=wifi chybí"
grep -q '^interface-name=wlan0$' "$F" && ok "interface-name=wlan0" || bad "interface-name chybí"
grep -q '^ssid=pece$'      "$F" && ok "ssid zapsán"        || bad "ssid chybí"
grep -q '^psk=heslo123$'   "$F" && ok "WPA2 heslo zapsáno" || bad "psk chybí"
grep -q '^key-mgmt=wpa-psk$' "$F" && ok "key-mgmt=wpa-psk" || bad "key-mgmt chybí"
grep -q '^method=manual$'  "$F" && ok "ipv4 method=manual (DHCP adresu nepřepíše)" \
                               || bad "method != manual — DHCP by adresu přepsalo"
grep -q '^addresses=192\.168\.8\.103/24$' "$F" && ok "adresa 192.168.8.103/24" || bad "adresa chybí"
grep -q '^gateway=192\.168\.8\.1$' "$F" && ok "gateway 192.168.8.1" || bad "gateway chybí"

echo "== 2) práva 0600 — jinak NM keyfile s heslem odmákne =="
PERM="$(stat -c '%a' "$F")"
[ "$PERM" = "600" ] && ok "mode 600" || bad "mode je $PERM, NM profil by odmkl"

echo "== 3) Ethernet bez SSID: profil na eth0, žádná wifi-sekce =="
F="$(gen eth A)"
grep -q '^type=ethernet$'      "$F" && ok "type=ethernet"  || bad "type=ethernet chybí"
grep -q '^interface-name=eth0$' "$F" && ok "interface-name=eth0" || bad "eth0 chybí"
grep -q '^\[wifi\]'            "$F" && bad "má [wifi] sekci bez SSID" || ok "bez [wifi] sekce"
grep -q '^\[wifi-security\]'   "$F" && bad "má [wifi-security] bez SSID" || ok "bez [wifi-security]"

echo "== 4) otevřená WiFi (bez PSK) = bez [wifi-security] =="
F="$(gen open B BOX_WIFI_SSID=hostap)"
grep -q '^\[wifi-security\]' "$F" && bad "má [wifi-security] bez hesla" || ok "bez [wifi-security]"

echo "== 5) skrytá síť = hidden=1 =="
F="$(gen hid B BOX_WIFI_SSID=skryta BOX_WIFI_HIDDEN=1)"
grep -q '^hidden=1$' "$F" && ok "hidden=1" || bad "hidden chybí"

echo "== 6) vlastní IP a maska (192.168.8.0/24 se nemusí vejít) =="
F="$(gen ip B BOX_IP=10.0.0.77 BOX_PREFIX=16 BOX_GATEWAY=10.0.0.1)"
grep -q '^addresses=10\.0\.0\.77/16$' "$F" && ok "10.0.0.77/16" || bad "adresa/maska chybí"
grep -q '^gateway=10\.0\.0\.1$'    "$F" && ok "gateway 10.0.0.1" || bad "gateway chybí"

echo "== 7) prázdný BOX_DNS = žádný dns= řádek (box jen v lokální síti) =="
F="$(gen nodns B BOX_WIFI_SSID=x BOX_DNS=)"
grep -q '^dns=' "$F" && bad "má dns= při prázdném BOX_DNS" || ok "bez dns="

echo "== 8) BOX_IP musí být IPv4, jinak ať to řekne =="
rm -rf "$TMP/bad"
if ABC38_NET_ROOT="$TMP/bad" ABC38_NET_DEFAULTS= BOX_IP=not-an-ip bash "$SCRIPT" B >"$TMP/bad.log" 2>&1; then
    bad "rozbité BOX_IP prošlo bez chyby"
else
    grep -q 'not an IPv4' "$TMP/bad.log" && ok "řekne, že to není IPv4" || bad "chybová hláška nejasná"
fi

echo "== 9) BOX musí být A nebo B =="
if ABC38_NET_DEFAULTS= bash "$SCRIPT" C >/dev/null 2>&1; then
    bad "box C prošel (zrušený box)"
else
    ok "box C odmítnut"
fi

echo "== 10) UUID platné a pokaždé jiné (NM odmítne duplicitní) =="
U1="$(gen u1 A | xargs -I{} grep '^uuid=' {} | cut -d= -f2)"
U2="$(gen u2 B | xargs -I{} grep '^uuid=' {} | cut -d= -f2)"
case "$U1" in
    ????????-????-????-????-????????????) ok "uuid ve tvaru UUID" ;;
    *) bad "uuid divný: $U1" ;;
esac
[ "$U1" != "$U2" ] && ok "uuid se mezi boxy liší" || bad "A a B mají stejné uuid"

echo "== 11) profil jde znovu přegenerovat (idempotence) =="
R="$TMP/twice"
ABC38_NET_ROOT="$R" ABC38_NET_DEFAULTS= bash "$SCRIPT" B >/dev/null 2>&1
BEFORE="$(cat "$R/etc/NetworkManager/system-connections/box-B.nmconnection")"
ABC38_NET_ROOT="$R" ABC38_NET_DEFAULTS= bash "$SCRIPT" B >/dev/null 2>&1
AFTER="$(cat "$R/etc/NetworkManager/system-connections/box-B.nmconnection")"
[ "$BEFORE" = "$AFTER" ] && ok "druhý běh dá stejný obsah" || bad "přegenerování mění obsah"
[ "$(stat -c '%a' "$R/etc/NetworkManager/system-connections/box-B.nmconnection")" = "600" ] \
    && ok "práva se po druhém běhu nezkazila" || bad "práva utekla"

echo "== 12) výchozí adresa boxu B, i když se nic nepředá =="
rm -rf "$TMP/none"
ABC38_NET_ROOT="$TMP/none" ABC38_NET_DEFAULTS= bash "$SCRIPT" B >/dev/null 2>&1
F="$TMP/none/etc/NetworkManager/system-connections/box-B.nmconnection"
grep -q '^addresses=192\.168\.8\.103/24$' "$F" && ok "výchozí IP boxu B je 192.168.8.103" || bad "výchozí IP chybí"

echo "== 13) box A nedostane adresu boxu B =="
rm -rf "$TMP/boxa"
ABC38_NET_ROOT="$TMP/boxa" ABC38_NET_DEFAULTS= bash "$SCRIPT" A >/dev/null 2>&1
F="$TMP/boxa/etc/NetworkManager/system-connections/box-A.nmconnection"
grep -q '^addresses=192\.168\.8\.104/24$' "$F" && ok "výchozí IP boxu A je 192.168.8.104" || bad "A by si vzalo cizí adresu B"
BOX_IP=192.168.8.103 ABC38_NET_ROOT="$TMP/boxa" ABC38_NET_DEFAULTS= bash "$SCRIPT" A >/dev/null 2>&1
grep -q '^addresses=192\.168\.8\.103/24$' "$F" && ok "BOX_IP má i u A poslední slovo" || bad "BOX_IP se ignoruje"

# ── box-network.defaults ──────────────────────────────────────
# Profil WiFi v repu by prosákl do veřejného gitu, takže je v .gitignore a
# čte se jen když existuje. Tady jde o to, že se použije jako VÝCHOZÍ hodnota
# a že explicitní proměnná z prostředí ho pořád umí přepsat.
echo "== 14) box-network.defaults dodá WiFi, když se nepředá nic =="
DEF="$TMP/defaults"
printf 'BOX_WIFI_SSID=defaultniSit\nBOX_WIFI_PSK=heslo123\n' > "$DEF"
rm -rf "$TMP/dflt"
ABC38_NET_ROOT="$TMP/dflt" ABC38_NET_DEFAULTS="$DEF" bash "$SCRIPT" B >/dev/null 2>&1
F="$TMP/dflt/etc/NetworkManager/system-connections/box-B.nmconnection"
grep -q '^ssid=defaultniSit$' "$F" && ok "SSID ze souboru použito"        || bad "SSID ze souboru ignorováno"
grep -q '^psk=heslo123$'     "$F" && ok "PSK ze souboru použito"         || bad "PSK ze souboru ignorováno"
grep -q '^interface-name=wlan0$' "$F" && ok "SSID přepne rozhraní na wlan0" || bad "zůstalo eth0"

echo "== 15) ale proměnná z prostředí má přednost před souborem =="
rm -rf "$TMP/ovr"
ABC38_NET_ROOT="$TMP/ovr" ABC38_NET_DEFAULTS="$DEF" \
    BOX_WIFI_SSID=jinSit BOX_WIFI_PSK=jineHeslo bash "$SCRIPT" B >/dev/null 2>&1
F="$TMP/ovr/etc/NetworkManager/system-connections/box-B.nmconnection"
grep -q '^ssid=jinSit$'      "$F" && ok "BOX_WIFI_SSID přepsalo soubor"   || bad "soubor přepsal override"
grep -q '^psk=jineHeslo$'    "$F" && ok "BOX_WIFI_PSK přepsalo soubor"    || bad "soubor přepsal override"
grep -q '^ssid=defaultniSit$' "$F" && bad "v profilu zůstal SSID ze souboru" || ok "SSID ze souboru nevysál"

echo "== 16) vzor box-network.defaults.example je v repu =="
[ -f "$ROOT/box-network.defaults.example" ] && ok "example existuje" || bad "chybí box-network.defaults.example"
grep -q '^BOX_WIFI_PSK=SEM-DOJDE-HESLO-WIFI$' "$ROOT/box-network.defaults.example" \
    && ok "example má placeholder, ne skutečné heslo" || bad "example neobsahuje placeholder"

echo "== 17) skutečný box-network.defaults se do gitu nedostane =="
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    grep -qx 'box-network.defaults' "$ROOT/.gitignore" \
        && ok ".gitignore obsahuje box-network.defaults" \
        || bad "box-network.defaults není v .gitignore — heslo by lezlo do gitu"
    if [ -f "$ROOT/box-network.defaults" ]; then
        git -C "$ROOT" check-ignore -q box-network.defaults \
            && ok "soubor existuje a git hoignoruje" \
            || bad "soubor existuje, ale git ho NEignoruje"
        git -C "$ROOT" ls-files --error-unmatch box-network.defaults >/dev/null 2>&1 \
            && bad "soubor je už TRACKED v gitu" || ok "není v indexu"
    else
        ok "box-network.defaults tu není (užitečné není potřeba)"
    fi
else
    ok "mimo git repo, přeskočeno"
fi

echo "== 18a) dvě sítě: záložní profil, jiný uuid, nižší priorita =="
# Druhá WiFi (backup), na kterou box přepne sám. Klíčové je uuid: kdyby bylo
# odvozené jen z písmena boxu, oba profily by měly shodné uuid a NetworkManager
# by druhý tiše odmítl — záloha by nikdy nenaskočila.
F2="$(gen two B BOX_WIFI_SSID2=zalohni BOX_WIFI_PSK2=heslo456)"
B2="${F2%/box-B.nmconnection}/box-B-backup.nmconnection"
[ -f "$B2" ] && ok "záložní keyfile vznikl" || bad "záložní keyfile chybí"
grep -q '^ssid=zalohni$'      "$B2" && ok "záložní SSID zapsán"  || bad "záložní SSID chybí"
grep -q '^psk=heslo456$'     "$B2" && ok "záložní PSK zapsán"   || bad "záložní PSK chybí"
U_MAIN="$(grep '^uuid=' "$F2" | cut -d= -f2)"
U_BAK="$(grep '^uuid=' "$B2" | cut -d= -f2)"
[ -n "$U_BAK" ] && ok "záložní má uuid" || bad "záložní nemá uuid"
[ "$U_MAIN" != "$U_BAK" ] && ok "hlavní a záložní uuid jsou různé" \
                           || bad "stejné uuid — NM by zálohu odmítl"
grep -q '^autoconnect-priority=100$'  "$F2" && ok "hlavní má přednost (100)" || bad "hlavní priorita chybí"
grep -q '^autoconnect-priority=-100$' "$B2" && ok "záložní až v druhé vlně (-100)" || bad "záložní priorita chybí"
grep -q '^autoconnect-retries=0$' "$B2" && ok "záložní nečeká donekonečna" || bad "retries chybí"
# Bez BOX_IP2 musí backup jet po DHCP — adresa hlavní sítě by na jiné síti
# nikdo neposlouchala a box by neměl routu.
grep -q '^method=auto$'      "$B2" && ok "záložní bez BOX_IP2 jede po DHCP" || bad "záložní není DHCP"
grep -q '^addresses='        "$B2" && bad "záložní má statickou adresu hlavní sítě" \
                                || ok "záložní nemá adresu hlavní sítě"

echo "== 18b) záložní jde i staticky, když BOX_IP2 zadám =="
F3="$(gen two_static B BOX_WIFI_SSID2=zalohni BOX_IP2=10.9.0.50 BOX_GATEWAY2=10.9.0.1)"
B3="${F3%/box-B.nmconnection}/box-B-backup.nmconnection"
grep -q '^method=manual$'                 "$B3" && ok "BOX_IP2 -> manual"   || bad "BOX_IP2 nevyrobilo manual"
grep -q '^addresses=10\.9\.0\.50/24$'     "$B3" && ok "záložní adresa 10.9.0.50" || bad "záložní adresa chybí"
grep -q '^gateway=10\.9\.0\.1$'           "$B3" && ok "záložní brána 10.9.0.1" || bad "záložní brána chybí"

echo "== 18c) BOX_IP2 musí být IPv4, jinak ať to řekne =="
rm -rf "$TMP/bad2"
if ABC38_NET_ROOT="$TMP/bad2" ABC38_NET_DEFAULTS= \
   BOX_WIFI_SSID2=zalohni BOX_IP2=not-an-ip bash "$SCRIPT" B >"$TMP/bad2.log" 2>&1; then
    bad "rozbité BOX_IP2 prošlo bez chyby"
else
    grep -q 'not an IPv4' "$TMP/bad2.log" && ok "řekne, že BOX_IP2 není IPv4" || bad "chybová hláška nejasná"
fi

echo "== 18d) bez BOX_WIFI_SSID2 se druhý profil nevytváří =="
F4="$(gen one B)"
D4="${F4%/box-B.nmconnection}"
[ -e "$D4/box-B-backup.nmconnection" ] && bad "záložní profil vznikl bez SSID2" \
                                       || ok "jen jeden profil"

echo "== 18e) SSID2 z defaults funguje, proměnná z okolí ji přepíše =="
printf 'BOX_WIFI_SSID=hlavni\nBOX_WIFI_PSK=heslo123\nBOX_WIFI_SSID2=zdefault\nBOX_WIFI_PSK2=heslo456\n' > "$DEF"
rm -rf "$TMP/d2"
ABC38_NET_ROOT="$TMP/d2" ABC38_NET_DEFAULTS="$DEF" bash "$SCRIPT" B >/dev/null 2>&1
grep -q '^ssid=zdefault$' "$TMP/d2/etc/NetworkManager/system-connections/box-B-backup.nmconnection" \
    && ok "záložní SSID ze souboru" || bad "záložní SSID ze souboru ignorován"
rm -rf "$TMP/d3"
ABC38_NET_ROOT="$TMP/d3" ABC38_NET_DEFAULTS="$DEF" BOX_WIFI_SSID2=zenv \
    bash "$SCRIPT" B >/dev/null 2>&1
grep -q '^ssid=zenv$' "$TMP/d3/etc/NetworkManager/system-connections/box-B-backup.nmconnection" \
    && ok "BOX_WIFI_SSID2 přepsalo soubor" || bad "BOX_WIFI_SSID2 nepřepsalo soubor"

echo "== 18f) box-network.defaults se nesmí dostat do image =="
# qemu_raspi4.sh rsyncuje repo do /home/pi/tracker. Protože je defaults
# gitignorovaný (ne v .gitignore pro rsync), musí být vyloučený výslovně,
# jinak by se WiFi heslo četlo z karty.
# Oba prepare skripty rsyncují repo do /home/pi/tracker. Protože je defaults
# gitignorovaný (ne v .gitignore pro rsync), musí být vyloučený výslovně,
# jinak by se WiFi heslo četlo z karty.
for S in "$ROOT/qemu_raspi4.sh" "$ROOT/prepare-sd.sh"; do
    N="$(basename "$S")"
    [ -f "$S" ] || { bad "$N chybí, přeskočeno"; continue; }
    grep -q -- '--exclude=/box-network.defaults' "$S" \
        && ok "$N: rsync defaults výslovně vylučuje" \
        || bad "$N: rsync box-network.defaults nevylučuje — heslo by prosákl na kartu"
    grep -q 'prosaklo do image' "$S" \
        && ok "$N: po rsync kontroluje, že neprosákl" \
        || bad "$N: po rsync nehlídá, aby heslo neprosáklo"
done

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
