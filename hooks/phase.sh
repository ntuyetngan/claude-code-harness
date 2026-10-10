#!/usr/bin/env bash
# Sets or clears the repo phase the path guard reads: "fix" locks the named regression test files
# (test-first fixes), or all of tests/ when none is named. The phase file is "fix" then one path per line.
#   phase.sh set fix [test file...] | clear | show
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=phase
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "phase: not in a git repo" >&2; exit 64; }
REPO="$(basename "$ROOT")"; F="$LOOP_STATE/phase/$REPO"
case "${1:-show}" in
  set) case "${2:-}" in fix) shift 2; mkdir -p "$LOOP_STATE/phase"
              { echo fix; for p in "$@"; do case "$p" in /*) p="${p#"$ROOT"/}" ;; esac; echo "${p#./}"; done; } > "$F"
              hook_log "$REPO phase=fix $*"; echo "phase for $REPO: fix (locked: ${*:-all of tests/})" ;;
            *) echo "usage: phase.sh set fix [test file...]" >&2; exit 64 ;; esac ;;
  clear) rm -f "$F" && hook_log "$REPO phase cleared" && echo "phase for $REPO: cleared" ;;
  show) if [ -f "$F" ]; then echo "phase for $REPO: $(paste -sd' ' "$F") (set $(( ( $(date +%s) - $(stat -c %Y "$F") ) / 60 )) min ago)"; else echo "phase for $REPO: none"; fi ;;
  *) echo "usage: phase.sh set fix [test file...] | clear | show" >&2; exit 64 ;;
esac
