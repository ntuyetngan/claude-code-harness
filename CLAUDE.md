# Working style (every repo)

## Scope
- Make the minimal diff that satisfies the request. No extra guards, refactors, renames,
  docblock edits, or "while I was here" changes. If adjacent code needs work, list it and ask.
- No inline explanatory comments. Rationale goes into docs. Docs never carry line numbers,
  ticket numbers, test counts, or bug narratives.

## Plan amendments
- The plan's file list is a contract that may grow. A file the work turns out to need goes into the
  plan under "Discovered during implementation" with the reason and what revealed it, then it is
  edited. Callers, factories, helpers, types: add and continue. New surfaces, migrations, schema or
  config, payments, auth, venue privacy: add, then ask first. Never work around a missing file to
  keep the diff inside the plan, and never edit a file without adding it.

## Claims need evidence
- Findings, Sentry issues, and tickets are claims. Confirm the branch, read the current code,
  classify, report, and wait for "go" before editing.
- A statement about repo state quotes `git status`. When work looks missing after a branch switch,
  also quote `git stash list` (GitHub Desktop stashes on switch) before recreating anything.
  A root cause names the line and shows the command output that proves it.
- A test failure the user pasted from their own run on the current branch, whose fix touches only
  tests/, is not a claim to gate: report the cause with evidence, then edit and /verify without waiting.
- Pasted review findings whose request is to verify and fix are not gated either: verify each against
  the current code, fix the still-valid ones on the current branch, skip the rest with a reason, then
  /verify without waiting. Never create a branch or open a new PR for them; /handoff only pushes when
  the branch already has a PR. A finding that needs a design choice or a material file (per Plan
  amendments) still asks first.

## Verification
- Suites run only through `~/.claude/hooks/verify.sh` and `mutation.sh`, started as background tasks
  (the Bash tool caps a foreground call at 10 minutes; pest alone runs longer); wait for the completion
  notification, never poll. Never background git; never run pest, phpstan, phpcs, vitest or vue-tsc by hand.
- Choosing which tests to run is your judgment: read the callers of what changed and name the tests
  that exercise them. Running them and proving it is the script's job (/verify). Any Vue or TS spec
  needs vitest and vue-tsc. PHP needs pest, phpcs, phpstan on the changed files. Test filters go in
  single quotes.
- "Done" means a GREEN/RED table plus an explicit "could not verify" list. A RED row is never
  described as verified.

## Git
- Commits and pushes happen only through /handoff. Never stash, never force, never to master.
  The PR body is the repo template with "What and Why" left blank; /handoff fills the rest and
  attaches the QA screenshots with gh --attach.

## Environment (WSL, repo on /mnt/c)
- Node tools run after `source ~/.nvm/nvm.sh && nvm use 24`. When preflight says node_modules
  is Windows-built, run vitest and vue-tsc through Windows node (`/mnt/c/nvm4w/nodejs/npm.cmd`)
  instead. Never npm install from WSL. If npm or a registry token fails, stop and say so.
- The preflight table at session start is the environment truth. Do not rediscover it by
  retrying failed commands. Re-run it with /preflight after fixing something.

## Guarded areas
- nuxt/, database/schema/ and secrets are blocked by a hook. In /sentry-fix and /review-findings the
  regression test is locked once written; every other test file stays editable.

## Skills
- /planner before non-trivial changes. Its approval is the one gate: after it, implement, then run the
  verify, audit and handoff skills yourself, in that order, and ask only on a deviation from the plan.
  The user's next stop is the PR. /verify, /audit, /handoff by hand run one step alone. /quality for
  the CRAP and mutation gates by hand. /harness off|on switches the hooks on this machine; CLAUDE_LOOP=off
  at launch starts one session without them.
