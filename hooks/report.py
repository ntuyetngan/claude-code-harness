#!/usr/bin/env python3
"""Build the task page and the weekly page from what the loop records. No model call.

usage: report.py task <repo-root> [diff-sha]   -> ~/.claude/loop-state/reports/<repo>/task-<date>-<sha>.html
       (pass the sha after a commit: the working tree is clean then and --map has no diff to hash)
       report.py weekly <repo-root>            -> ~/.claude/loop-state/reports/<repo>/weekly.html
Prints the path written. Inputs: verify receipts, audit receipt, quality history, hooks.log, the plan
file for the branch, the QA receipt when present.
"""
import html, json, os, re, subprocess, sys, time
from collections import Counter, defaultdict
from pathlib import Path

HOME = Path.home(); STATE = HOME / '.claude' / 'loop-state'
mode, root = sys.argv[1], Path(sys.argv[2]).resolve()
repo = root.name
out_dir = STATE / 'reports' / repo; out_dir.mkdir(parents=True, exist_ok=True)
esc = html.escape

def git(*a):
    return subprocess.run(['git', '-C', str(root), *a], capture_output=True, text=True).stdout.strip()

def load(p):
    try: return json.loads(Path(p).read_text(encoding='utf-8'))
    except Exception: return None

def jsonl(p):
    rows = []
    for line in Path(p).read_text(encoding='utf-8').splitlines() if Path(p).exists() else []:
        try: rows.append(json.loads(line))
        except Exception: pass
    return rows

CSS = '''<style>
body{font:15px/1.55 -apple-system,"Segoe UI",sans-serif;margin:0;padding:24px 16px;background:#F4F6F7;color:#16202A;max-width:1100px;margin:0 auto}
h1{font-size:28px;margin:0 0 4px}h2{font-size:20px;margin:28px 0 8px}p{margin:0 0 10px;max-width:80ch}
table{border-collapse:collapse;width:100%;font-size:14px;background:#fff}th,td{text-align:left;vertical-align:top;padding:7px 10px;border-bottom:1px solid #D3DAE0}th{background:#E8ECEF;font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.G{color:#2E7D5B;font-weight:600}.R{color:#B23A3A;font-weight:600}.S{color:#77828E;font-weight:600}.W{color:#B4651A;font-weight:600}
code{font-family:ui-monospace,Menlo,monospace;font-size:.9em;background:#E8ECEF;padding:1px 4px}
.muted{color:#77828E}.wrap{overflow-x:auto}.sub{color:#46525F;margin-bottom:18px}
</style>'''

def status_cell(s):
    cls = {'GREEN': 'G', 'RED': 'R', 'SKIP': 'S'}.get(s, 'W'); return f'<span class="{cls}">{esc(str(s))}</span>'

def task_page(sha):
    branch = git('branch', '--show-current') or 'detached'
    base = git('merge-base', 'HEAD', 'master') or git('rev-parse', 'HEAD')
    rdir = STATE / 'verify' / repo / sha
    plan = None
    for f in sorted((HOME / '.claude' / 'plans' / repo).glob('*.md'), key=os.path.getmtime, reverse=True) if (HOME / '.claude' / 'plans' / repo).exists() else []:
        t = f.read_text(encoding='utf-8')
        if re.search(rf'^Branch: {re.escape(branch)}$', t, re.M) and re.search(r'^Status: (approved|in progress)', t, re.M): plan = (f, t); break
    parts = [CSS, f'<h1>Task report: {esc(repo)} on {esc(branch)}</h1>',
             f'<p class="sub">Diff {esc(sha)} against {esc(base[:10])}, built {time.strftime("%Y-%m-%d %H:%M")}. Everything here comes from files the loop wrote; nothing is judged by a model on this page.</p>']
    # 1. Plan
    parts.append('<h2>1. What was asked</h2>')
    if plan:
        f, t = plan
        goal = re.search(r'^## Goal\n(.*?)(?=^## )', t, re.S | re.M); done = re.search(r'^## Done when\n(.*?)(?=^## )', t, re.S | re.M)
        qa = re.search(r'^QA: (\w[\w ]*)', t, re.M)
        parts.append(f'<p><b>Plan</b> <code>{esc(str(f))}</code></p>')
        if goal: parts.append('<p>' + esc(goal.group(1).strip()) + '</p>')
        if done:
            parts.append('<p><b>Done when</b></p><ul>' + ''.join(f'<li>{esc(l.lstrip("- ").strip())}</li>' for l in done.group(1).strip().splitlines() if l.strip()) + '</ul>')
        parts.append(f'<p class="muted">QA: {esc(qa.group(1).strip()) if qa else "not stated in the plan"}</p>')
        planned = set(re.findall(r'`([^`]+)`', re.search(r'^## Files that change\n(.*?)(?=^## )', t, re.S | re.M).group(1))) if re.search(r'^## Files that change', t, re.M) else set()
        amended = set(re.findall(r'`([^`]+)`', re.search(r'^## Discovered during implementation\n(.*?)(?=^## )', t, re.S | re.M).group(1))) if re.search(r'^## Discovered during implementation', t, re.M) else set()
    else:
        parts.append('<p class="muted">No approved plan for this branch. The change was made without /planner.</p>'); planned, amended = set(), set()
    # 2. Diff by file
    parts.append('<h2>2. What changed</h2>')
    changed = [l for l in (git('diff', '--name-only', base).splitlines() + git('ls-files', '--others', '--exclude-standard').splitlines()) if l and not l.startswith('nuxt/')]
    rows = []
    for fpath in sorted(set(changed)):
        stat = git('diff', '--numstat', base, '--', fpath).split('\t')
        plus, minus = (stat[0], stat[1]) if len(stat) >= 2 else ('new', '')
        label = 'planned' if fpath in planned else ('added during implementation' if fpath in amended else ('outside the plan' if plan else ''))
        rows.append(f'<tr><td><code>{esc(fpath)}</code></td><td>+{esc(plus)} / -{esc(minus)}</td><td class="{"W" if label=="outside the plan" else ""}">{esc(label)}</td></tr>')
    parts.append('<div class="wrap"><table><tr><th>File</th><th>Lines</th><th>Against the plan</th></tr>' + ''.join(rows) + '</table></div>' if rows else '<p class="muted">No changes against the merge base.</p>')
    # 3. Receipts
    parts.append('<h2>3. Proof: receipts for this diff</h2>')
    rec = [load(p) for p in sorted(rdir.glob('*.json'))] if rdir.exists() else []
    rec = [r for r in rec if r and 'suite' in r]
    if rec:
        parts.append('<div class="wrap"><table><tr><th>Suite</th><th>Status</th><th>Detail</th><th>Time</th></tr>' + ''.join(
            f'<tr><td>{esc(r["suite"])}</td><td>{status_cell(r.get("status"))}</td><td>{esc(str(r.get("detail",""))[:240])}</td><td>{esc(str(r.get("elapsed_s","")))}s</td></tr>' for r in rec) + '</table></div>')
    else: parts.append('<p class="R">No receipts for this diff. /verify has not run on the current code.</p>')
    # 4. Quality
    q = [r for r in jsonl(STATE / 'quality' / f'{repo}.jsonl') if r.get('diff_sha') == sha]
    parts.append('<h2>4. Quality gates</h2>')
    crap = [r for r in q if r.get('method') and r.get('crap') is not None]; msi = [r for r in q if r.get('metric') == 'msi']
    if crap:
        parts.append('<div class="wrap"><table><tr><th>Method</th><th>CRAP</th><th>CC</th><th>Coverage</th><th>Status</th></tr>' + ''.join(
            f'<tr><td><code>{esc(r["file"])}:{r.get("line","")}</code> {esc(r["method"])}</td><td>{r["crap"]}</td><td>{r.get("complexity","")}</td><td>{r.get("coverage","")}%</td><td>{status_cell(r["status"])}</td></tr>' for r in crap) + '</table></div>')
    else: parts.append('<p class="muted">No CRAP scores recorded for this diff.</p>')
    if msi:
        m = msi[-1]; parts.append(f'<p>Mutation score <b>{m.get("value")}%</b> against {m.get("threshold")}% on {esc(str(m.get("classes","")))}. {esc(str(m.get("counts","")))}</p>')
    else: parts.append('<p class="muted">Mutation testing has not run for this diff.</p>')
    # 5. Audit
    parts.append('<h2>5. Audit</h2>')
    a = load(STATE / 'audit' / repo / f'{sha}.json')
    if a:
        for key, title in (('fixed', 'Fixed'), ('listed', 'Listed, 5 and below'), ('needs_human', 'NEEDS_HUMAN')):
            items = a.get(key) or []
            parts.append(f'<p><b>{title}</b>: ' + (esc('; '.join(str(i) for i in items)) if items else 'none') + '</p>')
    else: parts.append('<p class="muted">No audit receipt for this diff. /audit has not run.</p>')
    # 6. QA
    parts.append('<h2>6. Browser QA</h2>')
    qa_r = load(rdir / 'qa.json') if rdir.exists() else None
    if qa_r:
        parts.append('<div class="wrap"><table><tr><th>Scenario</th><th>Result</th><th>Evidence</th></tr>' + ''.join(
            f'<tr><td>{esc(str(s.get("scenario","")))}</td><td>{status_cell(s.get("status"))}</td><td>{esc(str(s.get("evidence","")))}</td></tr>' for s in qa_r.get('scenarios', [])) + '</table></div>')
    else: parts.append('<p class="muted">No QA receipt for this diff.</p>')
    # 7. Hook decisions in the last 12 hours for this repo
    parts.append('<h2>7. What the hooks did</h2>')
    cutoff = time.time() - 12 * 3600; lines = []
    for line in (STATE / 'hooks.log').read_text(encoding='utf-8').splitlines()[-2000:] if (STATE / 'hooks.log').exists() else []:
        try: ts = time.mktime(time.strptime(line[:19], '%Y-%m-%d %H:%M:%S'))
        except Exception: continue
        if ts >= cutoff and re.search(r'\b(BLOCK|refus|allow|WARN|verdict|RED|GREEN)\b', line): lines.append(line)
    blocks = [l for l in lines if 'BLOCK' in l]
    parts.append(f'<p>{len(blocks)} block(s) and {len(lines)} decision line(s) in the last 12 hours.</p>')
    if lines: parts.append('<div class="wrap"><table><tr><th>Time</th><th>Hook</th><th>Decision</th></tr>' + ''.join(
        f'<tr><td>{esc(l[11:19])}</td><td>{esc(l[21:37].strip())}</td><td class="{"R" if "BLOCK" in l else ""}">{esc(l[38:220])}</td></tr>' for l in lines[-40:]) + '</table></div>')
    out = out_dir / f'task-{time.strftime("%Y%m%d-%H%M")}-{sha}.html'
    out.write_text('\n'.join(parts), encoding='utf-8'); return out

def weekly_page():
    cutoff = time.time() - 7 * 86400
    parts = [CSS, f'<h1>Weekly: {esc(repo)}</h1>', f'<p class="sub">Last 7 days, built {time.strftime("%Y-%m-%d %H:%M")}.</p>']
    q = [r for r in jsonl(STATE / 'quality' / f'{repo}.jsonl') if r.get('ts', 0) >= cutoff]
    crap_s = [r for r in q if r.get('metric') == 'crap_summary']; msi = [r for r in q if r.get('metric') == 'msi']
    parts.append('<h2>Quality trend</h2>')
    if crap_s: parts.append('<div class="wrap"><table><tr><th>When</th><th>Methods scored</th><th>Above threshold</th><th>Combined</th><th>Average</th></tr>' + ''.join(
        f'<tr><td>{time.strftime("%m-%d %H:%M", time.localtime(r["ts"]))}</td><td>{r.get("methods")}</td><td>{r.get("above")}</td><td>{r.get("combined")}</td><td>{r.get("average")}</td></tr>' for r in crap_s[-30:]) + '</table></div>')
    else: parts.append('<p class="muted">No CRAP runs this week.</p>')
    if msi: parts.append('<div class="wrap"><table><tr><th>When</th><th>Mutation score</th><th>Threshold</th><th>Classes</th></tr>' + ''.join(
        f'<tr><td>{time.strftime("%m-%d %H:%M", time.localtime(r["ts"]))}</td><td>{r.get("value")}%</td><td>{r.get("threshold")}%</td><td>{esc(str(r.get("classes","")))[:80]}</td></tr>' for r in msi[-30:]) + '</table></div>')
    else: parts.append('<p class="muted">No mutation runs this week.</p>')
    parts.append('<h2>Hook activity</h2>')
    by_day = defaultdict(Counter)
    for line in (STATE / 'hooks.log').read_text(encoding='utf-8').splitlines() if (STATE / 'hooks.log').exists() else []:
        try: ts = time.mktime(time.strptime(line[:19], '%Y-%m-%d %H:%M:%S'))
        except Exception: continue
        if ts < cutoff: continue
        day = line[:10]; hook = line[21:37].strip()
        if 'BLOCK' in line: by_day[day]['blocks: ' + hook] += 1
        if hook == 'stop-gate' and 'BLOCK' in line: by_day[day]['stops refused'] += 1
        if hook == 'diff-judge' and 'verdict' in line: by_day[day]['diff judge verdicts'] += 1
        if hook == 'verify' and ' RED ' in line: by_day[day]['RED suites'] += 1
        if hook == 'verify' and ' GREEN ' in line: by_day[day]['GREEN suites'] += 1
    if by_day:
        keys = sorted({k for c in by_day.values() for k in c})
        parts.append('<div class="wrap"><table><tr><th>Day</th>' + ''.join(f'<th>{esc(k)}</th>' for k in keys) + '</tr>' + ''.join(
            f'<tr><td>{d}</td>' + ''.join(f'<td>{by_day[d].get(k, 0)}</td>' for k in keys) + '</tr>' for d in sorted(by_day)) + '</table></div>')
    else: parts.append('<p class="muted">No hook activity this week.</p>')
    out = out_dir / 'weekly.html'; out.write_text('\n'.join(parts), encoding='utf-8'); return out

if mode == 'task':
    sha = sys.argv[3] if len(sys.argv) > 3 else None
    if not sha:
        m = subprocess.run([str(HOME / '.claude' / 'hooks' / 'verify.sh'), '--map'], cwd=root, capture_output=True, text=True).stdout
        try: sha = json.loads(m)['diff_sha']
        except Exception: sys.exit('could not determine the diff sha')
        if not (STATE / 'verify' / repo / sha).exists():
            newest = sorted((STATE / 'verify' / repo).glob('*/'), key=os.path.getmtime, reverse=True) if (STATE / 'verify' / repo).exists() else []
            if newest: sha = newest[0].name
    print(task_page(sha))
elif mode == 'weekly':
    print(weekly_page())
else:
    sys.exit('usage: report.py task <root> [sha] | weekly <root>')
