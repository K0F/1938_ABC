# box-console-profile.sh — instaluje se jako /etc/profile.d/box-console.sh
#
# Login shell na fyzické konzoli tty1 po autologinu (viz
# getty-tty1-autologin.conf) naskočí do X s oknem trackeru. Startx se execne,
# takže login shell zmizí a jeho návratnost řeší getty (Restart=always):
# relace skončí a přihlášení i okno naběhnou znovu.
#
# Podmínky, aby se X nespustilo jinde než na TV: jen tty1, ne SSH, žádný
# DISPLAY, žádná X relace, která právě běží. Bez posledních dvou podmínek by
# se po Ctrl+C startx spustil znovu v téže relaci.
#
# Jistič: relace, která skončí do 30 s po startu, se pustí nejvýš třikrát za
# sebou. Čtvrtá už nechá login shell s vysvětlením — jinak by rozbité
# rozvrhnutí (chybějící X, rozbité okno) restartovalo pořád a TV blikala.
# Po opravě: rm /tmp/.box-console.fails (nebo box-console.sh off && on).

if [ -z "${SSH_CONNECTION:-}" ] \
   && [ -z "${SSH_CLIENT:-}" ] \
   && [ "$(tty 2>/dev/null || echo none)" = /dev/tty1 ] \
   && [ -z "${DISPLAY:-}" ]; then

    XINIT="${BOX_CONSOLE_XINIT:-/usr/local/bin/box-console.xinit}"
    [ -x "$XINIT" ] || return 0

    STATE="${BOX_CONSOLE_STATE:-/tmp}"
    FAILS_FILE="$STATE/.box-console.fails"
    LAST_FILE="$STATE/.box-console.last"

    now=$(date +%s)
    last=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
    fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

    if [ $((now - last)) -lt 30 ]; then
        fails=$((fails + 1))
    else
        fails=0
    fi
    printf '%s\n' "$fails" > "$FAILS_FILE" 2>/dev/null
    printf '%s\n' "$now"  > "$LAST_FILE" 2>/dev/null

    if [ "$fails" -ge 3 ]; then
        echo "box-console: X relace padá pořád dokola ($fails× po sobě) — nechávám login shell."
        echo "box-console: stav: journalctl -t box-console -n 20"
        echo "box-console: po opravě smaž $FAILS_FILE nebo pust' box-console.sh off && on"
    else
        echo "box-console: startuji X s oknem trackeru na HDMI konzoli..."
        # startx neumí předat serveru vlastní argumenty (za `--` je bere jako
        # argumenty klienta). My je potřebují, takže xinit napřímo, stejně jako
        # by ho sestavilo startx, jen s -nolisten tcp a -logfile navíc (chyby
        # Xorgu by jinak šly jen na tty, kde je nevidět).
        #
        # POZOR: režim výstupu (-screen) tu ZÁMĚRNĚ NENÍ. Tento Xorg bere
        # jeho hodnotu jako název sekce v xorg.conf ("No Screen section called
        # 640x480x24"), ne jako geometrii. Režim 640x480 nastavuje
        # 99-box-console.conf (instaluje ho box-console.sh).
        set -- "$XINIT" -- /etc/X11/xinit/xserverrc ":0" vt1 -keeptty -nolisten tcp \
            -logfile /tmp/xorg-console.log
        exec xinit "$@"
    fi
fi
