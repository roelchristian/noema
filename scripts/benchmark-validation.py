#!/usr/bin/env python3
"""Record one explicitly labelled validation timing in managed local evidence."""
import argparse
import json
import os
import platform
import signal
import subprocess
import time

from local_evidence import REPO, marker, open_run


def metadata(command):
    try:
        return subprocess.check_output(command, cwd=REPO, stderr=subprocess.STDOUT,
                                       timeout=15, text=True).strip()
    except (OSError, subprocess.SubprocessError) as error:
        return f'unavailable: {error}'


def write_record(run, name, value):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=run)
    with os.fdopen(fd, 'w') as stream:
        stream.write(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True, help='Fresh simple managed run name')
    parser.add_argument('--phase', required=True, choices=['clean', 'incremental', 'warm', 'execution'])
    parser.add_argument('--change', default='', help='Exact single-file change for an incremental sample')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.timeout <= 0:
        parser.error('Provide a command after -- and a positive timeout')
    if args.phase == 'incremental' and not args.change:
        parser.error('Incremental samples require --change describing the single-file edit')
    run = open_run(args.run_id, True)
    locked = False
    try:
        # Completed names are immutable: use a fresh run ID for each sample.
        if os.listdir(run):
            raise ValueError('Run already contains evidence; choose a fresh run ID')
        os.mkdir('.active', dir_fd=run)
        locked = True
        details = {'phase': args.phase, 'command': command, 'change': args.change,
                   'platform': platform.platform(), 'source_ref': metadata(['git', 'rev-parse', 'HEAD']),
                   'source_changes': metadata(['git', 'status', '--short']),
                   'swift': metadata(['swift', '--version']),
                   'macos': metadata(['sw_vers']), 'timeout_seconds': args.timeout}
        write_record(run, 'context.json', json.dumps(details, indent=2) + '\n')
        write_record(run, 'inventory.json', metadata(['python3', 'scripts/test-inventory.py', '--json']) + '\n')
        log_fd = os.open('command.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=run)
        started = time.perf_counter()
        with os.fdopen(log_fd, 'w') as log:
            try:
                child = subprocess.Popen(command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT,
                                         start_new_session=True)
                try:
                    status = child.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                    status = 124
                    log.write('\nValidation command timed out.\n')
                except BaseException:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                    raise
            except OSError:
                raise
        elapsed = time.perf_counter() - started
        write_record(run, 'result.json', json.dumps({'elapsed_seconds': elapsed, 'exit_code': status}, indent=2) + '\n')
        if status:
            marker(run, '.failed')
        marker(run, '.complete')
        print(f'{args.phase}: {elapsed:.3f}s; exit {status}; .local/agent-runs/{args.run_id}')
        return status
    except BaseException:
        if locked:
            marker(run, '.failed')
            marker(run, '.complete')
        raise
    finally:
        if locked:
            os.rmdir('.active', dir_fd=run)
        os.close(run)


if __name__ == '__main__':
    raise SystemExit(main())
