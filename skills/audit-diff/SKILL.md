---
name: audit-diff
description: Run the plan-versus-diff judge on demand and revert the incidental changes you choose. Compares this session's diff with the approved plan for the branch, labels each changed file requested or incidental, lists planned files not yet touched, flags comments and docs lines that will rot, then asks which incidental files to revert. Manual-only; run as "/audit-diff". For bug findings use /audit instead.
disable-model-invocation: true
---

# /audit-diff

Scope check, not bug check. The same Haiku judge the stop gate runs, invoked when you want it.

## Workflow

1. Find the plan: `~/.claude/hooks/lib.sh` has `find_plan <repo> <branch>`; run `source ~/.claude/hooks/lib.sh && find_plan "$(basename "$(git rev-parse --show-toplevel)")" "$(git branch --show-current)"`. No approved plan for this branch: say so and stop; there is nothing to judge against.
2. Run `~/.claude/hooks/diff-judge.sh <plan file> cli` from the repo root, in the foreground, with a 3 minute timeout. With `cli` as the session it judges every change against the merge base, not only this session's. Show its output unchanged.
3. Exit 0 means the diff matches the plan: say so in one line and stop.
4. Exit 2 lists incidental files, planned files not touched, and rot. Ask one AskUserQuestion, multi-select, listing each incidental file with the judge's reason. The user picks which to revert. Warn in the question that a revert restores the whole file at the merge base, so a file holding both requested and incidental changes needs a manual edit instead.
5. Revert the chosen tracked files with `git checkout -- <path>` one at a time, and delete chosen untracked files with `rm <path>`. Never `git checkout -- .`, never `git clean`, never `git stash`.
6. For planned files not touched and for rot, do not act; list them so the user decides.
7. If any file changed, run `~/.claude/hooks/verify.sh` so the receipts match the new diff.
8. Summary: reverted files, files left for manual edit, planned files still untouched, rot lines still present.
