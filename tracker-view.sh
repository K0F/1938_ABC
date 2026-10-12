#!/bin/bash
# tracker-view.sh — zapne/vypne okenní "viewing" session trackeru na boxu A:
#   Xvfb :99  +  tracker v okně  +  x11vnc (VNC na :5900)
#
# Produkční režim je bezhlavý tracker.service. Okenní tracker potřebuje
# stejnou kameru/zvuk/GPIO jako bezhlavý, takže se navzájem vylučují:
#   start -> zastaví tracker.service a nastartuje view
#   stop  -> zabije view a vrátí zpět tracker.service (bezhlavý)
#
# Obal: tracker-view.service (systemctl start|stop tracker-view).
#
#   usage: tracker-view.sh start|stop|status
#
# Připojení: VNC klient na <boxa>:5900, heslo "tracker".

set -u

TRACKER_DIR="${TRACKER_DIR:-/home/pi/tracker}"
GEOM="${GEOM:-1280x720x24}"
RPORT="${RPORT:-5900}"
LABEL="tracker-view"
RUN="/run/$LABEL"

log() { printf '[%s] %s\n' "$LABEL" "$*"; }

kill_pidfile() {
    local p="$RUN/$1.pid"
    [ -f "$p" ] || return 0
    local pid; pid="$(cat "$p" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$p"
}

wait_gone() {
    local i
    for i in $(seq 1 30); do
        pgrep -x tracker >/dev/null 2>&1 || return 0
        sleep 0.3
    done
    return 1
}

do_start() {
    mkdir -p "$RUN"
    log "zastavuji bezhlavý tracker.service"
    systemctl stop tracker.service 2>/dev/null || true
    sleep 1

    log "startuji Xvfb :99 ($GEOM)"
    Xvfb :99 -screen 0 "$GEOM" -ac -nolisten tcp >/tmp/xvfb99.log 2>&1 &
    echo $! > "$RUN/xvfb.pid"
    sleep 2

    if [ ! -f /home/pi/.vnc/passwd ]; then
        mkdir -p /home/pi/.vnc
        x11vnc -storepasswd tracker /home/pi/.vnc/passwd >/dev/null 2>&1 || true
    fi

    log "startuji tracker v okně na :99"
    env -C "$TRACKER_DIR" DISPLAY=:99 ./tracker --allow-restart --map map.csv \
        >/tmp/tracker-view.log 2>&1 &
    echo $! > "$RUN/tracker.pid"
    sleep 3

    log "startuji x11vnc na portu $RPORT"
    x11vnc -display :99 -forever -shared -rfbport "$RPORT" \
        -rfbauth /home/pi/.vnc/passwd -o /tmp/x11vnc.log -quiet &
    echo $! > "$RUN/x11vnc.pid"
    sleep 1

    log "hotovo — VNC na <boxa>:$RPORT, heslo 'tracker'"
}

do_stop() {
    log "zastavuji view (x11vnc, tracker, Xvfb)"
    kill_pidfile x11vnc
    kill_pidfile tracker
    wait_gone || log "tracker se neukončil včas"
    kill_pidfile xvfb
    rm -rf "$RUN"
    sleep 1
    log "vracím bezhlavý tracker.service"
    systemctl start tracker.service 2>/dev/null || true
}

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status)
        for n in xvfb tracker x11vnc; do
            p="$RUN/$n.pid"
            if [ -f "$p" ] && kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null; then
                echo "$n: běží (pid $(cat "$p"))"
            else
                echo "$n: neběží"
            fi
        done
        echo "tracker.service: $(systemctl is-active tracker.service 2>&1)"
        ;;
    *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
