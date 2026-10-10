---
name: quality
description: Run the code quality gates on demand, or read and change their thresholds. Gates: CRAP per changed method, mutation testing on the changed classes, or both, with the same scripts, thresholds and receipts as the automatic gates. Thresholds: "/quality show", "/quality set crap 25", "/quality set mutation 70", "/quality mutation off|on". Manual-only; run as "/quality crap", "/quality mutation", "/quality all", optionally with --pest 'tests/Feature/FooTest.php' to name the tests.
argument-hint: "[crap | mutation | all | show | set crap N | set mutation N | mutation on|off] [--pest 'paths']"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/hooks/verify.sh *) Bash(~/.claude/hooks/mutation.sh *) Bash(~/.claude/hooks/quality-config.sh *) Bash(timeout * ~/.claude/hooks/verify.sh *) Bash(timeout * ~/.claude/hooks/mutation.sh *)
---

Parse `$ARGUMENTS`. Threshold commands come first:

- `show`: run `~/.claude/hooks/quality-config.sh show` and print its output unchanged. It lists the current thresholds and the last runs from the history file, so a change can be based on real numbers.
- `set crap <number>` or `set mutation <percent>`: run `~/.claude/hooks/quality-config.sh set crap <number>` or `... set mutation <percent>`. Print its one line. A lower CRAP max or a higher mutation minimum is stricter. Do not run a gate afterwards unless asked.
- `mutation on` or `mutation off`: run `~/.claude/hooks/quality-config.sh mutation on|off`. Off keeps the threshold and makes /handoff record SKIP for the gate.

Otherwise the first word is `crap`, `mutation` or `all` (default `all`); a `--pest 'paths'` pair, if present, is passed through to both scripts.

- `crap`: run `~/.claude/hooks/verify.sh --only crap [--pest 'paths']` from the repo root, foreground, 30 minute timeout.
- `mutation`: run `~/.claude/hooks/mutation.sh [--pest 'paths']` from the repo root, foreground, 45 minute timeout.
- `all`: crap first, then mutation.

Show each script's output unchanged. Then one line per gate: GREEN or RED, the score, and for RED what would turn it GREEN: cover or split the named method for CRAP, strengthen the tests that should have caught the named surviving mutants for mutation. Do not retry a RED gate with the same inputs, and do not describe the work as verified on a RED result.

Both gates score only the change against the merge base with master: CRAP on methods whose lines the diff touched, mutation on the lines the diff added in its app classes, using the test files that map to them. CRAP ratchets: a method above the max is RED only when the diff made it worse (new method, complexity grew, or a changed line uncovered); otherwise it is DEBT, listed and not blocking. Mutation is advisory in /handoff. When the mapping misses the right tests, pass `--pest 'paths'`. The thresholds and the history file are named in `~/.claude/config/quality.json`.
