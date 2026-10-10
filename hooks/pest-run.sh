#!/usr/bin/env bash
# Runs the chosen pest files in K shards at once, each on its own provisioned test database
# (Laravel switches to <db>_test_<TEST_TOKEN> when LARAVEL_PARALLEL_TESTING is set, and creates a
# missing one from the schema first), then joins the logs and, with --coverage, merges the shards'
# coverage into clover.xml and crap4j.xml. Pest's own --parallel is not used: its merged clover comes
# out empty in this setup, and paratest takes a single path anyway.
#   pest-run.sh <out-dir> <shards> <timeout-s> [--coverage <app php files>... --] <test files>...
# Writes <out-dir>/pest.log (every shard's log, then one "Tests: N passed|failed" total), pest.rc (the
# worst shard's exit code), shard-<k>.log|.rc|.cov, and with --coverage clover.xml and crap4j.xml.
# Routes and events are cached with --env=testing, as CI does, and kept between runs; a hash of routes/,
# config/, the providers, listeners, bootstrap/app.php and .env.testing in loop-state/quality decides a
# rebuild. A cache written after that stamp is someone else's and is left alone. A planner line
# "<file>@i/n" runs part i of n of that file's tests (from --list-tests) through pest-shards.py's filter.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=pest-run
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$1"; K="$2"; TMO="$3"; shift 3
APP=(); COVER=0
if [ "${1:-}" = "--coverage" ]; then COVER=1; shift; while [ $# -gt 0 ] && [ "$1" != "--" ]; do APP+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift; fi
TESTS=("$@")
ROOT="$(repo_root "$PWD")"; REPO="$(basename "$ROOT")"; cd "$ROOT" || exit 64
[ ${#TESTS[@]} -gt 0 ] || { echo "pest-run: no test files"; exit 64; }
mkdir -p "$OUT"
export_test_env "$REPO"
DUR="$LOOP_STATE/quality/$REPO.pest-durations.json"
cfg=()
if [ $COVER = 1 ]; then
  # The narrowed config must sit in the repo root: php-code-coverage serializes shard paths relative to
  # the config's directory, and the merge puts them back under that same base.
  python3 "$HERE/narrow-phpunit.py" "$ROOT/phpunit.xml" "$ROOT/.verify-phpunit.xml" "$ROOT" "${APP[@]}" >/dev/null || { echo "pest-run: could not write the narrowed config"; exit 1; }
  grep -qx '.verify-phpunit.xml' "$ROOT/.git/info/exclude" 2>/dev/null || echo '.verify-phpunit.xml' >> "$ROOT/.git/info/exclude"
  cfg=(--configuration=.verify-phpunit.xml)
fi
STAMP="$LOOP_STATE/quality/$REPO.route-cache.sha"
want="$(find routes config app/Providers app/Listeners bootstrap/app.php .env.testing -type f 2>/dev/null | sort | xargs -d '\n' sha1sum 2>/dev/null | sha1sum | cut -c1-40)"
present=0; { [ -f bootstrap/cache/routes-v7.php ] || [ -f bootstrap/cache/events.php ]; } && present=1
ours=0; [ -f "$STAMP" ] && ! [ bootstrap/cache/routes-v7.php -nt "$STAMP" ] && ours=1
if [ $present = 0 ] || { [ $ours = 1 ] && [ "$(cat "$STAMP")" != "$want" ]; }; then
  mkdir -p "$(dirname "$STAMP")"
  if { php artisan route:cache --env=testing && php artisan event:cache --env=testing; } > "$OUT/route-cache.log" 2>&1; then
    echo "$want" > "$STAMP"
  else
    php artisan route:clear >/dev/null 2>&1; php artisan event:clear >/dev/null 2>&1; rm -f "$STAMP"
    echo "  route/event cache failed, running uncached (see $OUT/route-cache.log)"
  fi
fi
list_tests() {
  local l="$OUT/list-$(printf '%s' "$1" | sha1sum | cut -c1-12).txt"
  if [ ! -f "$l" ]; then
    LARAVEL_PARALLEL_TESTING=1 TEST_TOKEN=1 timeout 300 vendor/bin/pest --colors=never --list-tests "$1" 2>/dev/null | grep -E '^ - .*::' > "$l.raw"
    wc -l < "$l.raw" > "$l.count"; sed -nE 's/^ - .*::([^ ]+).*$/\1/p' "$l.raw" | awk '!seen[$0]++' > "$l"
  fi
  cat "$l"
}
rm -f "$OUT"/list-*
mapfile -t PLAN < <(python3 "$HERE/pest-shards.py" plan "$K" "$DUR" "${TESTS[@]}")
pids=(); ks=(); declare -A splitof; start=$(date +%s)
for ((k=1;k<=${#PLAN[@]};k++)); do
  files="${PLAN[$((k-1))]}"; [ -n "$files" ] || continue
  read -r -a members <<<"$files"
  filt=(); part=""
  if [[ "${members[0]}" =~ ^(.+)@([0-9]+)/([0-9]+)$ ]]; then
    f="${BASH_REMATCH[1]}"; i="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"; members=("$f")
    if [ "$(list_tests "$f" | wc -l)" -ge "$n" ]; then
      list_tests "$f" > "$OUT/list-part.txt"
      filt=(--filter "$(python3 "$HERE/pest-shards.py" filter "$i" "$n" "$OUT/list-part.txt")"); part=" (part $i/$n)"; splitof[$k]="$f"
    elif [ "$i" -ne 1 ]; then continue
    else part=" (whole file: could not list its tests)"; fi
  fi
  cov=(); [ $COVER = 1 ] && cov=(--coverage-php="$OUT/shard-$k.cov")
  echo "  shard $k (db token $k): ${members[*]}$part"
  ( LARAVEL_PARALLEL_TESTING=1 TEST_TOKEN=$k timeout "$TMO" vendor/bin/pest --colors=never "${cfg[@]}" "${cov[@]}" "${filt[@]}" "${members[@]}" > "$OUT/shard-$k.log" 2>&1; echo $? > "$OUT/shard-$k.rc" ) &
  pids+=($!); ks+=("$k")
done
wait
worst=0; passed=0; failed=0
: > "$OUT/pest.log"
for k in "${ks[@]}"; do
  rc="$(cat "$OUT/shard-$k.rc" 2>/dev/null || echo 1)"; [ "$rc" -gt "$worst" ] && worst=$rc
  sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/shard-$k.log" 2>/dev/null
  { echo "===== shard $k (exit $rc) ====="; cat "$OUT/shard-$k.log"; echo; } >> "$OUT/pest.log"
  p="$(grep -Eo 'Tests:[[:space:]]+[0-9]+ passed' "$OUT/shard-$k.log" | grep -Eo '[0-9]+' | tail -1)"; passed=$((passed + ${p:-0}))
  f="$(grep -Eo '[0-9]+ failed' "$OUT/shard-$k.log" | grep -Eo '[0-9]+' | tail -1)"; failed=$((failed + ${f:-0}))
  [ "$rc" -eq 124 ] && echo "shard $k timed out after ${TMO}s" >> "$OUT/pest.log"
done
# A renamed or split migration leaves the shard databases with the column but without the new row.
grep -qE "Duplicate column name|Base table or view not found" "$OUT/pest.log" && echo "shard databases are out of step with the migrations (renamed or split migration?): run php artisan --env=testing test:provision-parallel-databases, then verify again" >> "$OUT/pest.log"
declare -A ran
for k in "${!splitof[@]}"; do
  t="$(grep -E 'Tests:' "$OUT/shard-$k.log" | tail -1 | sed 's/(.*//' | grep -Eo '[0-9]+' | paste -sd+ | bc 2>/dev/null)"
  ran[${splitof[$k]}]=$(( ${ran[${splitof[$k]}]:-0} + ${t:-0} ))
done
for f in "${!ran[@]}"; do
  want="$(cat "$OUT/list-$(printf '%s' "$f" | sha1sum | cut -c1-12).txt.count" 2>/dev/null)"
  [ "${ran[$f]}" = "$want" ] || { echo "split parts of $f ran ${ran[$f]} of ${want:-?} listed tests; the part filters missed some" >> "$OUT/pest.log"; [ "$worst" -lt 1 ] && worst=1; }
done
if [ "$failed" -gt 0 ]; then echo "Tests:    $failed failed, $passed passed (all shards)" >> "$OUT/pest.log"; else echo "Tests:    $passed passed (all shards, $(( $(date +%s) - start ))s wall)" >> "$OUT/pest.log"; fi
echo "$worst" > "$OUT/pest.rc"
python3 "$HERE/pest-shards.py" record "$DUR" "$OUT"/shard-*.log >/dev/null 2>&1 || true
if [ $COVER = 1 ] && [ "$worst" -ne 124 ]; then
  covs=(); for k in "${ks[@]}"; do [ -s "$OUT/shard-$k.cov" ] && covs+=("$OUT/shard-$k.cov"); done
  [ ${#covs[@]} -gt 0 ] && php "$HERE/merge-coverage.php" "$ROOT" "$OUT/clover.xml" "$OUT/crap4j.xml" "${APP[@]}" -- "${covs[@]}" >> "$OUT/pest.log" 2>&1
fi
echo "pest: $(tail -1 "$OUT/pest.log") · ${#ks[@]} shard(s), worst exit $worst"
exit "$worst"
