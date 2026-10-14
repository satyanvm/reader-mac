#!/bin/bash
# End-to-end sync check: the real server (../server) and two Macs, simulated as two libraries
# with their own device ids, reading the same book. Mac A creates an account (email, password,
# the emailed code); Mac B signs in to it. Every app run ends in SIGKILL.
# Usage: scripts/sync-e2e.sh <book.pdf|book.epub> [page] [later-page]
set -uo pipefail
cd "$(dirname "$0")/.."
BOOK="$1"; PAGE="${2:-186}"; LATER="${3:-250}"
WORK="$(mktemp -d)"; LOG="$WORK/log.jsonl"; DB="$WORK/server.sqlite"; PORT=8799
APP="$(pwd)/build/Reader.app"; BIN="$APP/Contents/MacOS/Reader"
SERVER="$(cd ../server && pwd)"
node="node --disable-warning=ExperimentalWarning"

start_server() {
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null; then echo "port $PORT is already in use"; exit 1; fi
  READER_DB="$DB" PORT=$PORT READER_DEV_MAIL_DIR="$MAIL" $node "$SERVER/bin/server.js" >> "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && return; sleep 0.1; done
  echo "server didn't start"; exit 1
}
stop_server() { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }

MAIL="$WORK/mail"; EMAIL="reader-$RANDOM@example.com"; PASSWORD="correct horse battery"
ACCOUNT_ENV=()

run() { # library step linger [page] [file]
  local lib="$1" step="$2" linger="$3" page="${4:-$PAGE}" book="${5:-}"
  mkdir -p "$WORK/$lib"
  local before; before=$(cat "$LOG" 2>/dev/null | grep -c '"what":"done"')
  env ${ACCOUNT_ENV[@]+"${ACCOUNT_ENV[@]}"} READER_SUPPORT_DIR="$WORK/$lib" READER_SELFTEST="$step" READER_SELFTEST_LOG="$LOG" \
    READER_SELFTEST_PAGE="$page" READER_SELFTEST_LINGER="$linger" READER_SELFTEST_IMPORT="$book" \
    READER_DEV_MAIL_DIR="$MAIL" READER_SYNC_BASE_URL="http://127.0.0.1:$PORT" \
    "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 900); do
    [ "$(cat "$LOG" 2>/dev/null | grep -c '"what":"done"')" -gt "$before" ] && break
    sleep 0.1
  done
  [ "$(cat "$LOG" 2>/dev/null | grep -c '"what":"done"')" -gt "$before" ] || echo "   TIMEOUT: $lib $step never finished (see trace lines in $LOG)"
  kill -9 "$pid"; wait "$pid" 2>/dev/null; sleep 0.3
  ACCOUNT_ENV=()
  grep '"account"' "$LOG" | tail -1 | grep -q . && [ -n "${SHOW_ACCOUNT:-}" ] && echo "   account: $(grep '"account"' "$LOG" | tail -1)"
  echo "-- $lib $step: $(tail -2 "$LOG" | head -1 | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print("page", d.get("page"), "frac", round(d.get("fraction",0),3), "notice", d.get("notice"), d.get("telemetry",""))')"
}
server_row() { sqlite3 "$DB" "select page_index, round(page_offset,3), substr(device_id,1,8) from reading_positions"; }
pending() { sqlite3 "$WORK/$1/reader.sqlite" "select count(*) from reading_positions where pendingSync=1"; }

start_server
echo "1. Mac A creates an account ($EMAIL), confirms the emailed code, and reads to page index $PAGE"
ACCOUNT_ENV=(READER_SELFTEST_SIGNUP="$EMAIL:$PASSWORD"); SHOW_ACCOUNT=1
run A read 7 "$PAGE" "$BOOK"
echo "   accounts on the server: $(sqlite3 "$DB" "select email || ' verified=' || (email_verified_at is not null) from accounts")"
echo "   server: $(server_row)   A pending: $(pending A)"
echo "2. Mac B signs in with the same email and password, and opens the same book for the first time"
ACCOUNT_ENV=(READER_SELFTEST_SIGNIN="$EMAIL:$PASSWORD")
run B observe 1 "$PAGE" "$BOOK"
SHOW_ACCOUNT=
echo "3. Server goes down; B reads on to $LATER offline"
stop_server
run B read 7 "$LATER"
echo "   server down; B pending: $(pending B)"
echo "4. Server back; B relaunches and its offline progress goes up"
start_server
run B observe 6 "$LATER"
echo "   server: $(server_row)   B pending: $(pending B)"
echo "5. Mac A opens again: its local $PAGE first, then the server's newer $LATER"
run A observe 1 "$LATER"
echo "   A local: $(sqlite3 "$WORK/A/reader.sqlite" 'select pageIndex, round(pageOffset,3), substr(deviceId,1,8) from reading_positions')"
stop_server
echo "server log: $WORK/server.log"
