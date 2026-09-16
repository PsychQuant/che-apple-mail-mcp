#!/usr/bin/env python3
"""Check documented GitHub marketplace membership; never run installation commands."""
import argparse
import json
import os
import stat
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

MAX_BYTES = 1_048_576
NAME = re.compile(r'[A-Za-z0-9_.-]+\Z')
REPO = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z')

class Invalid(Exception):
    """Definite documentation/source resolution failure (exit 1)."""

class Uncertain(Exception):
    """Resolution could not be established (exit 2), never a pass."""

def repository(value):
    if value.startswith('https://github.com/'):
        value = value[len('https://github.com/'):].removesuffix('.git')
    if not REPO.fullmatch(value) or any(part in ('.', '..') for part in value.split('/')):
        raise Invalid('unsupported marketplace source; use GitHub owner/repository or HTTPS repository URL')
    return value

def shell_comment_prefix(line):
    """Strip only word-boundary, unquoted shell comments; keep in-word #."""
    quote = None
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote:
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        elif char == '#' and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line


def commands(readme):
    if len(readme.encode('utf-8')) > MAX_BYTES:
        raise Invalid('README exceeds 1 MiB')
    fence = None
    shell = False
    result = []
    for number, line in enumerate(readme.splitlines(), 1):
        mark = re.fullmatch(r'\s{0,3}(`{3,}|~{3,})([\w-]*)\s*', line)
        if mark:
            token, language = mark.groups()
            if fence is None:
                fence = token
                shell = language in ('', 'bash', 'sh', 'shell', 'zsh', 'console', 'shellsession')
            elif token[0] == fence[0] and len(token) >= len(fence) and not language:
                fence = None
            continue
        if fence is None:
            continue
        line = re.sub(r'^\s*\$\s+', '', line).strip()
        candidate = shell_comment_prefix(line)
        if not re.search(r'(?<![\w-])/?plugin\s+(?:install|marketplace\s+add)\b', candidate):
            continue
        if not shell:
            raise Invalid(f'README:{number}: installation instruction in unsupported fence language')
        try:
            words = shlex.split(shell_comment_prefix(line), comments=False)
        except ValueError as exc:
            raise Invalid(f'README:{number}: malformed command: {exc}') from exc
        if words[0] == '/plugin':
            words = ['claude', 'plugin'] + words[1:]
        if words[:4] == ['claude', 'plugin', 'marketplace', 'add'] and len(words) == 5:
            result.append(('add', repository(words[4]), number))
        elif words[:3] == ['claude', 'plugin', 'install'] and len(words) == 4:
            parts = words[3].split('@')
            if len(parts) != 2 or not all(NAME.fullmatch(p) for p in parts):
                raise Invalid(f'README:{number}: install must name plugin@marketplace')
            result.append(('install', words[3], number))
        else:
            raise Invalid(f'README:{number}: unsupported plugin command; update the checker before changing syntax')
    if fence is not None:
        raise Invalid('README has an unterminated fenced code block')
    if not any(k == 'add' for k, _, _ in result) or not any(k == 'install' for k, _, _ in result):
        raise Invalid('README must contain fenced marketplace add and plugin install instructions')
    if len({v.lower() for k, v, _ in result if k == 'add'}) > 8:
        raise Invalid('more than 8 marketplace sources; review checker budget')
    return result

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Invalid(f'duplicate JSON key: {key}')
        value[key] = item
    return value

def decode_manifest(data, repo):
    if len(data) > MAX_BYTES:
        raise Invalid(f'{repo}: manifest exceeds 1 MiB')
    try:
        value = json.loads(data.decode('utf-8'), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise Invalid(f'{repo}: malformed marketplace JSON') from exc
    if not isinstance(value, dict) or not isinstance(value.get('name'), str) or not NAME.fullmatch(value['name']):
        raise Invalid(f'{repo}: manifest must contain a valid marketplace name')
    plugins = value.get('plugins')
    if not isinstance(plugins, list):
        raise Invalid(f'{repo}: manifest plugins must be a list')
    names = set()
    for plugin in plugins:
        name = plugin.get('name') if isinstance(plugin, dict) else None
        if not isinstance(name, str) or not NAME.fullmatch(name) or name in names:
            raise Invalid(f'{repo}: invalid or duplicate plugin name')
        names.add(name)
    return value['name'], names

def require_curl():
    # 8.4.0 introduced max-filesize enforcement for unknown-length transfers.
    # https://curl.se/docs/manpage.html#--max-filesize
    try:
        result = subprocess.run(['curl', '--disable', '--version'], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Uncertain('curl >= 8.4.0 is required; version check unavailable') from exc
    match = re.match(r'curl (\d+)\.(\d+)\.(\d+)\b', result.stdout)
    if result.returncode or not match or tuple(map(int, match.groups())) < (8, 4, 0):
        raise Uncertain('curl >= 8.4.0 is required for a bounded unknown-length response; update curl')


def fetch_manifest(repo, deadline=None):
    repo = repository(repo)
    deadline = time.monotonic() + 40 if deadline is None else deadline
    if time.monotonic() >= deadline:
        raise Uncertain(f'{repo}: total check deadline exceeded')
    require_curl()
    url = f'https://raw.githubusercontent.com/{repo}/HEAD/.claude-plugin/marketplace.json'
    last = 'network error'
    for attempt in range(3):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Uncertain(f'{repo}: total check deadline exceeded')
        budget = min(10, remaining)
        with tempfile.TemporaryDirectory(prefix='install-check-') as folder:
            output = Path(folder) / 'manifest.json'
            args = ['curl', '--disable', '--silent', '--show-error', '--location', '--max-redirs', '3',
                    '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', str(min(3, budget)),
                    '--max-time', str(budget), '--max-filesize', str(MAX_BYTES), '--output', str(output),
                    '--write-out', '%{http_code}', url]
            try:
                completed = subprocess.run(args, capture_output=True, text=True, timeout=budget + 2)
            except subprocess.TimeoutExpired:
                last = 'request timeout'
            except OSError as exc:
                raise Uncertain(f'{repo}: cannot execute curl: {exc.strerror}') from exc
            else:
                status = completed.stdout.strip()
                if completed.returncode == 63 or (output.exists() and output.stat().st_size > MAX_BYTES):
                    raise Invalid(f'{repo}: manifest exceeds 1 MiB')
                if completed.returncode == 0 and status == '200':
                    if not output.is_file():
                        raise Uncertain(f'{repo}: response file missing')
                    return output.read_bytes()
                if status in ('404', '410'):
                    raise Invalid(f'{repo}: marketplace manifest HTTP {status}; update README source or restore it')
                if completed.returncode == 0 and status not in ('408', '425', '429', '500', '502', '503', '504', '403'):
                    raise Invalid(f'{repo}: unexpected HTTP {status}; marketplace could not be resolved')
                last = f'HTTP {status or "unknown"}, curl exit {completed.returncode}'
        if attempt < 2:
            pause = min(attempt + 1, max(0, deadline - time.monotonic()))
            time.sleep(pause)
    raise Uncertain(f'{repo}: resolution uncertain after 3 attempts ({last}); retry without treating this as installed')

def resolve(readme, fetch):
    marketplaces = {}
    seen_repos = {}
    resolved = []
    for kind, target, line in commands(readme):
        if kind == 'add':
            key = target.lower()
            if key in seen_repos:
                continue
            name, plugins = decode_manifest(fetch(target), target)
            if name in marketplaces:
                raise Invalid(f'README:{line}: ambiguous marketplace name {name} from multiple sources')
            marketplaces[name] = (target, plugins)
            seen_repos[key] = name
        else:
            plugin, name = target.split('@')
            if name not in marketplaces:
                raise Invalid(f'README:{line}: marketplace {name} not added under that name before install')
            repo, plugins = marketplaces[name]
            if plugin not in plugins:
                raise Invalid(f'README:{line}: plugin {plugin} missing from {name} ({repo}); update README target or restore the entry')
            resolved.append(f'{target} via {repo}')
    return resolved

def read_checkout_manifest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise Invalid('checkout manifest must be a regular file')
        data = source.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise Invalid('checkout manifest exceeds 1 MiB')
    return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--readme', type=Path, default=Path(__file__).resolve().parents[1] / 'README.md')
    parser.add_argument('--checkout-repo', help='Explicit PR-only repository whose manifest comes from the checkout')
    parser.add_argument('--checkout-manifest', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.readme.stat().st_size > MAX_BYTES:
            raise Invalid('README exceeds 1 MiB')
        readme = args.readme.read_text(encoding='utf-8')
        deadline = time.monotonic() + 90
        if args.checkout_manifest is not None and not args.checkout_repo:
            raise Invalid('--checkout-manifest requires --checkout-repo')
        checkout = repository(args.checkout_repo) if args.checkout_repo else None
        def fetch(repo):
            if checkout and repo.lower() == checkout.lower():
                return read_checkout_manifest(args.checkout_manifest or Path(__file__).resolve().parents[1] / ".claude-plugin/marketplace.json")
            return fetch_manifest(repo, deadline)
        results = resolve(readme, fetch)
    except Invalid as exc:
        print(f'INSTALL_RESOLUTION_INVALID: {exc}', file=sys.stderr)
        return 1
    except (Uncertain, OSError, UnicodeError) as exc:
        print(f'INSTALL_RESOLUTION_UNCERTAIN: {exc}', file=sys.stderr)
        return 2
    for result in results:
        print(f'MEMBERSHIP_RESOLVED: {result}')
    if args.checkout_repo:
        print(f'Scope: checkout membership for {checkout}; remote membership for other repositories.')
    else:
        print('Scope: remote marketplace membership only.')
    print('Claude loader/install not executed or verified.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
