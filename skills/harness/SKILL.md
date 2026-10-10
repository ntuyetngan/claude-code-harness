---
name: harness
description: Switch the engineering loop's hooks off or on for every session on this machine until /harness on, show their state, or build the task and weekly report pages. Off means preflight, the guards, the post-edit hook and the stop gate are skipped; skills such as /verify, /audit and /quality still run on demand. Manual-only; run as "/harness off", "/harness on", "/harness status", "/harness report" (this task) or "/harness report weekly".
argument-hint: '[off | on | status | report [task|weekly]]'
disable-model-invocation: true
allowed-tools: Bash(~/.claude/hooks/harness.sh *)
---

Run `~/.claude/hooks/harness.sh $ARGUMENTS` and show its one line. If the argument is `off`, add one sentence: commits and pushes are still blocked outside /handoff only while the loop is on, so with it off the ordinary git rules of the repo apply and nothing verifies the work automatically. If the argument is `on`, say the hooks fire again from the next tool call. With no argument, show the status. With `report` or `report weekly`, the script builds a page from the loop's own records (plan, changed files against the plan, receipts, quality scores, audit, QA, hook decisions) and opens it in the Windows browser; print its path and one line naming any RED or NEEDS_HUMAN item on it.

To start a whole session without the loop instead, launch Claude Code with `CLAUDE_LOOP=off claude`; that state is shown by `/harness status` and cannot be switched on from inside the session.
