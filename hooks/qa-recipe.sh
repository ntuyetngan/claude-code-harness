#!/usr/bin/env bash
# Runs a QA setup recipe on the dev box and prints the JSON it produces (ids and URLs a browser
# test then visits). A recipe is ~/.claude/qa/recipes/<name>.md (what it builds, its inputs, the
# browser steps that follow) plus <name>.php, a script that runs inside `php artisan tinker` on the
# box, uses the repo's factories and models, and prints one JSON object as its last line.
# The box is the same target devsync.sh uses (dev.* in ~/.claude/config/projects.json).
#   qa-recipe.sh list                       recipes and their one-line purpose
#   qa-recipe.sh show <name>                print the recipe's .md
#   qa-recipe.sh run <name> [KEY=VALUE...]  copy the .php to the box, run it, print its JSON
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=qa-recipe
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "qa-recipe: not in a git repo" >&2; exit 64; }
REPO="$(basename "$ROOT")"; CFG="$HOME/.claude/config/projects.json"; RDIR="$HOME/.claude/qa/recipes"
C="$(jq -c --arg r "$REPO" '.[$r] // {}' "$CFG" 2>/dev/null)"
host="$(jq -r '.dev.host // ""' <<<"$C")"; user="$(jq -r '.dev.user // ""' <<<"$C")"; port="$(jq -r '.dev.port // 22' <<<"$C")"
key="$(jq -r '.dev.key // ""' <<<"$C")"; rpath="$(jq -r '.dev.path // ""' <<<"$C")"; key="${key/#\~/$HOME}"
remote_dir="$(jq -r '.qa.remote_recipe_dir // "storage/app/qa-recipes"' <<<"$C")"

ssh_cmd() { local a=(ssh -o BatchMode=yes -o ConnectTimeout=15 -p "$port"); [ -n "$key" ] && [ -f "$key" ] && a+=(-i "$key" -o IdentitiesOnly=yes); "${a[@]}" "$user@$host" "$@"; }

case "${1:-}" in
  list) for f in "$RDIR"/*.md; do [ -f "$f" ] || { echo "no recipes in $RDIR"; break; }; printf '%-28s %s\n' "$(basename "${f%.md}")" "$(sed -nE 's/^Purpose: //p' "$f" | head -1)"; done ;;
  show) [ -f "$RDIR/${2:-}.md" ] || { echo "qa-recipe: no recipe '${2:-}'" >&2; exit 66; }; cat "$RDIR/$2.md" ;;
  run)
    name="${2:-}"; [ -f "$RDIR/$name.php" ] || { echo "qa-recipe: no setup script $RDIR/$name.php" >&2; exit 66; }
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$rpath" ] || { echo "qa-recipe: dev.host/user/path for $REPO missing in $CFG" >&2; exit 65; }
    shift 2
    # KEY=VALUE inputs travel as environment variables the script reads with getenv('QA_KEY').
    envs=""; for kv in "$@"; do case "$kv" in *=*) k="QA_${kv%%=*}"; v="${kv#*=}"; envs+="$(printf '%q=%q ' "$k" "$v")" ;; *) echo "qa-recipe: inputs are KEY=VALUE, got '$kv'" >&2; exit 64 ;; esac; done
    hook_log "$REPO run $name on $user@$host:$port"
    # The script is copied fresh each run so the box always executes the current recipe.
    tar czf - -C "$RDIR" "$name.php" | ssh_cmd "mkdir -p $rpath/$remote_dir && tar xzf - -C $rpath/$remote_dir" || { echo "qa-recipe: copy to the box failed" >&2; exit 70; }
    out="$(ssh_cmd "cd $rpath && ${envs}php artisan tinker --execute=\"require '$remote_dir/$name.php';\" 2>&1")"; rc=$?
    json="$(printf '%s\n' "$out" | grep -E '^\{.*\}$' | tail -1)"
    if [ $rc -ne 0 ] || [ -z "$json" ]; then printf 'qa-recipe: %s failed (exit %s). Output:\n%s\n' "$name" "$rc" "$out" >&2; exit 70; fi
    mkdir -p "$HOME/.claude/qa/runs"; printf '%s\n' "$json" | jq -c --arg n "$name" --arg ts "$(date -Iseconds)" '. + {recipe:$n, ran_at:$ts}' | tee -a "$HOME/.claude/qa/runs/$REPO.jsonl" ;;
  *) echo "usage: qa-recipe.sh list | show <name> | run <name> [KEY=VALUE...]" >&2; exit 64 ;;
esac
