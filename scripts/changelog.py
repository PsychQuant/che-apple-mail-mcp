#!/usr/bin/env python3
"""The repo's single definition of "a released CHANGELOG header" (#349).

Three consumers used to answer that question with three different parsers:
`VersionTests`, `ManifestVersionTests` and `scripts/release.sh`. They could
disagree, and two of the guards that #303/#311 deliberately set against each
other are only as strong as their agreeing on what they measure:

  * `## [2.27.0-rc1]` — `VersionTests` accepted it (its check went through
    `SemVer()`, which discards a `-suffix` by design), while
    `ManifestVersionTests` required three integer components and skipped to the
    next header. So `AppVersion.current` and the manifest version could hold
    DIFFERENT values with CI fully green.
  * A `## [9.9.9]` line inside a fenced code block — or any quoted example —
    was read as a real release header by every one of them.

So the rule lives here once, and the callers ask this script.

A released header is a line matching `## [MAJOR.MINOR.PATCH]` exactly, with
ASCII decimal components, appearing OUTSIDE any fenced code block. A `-rc1` /
`+build` suffix is deliberately NOT a released version: the release tag
validator in `release.sh` refuses such tags, so accepting one here would let a
prerelease header become the thing `AppVersion.current` is measured against.

Usage:
    changelog.py newest [PATH]        print the newest released version
    changelog.py has VERSION [PATH]   exit 0 iff VERSION has a released header
    changelog.py notes VERSION [PATH] print that version's section body
    changelog.py entries [PATH]       JSON inventory of visible release headers
"""
import re
import json
import sys

HEADER = re.compile(r'^##[ \t]+\[([0-9]{1,19}\.[0-9]{1,19}\.[0-9]{1,19})\][ \t]*(?:-.*)?$')
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')


def mask_comments(line, active):
    """Mask comment bytes in place, preserving heading columns and code spans."""
    result, pos = list(line), 0
    while pos < len(line):
        if active:
            end = line.find('-->', pos)
            stop = len(line) if end < 0 else end + 3
            result[pos:stop] = ' ' * (stop - pos)
            pos, active = stop, end < 0
        else:
            token = re.search(r'<!--|`+', line[pos:])
            if token is None:
                break
            start, stop = pos + token.start(), pos + token.end()
            if token.group() == '<!--':
                pos, active = start, True
            else:
                closing = re.search(r'(?<!`)`{' + str(stop - start) + r'}(?!`)', line[stop:])
                pos = stop + closing.end() if closing else stop
    return ''.join(result), active


def visible_lines(path):
    """Yield (index, raw line, heading text or None inside fenced code)."""
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    fence_char, fence_length, comment = None, 0, False
    for i, line in enumerate(lines):
        if fence_char is not None:
            closing = re.match(r'^ {0,3}(' + re.escape(fence_char) + r'{'+str(fence_length)+r',})[ \t]*$', line)
            if closing:
                fence_char = None
            yield i, line, None
            continue
        m = FENCE.match(line) if not comment else None
        if m and not (m.group(1)[0] == '`' and '`' in m.group(2)):
            fence_char, fence_length = m.group(1)[0], len(m.group(1))
            yield i, line, None
            continue
        projected, comment = mask_comments(line, comment)
        yield i, line, projected


def released_lines(path):
    """Keep the existing tuple API while sharing fence/comment handling."""
    for i, line, projected in visible_lines(path):
        h = HEADER.match(projected.rstrip()) if projected is not None else None
        yield i, line, (h.group(1) if h else None)


def newest(path):
    for _, _, version in released_lines(path):
        if version:
            return version
    return None


def notes(path, want):
    """The body between this version's header and the next ## header."""
    collected, capturing = [], False
    for _, line, visible in visible_lines(path):
        h = HEADER.match(visible.rstrip()) if visible is not None else None
        version = h.group(1) if h else None
        if version == want and not capturing:
            capturing = True
            continue
        if capturing:
            # Any level-2 header ends the section — including `## [Unreleased]`,
            # which `released_lines` does not classify as a version.
            if visible is not None and re.match(r'^##[ \t]', visible):
                break
            collected.append(line)
    if not capturing:
        return None
    while collected and not collected[0].strip():
        collected.pop(0)
    while collected and not collected[-1].strip():
        collected.pop()
    return '\n'.join(collected)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]

    if command == 'entries':
        path = argv[2] if len(argv) > 2 else 'CHANGELOG.md'
        rows = []
        for i, _, projected in visible_lines(path):
            match = HEADER.match(projected.rstrip()) if projected is not None else None
            if match:
                rows.append({'line': i + 1, 'header': projected.rstrip(), 'version': match.group(1)})
        print(json.dumps(rows))
        return 0

    if command == 'newest':
        path = argv[2] if len(argv) > 2 else 'CHANGELOG.md'
        version = newest(path)
        if version is None:
            print(f'no released "## [x.y.z]" header found in {path}', file=sys.stderr)
            return 1
        print(version)
        return 0

    if command in ('has', 'notes'):
        if len(argv) < 3:
            print(f'{command} needs a version', file=sys.stderr)
            return 2
        want, path = argv[2], (argv[3] if len(argv) > 3 else 'CHANGELOG.md')
        if command == 'has':
            return 0 if any(v == want for _, _, v in released_lines(path)) else 1
        body = notes(path, want)
        if body is None:
            print(f'no released section for [{want}] in {path}', file=sys.stderr)
            return 1
        print(body)
        return 0

    print(f'unknown command: {command}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
