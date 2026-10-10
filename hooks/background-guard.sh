#!/usr/bin/env bash
# PreToolUse(Bash): git never runs in the background (a backgrounded git held .git/index.lock once),
# and the test and lint tools run in the background only through the harness scripts, which write
# receipts and a running marker; a raw backgrounded phpstan or pest was left dangling before.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=background-guard
command -v jq >/dev/null 2>&1 || exit 0
read_hook_input
cmd="$(jq -r '.tool_input.command // ""' <<<"$HOOK_INPUT" 2>/dev/null)"
# A harness script started from the Bash tool gets no session id; the session that starts one is
# recorded per repo so verify.sh scopes to that session's snapshot, the same one the stop gate uses.
if printf '%s' "$cmd" | grep -Eq '\.claude/hooks/(verify|mutation|devsync)\.sh|\.claude/hooks/report\.py' && [ "$HOOK_SESSION" != unknown ]; then
  root="$(repo_root "$HOOK_CWD")"
  [ -n "$root" ] && mkdir -p "$LOOP_STATE/verify/$(basename "$root")" && printf '%s\n' "$HOOK_SESSION" > "$LOOP_STATE/verify/$(basename "$root")/caller-session"
fi
loop_enabled || exit 0
bg="$(jq -r '.tool_input.run_in_background // false' <<<"$HOOK_INPUT" 2>/dev/null)"
[ "$bg" = "true" ] || exit 0
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)'; then
  block "Blocked: git never runs in the background. Run it in the foreground."
fi
printf '%s' "$cmd" | grep -Eq '\.claude/hooks/(verify|mutation|crap-suite|devsync)\.sh' && exit 0
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_.-])(phpstan|phpcs|phpcbf|pest|vitest|vue-tsc)([^[:alnum:]_-]|$)|artisan[[:space:]]+test|npm[[:space:]]+run[[:space:]]+(test|type-check)'; then
  block "Blocked: test and lint tools run in the background only through ~/.claude/hooks/verify.sh or mutation.sh, which write receipts and a running marker. Use /verify."
fi
exit 0
