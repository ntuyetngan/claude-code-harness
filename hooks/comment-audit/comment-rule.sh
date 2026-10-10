FILE_TYPES='\.(sh|php|vue|ts|tsx|js|jsx|mjs|cjs)$'

# Translation files: comments there are translator notes, not code rationale — the WHY/WHAT rule doesn't apply.
EXCLUDE_PATHS='(^|/)resources/lang(-frontend)?/'

# `#\s` not bare `#`: PHP attributes (#[Route]) and CSS ids (#app {) are not comments.
COMMENT='^\s*(//|/\*|\*[^/]|#\s|<!--)'

# `x++; // why`: requires a space before the marker and excludes a preceding colon, so `http://` doesn't match.
TRAILING='\S.*[ \t](?<!:)(//|#)[ \t]+\S'

EXEMPT='^\s*(/\*+)?\s*\*?\s*@(param|return|var|throws|deprecated|see|template|extends|implements)\b|^\s*/\*+\s*$'

RULE='A comment may state only WHY: a non-obvious reason, constraint, or workaround. It must never state WHAT the code does, or restate the code in words. Maximum one line: if it needs more, the code should be refactored or the explanation moved to the PR description. Never comment a code-review fix. Type-only docblock tags are exempt.'

QUEUE_DIR="${HOME}/.claude/loop-state/comment-audit"

# Always on while the workflow settles: a silent hook looks like a broken one.
LOG_FILE="$QUEUE_DIR/audit.log"

# QUEUE_DIR sits in shared /tmp, so refuse a pre-existing symlink or a directory we don't own rather than write through it.
audit_safe_queue_dir() {
  if [ -e "$QUEUE_DIR" ] || [ -L "$QUEUE_DIR" ]; then
    # Ownership alone doesn't guarantee mode 0700 on a dir that predates this check — tighten it here and fail closed if we can't.
    [ ! -L "$QUEUE_DIR" ] && [ -d "$QUEUE_DIR" ] && [ -O "$QUEUE_DIR" ] && chmod 0700 "$QUEUE_DIR" 2>/dev/null
  else
    mkdir -m 0700 "$QUEUE_DIR" 2>/dev/null && [ -O "$QUEUE_DIR" ]
  fi
}

audit_log() {
  audit_safe_queue_dir || return 0
  # -f follows a symlink, so a symlink planted here would read as a regular file — reject it before any read/trim/append.
  [ -L "$LOG_FILE" ] && return 0
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null)" -gt 1000000 ] 2>/dev/null; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
  fi
  printf '%s  %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
}

audit_say() {
  jq -n --arg m "comment-audit: $1" '{systemMessage: $m}'
}
