#!/usr/bin/env bash
# Switch the loop's hooks off or on without touching settings.json. Takes effect on the next tool call.
#   harness.sh off | on | status
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=harness
case "${1:-status}" in
  off) touch "$LOOP_STATE/off" && hook_log "loop switched off" && echo "loop OFF: preflight, guards, post-edit and the stop gate are skipped until 'harness.sh on'. Skills still work on demand." ;;
  on) rm -f "$LOOP_STATE/off" && hook_log "loop switched on" && echo "loop ON: hooks active again on the next tool call." ;;
  status) if [ "${CLAUDE_LOOP:-on}" = off ]; then echo "loop OFF for this whole session (CLAUDE_LOOP=off in the environment)";
          elif [ -f "$LOOP_STATE/off" ]; then echo "loop OFF (off file set $(( ( $(date +%s) - $(stat -c %Y "$LOOP_STATE/off") ) / 60 )) min ago); 'harness.sh on' to resume";
          else echo "loop ON"; fi ;;
  report) kind="${2:-task}"; out="$(python3 "$(dirname "${BASH_SOURCE[0]}")/report.py" "$kind" "$PWD" ${3:+"$3"})" || exit 1
          echo "$kind report: $out"; command -v explorer.exe >/dev/null 2>&1 && explorer.exe "$(wslpath -w "$out")" >/dev/null 2>&1; exit 0 ;;
  *) echo "usage: harness.sh off | on | status | report [task|weekly]" >&2; exit 64 ;;
esac
