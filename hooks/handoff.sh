#!/usr/bin/env bash
# Arms or disarms the commit permission the git guard checks, and checks the PR body and the QA
# comment /handoff may post. Repo-scoped because a skill running in Bash cannot see its session id.
# Armed state expires after 30 minutes on its own.
#   handoff.sh arm | disarm | status
#   handoff.sh body-path               the one file the guard accepts as --body-file on gh pr create
#   handoff.sh body-check              verify that file against the repo template and stamp it
#   handoff.sh comment-path            the one file the guard accepts as --body-file on gh pr comment
#   handoff.sh comment-check           verify the QA comment (a "## QA" heading, images present) and stamp it
#   handoff.sh attach-args [comment]   print one --attach flag per image the body (or the comment) references
#   handoff.sh image-fix <file>         stamp an open PR's live body with only its local-path image lines removed
#   handoff.sh commit <msg-file> <file>...   arm, stage exactly the named files, commit, print the sha (stays armed for the push)
#   handoff.sh fold <pr> [--comment <id>]   fold the long parts into <details>: gh --attach appends the uploaded images after
#                                           the text, so after create or comment this moves them, and the Test Plan lines, into
#                                           <details>. The body version writes a stamped file for gh pr edit; the comment version
#                                           updates the harness's own "## QA" comment in place and refuses any other comment.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; HOOK_NAME=handoff
ROOT="$(repo_root "$PWD")"; [ -n "$ROOT" ] || { echo "handoff: not in a git repo" >&2; exit 64; }
REPO="$(basename "$ROOT")"; F="$LOOP_STATE/handoff/$REPO"
BODY="$F.body.md"; STAMP="$F.body.ok"; TEMPLATE="$ROOT/.github/pull_request_template.md"
COMMENT="$F.qa-comment.md"; CSTAMP="$F.qa-comment.ok"

# Image paths a file references as ![alt](path); relative paths resolve against the repo root.
images_in() { grep -oE '!\[[^]]*\]\([^)]+\)' "$1" 2>/dev/null | sed -E 's/^!\[[^]]*\]\(([^)]+)\)$/\1/' | sed -E 's/[[:space:]]+"[^"]*"$//'; }
resolve() { local p="${1/#\~/$HOME}"; case "$p" in /*) printf '%s' "$p";; *) printf '%s' "$ROOT/$p";; esac; }
section() { tr -d '\r' < "$2" | awk -v h="$1" '$0==h{on=1;next} /^## /{on=0} on' | tr -d '[:space:]'; }
check_images() {
  local img p
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    p="$(resolve "$img")"
    [ -f "$p" ] || { echo "$1: image not found: $img" >&2; exit 66; }
    case "${p,,}" in *.png|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.mp4|*.mov|*.webm) ;; *) echo "$1: not an uploadable file: $img" >&2; exit 65;; esac
  done < <(images_in "$2")
}

body_check() {
  [ -f "$TEMPLATE" ] || { echo "body-check: no template at $TEMPLATE" >&2; exit 65; }
  [ -f "$BODY" ] || { echo "body-check: write the body to $BODY first" >&2; exit 66; }
  local want have
  # The template is committed with CRLF line endings; compare headings without the carriage return.
  want="$(tr -d '\r' < "$TEMPLATE" | grep -E '^## ')"; have="$(tr -d '\r' < "$BODY" | sed '/<!-- This is an auto-generated comment: release notes by coderabbit.ai -->/,$d' | grep -E '^## ')"
  [ "$want" = "$have" ] || { printf 'body-check: headings must match the template exactly, in order.\nexpected:\n%s\ngot:\n%s\n' "$want" "$have" >&2; exit 65; }
  # The first section is the author's. It must be empty: nothing but whitespace between its heading and the next.
  local first; first="$(printf '%s\n' "$want" | head -1)"
  [ -z "$(section "$first" "$BODY")" ] || { echo "body-check: the section \"${first#\#\# }\" must be left blank for the author" >&2; exit 65; }
  local h
  while IFS= read -r h; do
    [ "$h" = "$first" ] && continue
    [ -n "$(section "$h" "$BODY")" ] || { echo "body-check: the section \"${h#\#\# }\" is empty; fill it or write why it does not apply" >&2; exit 65; }
  done <<<"$want"
  check_images body-check "$BODY"
  sha256sum "$BODY" | cut -d' ' -f1 > "$STAMP"
  hook_log "$REPO body checked $(cat "$STAMP")"
  echo "body-check: ok ($BODY, $(images_in "$BODY" | grep -c .) images, stamped)"
}

comment_check() {
  [ -f "$COMMENT" ] || { echo "comment-check: write the comment to $COMMENT first" >&2; exit 66; }
  head -1 "$COMMENT" | tr -d '\r' | grep -Eq '^## QA( |$)' || { echo "comment-check: the first line must be a '## QA ...' heading" >&2; exit 65; }
  [ -n "$(tail -n +2 "$COMMENT" | tr -d '[:space:]')" ] || { echo "comment-check: the comment has no scenarios" >&2; exit 65; }
  check_images comment-check "$COMMENT"
  sha256sum "$COMMENT" | cut -d' ' -f1 > "$CSTAMP"
  hook_log "$REPO qa comment checked $(cat "$CSTAMP")"
  echo "comment-check: ok ($COMMENT, $(images_in "$COMMENT" | grep -c .) images, stamped)"
}

attach_args() {
  local src="$BODY"; [ "${1:-}" = comment ] && src="$COMMENT"
  local img
  while IFS= read -r img; do [ -n "$img" ] && printf -- '--attach %q\n' "$(resolve "$img")"; done < <(images_in "$src")
}

case "${1:-status}" in
  arm) mkdir -p "$LOOP_STATE/handoff" && date +%s > "$F" && hook_log "$REPO armed" && echo "handoff armed for $REPO: git commit and push allowed for 30 minutes" ;;
  disarm) rm -f "$F" "$STAMP" "$CSTAMP" && hook_log "$REPO disarmed" && echo "handoff disarmed for $REPO" ;;
  status) if [ -f "$F" ] && [ $(( $(date +%s) - $(cat "$F") )) -lt 1800 ]; then echo "armed ($(( ( $(date +%s) - $(cat "$F") ) / 60 )) min ago)"; else echo "not armed"; fi ;;
  body-path) mkdir -p "$LOOP_STATE/handoff"; echo "$BODY" ;;
  body-check) body_check ;;
  comment-path) mkdir -p "$LOOP_STATE/handoff"; echo "$COMMENT" ;;
  comment-check) comment_check ;;
  attach-args) attach_args "${2:-}" ;;
  image-fix)
    # An open PR's live body (saved to $2) minus its local-path image lines, which gh --attach leaves as broken
    # links. Nothing else changes, so the author's text is kept byte for byte; the result is stamped like a body.
    [ -f "${2:-}" ] || { echo "image-fix: pass the file holding the PR's current body" >&2; exit 66; }
    grep -vE '^[[:space:]]*!\[[^]]*\]\((/|~)[^)]*\)[[:space:]]*$' "$2" > "$BODY"
    rm -f "$STAMP"; sha256sum "$BODY" | cut -d' ' -f1 > "$F.body.imgfix.ok"
    hook_log "$REPO body image-fix $(cat "$F.body.imgfix.ok") removed $(( $(wc -l < "$2") - $(wc -l < "$BODY") )) line(s)"
    echo "image-fix: ok ($BODY, removed $(( $(wc -l < "$2") - $(wc -l < "$BODY") )) local image line(s), stamped)" ;;
  commit)
    # The guard reads a Bash command before it runs, so "arm && git commit" in one call was blocked and the
    # message file of the blocked call never existed. This does the sequence in one guarded place.
    shift; msg="${1:-}"; shift || true
    [ -f "$msg" ] || { echo "commit: pass the commit message file first" >&2; exit 66; }
    [ $# -gt 0 ] || { echo "commit: name every file to stage; nothing is staged by pattern" >&2; exit 64; }
    for f in "$@"; do case "$f" in .|-A|--all|-u|*'*'*) echo "commit: stage files by name, never $f" >&2; exit 64 ;; esac; [ -e "$ROOT/$f" ] || { echo "commit: $f does not exist" >&2; exit 66; }; done
    mkdir -p "$LOOP_STATE/handoff"; date +%s > "$F"; hook_log "$REPO armed by commit"
    git -C "$ROOT" add -- "$@" || exit 1
    git -C "$ROOT" commit -F "$msg" >/dev/null || { echo "commit: git commit failed" >&2; exit 1; }
    hook_log "$REPO committed $(git -C "$ROOT" rev-parse --short HEAD) ($# files)"
    echo "committed $(git -C "$ROOT" rev-parse --short HEAD) on $(git -C "$ROOT" branch --show-current): $# file(s); still armed for the push" ;;
  fold)
    pr="${2:-}"; cid=""; [ "${3:-}" = --comment ] && cid="${4:-}"
    [ -n "$pr" ] || { echo "fold: pass the PR number" >&2; exit 64; }
    GHW="$(dirname "${BASH_SOURCE[0]}")/ghw.sh"; HERE_DIR="$(dirname "${BASH_SOURCE[0]}")"
    if [ -n "$cid" ]; then
      slug="$("$GHW" gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr -d '\r')"
      live="$F.live-comment.md"; "$GHW" gh api "repos/$slug/issues/comments/$cid" --jq .body 2>/dev/null | tr -d '\r' > "$live"
      head -1 "$live" | grep -q '^## QA' || { echo "fold: comment $cid is not the harness's QA comment; left alone" >&2; exit 65; }
      out="$F.folded-comment.md"; python3 "$HERE_DIR/fold-body.py" comment "$live" "$out"; rc=$?
      [ $rc -eq 3 ] && exit 0; [ $rc -eq 0 ] || exit $rc
      jq -n --rawfile b "$out" '{body:$b}' > "$F.folded-comment.json"
      "$GHW" gh api -X PATCH "repos/$slug/issues/comments/$cid" --input "$F.folded-comment.json" --jq .html_url 2>/dev/null | tr -d '\r'
      hook_log "$REPO folded QA comment $cid on PR $pr"
    else
      live="$F.live-body.md"; "$GHW" gh pr view "$pr" --json body --jq .body 2>/dev/null | tr -d '\r' > "$live"
      python3 "$HERE_DIR/fold-body.py" body "$live" "$BODY"; rc=$?
      [ $rc -eq 3 ] && exit 0; [ $rc -eq 0 ] || exit $rc
      rm -f "$STAMP"; sha256sum "$BODY" | cut -d' ' -f1 > "$F.body.imgfix.ok"
      hook_log "$REPO body fold stamped $(cat "$F.body.imgfix.ok")"
      echo "fold: body written and stamped; now run: ~/.claude/hooks/ghw.sh gh pr edit $pr --body-file $BODY"
    fi ;;
  *) echo "usage: handoff.sh arm | disarm | status | body-path | body-check | comment-path | comment-check | attach-args [comment] | image-fix <file> | commit <msg-file> <file>... | fold <pr> [--comment <id>]" >&2; exit 64 ;;
esac
