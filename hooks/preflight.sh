#!/usr/bin/env bash
# SessionStart hook and the body of /preflight. Prints a GREEN/RED table as context.
# Repairs, without asking in the session, the three things the owner agreed to at design time: starts
# Docker Desktop and the two containers, and applies pending migrations on the testing connection.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=preflight
FORCE="${PREFLIGHT_FORCE:-0}"
loop_enabled || [ "$FORCE" = 1 ] || { hook_log "skip: loop off"; exit 0; }
if [ -t 0 ]; then HOOK_INPUT='{}'; HOOK_SESSION=cli; HOOK_CWD="$PWD"; else read_hook_input; fi
# Run by hand (/preflight from the Bash tool) there is no session id; a snapshot under "unknown" would
# be newer than the real session's and hide that session's edits from verify.
[ "$HOOK_SESSION" = unknown ] && HOOK_SESSION=cli
ROOT="$(repo_root "$HOOK_CWD")"
[ -n "$ROOT" ] || { echo "preflight: not in a git repo, nothing to check"; exit 0; }
REPO="$(basename "$ROOT")"
if [ "$HOOK_SESSION" != cli ] && [ ! -f "$LOOP_STATE/$HOOK_SESSION/tree-at-start" ]; then
  mkdir -p "$LOOP_STATE/$HOOK_SESSION" && tree_snapshot "$ROOT" > "$LOOP_STATE/$HOOK_SESSION/tree-at-start" 2>/dev/null
  hook_log "tree snapshot for $HOOK_SESSION: $(wc -l < "$LOOP_STATE/$HOOK_SESSION/tree-at-start") pre-existing changed files"
fi
RECEIPT="$LOOP_STATE/preflight/$REPO.json"
LOCK="$LOOP_STATE/preflight/$REPO.lock"
ROWS=(); OVERALL=GREEN
row() { # status name detail
  ROWS+=("$1|$2|$3"); [ "$1" = RED ] && OVERALL=RED; hook_log "$1 $2: $3"
}
emit() {
  local t="Preflight for $REPO ($(date '+%H:%M')) — overall $OVERALL"$'\n'
  t+="| Status | Check | Detail |"$'\n'"| --- | --- | --- |"$'\n'
  local r; for r in "${ROWS[@]}"; do IFS='|' read -r s n d <<<"$r"; t+="| $s | $n | $d |"$'\n'; done
  t+=$'\n'"Rules: a RED row is the environment truth; do not retry the failing command, use the remedy or tell the user. Re-run with /preflight after fixing."
  jq -n --arg t "$t" --arg o "$OVERALL" --arg ts "$(date +%s)" '{ts:($ts|tonumber),overall:$o,table:$t}' > "$RECEIPT" 2>/dev/null
  if [ -t 1 ]; then printf '%s\n' "$t"; else jq -n --arg t "$t" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$t}}'; fi
}
# A receipt younger than 30 minutes is reused, RED or GREEN, so parallel sessions do not each pay
# the full run. /preflight sets PREFLIGHT_FORCE=1 to refresh after the user fixes something.
if [ "$FORCE" != 1 ] && [ -f "$RECEIPT" ]; then
  age=$(( $(date +%s) - $(jq -r '.ts // 0' "$RECEIPT" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 1800 ]; then
    t="$(jq -r '.table' "$RECEIPT")"; t="(cached ${age}s ago) $t"
    if [ -t 1 ]; then printf '%s\n' "$t"; else jq -n --arg t "$t" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$t}}'; fi
    exit 0
  fi
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  for _ in $(seq 1 60); do sleep 2; [ -d "$LOCK" ] || break; done
  rmdir "$LOCK" 2>/dev/null
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- generic checks ---
branch="$(git -C "$ROOT" branch --show-current 2>/dev/null)"; row GREEN "branch" "${branch:-detached}"
if [ -f "$ROOT/.git/index.lock" ]; then
  if pgrep -x git >/dev/null 2>&1; then row RED "git index.lock" "present and a git process is running; wait for it or find it with pgrep -a git"
  else rm -f "$ROOT/.git/index.lock" && row GREEN "git index.lock" "stale lock removed (no git process owned it)"; fi
else row GREEN "git index.lock" "none"; fi
if curl -sS -o /dev/null --max-time 8 https://github.com 2>/dev/null; then row GREEN "github reachable" "github.com answers from WSL; /handoff pushes and opens the PR from WSL"
else
  wgh="$(ls -d /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/GitHub.cli_*/bin/gh.exe "/mnt/c/Program Files/GitHub CLI/gh.exe" 2>/dev/null | head -1)"
  wver="$([ -x "$wgh" ] && timeout 20 "$wgh" --version 2>/dev/null | tr -d '\r' | sed -nE 's/^gh version ([0-9.]+).*/\1/p')"
  whosts="$(ls /mnt/c/Users/*/AppData/Roaming/"GitHub CLI"/hosts.yml 2>/dev/null | head -1)"
  wuser="$([ -n "$whosts" ] && sed -nE 's/^[[:space:]]+user:[[:space:]]*([^[:space:]]+).*/\1/p' "$whosts" | head -1)"
  if [ -z "$wver" ]; then row RED "github reachable" "github.com does not answer from WSL and no gh.exe on Windows: /handoff cannot push or open a PR. Once: winget install GitHub.cli, then gh auth login in a Windows terminal"
  elif [ -z "$wuser" ]; then row RED "github reachable" "github.com does not answer from WSL; Windows gh $wver is installed but not signed in: run gh auth login in a Windows terminal, then /handoff routes through it"
  else row GREEN "github reachable" "github.com does not answer from WSL; /handoff routes git push and gh through Windows gh $wver as $wuser (composer downloads still fail from WSL)"; fi
fi
ghuser="$(awk '/^github.com:/{f=1} f && /user:/{print $2; exit}' "$HOME/.config/gh/hosts.yml" 2>/dev/null)"
if [ -n "$ghuser" ]; then row GREEN "gh auth" "github.com as $ghuser (offline check of hosts.yml)"; else row RED "gh auth" "no github.com entry in ~/.config/gh/hosts.yml: run gh auth login"; fi
if [ -d "$HOME/.aws" ]; then
  if timeout 10 aws sts get-caller-identity >/dev/null 2>&1; then row GREEN "aws" "identity ok"; else row RED "aws" "session expired or no credentials: run aws login (or your SSO command) before any AWS-side verification"; fi
fi

# --- Laravel + Docker (this repo only) ---
if is_laravel "$ROOT"; then
  engine_up() { timeout 10 "$DOCKER_EXE" info >/dev/null 2>&1; }
  if ! engine_up; then
    hook_log "docker engine down, starting Docker Desktop"
    "$POWERSHELL" -NoProfile -Command "Start-Process -FilePath '$DOCKER_DESKTOP_EXE'" >/dev/null 2>&1
    for _ in $(seq 1 30); do sleep 3; engine_up && break; done
  fi
  if engine_up; then
    row GREEN "docker engine" "up"
    for c in app-mysql app-redis; do
      st="$(timeout 10 "$DOCKER_EXE" inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
      if [ "$st" != running ]; then timeout 30 "$DOCKER_EXE" start "$c" >/dev/null 2>&1; fi
    done
    ok=1
    for _ in $(seq 1 30); do tcp_open 127.0.0.1 3306 && tcp_open 127.0.0.1 6379 && break; sleep 2; done
    tcp_open 127.0.0.1 3306 && row GREEN "app-mysql" "port 3306 open" || { ok=0; row RED "app-mysql" "container not reachable on 3306: docker.exe logs app-mysql"; }
    tcp_open 127.0.0.1 6379 && row GREEN "app-redis" "port 6379 open" || { ok=0; row RED "app-redis" "container not reachable on 6379: docker.exe logs app-redis"; }
    if [ "$ok" = 1 ]; then
      pending="$(cd "$ROOT" && timeout 120 php artisan --env=testing migrate:status 2>/dev/null | grep -c Pending)"
      if [ -z "$pending" ]; then row RED "test db migrations" "migrate:status timed out or failed on the testing connection"
      elif [ "$pending" -gt 0 ]; then
        hook_log "running $pending pending migrations on testing env"
        mout="$(cd "$ROOT" && timeout 600 php artisan --env=testing migrate --force 2>&1 | tail -3)"; mrc=${PIPESTATUS[0]:-1}
        if [ "$mrc" = 0 ] && (cd "$ROOT" && timeout 900 php artisan --env=testing test:provision-parallel-databases >/dev/null 2>&1); then
          row GREEN "test db migrations" "$pending pending migrations applied and parallel test databases re-provisioned"
        else hook_log "migrate output: $mout"; row RED "test db migrations" "$pending pending; migrate or provisioning failed ($(printf '%s' "$mout" | tr '\n' ' ' | cut -c1-160)). Run: php artisan --env=testing migrate && php artisan --env=testing test:provision-parallel-databases"; fi
      else row GREEN "test db migrations" "none pending"; fi
    fi
  else
    row RED "docker engine" "Docker Desktop did not come up in 90 s: start it from the Start menu, then /preflight"
  fi
  if php -m | grep -qiE '^(pcov|xdebug)$'; then row GREEN "coverage driver" "$(php -m | grep -iE '^(pcov|xdebug)$' | head -1) loaded; CRAP and mutation gates can run"
  else row RED "coverage driver" "no PCOV: CRAP and mutation gates cannot run. Once: sudo apt-get install -y build-essential && sudo pecl install pcov && echo 'extension=pcov.so' | sudo tee /etc/php/8.5/cli/conf.d/20-pcov.ini"; fi
  if [ -d "$ROOT/vendor/pestphp/pest/src/Mutate" ] || [ -d "$ROOT/vendor/pestphp/pest-plugin-mutate" ]; then row GREEN "pest mutate" "built into this Pest; the mutation gate runs at /handoff"
  else row RED "pest mutate" "this Pest has no --mutate; the mutation gate cannot run"; fi
  pj="$(jq -c --arg r "$REPO" '.[$r].dev // {}' "$HOME/.claude/config/projects.json" 2>/dev/null)"
  ph="$(jq -r '.host // ""' <<<"$pj")"; pu="$(jq -r '.user // ""' <<<"$pj")"; pp="$(jq -r '.port // 22' <<<"$pj")"; pk="$(jq -r '.key // ""' <<<"$pj")"; pk="${pk/#\~/$HOME}"
  case "$ph" in ""|null|CHANGE_ME*) row GREEN "dev box" "not configured for $REPO (optional): set dev.host/user/port/key/path in ~/.claude/config/projects.json to enable /qa syncing" ;;
    *) if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$pp" ${pk:+-i "$pk" -o IdentitiesOnly=yes} "${pu:+$pu@}$ph" true >/dev/null 2>&1; then row GREEN "dev box" "${pu:+$pu@}$ph:$pp answers over ssh"
       else row RED "dev box" "${pu:+$pu@}$ph:$pp does not answer over ssh: check the company VPN, the key at $pk, and that the port is the one in projects.json. /qa cannot sync until then"; fi ;; esac
  tcp_open 127.0.0.1 3307 && row GREEN "rds tunnel" "127.0.0.1:3307 listening (read-only dev DB)" || row GREEN "rds tunnel" "down; only needed for RDS queries, start with ./db-tunnel.sh"
fi

# --- node and npm (any repo with package.json) ---
if [ -f "$ROOT/package.json" ]; then
  export NVM_DIR="$HOME/.nvm"; set +u; if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; nvm use 24 >/dev/null 2>&1; fi; set -u
  nv="$(node -v 2>/dev/null)"; case "$nv" in v24*) row GREEN "node" "$nv via nvm";; *) row RED "node" "expected v24 via nvm, got ${nv:-none}: source ~/.nvm/nvm.sh && nvm use 24";; esac
  pv="$(timeout 20 playwright-cli --version 2>/dev/null | tail -1)"; case "$pv" in [0-9]*) row GREEN "playwright-cli" "$pv, headed Chrome under WSLg (DISPLAY=:0); /qa can run";; *) row GREEN "playwright-cli" "not installed (optional): /qa reports BLOCKED until: source ~/.nvm/nvm.sh && nvm use 24 && npm install -g @playwright/cli@latest";; esac
  if [ -d "$ROOT/node_modules" ]; then
    if ls -d "$ROOT"/node_modules/@esbuild/linux-* >/dev/null 2>&1; then row GREEN "node_modules platform" "linux binaries present"
    elif ls -d "$ROOT"/node_modules/@esbuild/win32-* >/dev/null 2>&1; then
      if [ -x "$WIN_NODE_DIR/node.exe" ]; then row GREEN "node_modules platform" "built on Windows: vitest and vue-tsc run through /verify, which calls $WIN_NODE_DIR/node.exe on node_modules/vitest/vitest.mjs and node_modules/vue-tsc/bin/vue-tsc.js. npm.cmd cannot run from bash, and the npm scripts' NODE_OPTIONS= prefix fails under cmd.exe. Do not npm install from the agent."
      else row RED "node_modules platform" "built on Windows and no Windows node at $WIN_NODE_DIR: frontend suites cannot run from WSL. Install Node for Windows or rebuild node_modules yourself."; fi
    else row RED "node_modules platform" "no esbuild platform package found; node_modules may be incomplete"; fi
  else row RED "node_modules" "missing: npm ci needed (by you, not the agent)"; fi
  for reg in npm.pkg.github.com npm.pqina.nl; do
    if grep -qs "//$reg/:_authToken" "$ROOT/.npmrc" "$HOME/.npmrc" 2>/dev/null; then row GREEN "npm token $reg" "present in .npmrc (presence only, not validated)"
    else row RED "npm token $reg" "no _authToken line in .npmrc: npm ci will fail on private packages; stop and tell the user"; fi
  done
fi
emit
