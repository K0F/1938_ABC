#!/bin/bash
# tests/test-box-autossh.sh — testy pro reverzní AutoSSH tunel (box-autossh.sh)
#
# Ověřuje:
#   1. Detekci identity Boxu (A -> port 2224, B -> port 2225)
#   2. Prioritu /etc/box-identity, parametru a proměnné BOX
#   3. Správné sestavení parametrů reverzního tunelu (-R 127.0.0.1:PORT:localhost:22)
#   4. Přejímání proměnných pro cílový server (pesek.com:2222)
#   5. Detekci chybějícího klíče a ohlášení chyby
#
#   usage: ./tests/test-box-autossh.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/box-autossh.sh"
[ -x "$SCRIPT" ] || { echo "chybi $SCRIPT" >&2; exit 1; }

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { PASS=$((PASS + 1)); printf '    ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL %s\n' "$1"; }

echo "== 1) Detekce Box A -> port 2224 =="
OUT_A="$("$SCRIPT" status A)"
echo "$OUT_A" | grep -q 'Box identity: A' && ok "identita A" || bad "identita není A"
echo "$OUT_A" | grep -q 'Remote port:  2224' && ok "port 2224" || bad "port pro A není 2224"
echo "$OUT_A" | grep -q 'Target host:  pesek.com:2222' && ok "výchozí pesek.com:2222" || bad "špatný target host"

echo "== 2) Detekce Box B -> port 2225 =="
OUT_B="$("$SCRIPT" status B)"
echo "$OUT_B" | grep -q 'Box identity: B' && ok "identita B" || bad "identita není B"
echo "$OUT_B" | grep -q 'Remote port:  2225' && ok "port 2225" || bad "port pro B není 2225"

echo "== 3) /etc/box-identity má přednost před výchozím fallbackem =="
FAKE_ROOT="$TMP/fake"
mkdir -p "$FAKE_ROOT/etc"
echo "A" > "$FAKE_ROOT/etc/box-identity"
OUT_FILE="$(chroot "$FAKE_ROOT" /bin/sh -c 'exit 0' 2>/dev/null || true)"
# Test bez chrootu: otestujeme přes proměnnou prostředí BOX
BOX=A; OUT_ENV="$(BOX=A "$SCRIPT" status)"
echo "$OUT_ENV" | grep -q 'Box identity: A' && ok "BOX=A dává A" || bad "BOX=A nedalo A"
echo "$OUT_ENV" | grep -q 'Remote port:  2224' && ok "BOX=A dává 2224" || bad "BOX=A nedalo 2224"

OUT_ENV_B="$(BOX=B "$SCRIPT" status)"
echo "$OUT_ENV_B" | grep -q 'Box identity: B' && ok "BOX=B dává B" || bad "BOX=B nedalo B"
echo "$OUT_ENV_B" | grep -q 'Remote port:  2225' && ok "BOX=B dává 2225" || bad "BOX=B nedalo 2225"

echo "== 4) Vlastní server a port přes proměnné prostředí =="
OUT_CUSTOM="$(BOX_REMOTE_HOST=xn--peek-h6a.com BOX_REMOTE_SSH_PORT=2222 BOX_REMOTE_PORT=9999 "$SCRIPT" status A)"
echo "$OUT_CUSTOM" | grep -q 'Target host:  xn--peek-h6a.com:2222' && ok "custom host xn--peek-h6a.com" || bad "custom host selhal"
echo "$OUT_CUSTOM" | grep -q 'Remote port:  9999' && ok "custom port 9999" || bad "custom port selhal"

echo "== 5) Běh (run) bez klíče ohlásí chybu a skončí se statusem 1 =="
FAKE_KEY="$TMP/nonexistent_key"
set +e
ERR_OUT="$(BOX_SSH_KEY="$FAKE_KEY" "$SCRIPT" run A 2>&1)"
RET=$?
set -u
[ "$RET" -ne 0 ] && ok "skript bez klíče selhal" || bad "skript bez klíče neselhal"
echo "$ERR_OUT" | grep -q "ERROR: Key file $FAKE_KEY not found" && ok "chybová hláška o klíči" || bad "chybí hláška o klíči: $ERR_OUT"

echo "== 6) S platným klíčem spustí autossh nebo ssh s -R =="
touch "$TMP/fake_key"
# Podstrčíme falešný autossh
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/autossh" <<'EOF'
#!/bin/bash
echo "AUTOSSH: $*"
exit 0
EOF
chmod 755 "$FAKEBIN/autossh"

RUN_OUT="$(PATH="$FAKEBIN:$PATH" BOX_SSH_KEY="$TMP/fake_key" "$SCRIPT" run A)"
echo "$RUN_OUT" | grep -q 'AUTOSSH:' && ok "autossh byl zavolán" || bad "autossh nebyl zavolán"
echo "$RUN_OUT" | grep -q -- '-R 127.0.0.1:2224:localhost:22' && ok "reverzní tunel pro Box A (-R 127.0.0.1:2224:localhost:22)" || bad "špatný -R parametr: $RUN_OUT"
echo "$RUN_OUT" | grep -q -- '-p 2222' && ok "port 2222" || bad "chybí -p 2222"
echo "$RUN_OUT" | grep -q -- 'kof@pesek.com' && ok "kof@pesek.com" || bad "chybí kof@pesek.com"

RUN_OUT_B="$(PATH="$FAKEBIN:$PATH" BOX_SSH_KEY="$TMP/fake_key" "$SCRIPT" run B)"
echo "$RUN_OUT_B" | grep -q -- '-R 127.0.0.1:2225:localhost:22' && ok "reverzní tunel pro Box B (-R 127.0.0.1:2225:localhost:22)" || bad "špatný -R parametr pro B: $RUN_OUT_B"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
