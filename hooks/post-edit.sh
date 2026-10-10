#!/usr/bin/env bash
# PostToolUse(Edit|Write|MultiEdit): fix mixed line endings, format PHP, and report phpcs violations
# on the edited file only. Must stay fast: it runs on every edit.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=post-edit
command -v jq >/dev/null 2>&1 || exit 0
loop_enabled || exit 0
read_hook_input
f="$(jq -r '.tool_input.file_path // empty' <<<"$HOOK_INPUT" 2>/dev/null)"
[ -n "$f" ] && [ -f "$f" ] || exit 0
ROOT="$(repo_root "$(dirname "$f")")"; [ -n "$ROOT" ] || exit 0
notes=()

# Mixed endings (some CRLF, some LF) break phpcs and produce noisy diffs. A uniformly CRLF file is a
# Windows-edited file that git normalizes on its own, so it is left alone.
case "$f" in *.php|*.vue|*.ts|*.js|*.mjs|*.json|*.md|*.sh|*.yml|*.yaml|*.blade.php)
  crlf=$(grep -c $'\r$' "$f" 2>/dev/null || echo 0); total=$(wc -l < "$f" 2>/dev/null || echo 0)
  if [ "$crlf" -gt 0 ] && [ "$crlf" -lt "$total" ]; then sed -i 's/\r$//' "$f" && notes+=("normalized $crlf mixed CRLF line endings to LF in $f"); fi ;;
esac

case "$f" in *.php)
  if [ -x "$ROOT/vendor/bin/phpcbf" ]; then (cd "$ROOT" && timeout 60 vendor/bin/phpcbf -q "$f" >/dev/null 2>&1); fi
  # Only errors on lines this edit adds against HEAD are new; a whole-file count made every edit of a
  # legacy file look like dozens of fresh violations.
  if [ -x "$ROOT/vendor/bin/phpcs" ]; then
    rel="${f#$ROOT/}"; tmp="$(mktemp -d)"
    (cd "$ROOT" && timeout 60 vendor/bin/phpcs --report=emacs --no-colors "$rel" > "$tmp/phpcs.log" 2>/dev/null)
    python3 "$(dirname "${BASH_SOURCE[0]}")/added-lines.py" "$ROOT" HEAD "$rel" > "$tmp/added.json" 2>/dev/null || echo '{}' > "$tmp/added.json"
    out="$(python3 "$(dirname "${BASH_SOURCE[0]}")/lint-filter.py" phpcs "$tmp/phpcs.log" "$tmp/added.json" "$ROOT" 2>/dev/null)"; lrc=$?
    rm -rf "$tmp"
    [ $lrc -ne 0 ] && notes+=("phpcs on $rel after phpcbf: $out. Fix the new ones before verifying; the pre-existing count is the file's own.")
  fi ;;
esac

# Docs rot: line numbers, ticket ids, test counts and bug narrative go stale; the user strips them every time.
case "$f" in "$ROOT"/docs/*.md)
  # Only what a regex can know: line numbers, ticket ids, test counts. Whether prose is a bug narrative is judgment, left to the model and its CLAUDE.md rule.
  rot="$(grep -nE '\.(php|vue|ts|js):[0-9]+|\bZAI-[0-9]+\b|#[0-9]{4,}\b|\b[0-9]+ tests? (pass|passing|passed)\b' "$f" | head -4 | cut -c1-120 | tr '\n' ';')"
  [ -n "$rot" ] && notes+=("docs rot in $f (line numbers, ticket ids or test counts go stale): $rot. Keep the rationale, drop the reference.") ;;
esac

# Queue any new code comments for the Stop-time comment judge (repo's comment-audit, global copy).
printf '%s' "$HOOK_INPUT" | "$(dirname "${BASH_SOURCE[0]}")/comment-audit/comment-collect.sh" >/dev/null 2>&1 || true

if [ ${#notes[@]} -gt 0 ]; then
  msg="$(printf '%s\n' "${notes[@]}")"; hook_log "$msg"
  jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
fi
exit 0
