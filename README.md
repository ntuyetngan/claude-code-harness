# claude-code-harness

A personal engineering loop for Claude Code, built for a Laravel + Vue/Inertia repo worked on from WSL with the code on `/mnt/c`. It turns one approved plan into a pushed branch and an open PR, and refuses to let the session skip the steps in between: tests, review, browser QA and a human-written PR summary.

The repo mirrors the layout of `~/.claude/`: `hooks/`, `skills/`, `agents/`, `config/`, `CLAUDE.md` and the `hooks` block of `settings.json`.

## The loop

```
/planner  ──►  implement  ──►  /verify  ──►  /audit  ──►  /handoff (+ /qa)  ──►  PR
   ▲ the one human gate                                         you write "What and Why"
```

1. **/planner** turns a ticket, Sentry issue or bug report into a plan file in Plan Mode: goal, files to touch, tests, branch name, PR title and whether browser QA is required. Plan approval is the only approval the rest of the loop needs.
2. **Implement.** The session edits the files the plan names. A file it turns out to need is added to the plan before it is edited.
3. **/verify** maps the diff to the suites it requires (Pest, PHPStan, PHPCS for PHP; Vitest and vue-tsc for Vue/TS), runs them as one background task and writes one receipt per suite keyed by the diff hash. It prints a GREEN/RED table and a "could not verify" list.
4. **/audit** dispatches the read-only `reviewer` agent, which scores every finding 1 to 10. Findings above 5 are fixed with the minimal diff and re-verified, for at most two rounds; the rest are listed.
5. **/handoff** checks the receipts and the audit, runs **/qa** when the plan requires it, commits, pushes, and opens the PR with the repo template filled in except "What and Why", which it drafts for you to write in the browser.

## Skills

| Skill | What it does |
|---|---|
| `/planner` | Ticket or bug report to an approved plan file. |
| `/verify` | Runs the suites the diff requires; writes receipts. |
| `/audit` | Score-then-fix review loop over the working tree. |
| `/audit-diff` | Compares the diff with the plan, labels each file requested or incidental, offers to revert incidental ones. |
| `/handoff` | Commit, push, open the PR, attach QA screenshots. On a branch that already has a PR, pushes and comments instead. |
| `/qa` | Syncs the changed files to the dev box and drives headed Chrome through the plan's scenarios. |
| `/sentry-fix` | Sentry issue to a verified, uncommitted fix, with the regression test written first and then locked. |
| `/review-findings` | Verifies pasted or PR review findings, fixes the valid ones, answers bot threads. |
| `/quality` | CRAP and mutation gates on demand; read or change their thresholds. |
| `/preflight` | Re-runs the environment check. |
| `/harness` | Turns the hooks off or on for this machine, shows status, builds the task and weekly report pages. |

## Agents

All four are read-only and are dispatched by the skills, not by hand.

| Agent | Role |
|---|---|
| `reviewer` | Scores findings in the diff 1 to 10 with a fixed rubric. |
| `verifier` | Classifies one review finding as VALID, ALREADY_FIXED, STALE_FILE or INCORRECT_CLAIM. |
| `tracer` | Follows a stack trace or bug report to the failing line and reports the cause with evidence. |
| `qa-runner` | Runs one QA brief in headed Chrome with playwright-cli and returns screenshots and console evidence. |

## Hooks

| Event | Hook | Effect |
|---|---|---|
| SessionStart | `preflight.sh` | Prints a GREEN/RED environment table (branch, git lock, GitHub reachability, gh auth, AWS, Docker containers, dev box). Starts Docker and applies pending test migrations on its own. |
| PreToolUse (Bash) | `git-guard.sh` | Blocks stash, force or delete pushes, pushes to `main`/`master`, destructive resets and cleans, and inline PR bodies or comments. Commit and push are allowed only while `/handoff` has armed it, for 30 minutes. |
| PreToolUse (Bash) | `background-guard.sh` | Git never runs in the background; test and lint tools run in the background only through the harness scripts. |
| PreToolUse (Edit/Write) | `path-guard.sh` | Secrets (`.env*`, `*.key`, `*.pem`, `auth.json`) are never editable. During a test-first fix the regression test is locked. Repo-specific areas (`nuxt/`, `database/schema/`) are blocked and `legacy/` and non-English locale files warn. |
| PostToolUse (Edit/Write) | `post-edit.sh` | Fixes mixed line endings, formats PHP and reports PHPCS violations on the edited file. |
| Stop | `stop-gate.sh` | Refuses to end a turn that changed code until every required suite has a receipt for the current diff. Refuses once per diff, so a broken environment cannot trap the session. When an approved plan exists, `diff-judge.sh` has a separate model compare the plan with the diff. |

## Quality gates

Thresholds live in `config/quality.json`.

- **CRAP** per changed method, computed from Pest coverage during `/verify`. Above the maximum is RED only when the diff made the method worse; otherwise it is listed as debt.
- **Mutation testing** with Pest's `--mutate`, limited to the lines the diff added. Runs at handoff and is advisory.
- Pest runs in shards, each on its own test database, and the coverage is merged afterwards.

## Configuration

| File | Purpose |
|---|---|
| `config/projects.json` | Per repo, keyed by directory name: dev box ssh settings, which files to sync, which Windows frontend builds to run, QA base URL and named pages. |
| `config/qa-accounts.json` | QA logins per repo, environment and role. Keep it mode 600 and out of version control once filled in. |
| `config/quality.json` | CRAP, mutation and Pest shard settings. |
| `settings.json` | The `hooks` block to merge into `~/.claude/settings.json`. |
| `CLAUDE.md` | The working rules the session follows: minimal diffs, evidence for claims, plan amendments, verification and git rules. |

## Setup

1. Copy `hooks/`, `skills/`, `agents/` and `config/` into `~/.claude/`, and `CLAUDE.md` to `~/.claude/CLAUDE.md`.
2. Merge the `hooks` block of `settings.json` into `~/.claude/settings.json`.
3. Fill in `config/projects.json` for your repo (rename `example-repo` to the repo's directory name) and `config/qa-accounts.json`.
4. In `hooks/path-guard.sh`, replace `your-org/your-repo` with your repo's remote to enable its area guards.
5. For the dev box, export your key to OpenSSH format and run `hooks/devbox-key.sh <key> <user@host> [port]`.
6. Start a session; the preflight table shows what is still missing.

Requirements: WSL, `jq`, `gh`, PHP with Pest, PHPStan and PHPCS in the target repo, Node via nvm for Vitest and vue-tsc, Docker for the test database, and `playwright-cli` for `/qa`.

## Turning it off

`/harness off` skips preflight, the guards, the post-edit hook and the stop gate on this machine until `/harness on`. `CLAUDE_LOOP=off` at launch skips them for one session. The skills still run on demand.
