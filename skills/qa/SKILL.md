---
name: qa
description: Run the plan's browser QA scenarios against the dev box. Copies only the changed files to the box (a tar stream over ssh, after a Windows frontend build when needed), then drives the loop's own qa-runner agent through each scenario and writes a qa receipt with evidence. Runs by itself inside /handoff when the plan says QA is required, or when you agree to it for a frontend change; also runnable by hand as "/qa", or "/qa --no-sync" when the box already has the change. Reports BLOCKED, with the reason, when playwright-cli or the dev-box settings are missing.
argument-hint: '[--no-sync] [--no-build] [--from-handoff]'
allowed-tools: Bash(~/.claude/hooks/devsync.sh *) Bash(timeout * ~/.claude/hooks/devsync.sh *) Bash(~/.claude/hooks/qa-account.sh *) Bash(~/.claude/hooks/qa-recipe.sh *) Bash(timeout * ~/.claude/hooks/qa-recipe.sh *) Agent
---

# /qa

Prove the change works where a person would see it, not only in tests. Settings per repo are in `~/.claude/config/projects.json`.

## When it runs by itself

Only from `/handoff`, which invokes this skill with `--from-handoff`. Plan approval already approved the copy to the dev box (the planner says so when it asks about QA), so this skill does not ask again. Never start a browser run from any other skill or hook; a browser run is slow and visible, and the plan decides whether it is needed.

## Non-negotiable rules

- Never against production. The base URL comes from the project's `qa.base_url`; a `*.zaiko.io` host stops the skill.
- The dev box receives only the files this diff touched, plus built assets. Nothing is deleted there.
- Every scenario gets its own self-contained brief. The qa-agent cannot ask questions.
- A scenario that cannot run is BLOCKED with the reason, never marked passed.
- A scenario that needs a payment-gateway action (a real refund, charge or payout) is not browser-testable on the dev box; the planner marks it so, and it is recorded BLOCKED with that reason, never staged with a fake.
- No commits, no pushes.

## Workflow

### 1. Scenarios

Find the plan for the branch (`find_plan` in `~/.claude/hooks/lib.sh`). Take its `## QA scenarios` lines. No plan or no scenarios: write them yourself from the change, one per user-visible behavior, and show them before running (with `--from-handoff`, /handoff has already shown the changed files, so show the scenarios in one line each and continue). Each scenario: the URL or page, the steps, the expected result.

### 2. Preconditions

- `playwright-cli --version`. Missing: write the receipt `qa.json` in the verify receipt directory for this diff with `{"status":"BLOCKED","reason":"playwright-cli not installed"}` and stop with that one line.
- `~/.claude/hooks/devsync.sh --list` shows what would be copied and whether a Windows build runs first. The list is this session's changed files (the verify map's scope), not every dirty file in the tree. An entry with `CHANGE_ME` in it means the project settings are incomplete: BLOCKED with the field name. After the copy, devsync compares every build manifest with the box (a mismatch fails the sync: the box would serve a stale bundle) and runs each new migration in the change with `--path`; `--no-migrate` skips that.

### 3. Sync

Unless `--no-sync`: without `--from-handoff` and without an approved plan that says `QA: required`, show the list from step 2 and ask once per session through AskUserQuestion before the first copy to the box. Then run `~/.claude/hooks/devsync.sh` in the foreground with a 40 minute timeout (the Windows build is the slow part). A failed build or copy stops here.

### 3b. Accounts, saved logins, pages and recipes

The scenario line says what it needs; the loop resolves it before the browser opens.

- **Account** (`as: main`, `as: guest`): `~/.claude/hooks/qa-account.sh <role>` prints the login, the password and the saved-state file for this repo and environment. The file is `~/.claude/config/qa-accounts.json`, mode 600, filled in by the user; `qa-account.sh list` shows which roles have a password. An account with no password stops with "fill in `<role>` in qa-accounts.json". `guest` is not a login: it means Checkout v2 with a throwaway email on a real domain. The login and password go only into the agent brief, never into the summary, the receipt, the plan or a page.
- **Staff scenarios** (`as: staff`): any page under `/nerv` needs a Zaiko staff login; for anyone else it answers 404. `User::isZaikoStaff()` needs both a staff team row (`staff_user_teams`) and an email domain from `config('staff.email-whitelist')`: `zaiko.io` always, and `zaiko.dev` only when `APP_ENV` is local or testing (the dev box runs `local`, with no Google login for zaiko.dev). A gmail account can never be staff, whatever team it is on. The dev role is `qa-staff@zaiko.dev`, on staff team 1 (`super_admin`). If it is missing on a fresh dev DB, recreate it idempotently: copy a PHP file to the box and run it with `php artisan tinker --execute="require '/tmp/file.php';"` (never `tinker <file>`, which drops into the interactive prompt and hangs). The file does `User::where('email', …)->first() ?? User::factory()->create([...])`, sets the password from an env var (never on the command line), runs `$user->staffTeams()->syncWithoutDetaching([1])` and echoes `isZaikoStaff()`. Then add or keep the `staff` role in qa-accounts.json. Planner scenario lines for Nerv use `as: staff`, not `as: main`.
- **Saved login state**: when `state_exists` is true, the brief starts with `playwright-cli state-load <state_file>` and only falls back to the login form if the page shows the user logged out; after any fresh login the brief ends with `playwright-cli state-save <state_file>`, so the next run skips the form. When the state is missing, the brief logs in with the credentials and saves the state. **The brief always carries the email and password, state or no state**: a state older than the app's session lifetime (about a day on dev; `state_age_minutes` says how old) is expired, and a runner without the password can only report BLOCKED.
- **A non-staff login the form rejects is fixed, not reported.** When a group's runner reports BLOCKED because the login form rejected a non-staff account (`main`, or any role whose email is not on a staff domain), or the account does not exist: run `~/.claude/hooks/qa-recipe.sh run ensure-account EMAIL=<email> PASSWORD=<password>` with the values from `qa-account.sh <role>`. It resets the dev account's password to that one, restores it if soft-deleted, or creates it when missing. Delete the role's `state_file`, then dispatch that group once more. Only when `password_ok` is false, the recipe fails, or the second run is rejected again is the group BLOCKED, with the recipe output as the reason. Staff accounts keep the staff path above. A recreated account owns no ZCS profile: for a ZCS scenario, also run `qa-recipe.sh run zcs-profile-admin EMAIL=<email> FEATURES=<profile feature switches the page needs>` and use the `zcs_base_url` it prints.
- **Browser config**: every brief names `qa.browser_config` from `projects.json` as the config file; the qa-runner agent puts `--config <file>` on every `open`. Its Chrome flag pins `*.zaiko.dev` to the dev box; without it the public wildcard DNS sends microsite subdomains to another dev stack and the page loads with the wrong build (blank body, asset 404s from cdn.zaiko.dev). The agent refuses a brief without it.
- **Pages** (`page: <name>`): `qa.pages` in `~/.claude/config/projects.json` maps names to paths; `{placeholders}` are filled from the recipe result or the scenario. A name that is not there stops the scenario as BLOCKED with the name.
- **Recipes** (`recipe: <name>`): `~/.claude/hooks/qa-recipe.sh run <name> KEY=VALUE...` copies the recipe's PHP to the dev box and runs it inside `php artisan tinker`, which builds the data with the repo's factories and models (an approved online event with a ticket on sale, say) and prints one JSON line of ids and URLs. `qa-recipe.sh show <name>` explains what it builds, its inputs and the browser steps that follow; `list` names them all. The JSON's URLs go into the brief. A recipe that fails is a BLOCKED scenario with the recipe's output. Recipes run against the dev box's database and clean up nothing; they tag what they create with a `qa-` prefix in names so it can be found.

### 4. Run

Group the scenarios by account (`as: main`, `as: staff`, `as: guest`) and dispatch the `qa-runner` agent (`~/.claude/agents/qa-runner.md`, the loop's own copy of the repo's qa-agent with the dev-box rules built in) once per group, with one brief holding every scenario of that account in order, so the login and the state-save happen once per account instead of once per scenario. The brief contains: the base URL, the config file path, the account from step 3b (email, password, state file path, whether it exists) or the guest path, the recipe's URLs when one ran, the exact steps, the expected result, and the evidence path `.qa-evidence/<engine>-<scenario slug>.png`. The agent handles the config flag, the state load and save, and the dev-tooling console noise itself; the brief does not repeat those rules. At most one agent at a time; a headed browser cannot be shared. Collect each report as PASS, FAIL or BLOCKED with the agent's evidence and console or network notes.

### 5. Receipt and summary

Move the evidence files from `.qa-evidence/` into `<receipt dir>/qa/` so nothing is left in the tree, and write `qa.json` there: `{"status": "GREEN"|"RED"|"BLOCKED", "scenarios": [{"scenario","status","evidence","notes"}]}`. GREEN only when every scenario passed.

Summary: one line per scenario with its status and evidence path, then the receipt path. A RED scenario names what the agent saw versus what was expected, so the fix is obvious.
