#!/usr/bin/env bash
# Stop hook: refuse to end a turn that changed code until every mapped suite has a receipt for the
# current diff. One refusal per diff: the second stop on the same diff passes, so a dead environment
# cannot trap the session, and the summary must then carry the RED table. A verify run in progress
# lets the turn end; its completion notification brings the session back.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=stop-gate
command -v jq >/dev/null 2>&1 || exit 0
loop_enabled || exit 0
read_hook_input
ROOT="$(repo_root "$HOOK_CWD")"; [ -n "$ROOT" ] || exit 0
SDIR="$LOOP_STATE/$HOOK_SESSION"; mkdir -p "$SDIR"
REFUSED_FILE="$SDIR/stop-refused-sha"
active="$(jq -r '.stop_hook_active // false' <<<"$HOOK_INPUT" 2>/dev/null)"

if [ ! -f "$SDIR/tree-at-start" ]; then hook_log "allow: no session snapshot for $HOOK_SESSION (preflight did not run at start)"; exit 0; fi
RUN_MARK="$LOOP_STATE/verify/$(basename "$ROOT")/running"
if [ -f "$RUN_MARK" ]; then
  read -r rpid rsha _ < "$RUN_MARK"
  if kill -0 "$rpid" 2>/dev/null; then
    hook_log "allow: verify running (pid $rpid, diff $rsha)"
    echo "Note: verify.sh is still running (pid $rpid) for diff $rsha; say the receipts are pending and wait for its completion notification." >&2
    exit 0
  fi
  rm -f "$RUN_MARK"
fi
MAP="$(cd "$ROOT" && "$(dirname "${BASH_SOURCE[0]}")/verify.sh" --map --session "$HOOK_SESSION" 2>/dev/null)" || exit 0
[ -n "$MAP" ] || exit 0
sha="$(jq -r '.diff_sha' <<<"$MAP")"; rdir="$(jq -r '.receipts' <<<"$MAP")"
mapfile -t suites < <(jq -r '.suites[]' <<<"$MAP")
# Judges run once per session each, after receipts are green (or when nothing needed a suite).
judges() {
  local jr="$SDIR/judge-rounds" branch plan out rc
  [ "$active" = true ] && [ -f "$jr" ] && { hook_log "allow: judges already refused once"; return 0; }
  out="$(printf '%s' "$HOOK_INPUT" | "$(dirname "${BASH_SOURCE[0]}")/comment-audit/comment-judge.sh" 2>/dev/null)"
  if jq -e '.decision=="block"' <<<"$out" >/dev/null 2>&1; then echo 1 > "$jr"; printf '%s\n' "$out"; exit 0; fi
  branch="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
  plan="$(find_plan "$(basename "$ROOT")" "$branch")" || { hook_log "judge: no approved plan for $branch"; return 0; }
  (cd "$ROOT" && "$(dirname "${BASH_SOURCE[0]}")/diff-judge.sh" "$plan" "$HOOK_SESSION"); rc=$?
  [ $rc -eq 2 ] && { echo 1 > "$jr"; exit 2; }
  return 0
}
[ ${#suites[@]} -gt 0 ] || { hook_log "allow: no suites map to this session's changes ($sha)"; rm -f "$REFUSED_FILE"; judges; exit 0; }

missing=(); red=()
for s in "${suites[@]}"; do
  r="$rdir/$s.json"
  if [ ! -f "$r" ]; then
    # A GREEN receipt whose suite read the same files, under another diff sha, covers this one too.
    want="$(jq -r --arg s "$s" '.inputs[$s] // ""' <<<"$MAP")"; hit=""
    if [ -n "$want" ]; then
      for o in $(ls -t "$(dirname "$rdir")"/*/"$s.json" 2>/dev/null | head -40); do
        [ "$(jq -r 'select(.status == "GREEN") | .inputs // ""' "$o" 2>/dev/null)" = "$want" ] && { hit="$o"; break; }
      done
    fi
    if [ -n "$hit" ]; then hook_log "GREEN $s by inputs from $(basename "$(dirname "$hit")")"; else missing+=("$s"); fi
  elif [ "$(jq -r '.status' "$r" 2>/dev/null)" != GREEN ]; then red+=("$s: $(jq -r '.detail' "$r" 2>/dev/null | cut -c1-120)"); fi
done
stray="$(pgrep -af 'phpstan|vitest|vue-tsc' 2>/dev/null | grep -v pgrep | head -3)"

if [ ${#missing[@]} -eq 0 ] && [ ${#red[@]} -eq 0 ]; then
  hook_log "allow: all ${#suites[@]} suites GREEN for $sha"
  rm -f "$REFUSED_FILE"
  [ -n "$stray" ] && printf 'Note: processes still running that may be yours: %s\n' "$stray" >&2
  judges
  exit 0
fi
# Already refused once for this exact diff: the same table on every later turn helps nobody.
if [ "$(cat "$REFUSED_FILE" 2>/dev/null)" = "$sha" ]; then
  hook_log "allow: already refused once for $sha (missing=[${missing[*]}] red=${#red[@]})"
  echo "Note: diff $sha still has ${#red[@]} RED and ${#missing[@]} missing receipt(s); the summary must show the RED table and what could not be verified." >&2
  exit 0
fi
echo "$sha" > "$REFUSED_FILE"
{
  echo "Stop refused (once per diff): code changed in this session ($(jq -r '.changed | join(", ")' <<<"$MAP" | cut -c1-200)) has no green verification for diff $sha."
  [ ${#missing[@]} -gt 0 ] && echo "No receipt yet: ${missing[*]}. Run /verify (it starts ~/.claude/hooks/verify.sh as a background task and writes receipts; wait for its completion notification)."
  [ ${#red[@]} -gt 0 ] && { echo "RED receipts:"; printf '  - %s\n' "${red[@]}"; echo "Fix the code and run /verify again. If a suite cannot run here, its RED reason stays in the receipt; the next stop on this diff is allowed, and your summary must show the RED table and say what could not be verified."; }
  [ -n "$stray" ] && echo "Processes still running: $stray"
} >&2
hook_log "BLOCK sha=$sha missing=[${missing[*]}] red=${#red[@]}"
exit 2
