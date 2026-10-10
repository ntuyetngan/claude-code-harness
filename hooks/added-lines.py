#!/usr/bin/env python3
"""Lines the working tree adds against a base commit, per file, as JSON: {"path": [line, ...]}.

usage: added-lines.py <repo-root> <base> <file>...
Untracked files count as wholly added. Lines are 1-based line numbers in the current file.
"""
import json, subprocess, sys
from pathlib import Path

root, base, files = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
out = {}
tracked = set(subprocess.run(['git', '-C', str(root), 'ls-files', '--', *files], capture_output=True, text=True).stdout.split('\n'))
for f in files:
    p = root / f
    if not p.is_file():
        continue
    if f not in tracked:
        out[f] = list(range(1, sum(1 for _ in p.open('rb')) + 1))
        continue
    diff = subprocess.run(['git', '-C', str(root), 'diff', '-U0', base, '--', f], capture_output=True, text=True).stdout
    lines = []
    for line in diff.splitlines():
        if line.startswith('@@'):
            new = line.split('+', 1)[1].split(' ', 1)[0]
            start, _, count = new.partition(',')
            count = int(count) if count else 1
            lines.extend(range(int(start), int(start) + count))
    out[f] = lines
json.dump(out, sys.stdout)
