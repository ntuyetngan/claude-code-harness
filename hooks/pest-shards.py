#!/usr/bin/env python3
"""Balance pest files over K shards, and remember how long each file took.

usage: pest-shards.py plan <K> <durations.json> <file>...   -> K lines, files separated by spaces (a line may be empty)
       pest-shards.py record <durations.json> <pest.log>...  -> adds each log's per-file seconds to the json
       pest-shards.py filter <i> <n> <list-file>             -> --filter regex for part i of n of the listed tests
Planning is longest-processing-time first: files sorted by their last known seconds (line count when
unknown) go one at a time onto the shard with the least load, so the slowest file never shares a shard
with more than it must. With fewer files than shards, the spare shards go to the heaviest files while a
part stays above SPLIT_MIN_SECONDS; such a line is a single "<file>@<i>/<n>", part i of n of its tests.
Pest matches --filter against the printable description, while --list-tests prints the evaluable method
name (Str::evaluable: "_" -> "__", every other non-alphanumeric byte -> "_"), so each run of L underscores
becomes ".{ceil(L/2),L}". A pattern can match a sibling test, which runs it twice; it never misses its own.
"""
import json, re, sys
from pathlib import Path

SPLIT_MIN_SECONDS = 60

def load(p):
    try: return json.loads(Path(p).read_text())
    except Exception: return {}

def class_to_file(cls):
    return cls.replace('Tests\\', 'tests/').replace('\\', '/') + '.php'

if sys.argv[1] == 'plan':
    k, dur_path, files = int(sys.argv[2]), sys.argv[3], sys.argv[4:]
    durations = load(dur_path)
    def weight(f):
        if f in durations: return durations[f]
        try: return sum(1 for _ in open(f, 'rb')) / 10.0
        except Exception: return 1.0
    if 0 < len(files) < k:
        parts = {f: 1 for f in files}
        for _ in range(k - len(files)):
            f = max(files, key=lambda x: weight(x) / parts[x])
            if weight(f) / (parts[f] + 1) < SPLIT_MIN_SECONDS: break
            parts[f] += 1
        for f in files:
            n = parts[f]
            for i in range(1, n + 1):
                print(f if n == 1 else f'{f}@{i}/{n}')
        sys.exit(0)
    shards = [[0.0, []] for _ in range(max(1, min(k, len(files))))]
    for f in sorted(files, key=weight, reverse=True):
        s = min(shards, key=lambda x: x[0]); s[0] += weight(f); s[1].append(f)
    for _, members in shards:
        print(' '.join(members))
elif sys.argv[1] == 'record':
    dur_path, logs = sys.argv[2], sys.argv[3:]
    durations = load(dur_path); cur = None; seen = set()
    for log in logs:
        for line in Path(log).read_text(encoding='utf-8', errors='replace').splitlines():
            if re.match(r'\s*Tests:\s', line): cur = None; continue
            m = re.search(r'\b(PASS|FAIL|WARN)\s+(Tests\\\S+)', line)
            if m:
                cur = class_to_file(m.group(2))
                if cur not in seen: seen.add(cur); durations[cur] = 0.0
                continue
            m = re.search(r'\s([0-9]+\.[0-9]+)s\s*$', line)
            if m and cur: durations[cur] = round(durations.get(cur, 0.0) + float(m.group(1)), 2)
    Path(dur_path).parent.mkdir(parents=True, exist_ok=True)
    Path(dur_path).write_text(json.dumps(durations, indent=0, sort_keys=True))
    print(f'recorded {len(durations)} file duration(s) in {dur_path}')
elif sys.argv[1] == 'filter':
    i, n = int(sys.argv[2]), int(sys.argv[3])
    names = list(dict.fromkeys(re.match(r'[A-Za-z0-9_\u0080-\U0010ffff]*', x).group() for x in Path(sys.argv[4]).read_text().split()))
    def pattern(name):
        name = name.removeprefix('__pest_evaluable_')
        return re.sub(r'_+', lambda m: '.{%d,%d}' % ((len(m.group()) + 1) // 2, len(m.group())), name)
    mine = [pattern(x) for k, x in enumerate(names) if k % n == i - 1]
    print('/::(' + '|'.join(mine) + ')(\\s|$)/' if mine else '')
else:
    sys.exit(__doc__)
