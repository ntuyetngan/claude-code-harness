#!/usr/bin/env bash
# Called by stop-gate.sh when an approved plan exists for the branch. A separate Haiku that never saw
# the conversation compares the plan with this session's diff and labels every hunk requested or
# incidental, lists planned files the diff never touched, and flags rot in docs. Exit 2 with the
# findings blocks the stop; a judge failure also refuses once, asking for a self-audit (fail closed, by decision).
#
#   diff-judge.sh <plan-file> <session-id>
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=diff-judge
PLAN="$1"; SESSION="$2"
command -v claude >/dev/null 2>&1 || { hook_log "skip: claude CLI not found"; exit 0; }
[ -f "$PLAN" ] || exit 0
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || exit 0
cd "$ROOT" || exit 0
MAP="$("$(dirname "${BASH_SOURCE[0]}")/verify.sh" --map --session "$SESSION" 2>/dev/null)" || exit 0
mapfile -t files < <(jq -r '.changed[]' <<<"$MAP" 2>/dev/null)
[ ${#files[@]} -gt 0 ] || exit 0
BASE="$(git merge-base HEAD master 2>/dev/null || git rev-parse HEAD)"

diff_text=""
for f in "${files[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then d="$(git diff "$BASE" -- "$f" 2>/dev/null)"
  else d="$(printf -- '--- new file: %s\n' "$f"; sed 's/^/+/' "$f")"; fi
  diff_text+="$d"$'\n'
done
if [ "${#diff_text}" -gt 90000 ]; then
  hook_log "too large for the judge (${#diff_text} chars); refusing once"
  printf 'Stop refused: the diff (%d chars) is too large for the diff judge. Audit it yourself against the plan %s: list every hunk as requested or incidental, revert the incidental ones, then finish with that list in the summary.\n' "${#diff_text}" "$PLAN" >&2
  exit 2
fi

# Planned files the diff never touched are computed here, not by the model: every backticked path
# under "## Files that change" that is neither changed this session nor already in the tree's diff.
mapfile -t planned < <(awk '/^## Files that change/{f=1;next} /^## /{f=0} f' "$PLAN" | grep -o '`[^`]*`' | tr -d '`' | sort -u)
mapfile -t amended < <(awk '/^## Discovered during implementation/{f=1;next} /^## /{f=0} f' "$PLAN" | grep -v '^<!--' | grep -o '`[^`]*`' | tr -d '`' | sort -u)
amended_txt=""; for af in "${amended[@]}"; do amended_txt+="  - $af"$'\n'; done
missed_det=""
for pf in "${planned[@]}"; do printf '%s\n' "${files[@]}" | grep -qxF "$pf" || missed_det+="  - $pf"$'\n'; done

prompt="$(cat <<EOF
PLAN FILE (the contract for this change):
<plan>
$(cat "$PLAN")
</plan>

DIFF (every change this session made, one hunk block per file):
<diff>
$diff_text
</diff>

Judge the diff against the plan. Output ONLY a JSON object, no prose, no code fence:
{
  "hunks": [ {"file": "path", "what": "under 12 words", "verdict": "requested" | "incidental", "why": "under 12 words"} ],
  "rot": [ "path: quoted text of an ADDED comment line (// # /* *) that restates the code, or an added line in a docs/*.md file carrying a line number, ticket id, test count, or bug narrative" ]
}
Rules: one entry per file in hunks, judged as a whole. "requested" means the plan's goal, expected output, files that change, discovered-during-implementation list, or proof requires it. A file listed under "Discovered during implementation" with a reason counts as planned. "incidental" means a refactor, rename, extra guard, docblock or comment edit, formatting change, or a file the plan names nowhere. A test file named in Proof is requested. "rot" is only about comment lines and docs lines; code itself, however questionable, is never rot. Do not invent files. Empty arrays are fine.
EOF
)"

started=$SECONDS
verdict="$(printf '%s' "$prompt" | MAX_THINKING_TOKENS=0 timeout 90 claude -p --model haiku \
  --system-prompt "You are a strict diff auditor. You have no tools and read no files. You output exactly one JSON object and nothing else." \
  --disallowed-tools "Read,Write,Edit,Bash,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --setting-sources '' --exclude-dynamic-system-prompt-sections 2>/dev/null)"
rc=$?
json="$(printf '%s' "$verdict" | sed -n '/{/,$p' | sed 's/^```json//; s/^```//')"
if [ $rc -ne 0 ] || ! jq -e '.hunks and .rot' <<<"$json" >/dev/null 2>&1; then
  hook_log "FAIL rc=$rc in $((SECONDS-started))s, malformed or empty verdict; refusing once"
  printf 'Stop refused: the diff judge did not return a usable verdict (exit %s). Audit the diff yourself against the plan %s: list every hunk as requested or incidental, revert the incidental ones, name planned files not yet touched, then finish with that list in the summary.\n' "$rc" "$PLAN" >&2
  exit 2
fi
inc="$(jq -r '.hunks[] | select(.verdict=="incidental") | "  - \(.file): \(.what) (\(.why))"' <<<"$json")"
missed="${missed_det%$'\n'}"
rot="$(jq -r '.rot[] | "  - \(.)"' <<<"$json")"
hook_log "verdict in $((SECONDS-started))s: $(jq -c '{inc:([.hunks[]|select(.verdict=="incidental")]|length), rot:(.rot|length)}' <<<"$json") missed=$(printf '%s' "$missed_det" | grep -c .)"
if [ -z "$inc" ] && [ -z "$missed" ] && [ -z "$rot" ]; then exit 0; fi
{
  echo "Stop refused: the diff does not match the approved plan ($PLAN)."
  [ -n "$inc" ] && { echo "Incidental changes the plan does not ask for. Revert each, or add it to the plan under \"Discovered during implementation\" with the reason it was needed:"; echo "$inc"; }
  [ -n "$amended_txt" ] && { echo "Files added to the plan during implementation (accepted, listed for your review):"; printf '%s' "$amended_txt"; }
  [ -n "$missed" ] && { echo "Planned files or surfaces the diff never touched. Implement them, or update the plan with the user's agreement:"; echo "$missed"; }
  [ -n "$rot" ] && { echo "Comments or docs lines that will rot. Remove them:"; echo "$rot"; }
  echo "Then run /verify if code changed, and finish with a summary that lists what was reverted."
} >&2
exit 2
