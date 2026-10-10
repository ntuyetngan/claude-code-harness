---
name: handoff
description: Turn verified, audited work in the working tree into a pushed branch and an open PR. Checks receipts and the audit, asks which files to stage when no plan names them, runs the browser QA itself when the plan requires it, arms the git guard for 30 minutes, commits with the attribution trailer, pushes, opens the PR with the repo template filled except "What and Why" and the QA screenshots attached, prints a draft of that first section for you to write, and disarms. On a branch whose PR already exists it pushes and posts the new QA screenshots as a PR comment. Routes push and gh through Windows when GitHub does not answer from WSL. Runs by itself after /audit on an approved plan, using the plan's branch, title and files without asking; also by hand as "/handoff".
---

# /handoff

The only place commits and pushes happen. On an approved plan it runs without a question: the plan already holds the branch, the title, the files and the QA decision, and plan approval was the approval to sync the dev box. It asks only when something deviates from the plan. The PR body follows the repo template: "What and Why" is yours and stays blank; Tasks, Test Plan and Screenshots are filled by this skill from the plan, the receipts and the QA evidence. Browser QA is part of this skill, not a step you run first.

## Non-negotiable rules

- No commit before the receipts for the current diff are GREEN and an audit receipt with no NEEDS_HUMAN exists. Missing ones are produced first, never skipped.
- Stage only the files this work changed. The tree may hold the user's own unrelated work; it is never swept into the commit.
- Never `git add -A`, never `git add .`, never stash, never force, never push to master.
- The PR body is the file from `handoff.sh body-path`, written by you, checked by `handoff.sh body-check`, and nothing else. Never `--body`, never `--fill`. The first section is never written by an agent: this is the owner's personal override of the repo's pr-description-convention, decided 2026-09-28, and the guard enforces its shape.
- The body is written once, at PR creation. The one later edit an agent may make is `handoff.sh image-fix <live body>`, which removes its own local-path image lines and nothing else (its stamp lets `gh pr edit --body-file` through); the author's text is never touched. Later screenshots go into a PR comment from `handoff.sh comment-path`, checked by `handoff.sh comment-check`. Never a reply in a review thread; a top-level comment on the owner's own PR only.
- Screenshots reach the PR only through `--attach`; nothing is committed to the repo for them and nothing is hosted elsewhere.
- Push and gh go through `~/.claude/hooks/ghw.sh`, which uses WSL when github.com answers and the Windows binaries when it does not. Never work around a failed push by hand.
- The draft of "What and Why" is printed in the CLI, once, in one fenced block, with no AI footer.

## Workflow

### 1. Gate

- `~/.claude/hooks/verify.sh --map` for the diff sha, the receipt directory and the files outside the plan. Every mapped suite needs a GREEN receipt for that sha; otherwise run the `verify` skill now (a background task; wait for its completion notification) and stop if anything stays RED. Save the sha: the task report needs it after the commit.
- `~/.claude/loop-state/audit/<repo>/<diff sha>.json` must exist with no NEEDS_HUMAN and no RED suite; otherwise run the `/audit` loop now, then re-check. Anything still open above 5 stops the handoff with the list.
- Mutation testing does not gate the PR: it runs in step 4b, after the push, while CI and CodeRabbit work.
- `~/.claude/hooks/ghw.sh route` must not answer `none`. `windows:` means Windows gh and git will be used; if the preflight table says Windows gh is not signed in, stop and ask the user to run `gh auth login` in a Windows terminal first.

### 1b. Done when, line by line

The plan's "Done when" section is the promise; the receipts are the evidence. For each line, name the receipt, test, command output or screenshot that proves it, in one line each. A line with no proof is one AskUserQuestion: accept it unproven, or stop and prove it. Never move on with a "Done when" line silently unmet; a change can pass every suite and still not do what was asked.

### 1c. Does this handoff need browser QA?

Decide it now, run it in step 3c:

- The plan says `QA: required`: yes. A `qa.json` receipt for this diff that is already GREEN satisfies it and no second run happens.
- The plan says `QA: not needed`, or there is no plan, and the diff touches no Vue, Blade, CSS or frontend translation file: no. The summary says so.
- The plan says `QA: not needed`, or there is no plan, but the diff touches such files: one AskUserQuestion naming those files. Yes runs the QA with scenarios written from the change; no records "QA skipped by you" in the summary. With a plan that says `QA: not needed` and no such files, nothing is asked.

### 2. Files to stage

- With an approved plan for the branch (`find_plan` in `~/.claude/hooks/lib.sh`): the files under "Files that change" and "Discovered during implementation", plus files the plan's Proof names. Show `git status --short` beside that list.
- Without a plan: show `git status --short` and ask one AskUserQuestion, multi-select, listing every changed and untracked file. The user picks. Nothing is staged that they did not pick.
- A file `verify.sh --map` lists under `outside_plan` (changed this session, not named by the plan) is one AskUserQuestion: stage it (and add it to the plan with a reason), or leave it in the tree. A file that was already dirty at session start and is unchanged since is the owner's own work: it is left alone and named once in the summary, never asked about one by one.

### 3. Branch and message

- Branch and title come from the plan's `Branch:` and `PR title:` lines. On master, create the branch with `git switch -c <name>`; it is always `YYYYMMDD-<task-slug>`, today's date and a short kebab-case slug of the task, for example `20260928-pos-paypay-status-poll`.
- Without a plan, or when the plan lacks them, the title is in the repo format: `[ZAI-nnnnn][Area] Description` when a Linear ticket exists, `[<SENTRY-SHORT-ID>][Area] Description` when only a Sentry issue does, else `[No Linear][Area] Description`. Area is the PR title prefix the repo uses for that surface, such as POS, ZCS, Nerv, Microsite.
- Commit message: the title line, a blank line, a `Fixes <SENTRY-SHORT-ID>` line when there is one, and the attribution trailer the session's instructions require.

With an approved plan: no question. Print the branch, the title, the staged files and, when step 1c said yes, the files `~/.claude/hooks/devsync.sh --list` will copy, then continue. Without a plan, or when the plan lacks the branch or title: one AskUserQuestion with the branch, the title, the staged file list and that sync list. Approve, or Other with changes.

### 3c. Browser QA

When step 1c said yes and no GREEN `qa.json` exists for this diff: invoke the `qa` skill with `--from-handoff`. It syncs, runs every scenario in a headed browser, and writes the receipt with the screenshots under `<receipt dir>/qa/`. Then:

- GREEN: continue.
- RED: stop. Print the failing scenarios with what the agent saw versus what was expected. Nothing is committed; fix, `/verify`, and run `/handoff` again.
- BLOCKED: one AskUserQuestion: hand off without browser QA (the summary and the Test Plan say so), or stop until it can run.

### 3d. PR body, or the QA comment

**No PR yet for this branch** (`ghw.sh gh pr view --json number` fails): write the body to the path `~/.claude/hooks/handoff.sh body-path` prints, with exactly the headings of `.github/pull_request_template.md`, in order:

- **What and Why**: nothing. Not a placeholder, not a prompt. The author writes it in the browser.
- **Tasks (Linear/Sentry)**: one line per ticket or Sentry issue the plan names, as a link (`https://linear.app/zaiko/issue/ZAI-nnnnn`, the Sentry issue URL). None: `No Linear ticket` and why, in one line.
- **Test Plan**: what proves the change, from the receipts, not from memory. First one visible line that sums it up (`pest 132 passed, CRAP fine, browser QA 3/3 PASS, mutation runs after this PR opened`), then a `<details>` block with `<summary>Suites, QA scenarios and Done-when proof</summary>` holding the rest: one line per suite that ran, with its result (pest with the test names, phpstan, phpcs, vitest, type-check, CRAP; mutation is not listed, its result comes after the PR opened). Then the QA scenarios from `qa.json`, one line each with PASS, or "browser QA skipped by you" / "not needed" with the reason. Then the "Done when" lines with their proof, one line each. Short lines; a reviewer reads this to know what to re-run, and the fold keeps the PR page readable.
- **Screenshots**: one Markdown image per QA evidence file, `![<scenario in a few words>](<absolute path of the png under the receipt directory>)`, in scenario order. These local lines only feed `attach-args`: gh does not rewrite them, it appends each uploaded image itself, so `ghw.sh` sends the body to gh without its local-path image lines whenever `--attach` is passed. No QA: `No browser change` or the skip reason, in one line.

Then `~/.claude/hooks/handoff.sh body-check`. It refuses different or reordered headings, a filled first section, an empty later section, or an image that does not exist, and stamps the file when it passes. The guard only lets a stamped file through, and any later edit needs a new check.

**A PR already exists**: the body is not touched. When this handoff ran QA, write the comment to the path `~/.claude/hooks/handoff.sh comment-path` prints: first line `## QA <date> <short sha>`, then a `<details>` block with `<summary>QA details</summary>` holding one line per scenario with PASS and any notes, then `</details>`, then one image line per evidence file as above (outside the block: they only feed `attach-args`). Then `~/.claude/hooks/handoff.sh comment-check`, which stamps it the same way. No QA this time: no comment.

**Folding the images.** `gh --attach` appends each uploaded image after the text, outside any `<details>`. Right after `gh pr create` run `~/.claude/hooks/handoff.sh fold <pr>`: it fetches the live body, moves the appended images (and an unfolded Test Plan, on an older PR) into `<details>`, stamps the file, and prints the `ghw.sh gh pr edit <pr> --body-file <path>` line to run next. Right after `gh pr comment` run `~/.claude/hooks/handoff.sh fold <pr> --comment <id>` with the id from the comment URL (`#issuecomment-<id>`): it updates the harness's own `## QA` comment in place and refuses any other comment. Both are no-ops when nothing needs folding.

### 4. Commit, push, PR

New PR:

```
~/.claude/hooks/handoff.sh commit ~/.claude/loop-state/handoff/<repo>.msg <each staged file>
~/.claude/hooks/ghw.sh git push -u origin <branch>
~/.claude/hooks/ghw.sh gh pr create --title "<title>" --base master --body-file <the path body-path printed> <the --attach flags attach-args printed, written out>
~/.claude/hooks/handoff.sh fold <pr number from the URL gh printed>
~/.claude/hooks/ghw.sh gh pr edit <pr number> --body-file <the path fold printed>
~/.claude/hooks/handoff.sh disarm
```

Existing PR:

```
~/.claude/hooks/handoff.sh commit <message file> <each staged file>
~/.claude/hooks/ghw.sh git push origin <branch>
~/.claude/hooks/ghw.sh gh pr comment <number> --body-file <the path comment-path printed> <the --attach flags "attach-args comment" printed, written out>
~/.claude/hooks/handoff.sh fold <number> --comment <the id at the end of the comment URL>
~/.claude/hooks/handoff.sh disarm
```

Write the message file first, in its own call. `handoff.sh commit` arms the guard, stages exactly the files named (never a pattern), commits, prints the sha and stays armed for the push; the guard reads a Bash command before it runs, so `arm && git commit` in one call is blocked. Write the paths and flags out literally, as `body-path`, `comment-path` and `attach-args` printed them; the guard cannot see through a `$(...)` substitution. Disarm even when a step fails. Report the PR URL from `gh pr create`, or the comment URL.

### 4b. Mutation, after the push

When `mutation.enabled` is true in `~/.claude/config/quality.json` and app PHP files changed: right after the push (and the PR or comment steps), start `~/.claude/hooks/mutation.sh` as a background task from the same working tree, then go on to steps 5 through 7 without waiting. It mutates only the lines this diff added (the receipt names the scope; `whole class` means the line scope did not load). Its budget is `mutation.timeout_seconds`. Mutation is advisory: no result blocks the PR or asks the user to wait. The receipt, when the notification arrives:

- GREEN: every mutant ran and the score is at or above `min_msi`. Report it in one line.
- PARTIAL: the budget ran out first and no survivor sits on an added line. It does not block, but it is not verified: report it as `mutation PARTIAL n/N` on the "could not verify" list, never as a bare score.
- RED: report the surviving mutants with `added` or `pre-existing` per line, and offer once to strengthen the tests for the added ones (verify, then this skill again pushes a follow-up). Do not do it unasked.
- SKIP (disabled, no class changed, or no added lines): one line.

If the tree changes before the notification arrives, the result describes the committed state only; say that next to the result.

### 5. Plan file

If a plan exists: set its Status to `in progress`, and when it has phases, set the current phase's Status to `PR opened <url>`. Append a status-log line.

### 6. Draft of "What and Why"

New PR only. Print one fenced markdown block for that section. Keep it short. Where only the author can answer, leave a prompt in angle brackets rather than an invented answer: the why, what the reviewer should look at hardest, anything risky. No robot footer, no tagline.

### 6b. Corrections, in three tiers

List what the user corrected during this task: a reverted change, a rejected approach, a wording they struck, a question they had to answer twice. For each, name the tier and act:

- It belongs to one workflow (a planning habit, a review-findings habit): append one line to that skill's file under a "Learned" heading. Loaded only when the skill runs.
- It spans workflows: write a feedback memory with a why line and a how-to-apply line, and one index line. Only the index line loads each session.
- It happened before and applies to every task: propose one sentence for CLAUDE.md through AskUserQuestion. Write it only on yes. CLAUDE.md stays under a page.

No corrections: say so in one line.

### 6c. Task report

Run `~/.claude/hooks/harness.sh report task <diff sha saved in step 1>` so the page for this task exists and opens; after the commit the tree is clean and the sha can no longer be derived. Name its path in the summary.

### 7. Summary

PR URL (or the comment URL), branch, commit sha, the route used (WSL or Windows), staged files, files left in the tree, the "Done when" lines with their proof, the QA result per scenario or why none ran, how many screenshots were attached, the corrections and where each went, the path of the task report page, the mutation result or `mutation running (advisory)`, and, for a new PR, "What and Why drafted above, left blank on the PR".

## Learned
- `handoff.sh commit` stages the named files but keeps anything already staged. Before it, run `git diff --cached --name-only`; when the index holds files outside the plan, `git reset -q -- <those>` first and `git add` them back after the commit, so the commit carries only this work. The owner said: do not commit files you did not create.
