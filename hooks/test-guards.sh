#!/usr/bin/env bash
# Feeds representative tool inputs to git-guard.sh and background-guard.sh and prints allow/BLOCK per case.
# The command strings below are test data; nothing here is executed as a git command.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
CWD="${1:-$PWD}"
git -C "$CWD" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "usage: test-guards.sh <path to a git repo>; $CWD is not one, and the armed cases would fail" >&2; exit 64; }
J() { jq -cn --arg c "$1" --arg cwd "$CWD" --arg s "${2:-testsess}" --argjson bg "${3:-false}" \
  '{session_id:$s,cwd:$cwd,tool_name:"Bash",tool_input:{command:$c,run_in_background:$bg}}'; }
t() { # hook expected desc json
  local out rc; out=$(printf '%s' "$4" | "./$1" 2>&1); rc=$?
  local got; [ $rc -eq 2 ] && got=BLOCK || got=allow
  local mark; [ "$got" = "$2" ] && mark=ok || { mark=FAIL; FAILS=$((FAILS+1)); }
  printf '%-4s %-5s %s\n' "$mark" "$got" "$3"
  [ "$mark" = FAIL ] && printf '       %s\n' "${out:0:120}"
}
FAILS=0
echo "=== git-guard ==="
t git-guard.sh BLOCK "stash" "$(J 'git stash')"
t git-guard.sh allow "stash list" "$(J 'git stash list')"
t git-guard.sh allow "stash show -p" "$(J 'git stash show -p stash@{0}')"
t git-guard.sh BLOCK "stash pop" "$(J 'git stash pop')"
t git-guard.sh BLOCK "stash push" "$(J 'git stash push -m x')"
t git-guard.sh BLOCK "stash list then stash" "$(J 'git stash list && git stash')"
t git-guard.sh BLOCK "stash listx is not list" "$(J 'git stash listx')"
t git-guard.sh BLOCK "force-with-lease" "$(J 'git push --force-with-lease origin feat')"
t git-guard.sh BLOCK "push -f" "$(J 'git push -f origin feat')"
t git-guard.sh BLOCK "push to master" "$(J 'git push origin master')"
t git-guard.sh BLOCK "bare push while on master" "$(J 'git push')"
REPO="$(basename "$CWD")"; HF="$HOME/.claude/loop-state/handoff/$REPO"; rm -f "$HF"
t git-guard.sh BLOCK "push feature branch without handoff" "$(J 'git push -u origin feat/x')"
t git-guard.sh BLOCK "commit without handoff" "$(J 'git commit -m "x"')"
mkdir -p "$(dirname "$HF")" && date +%s > "$HF"
t git-guard.sh allow "commit while armed" "$(J 'git commit -m "x"')"
t git-guard.sh allow "push feature branch while armed" "$(J 'git push -u origin feat/x')"
t git-guard.sh BLOCK "push to master while armed" "$(J 'git push origin master')"
echo $(( $(date +%s) - 1900 )) > "$HF"
t git-guard.sh BLOCK "commit with expired arm" "$(J 'git commit -m "x"')"
rm -f "$HF"
t git-guard.sh BLOCK "reset --hard" "$(J 'git reset --hard HEAD~1')"
t git-guard.sh BLOCK "checkout -- ." "$(J 'git checkout -- .')"
t git-guard.sh BLOCK "pr create with body" "$(J 'gh pr create --title "[ZAI-1][X] y" --body "text"')"
t git-guard.sh BLOCK "pr create --fill" "$(J 'gh pr create --fill')"
t git-guard.sh allow "pr create title only" "$(J 'gh pr create --title "[ZAI-1][X] y"')"
t git-guard.sh allow "pr create with the repo template as body" "$(J 'gh pr create --title "[ZAI-1][X] y" --body-file .github/pull_request_template.md')"
t git-guard.sh BLOCK "pr create with another body file" "$(J 'gh pr create --title "[ZAI-1][X] y" --body-file draft.md')"
t git-guard.sh BLOCK "pr edit --body-file" "$(J 'gh pr edit 1 --body-file d.md')"
# The /handoff body: allowed only as the exact file from handoff.sh body-path, after body-check stamped it.
if [ -f "$CWD/.github/pull_request_template.md" ]; then
  BODY="$(cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" body-path)"
  IMG="$HOME/.claude/loop-state/handoff/test-evidence.png"; printf '\x89PNG\r\n' > "$IMG"
  { echo "## What and Why"; echo; echo "## Tasks (Linear/Sentry)"; echo "- ZAI-1"; echo "## Test Plan"; echo "- pest GREEN"; echo "## Screenshots"; echo "![home]($IMG)"; } > "$BODY"
  if (cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" body-check >/dev/null 2>&1); then
    t git-guard.sh allow "pr create with the stamped handoff body and --attach" "$(J "gh pr create --title \"[ZAI-1][X] y\" --base master --body-file $BODY --attach $IMG")"
    t git-guard.sh BLOCK "pr edit even with the stamped handoff body" "$(J "gh pr edit 12 --body-file $BODY --attach $IMG")"
    t git-guard.sh BLOCK "stamped body plus --fill" "$(J "gh pr create --title x --body-file $BODY --fill")"
    t git-guard.sh allow "ghw.sh gh pr create with the stamped body" "$(J "~/.claude/hooks/ghw.sh gh pr create --title x --body-file $BODY")"
    t git-guard.sh allow "timeout ghw.sh gh pr create with the stamped body" "$(J "timeout 300 ~/.claude/hooks/ghw.sh gh pr create --title x --body-file $BODY")"
    echo "- edited after the check" >> "$BODY"
    t git-guard.sh BLOCK "handoff body edited after the stamp" "$(J "gh pr create --title x --body-file $BODY")"
    # image-fix: an open PR's live body minus its local image lines may go back through gh pr edit, and nowhere else.
    LIVE="$HOME/.claude/loop-state/handoff/test-live-body.md"
    { echo "## What and Why"; echo "the author's own words"; echo "## Tasks (Linear/Sentry)"; echo "- ZAI-1"; echo "## Test Plan"; echo "- pest GREEN"; echo "## Screenshots"; echo "![home]($IMG)"; echo "![home](https://github.com/user-attachments/assets/x)"; } > "$LIVE"
    if (cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" image-fix "$LIVE" >/dev/null 2>&1) && ! grep -q "$IMG" "$BODY" && grep -q "the author's own words" "$BODY"; then
      t git-guard.sh allow "pr edit with the image-fix body" "$(J "~/.claude/hooks/ghw.sh gh pr edit 12 --body-file $BODY")"
      t git-guard.sh BLOCK "pr create with the image-fix body" "$(J "gh pr create --title x --body-file $BODY")"
      echo "- edited" >> "$BODY"
      t git-guard.sh BLOCK "image-fix body edited after the stamp" "$(J "gh pr edit 12 --body-file $BODY")"
    else echo "FAIL  image-fix did not strip only the local image lines"; FAILS=$((FAILS+1)); fi
    rm -f "$LIVE" "${BODY%.md}.imgfix.ok"
  else
    echo "FAIL  body-check did not accept a valid body"; FAILS=$((FAILS+1))
  fi
  { echo "## What and Why"; echo "written by the agent"; echo "## Tasks (Linear/Sentry)"; echo "- ZAI-1"; echo "## Test Plan"; echo "- x"; echo "## Screenshots"; echo "none"; } > "$BODY"
  if (cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" body-check >/dev/null 2>&1); then echo "FAIL  body-check accepted a filled What and Why"; FAILS=$((FAILS+1)); else echo "ok   BLOCK body-check refuses a filled What and Why"; fi
  CMT="$(cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" comment-path)"
  { echo "## QA 2026-09-28 abc1234"; echo "- Home page loads: PASS"; echo "![home]($IMG)"; } > "$CMT"
  t git-guard.sh BLOCK "pr comment with an unchecked comment file" "$(J "gh pr comment 12 --body-file $CMT --attach $IMG")"
  if (cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" comment-check >/dev/null 2>&1); then
    t git-guard.sh allow "pr comment with the stamped QA comment" "$(J "~/.claude/hooks/ghw.sh gh pr comment 12 --body-file $CMT --attach $IMG")"
    echo "- edited" >> "$CMT"
    t git-guard.sh BLOCK "QA comment edited after the stamp" "$(J "gh pr comment 12 --body-file $CMT")"
  else echo "FAIL  comment-check did not accept a valid comment"; FAILS=$((FAILS+1)); fi
  { echo "not a heading"; echo "![home]($IMG)"; } > "$CMT"
  if (cd "$CWD" && "$HOME/.claude/hooks/handoff.sh" comment-check >/dev/null 2>&1); then echo "FAIL  comment-check accepted a comment without the QA heading"; FAILS=$((FAILS+1)); else echo "ok   BLOCK comment-check refuses a comment without the QA heading"; fi
  t git-guard.sh BLOCK "pr comment inline body" "$(J 'gh pr comment 12 --body "looks good"')"
  t git-guard.sh BLOCK "pr comment with another file" "$(J 'gh pr comment 12 --body-file notes.md')"
  rm -f "$BODY" "${BODY%.md}.ok" "$CMT" "${CMT%.md}.ok" "$IMG"
fi
t git-guard.sh BLOCK "ghw.sh git push to master" "$(J '~/.claude/hooks/ghw.sh git push origin master')"
t git-guard.sh BLOCK "ghw.sh git push without handoff" "$(J '~/.claude/hooks/ghw.sh git push -u origin feat/x')"
date +%s > "$HF"
t git-guard.sh allow "ghw.sh git push while armed" "$(J '~/.claude/hooks/ghw.sh git push -u origin feat/x')"
rm -f "$HF"
t git-guard.sh allow "pr edit --title" "$(J 'gh pr edit 1 --title "new"')"
t git-guard.sh allow "status and diff" "$(J 'git status && git diff --stat')"
t git-guard.sh BLOCK "chained status then stash" "$(J 'git status; git stash')"
t git-guard.sh allow "log" "$(J 'git log --oneline -5')"
t git-guard.sh allow "mention inside a heredoc string" "$(J 'python3 - <<EOF
print("the guard blocks git stash and gh pr create --body")
EOF')"
t git-guard.sh allow "mention inside an echo" "$(J 'echo "never run git push --force"')"
t git-guard.sh BLOCK "real command after a heredoc" "$(J 'cat <<EOF
notes
EOF
git stash')"
t git-guard.sh BLOCK "with timeout prefix" "$(J 'timeout 30 git stash')"
t git-guard.sh BLOCK "with env assignment prefix" "$(J 'GIT_DIR=.git git stash')"
echo "=== background-guard ==="
t background-guard.sh BLOCK "phpstan background" "$(J 'vendor/bin/phpstan analyse app' testsess true)"
t background-guard.sh allow "phpstan foreground" "$(J 'vendor/bin/phpstan analyse app' testsess false)"
t background-guard.sh BLOCK "git diff background" "$(J 'git diff --stat' testsess true)"
t background-guard.sh BLOCK "artisan test background" "$(J 'php artisan test --filter=Foo' testsess true)"
t background-guard.sh BLOCK "type-check background" "$(J 'npm run type-check' testsess true)"
t background-guard.sh allow "sleep background" "$(J 'sleep 30' testsess true)"
t background-guard.sh allow "verify.sh background" "$(J "cd $CWD && ~/.claude/hooks/verify.sh --pest 'tests/Unit/FooTest.php'" testsess true)"
t background-guard.sh allow "mutation.sh background" "$(J '~/.claude/hooks/mutation.sh' testsess true)"
t background-guard.sh BLOCK "pest background outside the script" "$(J 'vendor/bin/pest tests/Unit/FooTest.php' testsess true)"
t background-guard.sh BLOCK "git commit background" "$(J 'git commit -m x' testsess true)"
t background-guard.sh allow "word containing git" "$(J 'ls widgit' testsess true)"
echo "failures: $FAILS"
exit $FAILS
