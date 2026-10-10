#!/usr/bin/env python3
"""Fold the long parts of a PR body or a QA comment into <details> blocks.

usage: fold-body.py body <live-body.md> <out.md>       PR body: Test Plan lines and the screenshots
       fold-body.py comment <live-comment.md> <out.md>  QA comment: everything under the "## QA" heading
Exit 0 when the output differs from the input, 3 when nothing needed folding (already folded), 65 on a
shape the tool does not touch (a comment that is not a "## QA" comment).

gh --attach appends each uploaded image as a bare "![name](https://github.com/user-attachments/...)"
line after the text, outside any block, so folding has to run after the create or comment call. The
transformation moves only those appended image lines and wraps only the harness's own sections; the
author's text is kept byte for byte. A section that already holds a <details> block is left alone,
except that stray appended images after it are moved inside.
"""
import re, sys

IMG = re.compile(r'^!\[[^\]]*\]\((https://github\.com/user-attachments/[^)]+|https://private-user-images\.githubusercontent\.com/[^)]+)\)\s*$')
CR_MARK = '<!-- This is an auto-generated comment: release notes by coderabbit.ai -->'

def split_trailing_images(lines):
    """Appended images sit at the end (before the CodeRabbit block, if any): return (rest, images, tail)."""
    tail = []
    if any(CR_MARK in l for l in lines):
        i = next(i for i, l in enumerate(lines) if CR_MARK in l)
        lines, tail = lines[:i], lines[i:]
    imgs = []
    while lines and (IMG.match(lines[-1]) or lines[-1].strip() == ''):
        l = lines.pop()
        if IMG.match(l): imgs.insert(0, l.strip())
    return lines, imgs, tail

def fold_body(text):
    lines = text.split('\n')
    changed = False
    # 1. Test Plan: wrap its lines unless a <details> is already there; the first line stays as the summary line.
    heads = [i for i, l in enumerate(lines) if l.startswith('## ')]
    def section(name):
        for i in heads:
            if lines[i].strip() == f'## {name}':
                end = next((j for j in heads if j > i), len(lines))
                return i, end
        return None
    tp = section('Test Plan')
    if tp:
        i, end = tp
        body = lines[i + 1:end]
        if not any('<details' in l for l in body):
            content = [l for l in body]
            while content and content[0].strip() == '': content.pop(0)
            while content and content[-1].strip() == '': content.pop()
            if len(content) > 3:
                first, rest = content[0], content[1:]
                lines[i + 1:end] = ['', first, '', '<details>', '<summary>Suites, QA scenarios and Done-when proof</summary>', ''] + rest + ['', '</details>', '']
                changed = True
                heads = [k for k, l in enumerate(lines) if l.startswith('## ')]
    # 2. Screenshots: move the appended images into a <details> block at the end of that section.
    rest, imgs, tail = split_trailing_images(lines)
    if imgs:
        ss = None
        for k, l in enumerate(rest):
            if l.strip() == '## Screenshots': ss = k
        block = ['', '<details>', f'<summary>Screenshots ({len(imgs)})</summary>', ''] + [x for pair in zip(imgs, [''] * len(imgs)) for x in pair] + ['</details>', '']
        if ss is not None and any('<details' in l for l in rest[ss:]):
            # a folded block exists already: put the strays inside it, before its closing tag
            close = max(k for k, l in enumerate(rest) if l.strip() == '</details>')
            rest[close:close] = [''] + [x for pair in zip(imgs, [''] * len(imgs)) for x in pair]
        else:
            while rest and rest[-1].strip() == '': rest.pop()
            rest += block
        lines = rest + ([''] + tail if tail else [])
        changed = True
    return '\n'.join(lines), changed

def fold_comment(text):
    lines = text.split('\n')
    if not lines or not lines[0].startswith('## QA'):
        return text, None
    head, body = lines[0], lines[1:]
    rest, imgs, _ = split_trailing_images(body)
    if any('<details' in l for l in rest):
        if not imgs:
            return text, False
        close = max(k for k, l in enumerate(rest) if l.strip() == '</details>')
        rest[close:close] = [''] + [x for pair in zip(imgs, [''] * len(imgs)) for x in pair]
        return '\n'.join([head] + rest), True
    while rest and rest[0].strip() == '': rest.pop(0)
    while rest and rest[-1].strip() == '': rest.pop()
    n = len(imgs)
    summary = 'QA details' + (f' and {n} screenshot{"s" if n != 1 else ""}' if n else '')
    out = [head, '', '<details>', f'<summary>{summary}</summary>', ''] + rest
    if imgs:
        out += [''] + [x for pair in zip(imgs, [''] * len(imgs)) for x in pair]
    out += ['</details>', '']
    return '\n'.join(out), True

mode, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding='utf-8').read().replace('\r\n', '\n')
if mode == 'body':
    out, changed = fold_body(text)
elif mode == 'comment':
    out, changed = fold_comment(text)
    if changed is None:
        sys.exit('fold-body: not a "## QA" comment; left alone')
else:
    sys.exit(__doc__)
open(dst, 'w', encoding='utf-8').write(out)
print('folded' if changed else 'already folded, nothing to do')
sys.exit(0 if changed else 3)
