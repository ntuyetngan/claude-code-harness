#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit|NotebookEdit): refuse edits in guarded areas and during locked phases.
#
# Areas (zaikoio only): nuxt and schema (database/schema) block; legacy and lang (non-en locale files) only warn.
# Any repo: secrets (.env*, auth.json, *.pem, *.key) are never editable; while the repo phase is "fix"
# (test-first), the regression test files phase.sh recorded are locked, or all of tests/ when it named none.
#
# A guard is lifted for 12 hours by touching ~/.claude/loop-state/allow/<repo>/<area>, which a skill
# does only after the user said yes through AskUserQuestion. Secrets have no lift.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=path-guard
command -v jq >/dev/null 2>&1 || exit 0
loop_enabled || exit 0
read_hook_input
f="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$HOOK_INPUT" 2>/dev/null)"
[ -n "$f" ] || exit 0
case "$f" in /*) abs="$f" ;; *) abs="$HOOK_CWD/$f" ;; esac
# The session's repo first: a nested checkout such as nuxt/ has its own .git and would otherwise hide the guarded path.
ROOT="$(repo_root "$HOOK_CWD")"
case "$abs" in "$ROOT"/*) ;; *) ROOT="$(repo_root "$(dirname "$abs")")" ;; esac
[ -n "$ROOT" ] || exit 0
rel="${abs#"$ROOT"/}"
REPO="$(basename "$ROOT")"
fresh() { [ -f "$1" ] && [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt 43200 ]; }
allowed() { fresh "$LOOP_STATE/allow/$REPO/$1"; }
phase() { fresh "$LOOP_STATE/phase/$REPO" && head -1 "$LOOP_STATE/phase/$REPO" 2>/dev/null; }

case "$rel" in
  .env|.env.*|auth.json|*.pem|*.key|storage/oauth-*.key)
    block "Blocked: $rel holds credentials. The harness never edits secrets. Tell the user what needs to change." ;;
esac

ph="$(phase)"
if [ "$ph" = fix ]; then
  case "$rel" in tests/*)
    locked="$(tail -n +2 "$LOOP_STATE/phase/$REPO" 2>/dev/null)"
    if [ -z "$locked" ] || grep -qxF "$rel" <<<"$locked"; then
      allowed tests || block "Blocked: $rel is locked during the fix phase. The failing regression test was written before the fix; fix the code, not the test. Other test files stay editable. If this test itself is wrong, ask the user; on yes touch $LOOP_STATE/allow/$REPO/tests."
    fi ;;
  esac
fi

if git -C "$ROOT" remote get-url origin 2>/dev/null | grep -q 'zaikoio/zaikoio'; then
  area=""
  case "$rel" in
    legacy/*|legacy_public/*) area=legacy ;;
    nuxt/*) area=nuxt ;;
    database/schema/*) area=schema ;;
    resources/lang/*/*) [ "$(cut -d/ -f3 <<<"$rel")" != en ] && area=lang ;;
    resources/lang-frontend/*/*/*) [ "$(cut -d/ -f4 <<<"$rel")" != en ] && area=lang ;;
  esac
  # legacy and non-en locales are edited on purpose often enough (legacy bugs, translation requests)
  # that they warn instead of block. nuxt and the schema dump still block.
  case "$area" in
    legacy) hook_log "WARN $rel (legacy)"; jq -n --arg m "Reminder: $rel is under legacy/. Keep the diff surgical, follow the existing pattern, no refactors (zaikoio-legacy-guardrails). Say in the summary that legacy was touched." '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'; exit 0 ;;
    lang)   hook_log "WARN $rel (lang)"; jq -n --arg m "Reminder: $rel is a non-en locale file shared with Crowdin. A committed value becomes the approved translation until a translator changes it; never assert on it in tests (translation-source-of-truth)." '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'; exit 0 ;;
  esac
  if [ -n "$area" ] && ! allowed "$area"; then
    case "$area" in
      nuxt)   why="nuxt/ is an adjacent surface the team does not change from this repo without asking." ;;
      schema) why="database/schema/ is the pruned schema dump; migrations change the schema, never this file." ;;
    esac
    block "Blocked: $rel is in the guarded area '$area'. $why Ask the user; if they say yes, run: mkdir -p $LOOP_STATE/allow/$REPO && touch $LOOP_STATE/allow/$REPO/$area (lifts the guard for 12 hours), then retry."
  fi
fi
exit 0
