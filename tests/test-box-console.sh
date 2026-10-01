#!/bin/bash
# tests/test-box-console.sh — logika HDMI konzole (X session, profil, jistič)
# bez X serveru, bez kamery a bez systemd: falešný tracker, falešné tty.
#
# Pokrývá:
#   * tracker v okně běží z pracovního adresáře (font terminus.ttf)
#   * spadnutí trackera → cyklus ho zvedne, čistý exit (rc=0) taky
#   * relace běží na softwarovém GL (hardwarový GLX tady GLFW neumí)
#   * chybějící kamera se čeká, ale ne navěky
#   * chybějící binárka = konec relace, ne nekonečná smyčka
#   * profil se spustí jen na tty1, ne přes SSH a ne dvakrát
#   * jistič po třech rychlých pádech přestane restartovat a nechá shell
#   * režim konzole vypne headless službu (kamera má jednoho vlastníka)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: dostal '$2', chtěl '$3'"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (chybí '$3')"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (nepřežil '$3')"; else ok "$1"; fi; }
# jen kód, bez komentářů (ty popisují i chybné tvary, které chceme vyhnat)
code() { grep -vE '^[[:space:]]*#' "$1"; }
# celý argument, ne podřetězec ("x24" je kus "640x480x24")
noline() { if printf '%s\n' "$2" | grep -qxF -- "$3"; then bad "$1 (je tam argument '$3')"; else ok "$1"; fi; }

echo "== test box-console =="

# falešný tracker: zapíše do COUNTER, prvních FAKE_FAILS běhů skončí
# neúspěchem (FAKE_CODE), další čistě — abychom nemuseli čekat, až se
# nakonec ukápe
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
# Relace xinit nesmí nikdy skončit sama, takže běh musí někdo ukončit —
# tady to udělá falešný tracker po FAKE_MAX spuštěních (default 3).
cat > "$FAKEBIN/tracker" <<'EOF'
#!/bin/bash
echo "${PWD}" > "$COUNTER.pwd"
n=$(( $(cat "$COUNTER.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNTER.n"
echo run >> "$COUNTER"
if [ "$n" -ge "${FAKE_MAX:-3}" ]; then
    kill -TERM "$PPID" 2>/dev/null
    exit 0
fi
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then
    exit "${FAKE_CODE:-7}"
fi
exit 0
EOF
chmod +x "$FAKEBIN/tracker"
export COUNTER="$TMP/counter"

reset_fake() { rm -f "$COUNTER" "$COUNTER.n" "$COUNTER.pwd"; }

run_xinit() {   # stdout+stderr, bez loggeru
    FAKE_FAILS="${FAKE_FAILS:-0}" FAKE_CODE="${FAKE_CODE:-7}" \
    FAKE_MAX="${FAKE_MAX:-3}" \
    BOX_CONSOLE_TRACKER="$FAKEBIN/tracker" \
    BOX_CONSOLE_CAMERA="$CAMERA" \
    BOX_CONSOLE_WAIT="$WAIT" BOX_CONSOLE_RETRY=0 BOX_CONSOLE_BACKOFF=0 \
    PATH="$TMP/nolog:$PATH" \
    bash "$ROOT/box-console.xinit" 2>&1
}

# ── tracker spadne, zvedne se ──────────────────────────────────────────
CAMERA="$TMP/video0"; : > "$CAMERA"
reset_fake
FAKE_FAILS=1 WAIT=0 OUT="$(run_xinit; echo "rc=$?")"
has "smyčka to zopakuje po pádu" "$OUT" "tracker skončil s 7"

# Čistý exit (rc=0, typicky SIGINT ze zvukové obnovy) NESMÍ relaci ukončit:
# jinak by getty pustil nové X a okno na TV by se objevilo až po restartu
# systému. Session běží na softwarovém GL, takže další klient se vytvoří vždy.
reset_fake
FAKE_FAILS=0 WAIT=0 OUT="$(run_xinit; echo "rc=$?")"
chk "čistý exit = tracker se pustí znovu" "$(grep -c run "$COUNTER")" "3"
has "čistý exit je ohlasen" "$OUT" "tracker skončil čistě"
has "a relace běží dál" "$OUT" "X relace běží dál"

# deset pádů po sobě = poslední pojistka, ať člověk u TV má login prompt
reset_fake
FAKE_FAILS=99 FAKE_CODE=7 FAKE_MAX=99 WAIT=0 OUT="$(run_xinit; echo "rc=$?")"
chk "po 10 pádech relace skončí" "$(grep -c run "$COUNTER")" "10"
has "a řekne proč" "$OUT" "nespravuje"
has "s nenulovým návratem" "$OUT" "rc=1"

# ── font se hledá v pracovním adresáři, ne v PATH ──────────────────────
has "spouští se z adresáře trackera" "$(cat "$COUNTER.pwd" 2>/dev/null)" "$FAKEBIN"

# ── kamera chybí: čeká, ale ne navěky ──────────────────────────────────
CAMERA="$TMP/neexistuje"; reset_fake
FAKE_FAILS=0 FAKE_MAX=1 WAKE_MAX=2 WAIT=2 OUT="$(run_xinit; echo "rc=$?")"
has "chybějící kamera se ohlásí" "$OUT" "se neobjevila za 2s"
has "přesto se zkusí spustit" "$OUT" "spouštím:"

# ── chybějící binárka: konec relace, ne smyčka ─────────────────────────
CAMERA="$TMP/video0"
OUT="$(BOX_CONSOLE_TRACKER="$TMP/bin/neexistuje" BOX_CONSOLE_CAMERA="$CAMERA" \
       BOX_CONSOLE_WAIT=0 PATH="$TMP/nolog:$PATH" \
       bash "$ROOT/box-console.xinit" 2>&1; echo "rc=$?")"
has "chybějící binárka = jasná hláška" "$OUT" "není spustitelný"
has "a relace končí" "$OUT" "rc=1"

# ── profil: spustí se jen na tty1, ne přes SSH ─────────────────────────
# startx nahradíme stubem, který zapíše stopu
mkdir -p "$TMP/nolog" "$TMP/stub"
for stub in startx xinit; do
    printf '#!/bin/bash\necho started >> "$TRACE"\nprintf "%%s\\n" "$@" >> "$TRACE.args"\n' > "$TMP/stub/$stub"
    chmod +x "$TMP/stub/$stub"
done
printf '#!/bin/sh\nexit 0\n' > "$TMP/nolog/logger"
chmod +x "$TMP/nolog/logger"

PROFILE="$ROOT/box-console-profile.sh"
STATE="$TMP/state"; mkdir -p "$STATE"

run_profile() {  # tty, extra env, zdroj profilu ve sh -c (exec by nahradí shell)
    local fake_tty="$1"; shift
    rm -f "$TRACE"
    # SSH_* se musí odstranit i když je má prostředí, ze kterého test běží —
    # jinak by profil (správně) odmítl X spustit a test padal podle toho,
    # odkud byl spuštěn.
    env -u DISPLAY -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" \
        TRACE="$TRACE" BOX_CONSOLE_STATE="$STATE" \
        BOX_CONSOLE_XINIT="$ROOT/box-console.xinit" \
        TTY="$fake_tty" "$@" \
        sh -c 'tty() { [ -n "$TTY" ] && echo "$TTY" || echo "not a tty"; }; . '"$PROFILE" >/dev/null 2>&1
    [ -f "$TRACE" ] && echo yes || echo no
}

TRACE="$TMP/trace1"
chk "profil spustí X na tty1" "$(run_profile /dev/tty1)" "yes"
TRACE="$TMP/trace2"
chk "na tty2 (monitor) nespustí" "$(run_profile /dev/tty2)" "no"
TRACE="$TMP/trace3"
chk "přes SSH nespustí" "$(run_profile /dev/tty1 SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22")" "no"
TRACE="$TMP/trace4"
chk "když už je DISPLAY, nespustí druhý" "$(run_profile /dev/tty1 DISPLAY=:0)" "no"

# chybějící session soubor = profil nesmí nic dělat (jinak by se pořád
# pokoušel o startx, který nemá co spustit)
TRACE="$TMP/trace5"
OUT="$(env -u DISPLAY PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" TRACE="$TRACE" \
      BOX_CONSOLE_STATE="$STATE" TTY=/dev/tty1 BOX_CONSOLE_XINIT=/neexistuje \
      sh -c 'tty() { echo /dev/tty1; }; . '"$PROFILE" 2>&1)"
chk "bez session souboru se X nespustí" "$([ -f "$TRACE" ] && echo yes || echo no)" "no"

# ── X musí zůstat v nativním režimu TV: 640x480 neumí GLX vizuály ──────
STATE="$TMP/state3"; mkdir -p "$STATE"
TRACE="$TMP/trace8"; ARGS="$TRACE.args"; rm -f "$TRACE" "$ARGS"
env -u DISPLAY -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" TRACE="$TRACE" \
    BOX_CONSOLE_STATE="$STATE" TTY=/dev/tty1 \
    BOX_CONSOLE_XINIT="$ROOT/box-console.xinit" \
    sh -c 'tty() { echo /dev/tty1; }; . '"$PROFILE" >/dev/null 2>&1
ARGS="$(cat "$ARGS" 2>/dev/null)"
has "server běží na tty1" "$ARGS" "vt1"
has "a chyby Xorgu jdou do logu" "$ARGS" "-logfile"
noline "žádný -screen (640x480 by GLX rozbilo)" "$ARGS" "-screen"
has "server běží na tty1" "$ARGS" "vt1"

# ── jistič: tři rychlé pády = konec, login shell zůstane ───────────────
STATE="$TMP/state2"; mkdir -p "$STATE"
TRACE="$TMP/trace6"; rm -f "$TRACE"
for _ in 1 2 3 4; do
    env -u DISPLAY -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" TRACE="$TRACE" \
        BOX_CONSOLE_STATE="$STATE" TTY=/dev/tty1 \
        BOX_CONSOLE_XINIT="$ROOT/box-console.xinit" \
        sh -c 'tty() { echo /dev/tty1; }; . '"$PROFILE" >/dev/null 2>&1
done
chk "jistič pustí start třikrát" "$(grep -c started "$TRACE")" "3"
has "a pak to řekne do shellu" "$(env -u DISPLAY -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" TRACE="$TRACE" \
        BOX_CONSOLE_STATE="$STATE" TTY=/dev/tty1 \
        BOX_CONSOLE_XINIT="$ROOT/box-console.xinit" \
        sh -c 'tty() { echo /dev/tty1; }; . '"$PROFILE" 2>&1)" "nechávám login shell"

# po 30 s pauze jistič zase pustí
printf '0\n%s\n' "$(( $(date +%s) - 40 ))" > "$STATE/.box-console.fails"
printf '%s\n' "$(( $(date +%s) - 40 ))" > "$STATE/.box-console.last"
TRACE="$TMP/trace7"; rm -f "$TRACE"
env -u DISPLAY -u SSH_CONNECTION -u SSH_CLIENT PATH="$TMP/stub:$TMP/nolog:/usr/bin:/bin" TRACE="$TRACE" \
    BOX_CONSOLE_STATE="$STATE" TTY=/dev/tty1 \
    BOX_CONSOLE_XINIT="$ROOT/box-console.xinit" \
    sh -c 'tty() { echo /dev/tty1; }; . '"$PROFILE" >/dev/null 2>&1
chk "po delší pauze se rozjede znovu" "$(grep -c started "$TRACE")" "1"

# ── konfigurace: co se do repa vejde a co nesmí ───────────────────────
DROPIN="$ROOT/getty-tty1-autologin.conf"
has "autologin bez hesla na tty1" "$(cat "$DROPIN")" "--autologin pi"
has "a vypne původní ExecStart" "$(cat "$DROPIN")" "ExecStart="

# Autologin pro box B (login shell na TV, když je headless sampler a nemá
# binárku tracker). Oba prepare skripty MAZOU autologin.conf jako artefakt
# předchozího boxu, takže se musí instalovat AŽ po tom rm — jinak by si
# skript smazal to, co před chvílí nainstaloval.
for P in "$ROOT/prepare-sd.sh" "$ROOT/qemu_raspi4.sh"; do
    N="$(basename "$P")"
    [ -f "$P" ] || { bad "$N chybí"; continue; }
    has "$N umí --console-login" "$(cat "$P")" "--console-login"
    has "$N instaluje getty drop-in" "$(cat "$P")" \
        "getty@tty1.service.d/autologin.conf"
    # Pořadí: rm musí být před instalací.
    I_RM="$(grep -n 'rm -f .*getty@tty1.service.d/autologin.conf' "$P" | head -1 | cut -d: -f1)"
    I_IN="$(grep -n 'getty-tty1-autologin.conf' "$P" | head -1 | cut -d: -f1)"
    if [ -n "$I_RM" ] && [ -n "$I_IN" ] && [ "$I_IN" -gt "$I_RM" ]; then
        ok "$N: drop-in se instaluje až po rm, který by ho smazal (ř. $I_IN > $I_RM)"
    else
        bad "$N: instalace (ř. ${I_IN:-?}) není za rm (ř. ${I_RM:-?}) — skript by si vlastní práci smazal"
    fi
    # Box B nemá tracker, takže X relace se NEinstaluje — jinak by padala v
    # smyčce (viz box-console.xinit, který bez binárky končí).
    hasnt "$N: X relaci na box B netáhne" "$(cat "$P")" \
        "box-console-profile.sh"
done

SCRIPT="$ROOT/box-console.sh"
S="$(cat "$SCRIPT")"
has "režim on vypne headless službu" "$S" "systemctl disable --now tracker.service"
has "režim off ji zase zapne" "$S" "systemctl enable --now tracker.service"
has "on i off jsou idempotentní" "$S" "idempotentní"
has "on odmítne běžet, když chybí X" "$S" "chybí X (startx/xrandr)"
# sudo vyhazuje SSH_CONNECTION z prostředí, takže se nesmí rozhodovat podle něj
hasnt "nerozhoduje podle SSH_CONNECTION" "$S" '"$SSH_CONNECTION"'
has "rozpozná console podle tty" "$S" '= /dev/tty1 ]'
# X se nesmí přepojovat přes `systemctl restart getty@tty1` — nový X pak
# naběhne dřív, než starý uvolní DRM, a nemá GLX vizuály (GLXBadFBConfig).
hasnt "nepřepojí login přes systemctl restart" "$(code "$SCRIPT")" "systemctl restart getty"
has "login se přepojí přes stop, počká na Xorg a start" "$(code "$SCRIPT")" "pgrep -x Xorg"
has "a startne ho až poté" "$(code "$SCRIPT")" "systemctl start getty@tty1"
# režim výstupu: X musí zůstat v nativním režimu TV, 640x480 neumí GLX
hasnt "xinit nepřepíná režim výstupu" "$(code "$ROOT/box-console.xinit")" "xrandr --output"
hasnt "ani zmenšením framebufferu" "$(code "$ROOT/box-console.xinit")" "--fb"
hasnt "xinit se nespouští přes startx" "$(cat "$PROFILE")" "exec startx"
# X nesmí skončit za běhu (GLX umí jen první X po bootu), takže konzole se
# rozjíždí při startu systému a zvuková obnova trackera nekončí relaci
hasnt "xinit si už nic neodkládá" "$(code "$ROOT/box-console.xinit")" "/run/box-console."
# 'on' přepojí login (počká na dojezd starého X), ale ne restartuje systém —
# kdyby ho restartovalo, přišlo by o nesprávný login prompt v profilu.
has "a 'on' neprázdní login místo login promptu" "$(code "$ROOT/box-console-profile.sh")" "nechávám login shell"
hasnt "ani nerestartuje systém" "$(code "$SCRIPT")" "systemctl reboot"
has "čistý exit trackera relaci neukončí" "$(code "$ROOT/box-console.xinit")" "X relace běží dál"
has "a po řadě pádů ji ukončí" "$(code "$ROOT/box-console.xinit")" "nespravuje"
# V konzoli trackera drží cyklus v box-console.xinit, ne systemd — obnova ho
# zabije a cyklus ho pustí znovu nad čerstvou kartou.
has "zvuková obnova ho zabije SIGKILLem" "$(cat "$SCRIPT")" "pkill -KILL -x"
hasnt "a ne SIGINTem" "$(cat "$SCRIPT")" "pkill -INT -x"

# konzolová relace nemá jednotku, jen proces
DROPIN2="$ROOT/box-sound-restart.service"
has "jednotka zůstává udev-only" "$(cat "$DROPIN2")" "Bez [Install]"
hasnt "jednotka není v bootu sama od sebe" "$(cat "$DROPIN2")" "WantedBy="

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
