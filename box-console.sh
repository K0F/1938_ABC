#!/bin/bash
# box-console.sh — HDMI konzola boxu: přepíná mezi headless službou a oknem
# trackeru na TV (autologin + X session na tty1).
#
#   usage: sudo box-console.sh on | off | status
#
#   on     nainstaluje profil, autologin na tty1 a X session, vypne headless
#          tracker.service (kameru a zvukovku smí držet jediný proces)
#   off    všechno odstraní a vrátí headless tracker.service
#   status ukáže, v jakém režimu box je
#
# on/off jsou idempotentní a dají se opakovat — soubory se instalují z
# adresáře, kde leží tenhle skript (případně z /usr/local/sbin).
#
# Předpoklad: balíky xserver-xorg-core (modesetting přes /dev/dri), xinit,
# xfonts-base, x11-xserver-utils, libglfw3 — viz README, nebo:
#   apt-get install -y --no-install-recommends xserver-xorg-core xinit \
#       xfonts-base x11-xserver-utils libglfw3

set -u

XINIT=/usr/local/bin/box-console.xinit
PROFILE=/etc/profile.d/box-console.sh
GETTY_DROPIN=/etc/systemd/system/getty@tty1.service.d/autologin.conf
SOUND_DROPIN=/etc/systemd/system/box-sound-restart.service.d/console.conf
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "musí běžet jako root: sudo $0 $*"

# zdroj souboru: stejný adresář jako skript, nebo /usr/local/sbin (z image)
src() {
    for d in "$SELF_DIR" /usr/local/sbin; do
        [ -f "$d/$1" ] && { echo "$d/$1"; return 0; }
    done
    echo ""
}

have_x() {
    command -v startx >/dev/null 2>&1 || return 1
    command -v xrandr >/dev/null 2>&1 || return 1
    return 0
}

cmd_on() {
    for f in box-console.xinit box-console-profile.sh getty-tty1-autologin.conf; do
        [ -n "$(src "$f")" ] || die "chybí $f (musí ležet vedle tohoto skriptu)"
    done

    if ! have_x; then
        die "chybí X (startx/xrandr). Nejdřív:
  apt-get install -y --no-install-recommends xserver-xorg-core xinit xfonts-base x11-xserver-utils libglfw3"
    fi
    [ -x /home/pi/tracker/tracker ] || die "chybí /home/pi/tracker/tracker — nejdřív make v /home/pi/tracker"

    install -m 0755 "$(src box-console.xinit)" "$XINIT"
    install -m 0644 "$(src box-console-profile.sh)" "$PROFILE"
    mkdir -p "$(dirname "$GETTY_DROPIN")" "$(dirname "$SOUND_DROPIN")"
    install -m 0644 "$(src getty-tty1-autologin.conf)" "$GETTY_DROPIN"

    # V konzoli trackera drží cyklus v box-console.xinit, ne systemd, takže ho
    # obnova zabije a cyklus ho pustí znovu. SIGKILL, ne SIGINT: SIGINT by ho
    # ukončil čistě (rc=0) a cyklus by si toho nevšiml... (stejně by ho pustil
    # znovu, ale SIGKILL je jednoznačnější — ví se, že to byla obnova, ne
    # pád). V bezhlavém režimu je drop-in prázdný, tam to dělá systemd.
    cat > "$SOUND_DROPIN" <<'EOF'
[Service]
Environment=RESTART_UNITS=tracker
Environment=RESTART_CMD=pkill -KILL -x
EOF

    # Kameru a zvukovku drží jediný proces. Dvě instance by si rvaly za
    # /dev/video0 a zvukovou kartu (EBUSY), a pak by nebyl slyšet ani jeden.
    if systemctl is-enabled --quiet tracker.service 2>/dev/null \
       || systemctl is-active --quiet tracker.service 2>/dev/null; then
        systemctl disable --now tracker.service
        echo "  tracker.service vypnuta (kameru drží X session)"
    fi
    rm -f /tmp/.box-console.fails /tmp/.box-console.last
    echo console > /etc/box-console-mode

    systemctl daemon-reload
    echo "  konzole zapnutá: $XINIT, $PROFILE, autologin na tty1"

    # SSH_CONNECTION tu nepomůže — sudo ho z prostředí vyhazuje. Ovládací
    # terminál si sudo nechává, takže stačí porovnat tty.
    if [ "$(tty 2>/dev/null || echo none)" = /dev/tty1 ]; then
        echo "  sedíš u console: tady se nepřepojím, jen po restartu systému"
        return 0
    fi

    # Konzole má vlastní X relaci, takže se zapíná přepojením loginu na tty1.
    # `systemctl restart` je nebezpečný (nové X dřív než staré uvolní DRM),
    # proto restart_login: nejdřív počká, až staré X dojede.
    restart_login "getty@tty1 spuštěno, okno by se mělo objevit na TV"
}

# Spuštění (nebo úplné zastavení) loginu na tty1. `systemctl stop` vrací dřív,
# než Xorg doleje, a DRM/VT se pak usazují ještě chvíli — proto čekáme na
# proces i na usazení. Samotné `systemctl restart` je tu vyloženě nebezpečné:
# nové X by naběhlo dřív, než staré uvolní DRM, a GLX by vůbec nefungovalo.
restart_login() {
    local msg="$1" i
    systemctl stop getty@tty1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        pgrep -x Xorg >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -x Xorg >/dev/null 2>&1; then
        echo "  pozor: starý Xorg pořád běží, přepojení loginu riskuje rozbitý GLX"
    fi
    sleep 3
    systemctl start getty@tty1
    echo "  $msg"
}

cmd_off() {
    rm -f "$PROFILE" "$GETTY_DROPIN" "$SOUND_DROPIN"
    rm -f /tmp/.box-console.fails /tmp/.box-console.last
    echo headless > /etc/box-console-mode
    [ -f "$XINIT" ] && { rm -f "$XINIT"; echo "  $XINIT smazán"; }

    if [ -f /etc/systemd/system/tracker.service ]; then
        systemctl enable --now tracker.service
        echo "  tracker.service zapnutá zpět (headless)"
    fi
    systemctl daemon-reload
    echo "  konzole vypnutá"
    if [ "$(tty 2>/dev/null || echo none)" = /dev/tty1 ]; then
        echo "  pro návrat login promptu na TV: reboot"
    else
        restart_login "getty@tty1 přepojeno, na TV je zpět login prompt"
    fi
}

cmd_status() {
    printf 'režim:          %s\n' "$(cat /etc/box-console-mode 2>/dev/null || echo 'nezjištěno (neprobíhalo box-console.sh)')"
    printf 'profil:         %s\n' "$([ -f "$PROFILE" ] && echo nainstalován || echo chybí)"
    printf 'autologin:      %s\n' "$([ -f "$GETTY_DROPIN" ] && echo 'ano (bez hesla na tty1)' || echo ne)"
    printf 'X relace:       %s\n' "$XINIT"
    printf 'startx:         %s\n' "$(command -v startx 2>/dev/null || echo 'chybí (xinit není doinstalovaný)')"
    printf 'Xorg:           %s\n' "$(ls /usr/lib/xorg/Xorg 2>/dev/null || echo 'chybí (xserver-xorg-core není doinstalovaný)')"
    printf 'tracker služba: %s\n' "$(systemctl is-enabled tracker.service 2>/dev/null | head -1 || true)"
    # X i tracker běží jako pi, ne jako root, kdo příkaz spouští — pgrep bez
    # -u tedy (a pgrep -u 0 by je naopak nenašel).
    printf 'X běží:         %s\n' "$(pgrep -x Xorg >/dev/null 2>&1 && echo "ano (pid $(pgrep -x Xorg | tr '\n' ' '))" || echo ne)"
    printf 'tracker běží:   %s\n' "$(pgrep -x tracker >/dev/null 2>&1 && echo "ano (pid $(pgrep -x tracker | tr '\n' ' '))" || echo ne)"
    printf 'jistič:         %s\n' "$(cat /tmp/.box-console.fails 2>/dev/null || echo 0) selhání po sobě"
    if [ -f "$XINIT" ]; then
        echo
        echo "poslední logy relace:"
        journalctl -t box-console -n 5 --no-pager 2>/dev/null | sed 's/^/  /'
    fi
}

case "${1:-}" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    *)      die "usage: sudo $0 on|off|status" ;;
esac
