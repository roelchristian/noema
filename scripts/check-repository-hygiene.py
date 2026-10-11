#!/usr/bin/env python3
"""Check repository paths, generated evidence and local documentation references.

Inspect tracked files by default; --include-untracked also checks new nonignored
files before staging. This is a lexical link guard, not a Markdown/code parser.
"""
import argparse
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
ROOT_MARKDOWN = {'README.md', 'AGENTS.md'}
REGISTRY = 'scripts/repository-hygiene-fixtures.json'
GENERATED = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.pdf', '.log', '.txt',
             '.csv', '.tsv', '.trace', '.zip', '.md', '.markdown', '.html'}
# HTML can be a genuine executable fixture, but requires explicit reviewed ownership.
REPORT = re.compile(r'(?:^|[-_.])(?:milestone|journal|transcript|investigation|'
                    r'completion-report|validation-report|task-report)(?:[-_.]|$)', re.I)
LINK = re.compile(r'!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+["\'][^\n]*?["\'])?\s*\)')
REFERENCE = re.compile(r'^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)', re.M)
# Source/script literals and Markdown code references to repository docs are audited,
# including old uppercase root document names even when not written as Markdown links.
DOC_PATH = re.compile(r'(?<![\w/-])((?:\.{1,2}/)*(?:docs/|Resources/|scripts/|\.github/)[\w./-]+\.md|[A-Z][A-Z_0-9-]*\.md|README\.md|AGENTS\.md)(?:#[\w-]+)?')
TEXT_SUFFIXES = {'.md', '.markdown', '.swift', '.py', '.sh', '.json', '.yml', '.yaml', '.html'}


def repository_files(root, include_untracked=False):
    args = ['git', 'ls-files', '-z', '--cached']
    if include_untracked:
        args += ['--others', '--exclude-standard']
    names = subprocess.check_output(args, cwd=root).decode().split('\0')
    # Deleted tracked files are absent in the proposed working tree.
    return sorted({n for n in names if n and ((root / n).exists() or (root / n).is_symlink())})


def fixture_registry(root, files):
    errors = []
    try:
        entries = json.loads((root / REGISTRY).read_text())
        if not isinstance(entries, list):
            raise ValueError('expected a list')
        approved = set()
        for entry in entries:
            path, reason = entry['path'], entry['reason']
            parsed = PurePosixPath(path)
            if (not isinstance(reason, str) or not reason.strip() or
                    parsed.is_absolute() or '..' in parsed.parts or
                    not path.startswith('validation/') or path not in files or
                    path in approved):
                raise ValueError(f'invalid/stale/duplicate fixture ownership: {path}')
            approved.add(path)
        return approved, errors
    except (OSError, ValueError, TypeError, KeyError) as error:
        return set(), [f'{REGISTRY}: {error}']


def path_errors(path, approved):
    parts = PurePosixPath(path).parts
    suffix = PurePosixPath(path).suffix.lower()
    errors = []
    if len(parts) == 1 and suffix in {'.md', '.markdown'} and path not in ROOT_MARKDOWN:
        errors.append(f'Root Markdown is not allowlisted: {path}')
    if parts[0] == '.local' or path == 'AGENTS.local.md':
        errors.append(f'Private/local output must be untracked: {path}')
    if suffix in {'.md', '.markdown', '.txt'} and REPORT.search(PurePosixPath(path).name):
        errors.append(f'Historical execution report must remain local: {path}')
    if parts[0] == 'validation' and path not in approved:
        if suffix in GENERATED or any(p.lower() in {'evidence', 'generated', 'captures', 'screenshots', 'reports'} for p in parts[1:-1]) or 'manifest' in parts[-1].lower():
            errors.append(f'Generated validation artifact needs reviewed fixture ownership: {path}')
    return errors


def anchors(text):
    found = set(re.findall(r'<a\s+[^>]*id=["\']([^"\']+)', text, re.I))
    used = {}
    for heading in re.findall(r'^#{1,6}\s+(.+?)(?:\s+#+)?$', text, re.M):
        heading = re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-')
        count = used.get(heading, 0)
        found.add(heading + (f'-{count}' if count else ''))
        used[heading] = count + 1
    return found


def link_error(root, origin, target):
    target = target.strip('<>')
    parsed = urlsplit(target)
    if parsed.scheme or target.startswith('//'):
        return None
    local = unquote(parsed.path)
    resolved = (root / origin).parent / local if local else root / origin
    resolved = resolved.resolve()
    if not resolved.is_relative_to(root.resolve()) or not resolved.exists():
        return f'{origin}: broken local reference {target}'
    if parsed.fragment and resolved.suffix.lower() in {'.md', '.markdown'}:
        if unquote(parsed.fragment) not in anchors(resolved.read_text()):
            return f'{origin}: missing anchor {target}'
    return None


def inspect(root, files):
    approved, errors = fixture_registry(root, files)
    warnings = []
    for path in files:
        errors.extend(path_errors(path, approved))
        candidate = root / path
        if candidate.is_symlink():
            resolved = candidate.resolve()
            if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
                errors.append(f'{path}: broken, directory or escaping repository symlink')
                continue
        if candidate.suffix.lower() not in TEXT_SUFFIXES or path.startswith('Examples/'):
            continue  # User/example vault contents are not engineering documentation.
        try:
            text = candidate.read_text()
        except (UnicodeError, OSError) as error:
            errors.append(f'{path}: cannot read text: {error}')
            continue
        if candidate.suffix.lower() in {'.md', '.markdown'}:
            for target in [*LINK.findall(text), *REFERENCE.findall(text)]:
                error = link_error(root, path, target)
                if error:
                    errors.append(error)
        # This module deliberately contains missing/hostile reference fixtures.
        # All production files and Swift test references still receive this audit.
        literal_text = "" if path == "scripts/test-repository-hygiene.py" else text
        for match in DOC_PATH.finditer(literal_text):
            target = match.group(0)
            # Code literals often use root-relative commands; prefer document-relative
            # first for Markdown, then repository-relative for source/script comments.
            direct = link_error(root, path, target)
            if direct and link_error(root, 'README.md', target):
                errors.append(f'{path}: missing documentation reference {target}')
        lines, size = len(text.splitlines()), len(text.encode())
        if path == 'AGENTS.md' and lines > 120:
            warnings.append(f'{path}: {lines} lines (target <=120)')
        if path == 'docs/validation.md' and (lines > 300 or size > 30000):
            warnings.append(f'{path}: {lines} lines/{size} bytes (target 200–300 lines, <=30 KB)')
    return sorted(set(errors)), warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-untracked', action='store_true')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    if args.selftest:
        import unittest
        spec = importlib.util.spec_from_file_location('hygiene_tests', ROOT / 'scripts/test-repository-hygiene.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        if suite.countTestCases() == 0:
            raise RuntimeError('Hygiene selftest loaded no tests')
        if not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful():
            return 1
    files = repository_files(ROOT, args.include_untracked)
    errors, warnings = inspect(ROOT, files)
    for warning in warnings:
        print(f'WARNING: {warning}', file=sys.stderr)
    for error in errors:
        print(f'ERROR: {error}', file=sys.stderr)
    if errors:
        return 1
    print(f'Repository hygiene passed ({len(files)} files; {len(warnings)} size warnings).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
