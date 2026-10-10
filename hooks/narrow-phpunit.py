#!/usr/bin/env python3
"""Copy a phpunit.xml, narrow <source> to the given files, and fix paths for where the copy lives.
usage: narrow-phpunit.py <repo phpunit.xml> <out.xml> <repo root> file... [--tests test-file...]
Relative paths in phpunit.xml resolve against the config file's own directory. A copy written
outside the repo gets absolute paths; a copy written inside the repo root keeps them relative,
which pest --parallel needs: its workers serialize coverage relative to the config's directory,
and the merged report is filtered against <source>, so an out-of-tree config yields an empty
clover. With --tests, the config also gets a testsuite named "verify" holding exactly those
files, since paratest accepts one path argument and a chosen set of files reaches it as
--testsuite=verify."""
import os, sys, xml.etree.ElementTree as ET
from pathlib import Path
args = sys.argv[1:]
tests = []
if '--tests' in args:
    i = args.index('--tests'); tests = args[i + 1:]; args = args[:i]
src, out, root, *files = args
root = Path(root).resolve()
in_tree = Path(out).resolve().parent == root
tree = ET.parse(src); r = tree.getroot()
def fix(p):
    p = p.strip()
    return p if in_tree or p.startswith('/') else str(root / p)
for attr in ('bootstrap', 'cacheDirectory'):
    v = r.get(attr)
    if v:
        r.set(attr, fix(v))
for el in r.iter():
    if el.tag in ('directory', 'file') and el.text:
        el.text = fix(el.text)
    v = el.get('bootstrap')
    if v:
        el.set('bootstrap', fix(v))
source = r.find('source')
if source is None:
    source = ET.SubElement(r, 'source')
for child in list(source):
    source.remove(child)
inc = ET.SubElement(source, 'include')
for f in files:
    e = ET.SubElement(inc, 'file'); e.text = f if in_tree else str(root / f)
if tests:
    suites = r.find('testsuites')
    if suites is None:
        suites = ET.SubElement(r, 'testsuites')
    for s in list(suites):
        if s.get('name') == 'verify':
            suites.remove(s)
    suite = ET.SubElement(suites, 'testsuite', name='verify')
    for t in tests:
        e = ET.SubElement(suite, 'file'); e.text = t if in_tree else str(root / t)
tree.write(out, encoding='unicode', xml_declaration=True)
print(f"narrowed phpunit config: {len(files)} source file(s), {len(tests)} test file(s) -> {out} ({'in tree, relative paths' if in_tree else 'absolute paths'})")
