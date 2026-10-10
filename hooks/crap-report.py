#!/usr/bin/env python3
"""Per-method CRAP for the methods a diff touches, read from a Clover coverage report.

usage: crap-report.py <clover.xml> <repo-root> <merge-base> <threshold> <history.jsonl> <diff-sha> file...

Clover from php-code-coverage carries, per method line, `complexity` and `crap` (already computed
with that method's own coverage), plus one line element per statement with its hit count. A method's
range is its line to the next method line or the file's last covered line. Only methods whose range
intersects a diff hunk are reported; untouched code never blocks.

Ratchet: a method above the threshold is RED only when the diff made it worse: the method is new, its
complexity grew against the merge base (base-complexity.php), or a statement on a changed line is
uncovered. Otherwise it is DEBT: listed, never blocking. When the base complexity cannot be read, the
method is RED as before.
"""
import json, re, subprocess, sys, time, xml.etree.ElementTree as ET
from pathlib import Path

clover, root, base, threshold, history, diff_sha, *files = sys.argv[1:]
threshold = float(threshold)
root = Path(root)

def changed_ranges(rel):
    """Line ranges added or modified in the working tree vs the merge base. Untracked: whole file."""
    tracked = subprocess.run(['git', 'ls-files', '--error-unmatch', rel], cwd=root, capture_output=True).returncode == 0
    if not tracked:
        n = sum(1 for _ in open(root / rel, encoding='utf-8', errors='replace'))
        return [(1, n)]
    out = subprocess.run(['git', 'diff', '-U0', base, '--', rel], cwd=root, capture_output=True, text=True).stdout
    ranges = []
    for m in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', out, re.M):
        start = int(m.group(1)); count = int(m.group(2)) if m.group(2) is not None else 1
        if count > 0:
            ranges.append((start, start + count - 1))
    return ranges

def overlaps(a, b):
    return a[0] <= b[1] and b[0] <= a[1]

def base_complexity(rel):
    """{method: cc} at the merge base; {} when the file is new there; None when it cannot be read."""
    src = subprocess.run(['git', 'show', f'{base}:{rel}'], cwd=root, capture_output=True)
    if src.returncode != 0:
        return {}
    res = subprocess.run(['php', str(Path(__file__).with_name('base-complexity.php'))], cwd=root, input=src.stdout, capture_output=True)
    try:
        return json.loads(res.stdout or b'null')
    except ValueError:
        return None

tree = ET.parse(clover)
by_file = {}
for f in tree.iter('file'):
    name = f.get('name', '')
    try:
        rel = str(Path(name).resolve().relative_to(root.resolve()))
    except ValueError:
        rel = name
    by_file[rel] = f

rows = []
for rel in files:
    f = by_file.get(rel)
    if f is None:
        rows.append({'file': rel, 'method': '(not in coverage report)', 'crap': None, 'complexity': None, 'coverage': None, 'status': 'SKIP'})
        continue
    lines = sorted(((int(l.get('num')), l) for l in f.iter('line')), key=lambda t: t[0])
    methods = [(num, l) for num, l in lines if l.get('type') == 'method']
    last = lines[-1][0] if lines else 0
    ranges = changed_ranges(rel)
    base_cc = 'unread'
    for i, (start, l) in enumerate(methods):
        end = methods[i + 1][0] - 1 if i + 1 < len(methods) else last
        if not any(overlaps((start, end), r) for r in ranges):
            continue
        stmts = [x for num, x in lines if start < num <= end and x.get('type') == 'stmt']
        covered = sum(1 for x in stmts if int(x.get('count', '0')) > 0)
        cov = round(100.0 * covered / len(stmts), 1) if stmts else 100.0
        crap = float(l.get('crap', '0') or 0)
        cc = int(l.get('complexity', '0') or 0)
        status, why = 'GREEN', ''
        if crap > threshold:
            name = l.get('name')
            if base_cc == 'unread':
                base_cc = base_complexity(rel)
            uncovered_changed = any(int(x.get('count', '0')) == 0 and any(r[0] <= int(x.get('num')) <= r[1] for r in ranges) for x in stmts)
            if base_cc is None:
                status, why = 'RED', 'base complexity unknown'
            elif name not in base_cc:
                status, why = 'RED', 'new method'
            elif cc > base_cc[name]:
                status, why = 'RED', f"complexity grew from {base_cc[name]}"
            elif uncovered_changed:
                status, why = 'RED', 'a changed line is not covered'
            else:
                status, why = 'DEBT', f"pre-existing (CC {base_cc[name]} at base, changed lines covered)"
        rows.append({'file': rel, 'method': l.get('name'), 'line': start, 'crap': crap, 'complexity': cc,
                     'coverage': cov, 'status': status, 'why': why})

ts = int(time.time())
with open(history, 'a', encoding='utf-8') as h:
    for r in rows:
        h.write(json.dumps({'ts': ts, 'diff_sha': diff_sha, 'threshold': threshold, **r}) + '\n')

red = [r for r in rows if r['status'] == 'RED']
debt = [r for r in rows if r['status'] == 'DEBT']
scored = [r for r in rows if r['crap'] is not None]
combined = round(sum(r['crap'] for r in scored), 1)
average = round(combined / len(scored), 1) if scored else 0.0
with open(history, 'a', encoding='utf-8') as h:
    h.write(json.dumps({'ts': ts, 'diff_sha': diff_sha, 'metric': 'crap_summary', 'threshold': threshold,
                        'methods': len(scored), 'combined': combined, 'average': average, 'above': len(red), 'debt': len(debt)}) + '\n')
band = lambda c: 'fine' if c <= 30 else ('needs attention' if c <= 60 else 'high risk')
print(f"CRAP threshold {threshold:g}: {len(scored)} changed method(s) scored, {len(red)} above threshold and made worse, {len(debt)} pre-existing debt; "
      f"combined {combined:g}, average {average:g} ({band(average)})")
for r in sorted(scored, key=lambda r: -r['crap']):
    fix = ''
    if r['status'] == 'RED':
        need = 'split it; complexity alone exceeds the threshold' if r['complexity'] >= threshold else 'cover it, or split it'
        fix = f"  -> {r['why']}: {need}"
    if r['status'] == 'DEBT':
        fix = f"  -> {r['why']}; not blocking"
    print(f"  {r['status']:5} {r['crap']:7.1f}  CC {r['complexity']:3d}  cov {r['coverage']:5.1f}%  {r['file']}:{r['line']} {r['method']}{fix}")
for r in rows:
    if r['status'] == 'SKIP':
        print(f"  SKIP  {r['file']}: {r['method']}")
sys.exit(1 if red else 0)
