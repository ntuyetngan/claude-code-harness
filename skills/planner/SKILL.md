---
name: planner
description: Turn a ticket, Sentry issue, feature ask, or bug report into an approved plan file before any code changes. Enters Plan Mode itself, confirms the goal and expected output first, sweeps every surface the change touches, asks with AskUserQuestion whenever a decision or uncertainty remains, never guesses, and hands the finished plan to Plan Mode's own approval. That approval is the one human gate before the PR: after it the session implements, verifies, audits, runs browser QA and hands off by itself, asking only on a deviation. Manual-only; invoke as "/planner ZAI-12345", "/planner <sentry url>", or "/planner <ask>". Pasted review findings belong to /review-findings, not here.
argument-hint: '[ZAI-nnnnn | sentry issue | short ask]'
disable-model-invocation: true
---

# /planner

Produce a plan the user can approve without reading the conversation. The plan is a contract: the diff judge and the stop gate later read it, so every file, surface, and proof it names must be real.

## Non-negotiable rules

- **Enter Plan Mode first.** If Plan Mode is not active, call `EnterPlanMode` before anything else. It asks the user for consent; if they decline, stop.
- **Never edit, create, or delete anything in the repo.** The only files this skill writes are the Plan Mode plan file and its copy under `~/.claude/plans/`.
- **Never guess.** Any decision, ambiguity, or uncertainty that would change the plan goes to the user through AskUserQuestion. A plan built on an assumption is a plan built wrong.
- **Never ask what the repo already answers.** Stack, conventions, sibling patterns, existing tests, and route structure come from reading, not asking.
- **Be certain of the goal and the expected output before interviewing.** Restate them and get confirmation.
- **No commits, no branches, no git writes.** Reading git is fine.
- If the input is a batch of review findings, stop and point to `/review-findings`.

## Workflow

### 1. Intake

Read `$ARGUMENTS`.

- `ZAI-nnnnn` → fetch the issue through the Linear MCP: title, description, comments, attachments, linked branch or PR.
- A Sentry URL or short id → fetch it through the Sentry MCP: title, stack trace, affected release, event count.
- Free text → the ask itself.
- Nothing → ask what to plan, one question.

Record the branch with `git branch --show-current`. If the ticket names a branch and it differs, ask which one the plan is for.

Continuing a plan: if `~/.claude/plans/<repo>/<slug>.md` already exists for this input, read it before anything else. Show its phase table (phase, status, PR) and ask through AskUserQuestion whether to continue with the next unfinished phase, restart the plan, or drop it. On continue: verify the earlier phases really merged (`git log`, `gh pr view`), re-check the phase's files against the current branch since merged phases may have moved code, revise its checklist only if something changed, set its status to in progress, and hand it to `ExitPlanMode` as the plan for this session. Do not re-interview for decisions the file already records.

Size check: if the whole diff can be described in one sentence (a typo, a log line, a rename), say so and offer to skip the plan. Plan only when the approach is uncertain, several files change, or the area is unfamiliar.

### 2. Short read

Spend a bounded pass on the code, not an investigation: the entry points the ask names, the nearest sibling feature that already solves the same shape, the tests that cover the area, and the `docs/` page for it if one exists. Stop when you can state the goal, the output, and the pattern to mirror. If root cause is unclear for a bug, note that; the tracer agent does deep traces, not this step.

### 2b. Brief completeness check

Read `brief-checklist.md` in this skill's directory. For each of its eleven fields, mark it filled (from the ask, the ticket, the Sentry issue, or the short read) or missing. Fill from sources first; never fill from assumption. Every field still missing after that goes to the user in the goal-contract question or in one follow-up batch. Record the filled brief at the top of the plan file so an engineer who never saw the conversation has the same information.

### 3. Goal contract

One AskUserQuestion, before any interview. Restate in your own words:

- **Goal**: what changes for the user or system.
- **Expected output**: the concrete deliverables, each on its own line. Code paths, behavior, tests, docs page.
- **Done when**: the observable proof.
- **Branch and PR title**: the branch `YYYYMMDD-<task-slug>` (today's date, a short kebab-case slug) and the title `[ZAI-nnnnn][Area] Description`, `[<SENTRY-SHORT-ID>][Area] Description` or `[No Linear][Area] Description`, Area being the repo's prefix for that surface (POS, ZCS, Nerv, Microsite). Confirming the contract confirms both; /handoff uses them without asking again.

Offer "That is right" first, then one or two alternative readings you consider plausible. If the ask could mean materially different work, each reading is an option. Do not proceed until one is confirmed; "Other" answers replace your restatement verbatim.

### 4. Surface sweep

Find every place the change has to land, so nothing is missed the way one performers section, a receipt list, or a banner has been missed before.

- Grep the feature's identifiers across `app/`, `resources/`, `routes/`, `legacy/`, `legacy_public/`, `nuxt/`, `database/`, and `tests/`. Use fixed-string greps for names and route keys.
- List each surface with one line: path, what it renders or handles, and **in** / **out** / **unsure**.
- Every **unsure** surface goes into one AskUserQuestion, multi-select, at most four per question. Never decide a surface silently.
- Surfaces under `legacy/`, `legacy_public/`, and `nuxt/` default to **out** and are named explicitly so the user can pull them in.

### 5. Interview

Only decisions that change the plan. Compact batches of three to five strong questions, each with the consequence of each option in its description, recommended option first and marked. Typical questions:

- Which of two existing patterns to mirror, when both exist.
- Behavior at an edge the ticket does not cover.
- Whether a noticed adjacent problem is in scope. Default is out.
- Feature flag or no flag, when the repo uses one nearby.
- Which docs page takes the rationale.
- Whether the change needs a browser run on the dev host before handoff (a QA receipt). Ask it whenever the change touches something a person sees or clicks: Vue, Blade, routes, controllers, middleware, mail. Record the answer in the plan as `QA: required` or `QA: not needed`, with the scenarios to check when required, drawn from "Done when". Say in the question that `required` also approves copying the changed files to the dev box for that run, and running any migration the plan adds there; plan approval is the only approval the sync gets. Pick each scenario's account from its route: `as: staff` for anything under `/nerv`, `as: main` for the account-holder surfaces, `as: guest` for Checkout v2. A scenario that needs a payment-gateway action (a real refund, charge or payout) is not browser-testable on the dev box: write it as `not browser-testable: <reason>` under QA scenarios, so it is not discovered at QA time.

Do not ask for: stack details, conventions visible in nearby code, restatements, or preferences that do not change the plan. If nothing is uncertain after the sweep, skip this step and say so.

### 6. Write the plan file

Write the plan to the plan file Plan Mode names in its system message, so `ExitPlanMode` can show it. Save an identical copy at `~/.claude/plans/<repo>/<slug>.md`, where `<repo>` is the basename of `git rev-parse --show-toplevel` and `<slug>` is the ticket id, else the Sentry short id, else a kebab-case slug of the ask. The copy is the stable path the diff judge and the stop gate read later. Overwrite an existing copy for the same slug only after asking.

Use the template at `~/.claude/skills/planner/template.md`. Rules for the content:

- **Files that change**: one line per file, path plus why. Include the test files and the docs page. The list is the contract, and it may grow: a file the work turns out to need is added here and under "Discovered during implementation" with the reason and what revealed it. A caller, factory, helper or type is added and work continues. A new surface, a migration, a schema or config change, or anything under payments, auth or venue privacy is added and the user is asked before it is touched. A file edited without being added is incidental.
- **Pattern mirrored**: a real path. The implementation copies how that code solves the same problem.
- **Out of scope**: everything noticed and deliberately not done, so it is not "while I was here" work later.
- **Proof**: the exact suites and filters to run, and the regression test names to add. For a bug fix, the test is written and shown failing before the fix.
- **Minimal diff**: the plan itself must not include extra guards, refactors, renames, docblock edits, or inline comments. Rationale goes to the docs page named in the plan.
- **Assumptions**: every assumption the plan rests on, each marked confirmed (by the user) or verified (by a file the plan names). An unmarked assumption is a question not yet asked.
- **Simplicity check**: for every helper, abstraction, flag, fallback, or validation the plan adds, state why the simpler version fails a named constraint. If it does not, remove it.
- **Scope breadth**: when a change applies to several instances of the same surface, say "every X, not only the first" and list them.
- No line numbers in the plan; paths and identifiers only.

- **Phases, when one PR is not enough.** Split into phases when the repo's deploy rules require sequenced PRs (column renames, anything both deploy tiers must tolerate in a half-finished state), when the diff would not be reviewable as one PR, or when a later step depends on an earlier one being on production. Each phase is one PR with its own title in the repo's prefix format, its own branch, its files, a checklist of steps small enough to tick one at a time, its own proof, and a line saying why production stays safe while later phases are unmerged. Propose the split through AskUserQuestion before writing it: the phase boundaries are a decision. Single-PR plans delete the Phases section.
- **The checklist is live.** During implementation, tick each step in the `~/.claude/plans/` copy as it completes, and set the phase status when its PR opens and when it merges. A future session continues from the first unticked step.

Then critique the draft before showing it, in three questions: what could break, which step is the riskiest, and which options were not taken and why. Write the answers into the Risks and Options-not-taken sections. The bar for the plan: an engineer who has never seen this conversation could implement the change from the file alone.

### 7. Approval

Call `ExitPlanMode`. It shows the plan file and asks the user to approve or send it back. Do not ask "is this plan okay?" through AskUserQuestion; that is what `ExitPlanMode` does.

- Approved: set `Status: approved` and append a status-log line in the `~/.claude/plans/` copy. Then the loop runs without another prompt: implement the files the plan names (or the current phase's files), then invoke the `verify` skill, then `audit`, then `handoff`, which runs browser QA when the plan requires it and opens the PR. Stop and ask only on a deviation: a guarded path that needs an allow, a material file the plan did not name, a RED suite that a fix does not turn GREEN, a "Done when" line with no proof, browser QA RED or BLOCKED, a changed file outside the plan. The next thing the user reads should be the PR URL and the draft of "What and Why".
- Sent back: apply the user's note to both files, then call `ExitPlanMode` again.
- Told to drop: set `Status: dropped` in the copy and stop.

## Calibration

- Small, localized task (about three files, clear proof): compact plan, goal contract plus approval may be the only questions.
- Cross-cutting or risky task (auth, payments, permissions, migrations, data deletion, schema, concurrency, public API, legacy surfaces): fuller sweep, more questions, explicit risks section.
- Bug fix from Sentry: include the failing regression test in Proof; if root cause is not established by the short read, say so and plan the tracer step first rather than guessing the cause.

## Refinement behavior

- Asked to refine, reduce, compare options, or challenge assumptions: stay in Plan Mode and revise the file.
- Asked to implement while the skill is active: stay in Plan Mode and say implementation starts once the plan is approved through `ExitPlanMode`.

## Learned
- QA scenario lines for any `/nerv` page use `as: staff` (qa-staff@zaiko.dev, super admin on the dev DB); `as: main` is a gmail account and Nerv answers it with 404.
- A "doesn't display right on mobile" ticket under a parent with a Figma mobile frame: fetch that frame before the goal contract and offer the design as a reading; the user chose the Figma cards over the minimal scroll fix (ZCS monthly payout).
- A layout choice the repo already answers (breakpoint, CSS vs JS switch) is researched, not asked: count the sibling patterns (`md:hidden` in zcs/) and state the one you follow.
- Before planning a JS module for control icons, grep the stylesheet for an existing icon pattern; zaikolive draws video.js icons as SCSS data-URI mask-images ($theater-mode-icon-*), and the user chose that over the planned playerIcons.js (player UI v2, 2026-10-08).
- A layout-bug QA scenario reproduces the exact state in the ticket screenshot (ZAI-16342: Currency was also a select, which needs events in two currencies), names the recipe that builds that state, and asks for wide screenshots framed like the ticket plus a close-up. A scenario that only shows the fixed element in a different state was rejected by the user.
