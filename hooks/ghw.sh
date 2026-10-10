#!/usr/bin/env bash
# Route gh and git push to GitHub. WSL first; when github.com does not answer from WSL, the Windows
# binaries run instead (Windows reaches GitHub through its own network). Files passed to gh
# (--body-file, -F, --attach) are copied to a Windows temp folder so gh.exe reads a plain C: path.
#   ghw.sh route                       print which route would be used and why
#   ghw.sh gh <gh args...>             run gh (or gh.exe) with the same arguments
#   ghw.sh git push <git args...>      run git push (or git.exe push) in the current repo
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=ghw
WIN_GH="${GHW_WIN_GH:-$(ls -d /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/GitHub.cli_*/bin/gh.exe "/mnt/c/Program Files/GitHub CLI/gh.exe" 2>/dev/null | head -1)}"
WIN_GIT="${GHW_WIN_GIT:-/mnt/c/Program Files/Git/cmd/git.exe}"
WIN_TMP="/mnt/c/Users/$(/mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')/AppData/Local/Temp/claude-handoff"

wsl_reaches_github() { curl -sS -o /dev/null --max-time 6 https://api.github.com/ >/dev/null 2>&1; }
route() {
  if wsl_reaches_github; then echo "wsl: github.com answers from WSL"; return 0; fi
  [ -x "$WIN_GH" ] || { echo "none: github.com does not answer from WSL and no gh.exe found (winget install GitHub.cli)"; return 2; }
  echo "windows: github.com does not answer from WSL; using $WIN_GH"; return 1
}

# Copy a Linux-side file to the Windows temp folder and print its C:\ path. A file already under
# /mnt/c is only translated.
win_file() {
  local f="$1"; f="${f/#\~/$HOME}"
  case "$f" in /mnt/[a-z]/*) wslpath -w "$f"; return ;; esac
  mkdir -p "$WIN_TMP" || return 1
  cp -f "$f" "$WIN_TMP/$(basename "$f")" || return 1
  wslpath -w "$WIN_TMP/$(basename "$f")"
}

# WSL's gh is Ubuntu's 2.4.0; --attach needs 2.99 or newer. When the arguments carry --attach and the
# WSL gh is too old, the Windows gh is used even though WSL reaches GitHub.
wsl_gh_has_attach() {
  local v; v="$(gh --version 2>/dev/null | sed -nE 's/^gh version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
  [ -n "$v" ] && { set -- $v; [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 99 ]; }; }
}
# gh --attach appends the uploaded images itself and leaves local-path image lines in the body as broken
# links, so with --attach the body is sent without its local-path image lines.
strip_local_images() {
  local has=0 x; for x in "$@"; do case "$x" in --attach|--attach=*) has=1;; esac; done
  STRIPPED=(); local prev=""
  for x in "$@"; do
    if [ $has = 1 ] && { [ "$prev" = --body-file ] || [ "$prev" = -F ]; } && [ -f "${x/#\~/$HOME}" ]; then
      local out="$LOOP_STATE/handoff/$(basename "$x" .md).sent.md"
      grep -vE '^[[:space:]]*!\[[^]]*\]\((/|~)[^)]*\)[[:space:]]*$' "${x/#\~/$HOME}" > "$out"; x="$out"
    fi
    STRIPPED+=("$x"); prev="$x"
  done
}
run_gh() {
  strip_local_images "$@"; set -- "${STRIPPED[@]}"
  local r; r="$(route)"; local rc=$?
  if [ $rc -eq 0 ] && printf '%s\n' "$@" | grep -q -- '^--attach' && ! wsl_gh_has_attach; then
    if [ -x "$WIN_GH" ]; then r="windows: WSL gh is too old for --attach; using $WIN_GH"; rc=1
    else echo "ghw: --attach needs gh 2.99 or newer; WSL has $(gh --version | head -1) and no gh.exe was found (winget install GitHub.cli)" >&2; exit 69; fi
  fi
  hook_log "gh route: $r"
  case $rc in
    0) exec gh "$@" ;;
    2) echo "ghw: $r" >&2; exit 69 ;;
  esac
  local args=() a v alt
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --body-file|-F|--attach|--input)
        v="$1"; shift; alt=""
        # --attach takes "path#alt text"; keep the alt text after the copied path.
        if [ "$a" = --attach ]; then case "$v" in *'#'*) alt="#${v#*#}"; v="${v%%#*}";; esac; fi
        [ -f "${v/#\~/$HOME}" ] || { echo "ghw: file not found: $v" >&2; exit 66; }
        args+=("$a" "$(win_file "$v")$alt") ;;
      --body-file=*|--attach=*|--input=*) v="${a#*=}"; a="${a%%=*}"; set -- "$a" "$v" "$@" ;;
      *) args+=("$a") ;;
    esac
  done
  exec "$WIN_GH" "${args[@]}"
}

run_git_push() {
  local r; r="$(route)"; local rc=$?
  hook_log "git push route: $r"
  case $rc in
    0) exec git push "$@" ;;
    2) echo "ghw: $r" >&2; exit 69 ;;
  esac
  [ -x "$WIN_GIT" ] || { echo "ghw: no Windows git at $WIN_GIT" >&2; exit 69; }
  local root; root="$(repo_root "$PWD")"; [ -n "$root" ] || { echo "ghw: not in a git repo" >&2; exit 64; }
  exec "$WIN_GIT" -C "$(wslpath -w "$root")" push "$@"
}

case "${1:-}" in
  route) route; exit 0 ;;
  gh) shift; run_gh "$@" ;;
  git) shift; [ "${1:-}" = push ] || { echo "ghw: only 'git push' is routed" >&2; exit 64; }; shift; run_git_push "$@" ;;
  *) echo "usage: ghw.sh route | gh <args> | git push <args>" >&2; exit 64 ;;
esac
