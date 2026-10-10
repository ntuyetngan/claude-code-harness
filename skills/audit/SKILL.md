---
name: audit
description: Score-then-fix loop over the working tree. A read-only reviewer agent scores every finding 1 to 10; the session fixes findings above 5 with the minimal diff, verifies, and re-reviews, for at most two rounds. Findings at 5 and below are listed, never fixed. Writes an audit receipt that /handoff checks. Runs by itself after /verify on an approved plan; also by hand as "/audit" or "/audit 1" for a single round.
argument-hint: '[rounds, default 2]'
---

# /audit

Find and fix what the current diff introduces, up to the bar the user set: fix above 5, list the rest. The reviewer never fixes. This session never scores.

## Non-negotiable rules

- The `reviewer` agent scores. This session does not rescore, argue a finding down, or skip a finding above 5 without recording it as NEEDS_HUMAN with the reason.
- Fixes are minimal. A fix that needs a file the plan does not name adds that file to the plan under "Discovered during implementation" with the reason, then proceeds; if the file is a new surface, a migration, schema or config, or under payments, auth or venue privacy, it asks first. A fix that would need a file the user declines becomes NEEDS_HUMAN.
- No commits, no pushes, no stash. The working tree is the deliverable.
- Suites run only through `verify.sh`, started as a background task; wait for its completion notification.
- A round without a verify step is not a round.

## Workflow

### 1. Scope the diff

- Base: `git merge-base HEAD master`. Diff: tracked changes against that base plus untracked files (`git status --porcelain` for the list).
- Empty diff: say so and stop.
- Repo name: basename of `git rev-parse --show-toplevel`. Plan file: `~/.claude/plans/<repo>/<slug>.md` for the current branch's ticket, if one exists. Without a plan, the audit still runs but the scope pass has nothing to compare against; say so in the summary.
- Docs pages: from `docs/index.md`, the topic pages for the systems the changed paths belong to.
- Rounds: `$ARGUMENTS` if numeric, else 2.

### 2. Review

Dispatch the `reviewer` agent with: the diff, the plan path, the docs pages, and the instruction to return the JSON block described in its definition. One agent, one call. If the verify skill already dispatched the reviewer for this same diff sha (it does so right after starting `verify.sh`, so the two overlap), use that result instead of a new dispatch. While the reviewer works, if the current diff has no verify receipts yet, start `verify.sh` as a background task too; then collect both.

### 3. Fix above 5

For each finding with score 6 or higher, in score order:

- If the file is not in the plan's "Files that change" list, add it there and under "Discovered during implementation" with the finding as the reason; ask first when it is material (see the rule above).
- Apply the reviewer's minimal fix. No extra guards, no renames, no comments, no docblock edits.
- If the finding is a missing regression test, write the test, run it, and show it failing on the pre-fix code when that is practical; otherwise say it was not.

Findings at 5 and below are not touched. Keep them for the summary.

### 4. Verify

Start `~/.claude/hooks/verify.sh` from the repo root as a background task, exactly as the verify skill does, and wait for its notification. It maps the diff to suites, runs them, prints the GREEN / RED table, and writes the receipts the stop gate and `/handoff` read; a suite whose inputs did not change since a GREEN receipt is reused from that receipt, so a small fix re-runs only what it touched. When its name heuristic misses the right tests, pass `--pest 'paths'`. A RED suite is never retried with the same inputs.

### 5. Re-review and loop

Dispatch the reviewer again on the new diff, with the previous findings attached so it re-scores open ones and scores anything the fixes introduced. Fix above 5 again. Stop when nothing above 5 is open or when the round cap is reached. Anything above 5 still open at the cap is NEEDS_HUMAN with the last reviewer note.

### 6. Receipt and summary

Write `~/.claude/loop-state/audit/<repo>/<diff-sha>.json`, where `<diff-sha>` is `git diff <base> | sha1sum` after the last fix, containing: rounds run, findings fixed with scores, findings listed, NEEDS_HUMAN items, suite results. `/handoff` reads this and refuses to open a PR when any NEEDS_HUMAN item or RED suite is present.

Then the summary, in this order:

1. Fixed: `F1 [8] title — path:line`, one per line.
2. Listed, not fixed (5 and below): same shape.
3. NEEDS_HUMAN: same shape plus the reason.
4. Suites: GREEN / RED table with anything that could not be verified.

No preamble. No restating the diff.
