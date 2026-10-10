#!/usr/bin/env bash
# Runs the mapped Pest files once, in shards, with coverage, and scores the changed methods with CRAP.
#   crap-suite.sh <receipt-dir> <merge-base> <diff-sha> -- <app php files...> -- <pest files...>
# verify.sh derives the pest receipt from this same run (coverage/pest.log and pest.rc), so pest never
# runs twice. Pest already computes CRAP per method (php-code-coverage); this only reads it and applies
# the threshold from ~/.claude/config/quality.json to the methods the diff touched.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=crap
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RDIR="$1"; BASE="$2"; SHA="$3"; shift 3
[ "${1:-}" = "--" ] && shift
APP=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do APP+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
PEST=("$@")
ROOT="$(repo_root "$PWD")"; REPO="$(basename "$ROOT")"
Q="$HOME/.claude/config/quality.json"; max="$(jq -r '.crap.max // 30' "$Q" 2>/dev/null)"
shards="$(jq -r '.pest.shards // 4' "$Q" 2>/dev/null)"; tmo="$(jq -r '.pest.shard_timeout_seconds // 1800' "$Q" 2>/dev/null)"
php -m | grep -qiE '^(pcov|xdebug)$' || { echo "PCOV not loaded: sudo pecl install pcov, then add extension=pcov.so to /etc/php/8.5/cli/conf.d/20-pcov.ini"; exit 3; }
[ ${#PEST[@]} -gt 0 ] || { echo "no pest files to run with coverage"; exit 3; }
mkdir -p "$RDIR/coverage" "$LOOP_STATE/quality"
"$HERE/pest-run.sh" "$RDIR/coverage" "$shards" "$tmo" --coverage "${APP[@]}" -- "${PEST[@]}"
rc=$?
[ -f "$RDIR/coverage/clover.xml" ] || { echo "no clover report written (pest exit $rc): $(grep -iE 'error|fatal|timed out' "$RDIR/coverage/pest.log" | head -1 | cut -c1-140)"; exit 1; }
python3 "$HERE/crap-report.py" "$RDIR/coverage/clover.xml" "$ROOT" "$BASE" "$max" "$LOOP_STATE/quality/$REPO.jsonl" "$SHA" "${APP[@]}"
prc=$?
echo "reports: $RDIR/coverage/clover.xml and crap4j.xml"
exit $prc
