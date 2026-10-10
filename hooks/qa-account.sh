#!/usr/bin/env bash
# Looks up a QA account for the current repo and prints what a qa-agent brief needs: the login,
# the password, and the saved browser state file to load first. The file is ~/.claude/config/qa-accounts.json
# (mode 600). Output goes only into the brief; never into a summary, a receipt or a page.
#   qa-account.sh <role> [env]       print JSON {role, env, email, password, note, state_file, state_age_minutes}
#   qa-account.sh list [env]         print the roles the file has for this repo and env, with whether a password is set
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=qa-account
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "qa-account: not in a git repo" >&2; exit 64; }
REPO="$(basename "$ROOT")"; F="$HOME/.claude/config/qa-accounts.json"; ENV="${2:-dev}"
[ -f "$F" ] || { echo "qa-account: no $F; create it from the template in the qa skill" >&2; exit 66; }
[ "$(stat -c %a "$F")" = 600 ] || { echo "qa-account: $F must be mode 600 (chmod 600 $F)" >&2; exit 65; }
STATE_DIR="$HOME/.claude/qa/state"; mkdir -p "$STATE_DIR"
case "${1:-}" in
  list) jq -r --arg r "$REPO" --arg e "$ENV" '.[$r][$e] // {} | to_entries[] | "\(.key): \(if (.value.password // "") != "" then "password set" else "no password" end)\(if .value.note then " (" + .value.note + ")" else "" end)"' "$F" ;;
  "") echo "usage: qa-account.sh <role> [env] | list [env]" >&2; exit 64 ;;
  *) role="$1"; sf="$STATE_DIR/$REPO-$ENV-$role.json"
     jq -e --arg r "$REPO" --arg e "$ENV" --arg o "$role" '.[$r][$e][$o]' "$F" >/dev/null 2>&1 || { echo "qa-account: no '$role' for $REPO/$ENV in $F" >&2; exit 66; }
     # A saved state holds session cookies; keep it private whoever wrote it.
     [ -f "$sf" ] && chmod 600 "$sf"
     age=""; [ -f "$sf" ] && age=$(( ( $(date +%s) - $(stat -c %Y "$sf") ) / 60 ))
     jq -c --arg r "$REPO" --arg e "$ENV" --arg o "$role" --arg sf "$sf" --arg age "$age" \
       '.[$r][$e][$o] as $a | {role:$o, env:$e, email:($a.email // ""), password:($a.password // ""), note:($a.note // ""), state_file:$sf, state_exists:($age != ""), state_age_minutes:(if $age == "" then null else ($age|tonumber) end)}' "$F" ;;
esac
