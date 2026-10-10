#!/usr/bin/env bash
# Stop hook — reviews this turn's comments; a separate model can't inherit the reasoning that justified them.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/comment-rule.sh"

input="$(cat)"
session="$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)" || exit 0
case "$session" in *[!A-Za-z0-9_-]*|'') session=unknown ;; esac
queue="$QUEUE_DIR/$session.jsonl"
rounds="$QUEUE_DIR/$session.rounds"
audit_safe_queue_dir || exit 0

is_continuation="$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)"

# One real re-check on a continuation, then give up, so a fix can't dodge review but also can't loop forever.
if [ "$is_continuation" = "true" ]; then
  round="$(cat "$rounds" 2>/dev/null)"
  case "$round" in ''|*[!0-9]*) round=0 ;; esac
  if [ "$round" -ge 1 ]; then
    rm -f "$queue" "$rounds"
    audit_log "judge    skip      loop limit reached (already re-checked the fix)"
    audit_say "skipped (loop limit reached)"
    exit 0
  fi
else
  rm -f "$rounds"
fi

if [ ! -s "$queue" ]; then
  audit_log "judge    skip      nothing queued"
  exit 0
fi
# Every item carries its own file name now, so the per-file grouping isn't needed.
all_items="$(jq -s '[.[] | .file as $f | .items[] | {file: $f, context: .context, comment: .comment}]' "$queue" 2>/dev/null)"
n="$(jq 'length' <<<"$all_items" 2>/dev/null)"
[ "${n:-0}" -gt 0 ] 2>/dev/null || { rm -f "$queue"; exit 0; }

# Line count is enforced here in jq, not the prompt — the model doesn't reliably apply the rule's own one-line limit to a docblock.
auto_cuts="$(jq -r '.[] | select(.comment | test("\n")) | (.comment | split("\n")[0]) + " — runs past one line"' <<<"$all_items" 2>/dev/null)"
manual_items="$(jq '[.[] | select(.comment | test("\n") | not)]' <<<"$all_items" 2>/dev/null)"
mn="$(jq 'length' <<<"$manual_items" 2>/dev/null)"

cuts="$auto_cuts"

if [ "${mn:-0}" -gt 0 ]; then
  # Exact row count avoids essay-length replies; per-item ids let a row be matched back to its item instead of trusting an echoed (or, as observed, omitted) comment.
  prompt="$(jq -r --arg rule "$RULE" --arg n "$mn" '
    "RULE: \($rule)",
    "",
    "Output EXACTLY \($n) rows, one per AUDIT item, in order 1 through \($n).",
    "Each row:  <id>) KEEP <reason>   or   <id>) CUT <reason>, max 8 words.",
    "Use the AUDIT item'"'"'s own number as <id>. One row per number, in that order.",
    "Judge only the text below. Do not read files. No preamble, no summary.",
    "",
    "Delete the comment and ask what a reader loses.",
    "",
    "KEEP it if it states something not present in the code: a fact about an",
    "external system (a payment provider, a database engine, a protocol, a",
    "partner), a constraint or limit, a required ordering, or a consequence of",
    "getting it wrong. Do not CUT a comment just because the code below it visibly",
    "does what the comment refers to. Ask whether the reason is in the code, not",
    "the action.",
    "",
    "CUT it if it only names what the code does, argues for this design over an",
    "alternative, or carries ticket or project history.",
    "",
    "CUT it also if it narrates the bug this code fixes (for example, \"X used to",
    "happen until...\", \"previously...\", or a ticket ID), even when an external",
    "system is named in passing. KEEP only a plain fact about the external system,",
    "stated without a before/after narrative.",
    "",
    (to_entries[] | "--- \(.value.file) ---", .value.context, "AUDIT \(.key + 1): \(.value.comment)", "")
  ' <<<"$manual_items" 2>/dev/null)"

  [ -n "$prompt" ] || { rm -f "$queue"; exit 0; }

  # These flags stop the judge acting as an agent; without them a 1.7s call ran past 40s.
  audit_log "judge    start     $mn comment(s) ($n total, $((n - mn)) auto-cut multi-line)"
  started=$SECONDS
  verdict="$(printf '%s' "$prompt" | MAX_THINKING_TOKENS=0 claude -p --model haiku \
    --system-prompt "You are a terse code-comment auditor. You have no tools and read no files. You output only the exact rows requested, nothing else." \
    --disallowed-tools "Read,Write,Edit,Bash,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --setting-sources '' --exclude-dynamic-system-prompt-sections 2>/dev/null)"
  rc=$?

  took=$((SECONDS - started))
  audit_log "judge    verdict   rc=$rc ${took}s :: $(printf '%s' "${verdict:-<empty>}" | tr '\n' '|')"

  # An errored or empty call is not a pass — reporting "all passed" here would hide the failure behind a green result.
  if [ $rc -ne 0 ] || [ -z "$(printf '%s' "$verdict" | tr -d '[:space:]')" ]; then
    rm -f "$queue"
    audit_log "judge    FAIL      exit=$rc, not reviewed (${took}s)"
    audit_say "judge call failed (exit $rc) - comments NOT reviewed this turn"
    exit 0
  fi

  # Exact-id-sequence validation (not just row count) also catches two rows both judging item 1 while item 2 is silently never judged.
  valid_row='^[[:space:]]*[0-9]+\)[[:space:]]+(KEEP|CUT)[[:space:]]+[^[:space:]]'
  rows="$(printf '%s\n' "$verdict" | grep -cE "$valid_row")"
  nonblank="$(printf '%s\n' "$verdict" | grep -cE '[^[:space:]]')"
  ids="$(printf '%s\n' "$verdict" | grep -E "$valid_row" | sed -E 's/^[[:space:]]*([0-9]+)\).*/\1/')"
  expected="$(seq 1 "$mn")"
  if [ "$rows" -ne "$mn" ] || [ "$nonblank" -ne "$mn" ] || [ "$ids" != "$expected" ]; then
    rm -f "$queue"
    audit_log "judge    FAIL      malformed verdict ($rows/$mn rows, ids: $(printf '%s' "$ids" | tr '\n' ',')), not reviewed (${took}s)"
    audit_say "judge output malformed - comments NOT reviewed this turn"
    exit 0
  fi

  # Looks the comment up by id rather than trust the model's echo, so the report is accurate even if the model paraphrases or omits it.
  cut_pairs="$(printf '%s\n' "$verdict" | grep -E "$valid_row" | grep -E '\)[[:space:]]+CUT[[:space:]]' \
    | sed -E 's/^[[:space:]]*([0-9]+)\)[[:space:]]+CUT[[:space:]]+(.*)$/\1\t\2/')"
  model_cuts="$(printf '%s\n' "$cut_pairs" | jq -Rrs --argjson items "$manual_items" '
    split("\n") | map(select(length > 0))
    | [.[] | capture("^(?<id>[0-9]+)\t(?<reason>.*)$")?]
    | map($items[(.id | tonumber) - 1].comment + " — " + .reason)
    | .[]
  ' 2>/dev/null)"
  cuts="$(printf '%s\n%s\n' "$cuts" "$model_cuts" | sed '/^$/d')"
else
  audit_log "judge    start     0 comment(s) for the model ($n total, all auto-cut multi-line)"
fi

rm -f "$queue"

if [ -z "$cuts" ]; then
  audit_log "judge    PASS      all $n comment(s) accepted"
  audit_say "reviewed $n comment(s) - all passed"
  exit 0
fi

# Consumed only on an actual block, not merely on reaching a continuation — see the loop-limit check above.
[ "$is_continuation" = "true" ] && echo 1 > "$rounds" 2>/dev/null

ncut="$(printf '%s\n' "$cuts" | wc -l | tr -d ' ')"
audit_log "judge    BLOCK     $ncut of $n cut"
jq -n --arg v "$cuts" --arg m "comment-audit: blocked - $ncut of $n comment(s) cut" '{
  systemMessage: $m,
  decision: "block",
  reason: ("An independent review flagged comments in files changed this turn:\n\n\($v)\n\n" +
           "Delete or rewrite each one, then finish. Do not narrate the audit.")
}'
