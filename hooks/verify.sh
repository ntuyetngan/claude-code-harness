#!/usr/bin/env bash
# Maps this session's change to the suites that must run, runs them, and writes one receipt per suite
# keyed by the diff hash. The stop gate and /handoff read the same receipts. The skills start it as a
# background task (the Bash tool caps a foreground call at 10 minutes and pest alone runs longer); a
# running marker under the receipt root tells the stop gate a run is in progress.
#
#   verify.sh            run every mapped suite, print the GREEN/RED table, exit 1 if any RED
#   verify.sh --map      print the mapping as JSON (suites, files, diff sha) and exit; no suite runs
#   verify.sh --pest 'tests/Feature/FooTest.php tests/Unit/BarTest.php'   name the pest files
#   verify.sh --only phpcs,pest                                            run a subset
#   verify.sh --all      take every dirty file, not only this session's
#   verify.sh --fresh    run every suite even when a GREEN receipt with the same inputs exists
#
# Scope: only files that differ from the session-start snapshot count (a file already dirty at
# session start, and unchanged since, is the owner's own work). Files the plan does not name are
# listed as "outside the plan" so nothing lands unnoticed. Lint suites (phpcs, phpstan, type-check)
# go GREEN when no error sits on a line this diff added; errors that were there before are counted
# in the detail. Which pest files run is the model's choice (--pest); the name-based mapping is a
# fallback. Pest runs once, in shards on the parallel test databases, with coverage when crap is
# mapped, and both receipts come from that run. The suite groups (PHP lint, frontend, tests) share
# nothing and run at the same time. A suite whose inputs match an earlier GREEN receipt is reused
# from it, so a small fix after an audit re-runs only what it touched.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=verify
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_ONLY=0; PEST_OVERRIDE=""; ONLY=""; SESSION=""; ALL=0; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --map) MAP_ONLY=1 ;;
    --session) SESSION="$2"; shift ;;
    --pest) PEST_OVERRIDE="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --all) ALL=1 ;;
    --fresh) FRESH=1 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac; shift
done
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "verify: not in a git repo" >&2; exit 64; }
cd "$ROOT" || exit 64
REPO="$(basename "$ROOT")"
Q="$HOME/.claude/config/quality.json"
# The marker goes up before the file hashing below, so a stop in those seconds already sees a run.
RUN_MARK="$LOOP_STATE/verify/$REPO/running"
if [ "$MAP_ONLY" = 0 ]; then mkdir -p "$LOOP_STATE/verify/$REPO"; printf '%s %s %s\n' "$$" pending "$(date +%s)" > "$RUN_MARK"; trap 'rm -f "$RUN_MARK"' EXIT; fi

# --- changed files, session scope, plan, diff hash --------------------------------------------
BASE="$(git merge-base HEAD master 2>/dev/null || git rev-parse HEAD)"
mapfile -t CHANGED < <( { git diff --name-only "$BASE" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | grep -v '^nuxt/' | sort -u )
EXISTING=(); for f in "${CHANGED[@]}"; do [ -f "$f" ] && EXISTING+=("$f"); done
SCOPE=all
# The session is --session, else the one background-guard.sh recorded as starting this run. Another
# session's snapshot is never used: its scope differs from the stop gate's, and so does the diff sha.
[ -z "$SESSION" ] && [ -f "$LOOP_STATE/verify/$REPO/caller-session" ] && SESSION="$(head -1 "$LOOP_STATE/verify/$REPO/caller-session")"
if [ "$ALL" = 0 ]; then
  if [ -n "$SESSION" ] && [ -f "$LOOP_STATE/$SESSION/tree-at-start" ]; then
    SNAP="$LOOP_STATE/$SESSION/tree-at-start"
    S=(); for f in "${EXISTING[@]}"; do
      cur="$(sha1sum "$f" | cut -c1-40)"; old="$(grep -F "  $f" "$SNAP" | head -1 | cut -c1-40)"
      [ "$cur" != "$old" ] && S+=("$f")
    done; EXISTING=("${S[@]}"); SCOPE=session
  else
    echo "verify: no snapshot for session ${SESSION:-(none)}; scope is every dirty file" >&2
  fi
fi
PLAN="$(find_active_plan "$REPO" "$(git branch --show-current 2>/dev/null)")" || PLAN=""
OUTSIDE=()
if [ -n "$PLAN" ]; then
  mapfile -t PLANNED < <(plan_files "$PLAN")
  for f in "${EXISTING[@]}"; do hit=0; for p in "${PLANNED[@]}"; do case "$f" in $p) hit=1; break ;; esac; done; [ $hit = 1 ] || OUTSIDE+=("$f"); done
fi
# Hashed from the files' contents, not from git diff output, so committing the same tree keeps the same
# sha and its receipts; deleted files in scope count by name.
DIFF_SHA="$( { for f in "${EXISTING[@]}"; do printf '%s ' "$f"; sha1sum < "$f" | cut -c1-40; done
               git diff --name-only --diff-filter=D "$BASE" 2>/dev/null | sed 's/^/deleted /'; } | sha1sum | cut -c1-12)"
RDIR="$LOOP_STATE/verify/$REPO/$DIFF_SHA"

# --- mapping -----------------------------------------------------------------------------------
PHP=(); APP_PHP=(); TEST_PHP=(); FE=(); SPECS=(); CFG=()
for f in "${EXISTING[@]}"; do
  case "$f" in
    vendor/*|legacy/*|legacy_public/*|database/schema/*) continue ;;
    *.php) PHP+=("$f"); case "$f" in
              tests/Evals/*) ;;
              tests/*Test.php) TEST_PHP+=("$f") ;;
              app/*) APP_PHP+=("$f") ;;
              config/*) CFG+=("$f") ;;
            esac ;;
    resources/js/*.spec.ts|resources/js/*.spec.js|resources/js/*.test.ts|resources/js/*.test.js) SPECS+=("$f"); FE+=("$f") ;;
    resources/js/*.vue|resources/js/*.ts|resources/js/*.js) FE+=("$f") ;;
  esac
done
# Tests for a changed app class: any test file whose name contains the class basename.
PEST_FILES=()
if [ -n "$PEST_OVERRIDE" ]; then read -r -a PEST_FILES <<<"$PEST_OVERRIDE"
else
  for f in "${APP_PHP[@]}"; do b="$(basename "$f" .php)"; while IFS= read -r t; do PEST_FILES+=("$t"); done < <(find tests -path tests/Evals -prune -o -name "*${b}*Test.php" -print 2>/dev/null); done
  PEST_FILES+=("${TEST_PHP[@]}")
  mapfile -t PEST_FILES < <(printf '%s\n' "${PEST_FILES[@]}" | grep -v '^$' | sort -u)
fi
# Specs for a changed frontend file: the file itself if it is a spec, else a sibling or __tests__ spec with the same basename.
if [ ${#FE[@]} -gt 0 ]; then
  for f in "${FE[@]}"; do b="$(basename "$f")"; b="${b%.*}"; d="$(dirname "$f")"
    while IFS= read -r t; do SPECS+=("$t"); done < <(find "$d" "$d/__tests__" resources/js/tests -maxdepth 6 \( -name "${b}.spec.ts" -o -name "${b}.spec.js" -o -name "${b}.test.ts" \) -print 2>/dev/null)
  done
  mapfile -t SPECS < <(printf '%s\n' "${SPECS[@]}" | grep -v '^$' | sort -u)
fi
SUITES=()
[ ${#PHP[@]} -gt 0 ] && SUITES+=(php-lint phpcs phpstan)
[ ${#APP_PHP[@]} -gt 0 ] || [ ${#TEST_PHP[@]} -gt 0 ] && SUITES+=(pest)
[ ${#APP_PHP[@]} -gt 0 ] && SUITES+=(crap)
[ ${#CFG[@]} -gt 0 ] && SUITES+=(artisan-boot)
[ ${#FE[@]} -gt 0 ] && SUITES+=(vitest type-check)
if [ -n "$ONLY" ]; then IFS=',' read -r -a keep <<<"$ONLY"; F=(); for s in "${SUITES[@]}"; do for k in "${keep[@]}"; do [ "$s" = "$k" ] && F+=("$s"); done; done; SUITES=("${F[@]}"); fi
has_suite() { local s; for s in "${SUITES[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# What each suite reads, hashed, so an unchanged suite can reuse an earlier GREEN receipt.
hash_files() { { for f in "$@"; do [ -f "$f" ] && sha1sum "$f"; done; } | sha1sum | cut -c1-12; }
IN_PHP="$(hash_files "${PHP[@]}")"; IN_TESTS="$(hash_files "${APP_PHP[@]}" "${TEST_PHP[@]}" "${PEST_FILES[@]}")-$(printf '%s\n' "${PEST_FILES[@]}" | sha1sum | cut -c1-6)"
IN_FE="$(hash_files "${FE[@]}" "${SPECS[@]}")"; IN_CFG="$(hash_files "${CFG[@]}")"
inputs_for() { case "$1" in php-lint|phpcs|phpstan) echo "php-$IN_PHP" ;; pest|crap) echo "tests-$IN_TESTS" ;; vitest|type-check) echo "fe-$IN_FE" ;; artisan-boot) echo "cfg-$IN_CFG" ;; esac; }
if [ "$MAP_ONLY" = 1 ]; then
  jq -n --arg sha "$DIFF_SHA" --arg rdir "$RDIR" --arg plan "$PLAN" --arg scope "$SCOPE" \
    --argjson suites "$(printf '%s\n' "${SUITES[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson changed "$(printf '%s\n' "${EXISTING[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson outside "$(printf '%s\n' "${OUTSIDE[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson pest "$(printf '%s\n' "${PEST_FILES[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson specs "$(printf '%s\n' "${SPECS[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson inputs "$(for s in "${SUITES[@]}"; do printf '%s\t%s\n' "$s" "$(inputs_for "$s")"; done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add // {}')" \
    --arg session "$SESSION" \
    '{diff_sha:$sha, receipts:$rdir, scope:$scope, session:$session, plan:$plan, suites:$suites, changed:$changed, outside_plan:$outside, pest_files:$pest, specs:$specs, inputs:$inputs}'
  exit 0
fi

# --- runners -----------------------------------------------------------------------------------
mkdir -p "$RDIR"; rm -f "$RDIR"/row-*
printf '%s %s %s\n' "$$" "$DIFF_SHA" "$(date +%s)" > "$RUN_MARK"
python3 "$HERE/added-lines.py" "$ROOT" "$BASE" "${EXISTING[@]}" > "$RDIR/added-lines.json" 2>/dev/null || echo '{}' > "$RDIR/added-lines.json"
if ls -d node_modules/@esbuild/win32-* >/dev/null 2>&1 && [ -x "$WIN_NODE_DIR/node.exe" ]; then
  NODE=("$WIN_NODE_DIR/node.exe"); NODE_HOW="Windows node (node_modules is Windows-built)"
  export WSLENV="${WSLENV:+$WSLENV:}NODE_OPTIONS"
else
  set +u; export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; nvm use 24 >/dev/null 2>&1; set -u
  NODE=(node); NODE_HOW="WSL node $(node -v 2>/dev/null)"
fi
SHARDS="$(jq -r '.pest.shards // 4' "$Q" 2>/dev/null)"; SHARD_TMO="$(jq -r '.pest.shard_timeout_seconds // 1800' "$Q" 2>/dev/null)"
reuse_receipt() { # name: copy the newest GREEN receipt of another diff whose inputs match; 0 when reused
  local name="$1" want r from
  [ "$FRESH" = 1 ] && return 1
  want="$(inputs_for "$name")"
  for r in $(ls -t "$LOOP_STATE/verify/$REPO"/*/"$name.json" 2>/dev/null | head -40); do
    [ "$(dirname "$r")" = "$RDIR" ] && continue
    if [ "$(jq -r '.status' "$r" 2>/dev/null)" = GREEN ] && [ "$(jq -r '.inputs // ""' "$r" 2>/dev/null)" = "$want" ]; then
      from="$(basename "$(dirname "$r")")"
      jq --arg sha "$DIFF_SHA" --arg from "$from" --arg ts "$(date +%s)" '.diff_sha=$sha | .reused_from=$from | .ts=($ts|tonumber) | .detail=("reused from diff \($from), inputs unchanged; " + (.detail | sub("^(reused from diff [0-9a-f]+, inputs unchanged; )+"; "")))' "$r" > "$RDIR/$name.json"
      printf 'GREEN|%s|%s|0s\n' "$name" "$(jq -r '.detail' "$RDIR/$name.json" | cut -c1-160)" > "$RDIR/row-$name"
      printf '↻ %s  reused from diff %s (inputs unchanged)\n' "$name" "$from"; hook_log "GREEN $name reused from $from"
      return 0
    fi
  done
  return 1
}
finish_suite() { # name rc timeout start end log cmd
  local name="$1" rc="$2" tmo="$3" start="$4" end="$5" log="$6" cmd="$7" status detail tests="" lint lrc
  sed -i 's/\x1b\[[0-9;]*m//g' "$log" 2>/dev/null
  case "$name" in
    pest) tests="$(grep -Eo 'Tests:[[:space:]]+[0-9]+ (passed|failed)[^$]*' "$log" | tail -1 | cut -c1-80)"; grep -q 'No tests found\|no tests executed' "$log" && rc=99 ;;
    vitest) tests="$(grep -Eo 'Tests[[:space:]]+[0-9]+ (passed|failed)' "$log" | tail -1)"; grep -q 'No test files found' "$log" && rc=99 ;;
    phpcs|phpstan|type-check)
      # An error on a line this diff did not add was there before the change.
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
        lint="$(python3 "$HERE/lint-filter.py" "$name" "$log" "$RDIR/added-lines.json" "$ROOT" 2>/dev/null)"; lrc=$?
        if [ $lrc -eq 0 ] && [ -n "$lint" ]; then rc=0; tests="$lint; pre-existing errors are not this change's"; else tests="$lint"; fi
      fi ;;
  esac
  if [ "$rc" -eq 0 ]; then status=GREEN; detail="${tests:-ok}"; [ "$name" = crap ] && detail="$(grep -E '^CRAP threshold' "$log" | head -1 | cut -c1-160)"
  elif [ "$rc" -eq 124 ]; then status=RED; detail="timed out after ${tmo}s"
  elif [ "$rc" -eq 99 ]; then status=RED; detail="ran zero tests (bad filter or path)"
  elif [ "$rc" -eq 3 ]; then status=RED; detail="$(head -1 "$log" | cut -c1-200)"
  else
    status=RED
    case "$name" in
      phpcs|phpstan|type-check) detail="${tests:-$(grep -Ev '^\s*$' "$log" | head -1 | cut -c1-160)}" ;;
      pest)    detail="${tests:-failed}; $(grep -E '^\s*(FAILED|✗|⨯)' "$log" | head -2 | sed 's/^\s*//' | tr '\n' ' ' | cut -c1-160)" ;;
      vitest)  detail="${tests:-failed}; $(grep -E '(FAIL|✗|×|AssertionError|Error:)' "$log" | head -2 | sed 's/^\s*//' | tr '\n' ' ' | cut -c1-160)" ;;
      crap)    detail="$(grep -E '^CRAP threshold' "$log" | head -1 | cut -c1-120); $(grep -E '^\s+RED' "$log" | head -1 | sed 's/^\s*//' | cut -c1-120)" ;;
      *)       detail="exit $rc: $(grep -Ev '^\s*$' "$log" | grep -iE 'error|fail' | head -2 | tr '\n' ' ' | cut -c1-160)" ;;
    esac
  fi
  jq -n --arg n "$name" --arg s "$status" --arg d "$detail" --arg c "$cmd" --arg sha "$DIFF_SHA" --arg in "$(inputs_for "$name")" --argjson e $((end-start)) --arg ts "$(date +%s)" \
    '{suite:$n,status:$s,detail:$d,command:$c,diff_sha:$sha,inputs:$in,elapsed_s:$e,ts:($ts|tonumber)}' > "$RDIR/$name.json"
  printf '%s|%s|%s|%ss\n' "$status" "$name" "$detail" "$((end-start))" > "$RDIR/row-$name"
  printf '%s %s %ss  %s\n' "$([ "$status" = GREEN ] && echo ✔ || echo ✖)" "$name" "$((end-start))" "$detail" | cut -c1-200
  hook_log "$status $name ${detail}"
}
run_suite() { # name timeout cmd...
  local name="$1" tmo="$2"; shift 2; local log="$RDIR/$name.log" start end rc
  reuse_receipt "$name" && return 0
  printf '▶ %s started (%s)\n' "$name" "$*" | cut -c1-160
  start=$(date +%s); timeout "$tmo" "$@" > "$log" 2>&1; rc=$?; end=$(date +%s)
  finish_suite "$name" "$rc" "$tmo" "$start" "$end" "$log" "$*"
}
skip_suite() { printf 'RED|%s|%s|0s\n' "$1" "$2" > "$RDIR/row-$1"; jq -n --arg n "$1" --arg d "$2" --arg sha "$DIFF_SHA" --arg ts "$(date +%s)" '{suite:$n,status:"RED",detail:$d,diff_sha:$sha,elapsed_s:0,ts:($ts|tonumber)}' > "$RDIR/$1.json"; printf '✖ %s  %s\n' "$1" "$2"; hook_log "RED $1 $2"; }
run_tests() { # pest, with coverage and CRAP when crap is mapped: one sharded run, two receipts
  local start end rc prc
  if [ ${#PEST_FILES[@]} -eq 0 ]; then
    has_suite pest && skip_suite pest "no tests named: read the callers of ${APP_PHP[*]} and pass the tests that exercise them with --pest 'paths' (the name fallback found none)"
    has_suite crap && skip_suite crap "no pest files mapped, so no coverage to score"; return
  fi
  if has_suite crap && php -m | grep -qiE '^(pcov|xdebug)$'; then
    if reuse_receipt pest && reuse_receipt crap; then return; fi
    printf '▶ pest+crap started (%d shard(s) with coverage on %s)\n' "$SHARDS" "${PEST_FILES[*]}" | cut -c1-200
    # Same diff, same receipt dir: an earlier run's outputs must not be mistaken for this one's.
    rm -f "$RDIR/coverage/pest.log" "$RDIR/coverage/pest.rc" "$RDIR/coverage/clover.xml" "$RDIR/coverage/crap4j.xml" "$RDIR"/coverage/shard-*
    start=$(date +%s); timeout 2400 "$HERE/crap-suite.sh" "$RDIR" "$BASE" "$DIFF_SHA" -- "${APP_PHP[@]}" -- "${PEST_FILES[@]}" > "$RDIR/crap.log" 2>&1; rc=$?; end=$(date +%s)
    if [ -f "$RDIR/coverage/pest.log" ]; then
      prc="$(cat "$RDIR/coverage/pest.rc" 2>/dev/null || echo 1)"; [ $rc -eq 124 ] && prc=124
      finish_suite pest "$prc" 2400 "$start" "$end" "$RDIR/coverage/pest.log" "pest-run.sh $SHARDS shards --coverage ${PEST_FILES[*]}"
    else finish_suite pest 1 2400 "$start" "$end" "$RDIR/crap.log" "pest via crap-suite.sh"; fi
    finish_suite crap "$rc" 2400 "$start" "$end" "$RDIR/crap.log" "crap-suite.sh ${APP_PHP[*]} -- ${PEST_FILES[*]}"
  else
    has_suite pest && { reuse_receipt pest || { printf '▶ pest started (%d shard(s) on %s)\n' "$SHARDS" "${PEST_FILES[*]}" | cut -c1-200
      start=$(date +%s); "$HERE/pest-run.sh" "$RDIR/pest-shards" "$SHARDS" "$SHARD_TMO" "${PEST_FILES[@]}" > "$RDIR/pest-run.log" 2>&1; rc=$?; end=$(date +%s)
      finish_suite pest "$rc" "$SHARD_TMO" "$start" "$end" "$RDIR/pest-shards/pest.log" "pest-run.sh $SHARDS shards ${PEST_FILES[*]}"; }; }
    has_suite crap && skip_suite crap "PCOV not loaded; see the preflight remedy"
  fi
}
run_php_lint() {
  has_suite php-lint && { ok=1; for f in "${PHP[@]}"; do php -l "$f" >/dev/null 2>&1 || ok=0; done; [ $ok = 1 ] && run_suite php-lint 60 true || run_suite php-lint 60 sh -c 'for f in "$@"; do php -l "$f" || exit 1; done' _ "${PHP[@]}"; }
  has_suite phpcs && { [ -x vendor/bin/phpcs ] && run_suite phpcs 300 vendor/bin/phpcs --report=emacs "${PHP[@]}" || skip_suite phpcs "vendor/bin/phpcs missing"; }
  has_suite phpstan && { [ -x vendor/bin/phpstan ] && run_suite phpstan 1200 vendor/bin/phpstan analyse --no-progress --memory-limit=2G --error-format=raw "${PHP[@]}" || skip_suite phpstan "vendor/bin/phpstan missing"; }
  has_suite artisan-boot && run_suite artisan-boot 120 php artisan --env=testing --version
}
run_frontend() {
  has_suite vitest && { if [ ${#SPECS[@]} -gt 0 ]; then
    # The JSON report goes under node_modules first: Windows node cannot write to the WSL home.
    rm -f node_modules/.cache/verify-vitest.json
    NODE_OPTIONS=--no-experimental-webstorage run_suite vitest 900 "${NODE[@]}" node_modules/vitest/vitest.mjs run --reporter=default --reporter=json --outputFile.json=node_modules/.cache/verify-vitest.json "${SPECS[@]}"
    if [ -f node_modules/.cache/verify-vitest.json ]; then
      mv node_modules/.cache/verify-vitest.json "$RDIR/vitest-results.json"
      jq -r '.testResults[] | "  \(if .status == "passed" then "✔" else "✖" end) \(.name | gsub("\\\\"; "/") | sub("^.*?/resources/"; "resources/")) — \([.assertionResults[] | select(.status == "passed")] | length)/\(.assertionResults | length) passed"' "$RDIR/vitest-results.json" 2>/dev/null
    fi
  else skip_suite vitest "no spec maps to the changed frontend files (${FE[*]}); add one next to the file or under __tests__"; fi; }
  has_suite type-check && run_suite type-check 900 "${NODE[@]}" node_modules/vue-tsc/bin/vue-tsc.js --noEmit -p tsconfig.json --composite false
}

echo "verify: ${#EXISTING[@]} changed files (scope: $SCOPE${SESSION:+, session $SESSION}), diff $DIFF_SHA, suites: ${SUITES[*]:-none}"
[ ${#OUTSIDE[@]} -gt 0 ] && echo "outside the plan ($PLAN): ${OUTSIDE[*]}"
# The three groups share nothing (lint reads files, the frontend tools read node_modules, the tests
# own their databases), so they run at once; the tests are the long pole.
T0=$(date +%s)
run_tests & P_TESTS=$!
run_php_lint & P_PHP=$!
run_frontend & P_FE=$!
wait $P_TESTS $P_PHP $P_FE
ROWS=(); ANY_RED=0
for s in "${SUITES[@]}"; do
  [ -f "$RDIR/row-$s" ] || { skip_suite "$s" "no result recorded"; }
  ROWS+=("$(cat "$RDIR/row-$s")"); grep -q '^RED|' "$RDIR/row-$s" && ANY_RED=1
done
echo; echo "Verify for $REPO — diff $DIFF_SHA — scope $SCOPE — $(( $(date +%s) - T0 ))s wall — node: $NODE_HOW"
echo "| Status | Suite | Detail | Time |"; echo "| --- | --- | --- | --- |"
for r in "${ROWS[@]}"; do IFS='|' read -r st n d t <<<"$r"; echo "| $st | $n | $d | $t |"; done
[ ${#SUITES[@]} -eq 0 ] && echo "| GREEN | none | no suite maps to these files: ${EXISTING[*]:-(no changes)} | 0s |"
[ ${#OUTSIDE[@]} -gt 0 ] && echo "Outside the plan: ${OUTSIDE[*]} (add them to the plan, or leave them out of the commit)"
if [ "$ANY_RED" = 1 ]; then echo; echo "Could not verify: the RED rows above. Logs in $RDIR/. Do not describe RED work as verified."; exit 1; fi
echo "Receipts in $RDIR/"
exit 0
