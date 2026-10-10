#!/usr/bin/env bash
# PreToolUse(Bash): the git and gh rules that must hold without exception.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=git-guard
command -v jq >/dev/null 2>&1 || exit 0
loop_enabled || exit 0
read_hook_input
cmd="$(jq -r '.tool_input.command // ""' <<<"$HOOK_INPUT" 2>/dev/null)"
[ -n "$cmd" ] || exit 0
# ghw.sh only routes gh and git push to WSL or Windows; the rules apply to what it carries.
cmd="$(printf '%s' "$cmd" | sed -E 's#(^|[[:space:]])(~|\$HOME|/home/[^/[:space:]]+)/\.claude/hooks/ghw\.sh[[:space:]]+(gh|git)([[:space:]]|$)#\1\3\4#g')"
# A pattern counts only where a command can start: the beginning of the text, or after a separator
# (&& || ; | newline, or an opening subshell). Text inside a heredoc or a quoted string that merely
# mentions a command is not a command; that false positive blocked legitimate work on 2026-09-28.
cmd_positions="$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||;|\||\(|\$\()/\n/g')"
at() { printf '%s' "$cmd_positions" | grep -E "^[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+[A-Za-z_]+=[^[:space:]]+[[:space:]]+|[A-Za-z_]+=[^[:space:]]+[[:space:]]+|timeout[[:space:]]+[0-9]+[a-z]?[[:space:]]+)*($1)"; }
has() { at "$1" >/dev/null; }

at 'git[[:space:]]+stash' | grep -Evq 'git[[:space:]]+stash[[:space:]]+(list|show)([[:space:]]|$)' && block "Blocked: git stash. An interrupted stash chain hid the working tree once. Only 'git stash list' and 'git stash show' are allowed; compare with 'git show HEAD:path' or a worktree instead."
has 'git[[:space:]]+push[^|;&]*(--force|--force-with-lease|--force-if-includes|[[:space:]]-f([[:space:]]|$)|--delete|[[:space:]]-d([[:space:]]|$))' && block "Blocked: force or delete push. Never rewrite or remove a remote branch from an agent session."
has 'git[[:space:]]+push[^|;&]*[[:space:]](master|main)([[:space:]:]|$)' && block "Blocked: push to master. Push a feature branch and open a PR with /handoff."
if has 'git[[:space:]]+push([[:space:]]|$)' && ! printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]][A-Za-z0-9_./-]+[[:space:]]+[A-Za-z0-9_./:-]+'; then
  branch="$(git -C "$HOOK_CWD" branch --show-current 2>/dev/null)"
  case "$branch" in master|main) block "Blocked: 'git push' while on $branch would push to $branch. Create a feature branch first." ;; esac
fi
has 'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]|checkout[[:space:]]+(--[[:space:]]+\.|-f|--force)|switch[[:space:]]+(-f|--force|--discard-changes)|filter-branch|reflog[[:space:]]+expire)' && block "Blocked: destructive git command. Show the user the exact command and let them run it."

# PR body and PR comment. Three texts may leave an agent session: the repo template verbatim on
# create, the /handoff body file after handoff.sh body-check stamped it (template headings, first
# section blank, images present), and the /handoff QA comment after comment-check stamped it.
# Anything else, inline text and --fill included, is blocked, and a PR body is never edited: the
# author writes "What and Why" in the browser and a later edit would overwrite it. Decided by the
# owner on 2026-09-28 as a personal override of pr-description-convention.
stamped() { # file stamp
  [ -f "$2" ] && [ -f "$1" ] && [ "$(cat "$2")" = "$(sha256sum "$1" | cut -d' ' -f1)" ]
}
body_value() { # sub: the --body-file value of "gh pr <sub>", quotes stripped, ~ expanded
  local v
  v="$(printf '%s' "$cmd" | grep -oE "gh[[:space:]]+pr[[:space:]]+$1[^|;&]*(--body-file|-F)[[:space:]=]+[^[:space:]]+" | sed -E 's/.*(--body-file|-F)[[:space:]=]+//' | head -1)"
  v="${v//\"/}"; v="${v//\'/}"; printf '%s' "${v/#\~/$HOME}"
}
repo="$(repo_name "$HOOK_CWD")"; hb="$LOOP_STATE/handoff/$repo.body.md"; hc="$LOOP_STATE/handoff/$repo.qa-comment.md"
if has 'gh[[:space:]]+pr[[:space:]]+create[^|;&]*(--body|--body-file|--fill|[[:space:]]-b([[:space:]]|$)|[[:space:]]-F([[:space:]]|$))'; then
  has 'gh[[:space:]]+pr[[:space:]]+create[^|;&]*(--fill|--body([[:space:]=]|$)|[[:space:]]-b([[:space:]]|$))' && block "Blocked: inline PR body or --fill from an agent. Pass --body-file with the repo template, or the /handoff body file after 'handoff.sh body-check'."
  v="$(body_value create)"
  if [ "$v" != ".github/pull_request_template.md" ] && ! { [ "$v" = "$hb" ] && stamped "$hb" "${hb%.md}.ok"; }; then
    block "Blocked: PR body from an agent. Allowed bodies: --body-file .github/pull_request_template.md, or the file from 'handoff.sh body-path' after 'handoff.sh body-check' stamped it: What and Why blank, other sections filled, images present."
  fi
fi
has 'gh[[:space:]]+pr[[:space:]]+edit[^|;&]*(--body|--body-file|[[:space:]]-b([[:space:]]|$)|[[:space:]]-F([[:space:]]|$))' \
  && ! { [ "$(body_value edit)" = "$hb" ] && stamped "$hb" "${hb%.md}.imgfix.ok"; } && block "Blocked: editing a PR body from an agent. The author's What and Why lives there; later QA screenshots go into a PR comment through /handoff: handoff.sh comment-path, then comment-check."
if has 'gh[[:space:]]+pr[[:space:]]+comment([[:space:]]|$)'; then
  has 'gh[[:space:]]+pr[[:space:]]+comment[^|;&]*(--body([[:space:]=]|$)|[[:space:]]-b([[:space:]]|$)|--edit-last|--web)' && block "Blocked: inline PR comment from an agent. /handoff posts only the QA comment file after 'handoff.sh comment-check'."
  v="$(body_value comment)"
  if ! { [ "$v" = "$hc" ] && stamped "$hc" "${hc%.md}.ok"; }; then
    block "Blocked: PR comment from an agent. The only comment allowed is the file from 'handoff.sh comment-path' after 'handoff.sh comment-check' stamped it, posted by /handoff on the owner's own PR."
  fi
fi

if has 'git[[:space:]]+(commit|push)([[:space:]]|$)'; then
  REPO="$(repo_name "$HOOK_CWD")"; F="$LOOP_STATE/handoff/$REPO"
  armed=0; [ -f "$F" ] && [ $(( $(date +%s) - $(cat "$F" 2>/dev/null || echo 0) )) -lt 1800 ] && armed=1
  [ "$armed" = 1 ] || block "Blocked: git commit and push happen only inside /handoff. Run /handoff when the work is verified and audited; it arms this guard for 30 minutes, commits, pushes, and opens the PR with a title."
fi
exit 0
