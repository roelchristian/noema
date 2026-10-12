#!/usr/bin/env python3
"""Managed local evidence only; no caller-supplied cleanup roots."""
import argparse
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import uuid

REPO = Path(__file__).resolve().parent.parent
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}\Z")


def open_directory(name, parent, create=False):
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
    return os.open(name, DIR_FLAGS, dir_fd=parent)


def open_managed(create=False):
    root = os.open(REPO, DIR_FLAGS)
    try:
        local = open_directory('.local', root, create)
        try:
            return open_directory('agent-runs', local, create)
        finally:
            os.close(local)
    finally:
        os.close(root)


def open_run(run_id, create=False):
    if not RUN_ID.fullmatch(run_id):
        raise ValueError('Run ID must be a simple name of at most 96 characters')
    managed = open_managed(create)
    try:
        return open_directory(run_id, managed, create)
    finally:
        os.close(managed)


def exists(fd, name):
    try:
        return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def marker(fd, name):
    temporary = f'.marker-{uuid.uuid4().hex}'
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=fd)
    os.close(descriptor)
    try:
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
    finally:
        if exists(fd, temporary):
            os.unlink(temporary, dir_fd=fd)


def inspect_tree(fd, device):
    """Reject links, mount points and nested repositories before any removal."""
    for name in os.listdir(fd):
        entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if name == '.git' or stat.S_ISLNK(entry.st_mode) or entry.st_dev != device:
            raise ValueError(f'Unsafe evidence entry: {name}')
        if stat.S_ISDIR(entry.st_mode):
            child = open_directory(name, fd)
            try:
                inspect_tree(child, device)
            finally:
                os.close(child)
        elif not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
            raise ValueError(f'Unsupported evidence entry: {name}')


def remove_contents(fd, device, keep_lock=False):
    # Every descent is relative to an already-open directory and uses NOFOLLOW.
    # Even a concurrent path swap cannot redirect deletion into a symlink target.
    for name in os.listdir(fd):
        if keep_lock and name == '.active':
            continue
        entry = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if name == '.git' or stat.S_ISLNK(entry.st_mode) or entry.st_dev != device:
            raise ValueError(f'Unsafe evidence entry: {name}')
        if stat.S_ISDIR(entry.st_mode):
            child = open_directory(name, fd)
            try:
                remove_contents(child, device)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=fd)
        elif stat.S_ISREG(entry.st_mode):
            os.unlink(name, dir_fd=fd)
        else:
            raise ValueError(f'Unsupported evidence entry: {name}')


def eligible(fd, cutoff, force):
    if exists(fd, '.active') or exists(fd, '.pinned'):
        return False
    completed = exists(fd, '.complete')
    if completed and not stat.S_ISREG(completed.st_mode):
        raise ValueError('Completion marker must be a regular file')
    return bool(completed and stat.S_ISREG(completed.st_mode)
                and (force or completed.st_mtime < cutoff))


def cleanup(args):
    match = re.fullmatch(r'(\d+)([dhm])', args.older_than)
    if not match:
        raise ValueError('--older-than must be a nonnegative duration such as 7d, 24h or 30m')
    cutoff = time.time() - int(match[1]) * {'d': 86400, 'h': 3600, 'm': 60}[match[2]]
    try:
        managed = open_managed()
    except FileNotFoundError:
        return
    rejected = []
    try:
        for name in sorted(os.listdir(managed)):
            run = None
            locked = False
            try:
                if not RUN_ID.fullmatch(name):
                    raise ValueError('Invalid managed run name')
                run = open_directory(name, managed)
                identity = os.fstat(run)
                if not eligible(run, cutoff, args.force):
                    continue
                inspect_tree(run, identity.st_dev)
                if args.dry_run:
                    print(f'Would remove: .local/agent-runs/{name}')
                    continue
                # This is the same lock acquired by capture/selection producers.
                try:
                    os.mkdir('.active', dir_fd=run)
                except FileExistsError:
                    continue
                locked = True
                completed = exists(run, '.complete')
                if (exists(run, '.pinned') or not completed
                        or not stat.S_ISREG(completed.st_mode)
                        or (not args.force and completed.st_mtime >= cutoff)):
                    continue
                current = os.stat(name, dir_fd=managed, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
                    raise ValueError('Run directory changed during cleanup')
                inspect_tree(run, identity.st_dev)
                remove_contents(run, identity.st_dev, keep_lock=True)
                os.rmdir('.active', dir_fd=run)
                locked = False
                current = os.stat(name, dir_fd=managed, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
                    raise ValueError('Run directory changed during cleanup')
                os.rmdir(name, dir_fd=managed)
                print(f'Removed: .local/agent-runs/{name}')
            except (OSError, ValueError) as error:
                rejected.append(f'{name}: {error}')
            finally:
                if run is not None:
                    if locked:
                        os.rmdir('.active', dir_fd=run)
                    os.close(run)
    finally:
        os.close(managed)
    if rejected:
        raise ValueError('Refused unsafe evidence: ' + '; '.join(rejected))


def capture(args):
    if os.environ.get('BASELINE_REF'):
        raise ValueError('Historical pre-token capture is retired; recover the original fixture from Git history')
    phase = args.phase or 'after'
    kind = getattr(args, 'kind', 'tokens')
    run_id = args.run_id or time.strftime(f'visual-{kind}-%Y%m%dT%H%M%S') + f'-{os.getpid()}'
    run = open_run(run_id, True)
    locked = False
    try:
        inspect_tree(run, os.fstat(run).st_dev)
        os.mkdir('.active', dir_fd=run)
        locked = True
        if exists(run, phase):
            raise ValueError(f'{phase} already exists; choose a fresh run ID')
        for name in ('.complete', '.failed'):
            if exists(run, name):
                os.unlink(name, dir_fd=run)
        os.mkdir(phase, dir_fd=run)
        output = REPO / '.local/agent-runs' / run_id / phase
        variable, suite = {
            'tokens': ('NOEMA_TOKEN_SCREENSHOT_DIR', 'DesignTokenCaptureTests'),
            'typography': ('NOEMA_TYPOGRAPHY_AFTER_CAPTURE_DIR', 'TypographyCaptureTests'),
        }[kind]
        env = dict(os.environ, NOEMA_VISUAL_VALIDATION='1', **{variable: str(output)})
        subprocess.run(['./scripts/test.sh', '--filter', suite], cwd=REPO, env=env, check=True)
        ref = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO)
        (output / 'source-ref.txt').write_bytes(ref)
        platform = subprocess.check_output(['sw_vers']) + subprocess.check_output(['swift', '--version'])
        (output / 'platform.txt').write_bytes(platform)
        marker(run, '.complete')
        print(f'Captured {kind} {phase}: {output}')
        if kind == 'tokens':
            print(f'Select both current matrices: python3 validation/ui-design-tokens/select-evidence.py --run-id {run_id}')
    except Exception:
        if locked:
            marker(run, '.failed')
            marker(run, '.complete')
        raise
    finally:
        if locked:
            os.rmdir('.active', dir_fd=run)
        os.close(run)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    clean = actions.add_parser('cleanup')
    clean.add_argument('--older-than', default='7d')
    clean.add_argument('--dry-run', action='store_true')
    clean.add_argument('--force', action='store_true', help='Bypass age only; completed, active and pinned rules still apply')
    clean.add_argument('--protect-active', action='store_true', help='Active runs are always protected')
    cap = actions.add_parser('capture')
    cap.add_argument('--kind', choices=['tokens', 'typography'], default='tokens')
    cap.add_argument('run_id', nargs='?')
    cap.add_argument('phase', choices=['baseline', 'after'], nargs='?')
    args = parser.parse_args()
    try:
        (cleanup if args.action == 'cleanup' else capture)(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
