#!/usr/bin/env bash
# Shared helpers for the personal hooks. Sourced, not executed.

LOOP_STATE="${HOME}/.claude/loop-state"
HOOK_LOG="${LOOP_STATE}/hooks.log"
DOCKER_EXE="/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
DOCKER_DESKTOP_EXE='C:\Program Files\Docker\Docker\Docker Desktop.exe'
POWERSHELL="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
WIN_NODE_DIR="/mnt/c/nvm4w/nodejs"   # nvm4w symlink; node.exe and npm.cmd live here

mkdir -p "$LOOP_STATE" 2>/dev/null

hook_log() {
  printf '%s  %-16s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${HOOK_NAME:-hook}" "$1" >> "$HOOK_LOG" 2>/dev/null
}

# Reads the whole hook input from stdin once; callers use $HOOK_INPUT.
read_hook_input() {
  HOOK_INPUT="$(cat)"
  HOOK_SESSION="$(jq -r '.session_id // "unknown"' <<<"$HOOK_INPUT" 2>/dev/null)"
  case "$HOOK_SESSION" in *[!A-Za-z0-9_-]*|'') HOOK_SESSION=unknown ;; esac
  HOOK_CWD="$(jq -r '.cwd // empty' <<<"$HOOK_INPUT" 2>/dev/null)"
  [ -n "$HOOK_CWD" ] || HOOK_CWD="$PWD"
}

repo_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
repo_name() { basename "$(repo_root "$1")" 2>/dev/null; }
is_laravel() { [ -f "$1/artisan" ]; }

# Exit 2 blocks the tool call; the message on stderr is shown to Claude.
block() {
  hook_log "BLOCK $1"
  printf '%s\n' "$1" >&2
  exit 2
}

tcp_open() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# One line per changed file (vs merge-base with master, plus untracked): "<sha1>  <path>".
# Written at session start so the stop gate can tell this session's edits from pre-existing work.
tree_snapshot() {
  local root="$1" base
  base="$(git -C "$root" merge-base HEAD master 2>/dev/null || git -C "$root" rev-parse HEAD)"
  ( cd "$root" && { git diff --name-only "$base" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } \
    | grep -v '^nuxt/' | sort -u | while IFS= read -r f; do [ -f "$f" ] && sha1sum "$f"; done )
}

# Newest plan file under ~/.claude/plans/<repo>/ whose Branch line matches and whose Status is approved or in progress.
find_plan() {
  local repo="$1" branch="$2" d="$HOME/.claude/plans/$1" f
  [ -d "$d" ] || return 1
  for f in $(ls -t "$d"/*.md 2>/dev/null); do
    grep -q "^Branch: $branch\$" "$f" && grep -Eq '^Status: (approved|in progress)' "$f" && { echo "$f"; return 0; }
  done
  return 1
}


# The plan for the current work: the branch's plan, else, on master or main before /handoff has
# created the branch, the newest approved or in-progress plan for the repo.
find_active_plan() {
  local repo="$1" branch="$2" d="$HOME/.claude/plans/$1" f
  find_plan "$repo" "$branch" && return 0
  case "$branch" in master|main|'') ;; *) return 1 ;; esac
  for f in $(ls -t "$d"/*.md 2>/dev/null); do grep -Eq '^Status: (approved|in progress)' "$f" && { echo "$f"; return 0; }; done
  return 1
}

# Paths a plan names under "Files that change" and "Discovered during implementation": backticked,
# path-shaped, one per line. A run of x's (a migration timestamp not yet known) is kept as a glob.
plan_files() {
  awk '/^## (Files that change|Discovered during implementation)/{on=1;next} /^## /{on=0} on' "$1" \
    | grep -oE '`[^`]+`' | tr -d '`' | grep -E '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.*-]+)+$' | sed -E 's/x{4,}/*/g' | sort -u
}

# The loop can be switched off for a whole session (CLAUDE_LOOP=off claude) or mid-session
# (~/.claude/hooks/harness.sh off, which writes the off file). Event hooks call this first and exit 0
# when it fails; scripts run on purpose by a skill (/verify, /quality, /preflight) ignore it.
loop_enabled() { [ "${CLAUDE_LOOP:-on}" != off ] && [ ! -f "$LOOP_STATE/off" ]; }

# Laravel reads .env.testing only when APP_ENV=testing is set before boot; without it pest boots on .env.
# Per-repo extras come from projects.json "<repo>.test_env". Run from the repo root.
export_test_env() {
  local REPO="$1"
  if [ -f .env.testing ]; then
    export APP_ENV=testing
    grep -qE '^APP_KEY=.+' .env.testing || export APP_KEY="${APP_KEY:-base64:$(openssl rand -base64 32)}"
  fi
  while IFS= read -r kv; do [ -n "$kv" ] && export "$kv"; done < <(python3 -c 'import json,sys,os
d=json.load(open(os.path.expanduser("~/.claude/config/projects.json"))).get(sys.argv[1],{}).get("test_env",{})
print("\n".join(f"{k}={v}" for k,v in d.items()))' "$REPO" 2>/dev/null)
}
