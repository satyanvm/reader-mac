#!/bin/bash
# Runs the reading-position acceptance scenarios against the real app (build/Reader.app) with a
# scratch library, killing the process with SIGKILL between runs so nothing depends on a save at
# quit. Usage: scripts/acceptance.sh <book.pdf|book.epub> [page-index]
set -uo pipefail
cd "$(dirname "$0")/.."
BOOK="$1"; PAGE="${2:-186}"
WORK="$(mktemp -d)"; LOG="$WORK/log.jsonl"; SUPPORT="$WORK/support"; mkdir -p "$SUPPORT"
APP="$(pwd)/build/Reader.app"
BIN="$APP/Contents/MacOS/Reader"

run() { # step, then waits for the step's "done" line
  local step="$1"; shift
  local before; before=$(cat "$LOG" 2>/dev/null | grep -c '"what":"done"')
  # Launched directly (not with `open`), so only this process is killed, never a copy of Reader
  # someone is using.
  READER_SUPPORT_DIR="$SUPPORT" READER_SELFTEST="$step" READER_SELFTEST_LOG="$LOG" \
    READER_SELFTEST_PAGE="$PAGE" READER_SELFTEST_IMPORT="${1:-}" "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 600); do
    [ "$(cat "$LOG" 2>/dev/null | grep -c '"what":"done"')" -gt "$before" ] && break
    sleep 0.1
  done
  kill -9 "$pid"; wait "$pid" 2>/dev/null; sleep 0.3   # like a crash or power loss: no quit handlers run
}

run read "$BOOK"            # import, read to the page, never quit cleanly
echo "after kill -9: $(sqlite3 "$SUPPORT/reader.sqlite" 'select pageIndex, pageOffset, deviceId from reading_positions')"
run all                     # relaunch: restore, then resize, zoom, flowing text, text size
run all                     # and once more, after all that relayout
sed -e 's/"notice":"[^"]*",//' "$LOG"
echo "log: $LOG"
