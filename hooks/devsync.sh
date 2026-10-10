#!/usr/bin/env bash
# One-way copy of this change to the dev box: only the files the diff touched (tracked and untracked),
# plus built assets when frontend files changed, as a tar stream over ssh. Never deletes on the box. Settings per repo in
# ~/.claude/config/projects.json.
#   devsync.sh --list        show what would be copied and what would be built, copy nothing
#   devsync.sh               build on Windows if needed, then copy the files, then run remote_after_sync
#   devsync.sh --no-build    skip the frontend build even if frontend files changed
#   devsync.sh --no-migrate  do not run the migrations this change adds on the box
# After the copy, every build manifest on the box is compared with the local one (a copy that
# left the old bundle in place once cost a whole QA run), and each new migration in the change is
# run on the box with --path, since the plan that approved the migration approved the QA run too.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=devsync
LIST=0; NOBUILD=0; NOMIGRATE=0; while [ $# -gt 0 ]; do case "$1" in --list) LIST=1 ;; --no-build) NOBUILD=1 ;; --no-migrate) NOMIGRATE=1 ;; esac; shift; done
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "not in a git repo" >&2; exit 64; }
cd "$ROOT" || exit 64; REPO="$(basename "$ROOT")"
CFG="$HOME/.claude/config/projects.json"; C="$(jq -c --arg r "$REPO" '.[$r] // empty' "$CFG" 2>/dev/null)"
[ -n "$C" ] || { echo "no entry for $REPO in $CFG; add one before syncing" >&2; exit 2; }
# The target is built from projects.json itself (host, user, port, key) so the harness does not depend
# on an alias in ~/.ssh/config; dev.ssh is only a fallback alias when host is not set.
host="$(jq -r '.dev.host // ""' <<<"$C")"; user="$(jq -r '.dev.user // ""' <<<"$C")"; port="$(jq -r '.dev.port // 22' <<<"$C")"
key="$(jq -r '.dev.key // ""' <<<"$C")"; rpath="$(jq -r '.dev.path' <<<"$C")"
if [ -n "$host" ] && [ "$host" != null ]; then ssh_t="${user:+$user@}$host"; else ssh_t="$(jq -r '.dev.ssh' <<<"$C")"; port=""; fi
case "$ssh_t" in ""|null|CHANGE_ME*) echo "dev.host (or dev.ssh) for $REPO is not set in $CFG" >&2; exit 2 ;; esac
MAP="$("$(dirname "${BASH_SOURCE[0]}")/verify.sh" --map 2>/dev/null)"; sha="$(jq -r .diff_sha <<<"$MAP")"; RDIR="$(jq -r .receipts <<<"$MAP")"
mapfile -t files < <(jq -r '.changed[]' <<<"$MAP")
# drop excluded paths
mapfile -t ex < <(jq -r '.sync.excludes[]' <<<"$C")
keep=(); for f in "${files[@]}"; do skip=0; for e in "${ex[@]}"; do case "$f" in "$e"*|"${e%/}"|*/"$e"*) skip=1 ;; esac; done; [ $skip = 0 ] && keep+=("$f"); done
# which frontend builds does this change need? a build runs when one of its triggers changed; a changed
# path under any_build_triggers that matches no specific build runs every build.
nb="$(jq -r '.frontend.builds | length' <<<"$C")"; declare -a run_build; for ((i=0;i<nb;i++)); do run_build[$i]=0; done
mapfile -t anyt < <(jq -r '.frontend.any_build_triggers[]?' <<<"$C")
for f in "${keep[@]}"; do
  matched=0
  for ((i=0;i<nb;i++)); do while IFS= read -r t; do case "$f" in "$t"*) run_build[$i]=1; matched=1 ;; esac; done < <(jq -r ".frontend.builds[$i].triggers[]" <<<"$C"); done
  if [ $matched = 0 ]; then for t in "${anyt[@]}"; do case "$f" in "$t"*) for ((i=0;i<nb;i++)); do run_build[$i]=1; done ;; esac; done; fi
done
need_build=0; builds_txt=""; after=()
for ((i=0;i<nb;i++)); do [ "${run_build[$i]}" = 1 ] || continue; need_build=1; builds_txt+=" $(jq -r ".frontend.builds[$i].name" <<<"$C")"; after+=("$(jq -r ".frontend.builds[$i].output" <<<"$C")"); done
mapfile -t extra_after < <(jq -r '.sync.include_after_build[]?' <<<"$C"); after+=("${extra_after[@]}")
echo "devsync $REPO -> $ssh_t:$rpath  (diff $sha, ${#keep[@]} file(s)$([ $need_build = 1 ] && echo ", frontend builds first:$builds_txt" ))"
printf '  %s\n' "${keep[@]}"
[ $need_build = 1 ] && printf '  + %s (after build)\n' "${after[@]}"
[ "$LIST" = 1 ] && exit 0
[ ${#keep[@]} -gt 0 ] || { echo "nothing to copy"; exit 0; }
# 1. build on Windows (the node_modules are Windows-built; cmd.exe runs from this C: directory)
if [ $need_build = 1 ] && [ $NOBUILD = 0 ]; then
  # The builds write to separate output directories and share nothing, so they run at once; the
  # three of them took 206s in sequence and the longest alone takes about 100s.
  pids=(); names=(); s=$(date +%s)
  for ((i=0;i<nb;i++)); do
    [ "${run_build[$i]}" = 1 ] || continue
    name="$(jq -r ".frontend.builds[$i].name" <<<"$C")"; build="$(jq -r ".frontend.builds[$i].command" <<<"$C")"
    echo "▶ $name build on Windows: $build"
    timeout 1800 /mnt/c/Windows/System32/cmd.exe /c "$build" > "$RDIR/devsync-build-$name.log" 2>&1 &
    pids+=($!); names+=("$name")
  done
  failed=0
  for ((j=0;j<${#pids[@]};j++)); do
    wait "${pids[$j]}"; rc=$?
    echo "$([ $rc = 0 ] && echo ✔ || echo ✖) ${names[$j]} build done at $(( $(date +%s) - s ))s (exit $rc, log $RDIR/devsync-build-${names[$j]}.log)"
    [ $rc = 0 ] || { hook_log "${names[$j]} build failed rc=$rc"; failed=1; }
  done
  [ $failed = 0 ] || exit 1
  for d in "${after[@]}"; do [ -e "$d" ] && keep+=("$d"); done
fi
# 2. copy only those paths as a tar stream over ssh: relative paths are kept, nothing on the box is
# deleted, and the box needs nothing installed (it has no rsync, which is why tar is used).
sshcmd="ssh -o BatchMode=yes -o ConnectTimeout=15"; [ -n "$port" ] && sshcmd+=" -p $port"; key="${key/#\~/$HOME}"; [ -n "$key" ] && [ -f "$key" ] && sshcmd+=" -i $key -o IdentitiesOnly=yes"
printf '%s\n' "${keep[@]}" > "$RDIR/devsync-files.txt"
echo "▶ copying ${#keep[@]} path(s)"; s=$(date +%s)
tar czf - --no-recursion -T "$RDIR/devsync-files.txt" --recursion $(for d in "${after[@]}"; do [ -e "$d" ] && printf -- '%s ' "$d"; done) 2>"$RDIR/devsync.log" \
  | $sshcmd "$ssh_t" "mkdir -p $rpath && tar xzf - -C $rpath && echo copied" >> "$RDIR/devsync.log" 2>&1
rc=${PIPESTATUS[1]}; el=$(( $(date +%s) - s ))
if [ $rc -ne 0 ] || ! grep -q '^copied$' "$RDIR/devsync.log"; then echo "✖ copy failed (exit $rc): $(grep -v '^copied$' "$RDIR/devsync.log" | tail -2 | tr '\n' ' ' | cut -c1-200)"; hook_log "copy failed rc=$rc"; exit 1; fi
echo "✔ copied in ${el}s"
# 2b. the box must now serve what was built: compare each build manifest with the local one
for d in "${after[@]}"; do
  [ -f "$d/manifest.json" ] || continue
  lsum="$(sha1sum "$d/manifest.json" | cut -c1-40)"; rsum="$($sshcmd "$ssh_t" "sha1sum $rpath/$d/manifest.json 2>/dev/null | cut -c1-40")"
  if [ "$lsum" != "$rsum" ]; then echo "✖ $d/manifest.json on the box differs from the local build (box would serve a stale bundle)"; hook_log "manifest mismatch $d"; exit 1; fi
  echo "✔ $d/manifest.json matches on the box"
done
# 2c. migrations this change adds run on the box, one --path each, so the code it now holds can boot
mapfile -t migs < <(printf '%s\n' "${keep[@]}" | grep -E '^database/migrations/.*\.php$')
if [ ${#migs[@]} -gt 0 ] && [ $NOMIGRATE = 0 ]; then
  for m in "${migs[@]}"; do
    echo "▶ remote: php artisan migrate --path=$m --force"
    timeout 600 $sshcmd "$ssh_t" "cd $rpath && php artisan migrate --path=$m --force" >> "$RDIR/devsync.log" 2>&1 && echo "✔ migrated $m" || { echo "✖ migrate $m failed (see $RDIR/devsync.log)"; hook_log "migrate failed $m"; exit 1; }
  done
fi
# 3. remote commands (cache clears and the like)
mapfile -t remote < <(jq -r '.remote_after_sync[]' <<<"$C")
for cmd in "${remote[@]}"; do
  [ -n "$cmd" ] || continue
  echo "▶ remote: $cmd"; timeout 300 $sshcmd "$ssh_t" "cd $rpath && $cmd" >> "$RDIR/devsync.log" 2>&1 && echo "✔ $cmd" || echo "✖ $cmd (see $RDIR/devsync.log)"
done
jq -n --arg sha "$sha" --arg t "$ssh_t:$rpath" --argjson n ${#keep[@]} --argjson b $need_build --arg ts "$(date +%s)" '{suite:"devsync",status:"GREEN",detail:("copied \($n) path(s) to \($t)" + (if $b==1 then " after a frontend build" else "" end)),diff_sha:$sha,elapsed_s:0,ts:($ts|tonumber)}' > "$RDIR/devsync.json"
hook_log "GREEN devsync ${#keep[@]} paths to $ssh_t"
