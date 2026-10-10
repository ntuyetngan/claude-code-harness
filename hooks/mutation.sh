#!/usr/bin/env bash
# Mutation testing on the classes this diff changed, with Pest's built-in --mutate. Writes a receipt
# next to the verify receipts so /handoff can gate on it.
#   mutation.sh                 changed app classes vs merge-base with master, threshold from ~/.claude/config/quality.json
#   mutation.sh --pest 'paths'  name the test files yourself when the mapping misses
# Only the mapped test files run, and coverage is narrowed to the changed files through a generated
# PHPUnit config, so neither the full suite nor a full-app coverage pass ever starts. Pest has no
# line filter on its command line, so mutate-lines.php (prepended to the pest process) replaces its
# mutation generator with one that only mutates the lines this diff added; if that override does not
# load, the class is mutated whole and the receipt says so. When the budget runs out before every
# mutant ran, the receipt is PARTIAL (not verified) unless a survivor sits on a line this diff added,
# which makes it RED. Each survivor is marked added or pre-existing. Pest caches mutant results, so a
# later run continues where this one stopped.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=mutation
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HOME/.claude/config/quality.json"
PEST_OVERRIDE=""; while [ $# -gt 0 ]; do case "$1" in --pest) PEST_OVERRIDE="$2"; shift ;; esac; shift; done
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "mutation: not in a git repo" >&2; exit 64; }
cd "$ROOT" || exit 64
REPO="$(basename "$ROOT")"
MAP="$("$HERE/verify.sh" --map 2>/dev/null)"; sha="$(jq -r '.diff_sha' <<<"$MAP")"; RDIR="$(jq -r '.receipts' <<<"$MAP")"
mkdir -p "$RDIR/mutation" "$LOOP_STATE/quality"
min="$(jq -r '.mutation.min_msi // 60' "$Q" 2>/dev/null)"; tmo="$(jq -r '.mutation.timeout_seconds // 2400' "$Q" 2>/dev/null)"
enabled="$(jq -r '.mutation.enabled // true' "$Q" 2>/dev/null)"
RUN_MARK="$LOOP_STATE/verify/$REPO/running"; scope=""
receipt() { jq -n --arg s "$1" --arg d "$2${scope:+ [scope: $scope]}" --arg sha "$sha" --arg ts "$(date +%s)" --argjson e "${3:-0}" '{suite:"mutation",status:$s,detail:$d,diff_sha:$sha,elapsed_s:$e,ts:($ts|tonumber)}' > "$RDIR/mutation.json"; hook_log "$1 mutation $2"; }

[ "$enabled" = true ] || { receipt SKIP "mutation disabled in quality.json"; echo "mutation: disabled in $Q"; exit 0; }
php -m | grep -qiE '^(pcov|xdebug)$' || { receipt RED "no coverage driver (PCOV) loaded; see preflight remedy"; echo "✖ mutation: PCOV not loaded"; exit 1; }
BASE="$(git merge-base HEAD master 2>/dev/null || git rev-parse HEAD)"
mapfile -t changed_php < <(jq -r '.changed[] | select(startswith("app/") and endswith(".php"))' <<<"$MAP")
[ ${#changed_php[@]} -gt 0 ] || { receipt SKIP "no app/ PHP files changed"; echo "mutation: nothing to mutate"; exit 0; }
# PSR-4: app/Http/Middleware/SetUser.php -> App\Http\Middleware\SetUser. Files without a class are skipped.
classes=(); for f in "${changed_php[@]}"; do grep -qE '^(final |abstract |readonly )*(class|enum|trait) ' "$f" && classes+=("App\\$(echo "${f#app/}" | sed 's|\.php$||; s|/|\\|g')"); done
[ ${#classes[@]} -gt 0 ] || { receipt SKIP "changed app files hold no class to mutate"; echo "mutation: no classes"; exit 0; }
# Test files, in order of trust: named on the command line; the ones /verify ran for this same diff
# (the model chose them by reading callers); the filename fallback.
if [ -n "$PEST_OVERRIDE" ]; then read -r -a tests <<<"$PEST_OVERRIDE"; tests_from="named"
elif [ -f "$RDIR/pest.json" ] && rcmd="$(jq -r '.command // ""' "$RDIR/pest.json")" && [ -n "$rcmd" ]; then
  read -r -a tests < <(tr ' ' '\n' <<<"$rcmd" | grep -E '^tests/.*\.php$' | paste -sd' ' -); tests_from="the /verify receipt for this diff"
else mapfile -t tests < <(jq -r '.pest_files[]' <<<"$MAP"); tests_from="the filename fallback"; fi
[ ${#tests[@]} -gt 0 ] || { receipt RED "no test file maps to the changed app classes; nothing can kill a mutant. Add one or pass --pest 'paths'"; echo "✖ mutation: no mapped tests"; exit 1; }
# The config sits in the repo root with relative paths and a "verify" testsuite of the chosen files:
# pest --parallel (paratest) takes one path, and out-of-tree configs break its coverage bookkeeping.
python3 "$HERE/narrow-phpunit.py" "$ROOT/phpunit.xml" "$ROOT/.verify-phpunit.xml" "$ROOT" "${changed_php[@]}" --tests "${tests[@]}" >/dev/null || { receipt RED "could not build the narrowed phpunit config"; exit 1; }
grep -qx '.verify-phpunit.xml' "$ROOT/.git/info/exclude" 2>/dev/null || echo '.verify-phpunit.xml' >> "$ROOT/.git/info/exclude"
par="$(jq -r '.mutation.parallel // false' "$Q" 2>/dev/null)"; procs="$(jq -r '.mutation.processes // 4' "$Q" 2>/dev/null)"
[ -f "$RDIR/added-lines.json" ] || python3 "$HERE/added-lines.py" "$ROOT" "$BASE" "${changed_php[@]}" > "$RDIR/added-lines.json" 2>/dev/null
[ "$(jq '[.[] | length] | add // 0' "$RDIR/added-lines.json" 2>/dev/null)" != 0 ] || { receipt SKIP "the diff adds no lines to the changed app classes"; echo "mutation: no added lines to mutate"; exit 0; }

log="$RDIR/mutation.log"; classlist="$(IFS=,; echo "${classes[*]}")"
echo "▶ mutation started: classes ${classlist} · tests ${tests[*]} (from ${tests_from}) · min score ${min}% · timeout ${tmo}s"
printf '%s %s %s\n' "$$" "$sha" "$(date +%s)" > "$RUN_MARK"; trap 'rm -f "$RUN_MARK"' EXIT
export_test_env "$(basename "$ROOT")"
start=$(date +%s)
parallel=(); [ "$par" = true ] && parallel=(--parallel "--processes=$procs")
MUTATE_LINES_FILE="$RDIR/added-lines.json" timeout "$tmo" php -d auto_prepend_file="$HERE/mutate-lines.php" vendor/bin/pest --colors=never --configuration=.verify-phpunit.xml --testsuite=verify --mutate --class="$classlist" --covered-only \
  "${parallel[@]}" --min="$min" --ignore-min-score-on-zero-mutations > "$log" 2>&1
rc=$?; el=$(( $(date +%s) - start ))
sed -i 's/\x1b\[[0-9;]*m//g' "$log" 2>/dev/null
scope="added lines"; grep -q '^\[harness\] mutation scoped to added lines' "$log" || scope="whole class (line scope did not load)"
score="$(grep -Eo 'Score:[[:space:]]+[0-9.]+' "$log" | tail -1 | grep -Eo '[0-9.]+')"
counts="$(grep -E '^\s*Mutations:' "$log" | tail -1 | sed 's/^\s*//')"
total="$(grep -Eo '^\s*[0-9]+ Mutations for' "$log" | grep -Eo '[0-9]+' | head -1)"
killed="$(grep -c '^\s*✓ Line' "$log")"; survived="$(grep -c '^\s*⨯ Line' "$log")"
if [ "$par" = true ]; then
  # Parallel mode prints one symbol per mutant: . killed, x survived, t timed out, - uncovered.
  block="$(sed -n '/Mutations for/,$p' "$log" | grep -E '^\s*[.xt-]+\s*$' | tr -d ' \n')"
  killed="$(printf '%s' "$block" | tr -cd '.' | wc -c)"; survived="$(printf '%s' "$block" | tr -cd 'xt' | wc -c)"
fi
ran=$((killed + survived))
# Survivors, each marked by whether its line is one this diff added.
surv="$(python3 - "$log" "$RDIR/added-lines.json" <<'EOF'
import json, re, sys
log, added = sys.argv[1], {k: set(v) for k, v in json.load(open(sys.argv[2])).items()}
cur, out = None, []
for line in open(log, encoding='utf-8', errors='replace'):
    m = re.match(r'\s*RUN\s+(\S+)', line)
    if m: cur = m.group(1); continue
    m = re.match(r'\s*⨯ Line (\d+): (\w+)', line)
    if m and cur:
        n = int(m.group(1)); out.append(f"{cur}:{n} {m.group(2)} ({'added' if n in added.get(cur, set()) else 'pre-existing'})")
print(';'.join(out[:8]))
EOF
)"
if [ $rc -eq 124 ] && [ "$ran" -gt 0 ]; then
  score="$(python3 -c "print(round($killed*100/$ran, 1))")"; counts="partial: $ran of ${total:-?} mutants ran in ${tmo}s ($killed killed, $survived survived)"
fi
jq -cn --arg sha "$sha" --arg cls "$classlist" --arg counts "$counts" --arg scope "$scope" --argjson v "${score:-null}" --argjson min "$min" --arg ts "$(date +%s)" '{ts:($ts|tonumber),diff_sha:$sha,metric:"msi",value:$v,threshold:$min,classes:$cls,counts:$counts,scope:$scope}' >> "$LOOP_STATE/quality/$REPO.jsonl"
if [ -z "$score" ]; then
  [ $rc -eq 124 ] && { receipt RED "timed out after ${tmo}s before any mutant ran (baseline tests alone took the budget)" $el; echo "✖ mutation timed out before any mutant ran"; exit 1; }
  receipt RED "pest --mutate produced no score (exit $rc): $(grep -iE 'error|exception|fatal' "$log" | head -1 | cut -c1-140)" $el
  echo "✖ mutation failed (exit $rc), see $log"; exit 1
fi
if [ $rc -eq 124 ] && { [ -z "$total" ] || [ "$ran" -lt "$total" ]; }; then
  if grep -q '(added)' <<<"$surv"; then
    receipt RED "a mutant on a line this diff added survived ($counts). Surviving: $surv" $el
    echo "✖ mutation ${el}s  survivor on an added line  $counts"; echo "  surviving mutants (file:line mutator): $surv"; echo "  full report: $log"; exit 1
  fi
  receipt PARTIAL "not verified: only $ran of ${total:-?} mutants ran before the ${tmo}s budget; ${score}% on those, no survivor on an added line${surv:+. Surviving (pre-existing): $surv}" $el
  echo "◐ mutation ${el}s  PARTIAL $ran of ${total:-?} mutants  ${score}% on those"; [ -n "$surv" ] && echo "  surviving mutants: $surv"; exit 0
fi
if [ $rc -eq 0 ]; then
  receipt GREEN "score ${score}% on changed classes ($counts)${surv:+. Surviving: $surv}" $el; echo "✔ mutation ${el}s  score ${score}%  $counts"; [ -n "$surv" ] && echo "  surviving mutants: $surv"; exit 0
fi
receipt RED "score ${score}% below ${min}% ($counts). Surviving: ${surv:-see log}" $el
echo "✖ mutation ${el}s  score ${score}% below ${min}%  $counts"; echo "  surviving mutants (file:line mutator): ${surv:-see log}"; echo "  full report: $log"; exit 1
