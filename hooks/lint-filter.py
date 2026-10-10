#!/usr/bin/env python3
"""Split a linter log into errors on lines this diff added and errors that were already there.

usage: lint-filter.py <phpcs|phpstan|type-check> <log> <added-lines.json> [repo-root]
Prints one line: "new=<n> pre=<m>; first new: <file:line msg>" and exits 1 when n > 0, 0 otherwise.
Formats read: phpcs --report=emacs (path:line:col: type - msg), phpstan --error-format=raw
(path:line:msg), vue-tsc (path(line,col): error TSnnnn: msg). Paths are matched relative to the
repo root, so absolute paths in the log still resolve.
"""
import json, os, re, sys

kind, log, added_json = sys.argv[1], sys.argv[2], sys.argv[3]
root = os.path.abspath(sys.argv[4] if len(sys.argv) > 4 else os.getcwd())
added = {k: set(v) for k, v in json.load(open(added_json)).items()}
pat = {
    'phpcs': re.compile(r'^(?P<f>.+?):(?P<l>\d+):\d+:\s*(?P<m>(error|warning).*)$', re.I),
    'phpstan': re.compile(r'^(?P<f>[^:\s].*?):(?P<l>\d+):(?P<m>.*)$'),
    'type-check': re.compile(r'^(?P<f>.+?)\((?P<l>\d+),\d+\):\s*(?P<m>error TS.*)$'),
}[kind]

def rel(path):
    path = path.strip().replace('\\', '/')
    if os.path.isabs(path):
        path = os.path.relpath(path, root)
    return path.lstrip('./')

new, pre, first = 0, 0, ''
for line in open(log, encoding='utf-8', errors='replace'):
    m = pat.match(line.rstrip())
    if not m:
        continue
    if kind == 'phpcs' and not re.search(r'\b(error|warning)\b', m.group('m'), re.I):
        continue
    f, l = rel(m.group('f')), int(m.group('l'))
    if l in added.get(f, set()):
        new += 1
        first = first or f'{f}:{l} {m.group("m").strip()[:110]}'
    else:
        pre += 1
print(f'new={new} pre={pre}' + (f'; first new: {first}' if first else ('; none on added lines' if pre else '')))
sys.exit(1 if new else 0)
