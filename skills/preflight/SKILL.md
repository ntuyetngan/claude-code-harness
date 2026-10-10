---
name: preflight
description: Re-run the environment preflight on demand and print its GREEN/RED table. Use after starting Docker, logging in, pulling migrations, or whenever a session began with a RED row that has since been fixed. Manual-only.
disable-model-invocation: true
allowed-tools: Bash(PREFLIGHT_FORCE=1 *)
---

Run `PREFLIGHT_FORCE=1 ~/.claude/hooks/preflight.sh` in the foreground with a 600 second timeout and show the table it prints, unchanged. Then say in one line whether the environment is GREEN, or which RED rows remain and their remedies. Do not retry any failing command yourself; the table is the truth until the user changes something and runs this again.
