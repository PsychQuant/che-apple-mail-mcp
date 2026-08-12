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
"""
import re
import sys

HEADER = re.compile(r'^##[ \t]+\[([0-9]{1,19}\.[0-9]{1,19}\.[0-9]{1,19})\][ \t]*(?:-.*)?$')
FENCE = re.compile(r'^[ \t]*(```|~~~)')


def released_lines(path):
    """Yield (index, line, version_or_None) with fenced blocks masked out.

    The fence marker is tracked by its character (``` vs ~~~) so a ``` inside a
    ~~~ block does not close it.
    """
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    fence_char = None
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if m:
            if fence_char is None:
                fence_char = m.group(1)[0]
            elif m.group(1)[0] == fence_char:
                fence_char = None
            yield i, line, None
            continue
        if fence_char is not None:
            yield i, line, None
            continue
        h = HEADER.match(line.rstrip())
        yield i, line, (h.group(1) if h else None)


def newest(path):
    for _, _, version in released_lines(path):
        if version:
            return version
    return None


def notes(path, want):
    """The body between this version's header and the next ## header."""
    collected, capturing = [], False
    for _, line, version in released_lines(path):
        if version == want and not capturing:
            capturing = True
            continue
        if capturing:
            # Any level-2 header ends the section — including `## [Unreleased]`,
            # which `released_lines` does not classify as a version.
            if line.startswith('## '):
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
