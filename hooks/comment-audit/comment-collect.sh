#!/usr/bin/env bash
# PostToolUse(Edit|Write): queues comments for comment-judge.sh. Runs on every edit, so no model call, and must stay single-digit ms.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/comment-rule.sh"

input="$(cat)"
session="$(jq -r '.session_id // "unknown"' <<<"$input" 2>/dev/null)" || exit 0
case "$session" in *[!A-Za-z0-9_-]*|'') session=unknown ;; esac

audit_safe_queue_dir || exit 0

entry="$(jq -c \
  --arg types "$FILE_TYPES" \
  --arg exclude "$EXCLUDE_PATHS" \
  --arg comment "$COMMENT" \
  --arg trailing "$TRAILING" \
  --arg exempt "$EXEMPT" <<<"$input" '
  .tool_input as $in
  | ($in.file_path // "") as $file
  # A bare "\n" join would make the boundary between adjacent MultiEdit hunks look like one comment block.
  | ([$in.content, $in.new_string, ($in.edits[]?.new_string)]
      | map(select(type == "string"))
      | join("\n\n")
      | split("\n")) as $L
  # Shown the wrong lines, the judge cannot tell what is recoverable from the code.
  | [ range(0; $L | length) | select($L[.] | (test($comment) or test($trailing)) and (test($exempt) | not)) ] as $idx
  # Judged separately, each line of a block looks like a standalone remark.
  | ($idx | reduce .[] as $i ([];
      if (length > 0) and (.[-1][-1] == $i - 1)
      then .[:-1] + [.[-1] + [$i]]
      else . + [[$i]] end)) as $blocks
  | [ $blocks[]
      | {comment: ([.[] | $L[.]] | join("\n")),
         context: ($L[.[0] : (.[-1] + 5)] | join("\n"))} ] as $items
  | select(($file | test($types)) and ($file | test($exclude) | not) and ($items | length > 0))
  | {file: $file, items: $items[:20]}
' 2>/dev/null)"

file="$(jq -r '.tool_input.file_path // "?"' <<<"$input" 2>/dev/null)"

if [ -z "$entry" ]; then
  audit_log "collect  skip      $file (no new comments)"
  exit 0
fi

printf '%s\n' "$entry" >> "$QUEUE_DIR/$session.jsonl"
n="$(jq -r '.items | length' <<<"$entry" 2>/dev/null)"
audit_log "collect  queued $n  $file"
audit_say "queued $n comment(s) from $(basename "$file")"
exit 0
