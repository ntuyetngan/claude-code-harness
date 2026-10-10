#!/usr/bin/env bash
# Read or change the quality-gate thresholds in ~/.claude/config/quality.json, and show the trend.
#   quality-config.sh show                 current thresholds, and the last runs from the history file
#   quality-config.sh set crap <max>       a changed method above this CRAP score is RED (default 30)
#   quality-config.sh set mutation <min>   mutation score below this percent is RED at handoff (default 60)
#   quality-config.sh mutation on|off      enable or disable the mutation gate without losing its threshold
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=quality-config
Q="$HOME/.claude/config/quality.json"
[ -f "$Q" ] || { echo "no $Q" >&2; exit 64; }
ROOT="$(repo_root "$PWD")"; REPO="$(basename "${ROOT:-none}")"; H="$LOOP_STATE/quality/$REPO.jsonl"
write() { tmp="$(mktemp)"; jq "$1" "$Q" > "$tmp" && mv "$tmp" "$Q"; }
is_num() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }
case "${1:-show}" in
  show)
    echo "quality thresholds ($Q):"
    jq -r '"  CRAP max            \(.crap.max)   (changed methods above this are RED in every /verify)",
           "  mutation min score  \(.mutation.min_msi)%  (\(if .mutation.enabled then "enabled" else "DISABLED" end), runs in /handoff and /quality)"' "$Q"
    if [ -f "$H" ]; then
      echo "recent runs for $REPO ($H):"
      jq -r 'select(.metric=="crap_summary") | "  \(.ts|strftime("%Y-%m-%d %H:%M"))  CRAP  \(.methods) method(s), \(.above) above \(.threshold), combined \(.combined), average \(.average)"' "$H" | tail -5
      jq -r 'select(.metric=="msi") | "  \(.ts|strftime("%Y-%m-%d %H:%M"))  mutation  score \(.value)% against \(.threshold)%  (\(.counts))"' "$H" | tail -5
    else echo "no runs recorded yet for $REPO"; fi ;;
  set)
    case "${2:-}" in
      crap) is_num "${3:-}" || { echo "usage: quality-config.sh set crap <number>" >&2; exit 64; }
            old="$(jq -r .crap.max "$Q")"; write ".crap.max = ${3}" && hook_log "crap.max $old -> $3" && echo "CRAP max: $old -> $3. Applies to the next /verify." ;;
      mutation) is_num "${3:-}" || { echo "usage: quality-config.sh set mutation <percent>" >&2; exit 64; }
            old="$(jq -r .mutation.min_msi "$Q")"; write ".mutation.min_msi = ${3}" && hook_log "mutation.min_msi $old -> $3" && echo "mutation min score: $old% -> $3%. Applies to the next /handoff or /quality mutation." ;;
      *) echo "usage: quality-config.sh set crap <number> | set mutation <percent>" >&2; exit 64 ;;
    esac ;;
  mutation)
    case "${2:-}" in
      on) write '.mutation.enabled = true' && hook_log "mutation enabled" && echo "mutation gate enabled (min score $(jq -r .mutation.min_msi "$Q")%)" ;;
      off) write '.mutation.enabled = false' && hook_log "mutation disabled" && echo "mutation gate disabled: /handoff and /quality record SKIP instead of running it. Threshold kept." ;;
      *) echo "usage: quality-config.sh mutation on|off" >&2; exit 64 ;;
    esac ;;
  *) echo "usage: quality-config.sh show | set crap <n> | set mutation <percent> | mutation on|off" >&2; exit 64 ;;
esac
