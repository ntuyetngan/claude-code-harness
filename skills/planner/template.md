# <slug>: <one-line title>

Source: <Linear TEAM-nnnnn url | Sentry short id url | "ask">
Repo: <repo>
Branch: <YYYYMMDD-task-slug, created by /handoff>
PR title: <[TEAM-nnnnn|SENTRY-ID|No Linear][Area] Description>
Status: draft | approved | in progress | done | dropped
QA: required | not needed   <!-- browser run on the dev host before handoff; asked during planning -->
Created: <YYYY-MM-DD>
Current phase: <n of N, or "single">

## Intent
<the larger task this serves, who it is for, what the output enables>

## Goal
<one or two sentences, confirmed by the user>

## Expected output
- <deliverable: code path, behavior, test, docs page>
- <...>

## Done when
- <observable proof, one per line>

## Surfaces
| Surface | Handles | In / Out | Why |
| --- | --- | --- | --- |
| <path> | <what it renders or handles> | in | <reason> |
| <path> | <...> | out | <reason, e.g. legacy, not in ask> |

## Files that change
- `<path>` — <why>
- `<tests/...>` — <what it proves>
- `<docs/...>` — <rationale that lands here instead of inline comments>

## Pattern mirrored
`<path>` — <how it solves the same shape>

## Discovered during implementation
<!-- Files the plan did not name but the work needed. Add each one here AND under "Files that change".
     A caller, factory, helper or type: add it and continue. A new surface, migration, schema or config
     change, or anything under payments, auth or venue privacy: add it, then ask before touching it. -->
- `<path>` — needed because <reason>; revealed by <test name or error>

## Out of scope
- <noticed, deliberately not done>

## Assumptions
- <assumption> — confirmed by user | verified in `<path>`

## Options not taken
- <alternative> — <why the chosen approach wins under the named constraint>

## Risks
- <what could break, and how the proof catches it>
- Riskiest step: <which, and why>

## QA scenarios
<!-- Only when QA is required. One line each, from "Done when": what to open, what to do, what must be true.
     Prefixes: "as: main" (the account holder), "as: staff" (any /admin page), "as: guest" (Checkout v2); "recipe: <name>" to build the data on the dev box first;
     a line that needs a payment-gateway action reads "not browser-testable: <reason>" instead of steps
     (see ~/.claude/hooks/qa-recipe.sh list); "page: <name>" for a named page from projects.json qa.pages. -->
- as: main — recipe: <name> — <url, page: name, or a URL the recipe returns> — <action> — <expected>

## Proof
- `<command with single-quoted --filter>` — <what it must show>
- Regression test to add: `<TestClass::test_name>` — fails before the fix because <reason>
- Frontend: vitest on `<spec>` plus `npm run type-check`

## Phases
<!-- Only when the work needs more than one PR. Each phase is one PR, mergeable on its own,
     and safe on production while every later phase is still unmerged. Delete this section
     for single-PR plans. -->

### Phase 1 of N: <title>
PR title: `[TEAM-nnnnn][Area] <short description>`
Branch: <branch>
Status: not started | in progress | PR opened <url> | merged
Depends on: none | phase <n> merged on production
Files: `<path>`, `<path>`
Safe while later phases are unmerged because: <reason: both deploy tiers tolerate this state>
- [ ] <step, one edit or one test>
- [ ] <step>
- [ ] Proof: `<command>` shows <result>
- [ ] Docs: `<docs/...>` updated

### Phase 2 of N: <title>
PR title: `[TEAM-nnnnn][Area] <short description>`
Branch: <branch>
Status: not started
Depends on: phase 1 merged on production
Files: `<path>`
Safe while later phases are unmerged because: <reason>
- [ ] <step>
- [ ] Proof: `<command>` shows <result>

## Status log
- <YYYY-MM-DD HH:MM> draft written
