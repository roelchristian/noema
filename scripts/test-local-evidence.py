#!/usr/bin/env python3
"""Retention safety and local screenshot-regeneration contract tests."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parent.parent


class LocalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        (self.repo / 'validation/ui-design-tokens').mkdir(parents=True)
        for name in ('cleanup-local-evidence.sh', 'local_evidence.py'):
            shutil.copy2(SOURCE / 'scripts' / name, self.repo / 'scripts' / name)
        shutil.copy2(SOURCE / 'validation/ui-design-tokens/select-evidence.py',
                     self.repo / 'validation/ui-design-tokens/select-evidence.py')
        self.managed = self.repo / '.local/agent-runs'
        self.managed.mkdir(parents=True)
        self.outside = Path(self.temp.name) / 'user-vault'
        self.outside.mkdir()
        (self.outside / 'keep.md').write_text('user content')

    def tearDown(self):
        self.assertEqual((self.outside / 'keep.md').read_text(), 'user content')
        self.temp.cleanup()

    def run_cleanup(self, *args, expected=0):
        result = subprocess.run(['bash', str(self.repo / 'scripts/cleanup-local-evidence.sh'), *args],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def run_dir(self, name, age=8, complete=True):
        run = self.managed / name
        run.mkdir()
        (run / 'diagnostics.log').write_text('local diagnostics')
        if complete:
            (run / '.complete').touch()
            stamp = time.time() - age * 86400
            os.utime(run / '.complete', (stamp, stamp))
        return run

    def test_default_retention_and_completion_age(self):
        expired = self.run_dir('expired')
        fresh = self.run_dir('fresh', age=1)
        pending = self.run_dir('unfinished', complete=False)
        failed = self.run_dir('failed')
        (failed / '.failed').touch()
        # Directory mtime is irrelevant: completion marker anchors retention.
        os.utime(fresh, (1, 1))
        result = self.run_cleanup()
        self.assertFalse(expired.exists())
        self.assertFalse(failed.exists())
        self.assertTrue(fresh.exists())
        self.assertTrue(pending.exists())
        self.assertIn('expired', result.stdout)

    def test_dry_run_and_duration(self):
        old = self.run_dir('old')
        result = self.run_cleanup('--older-than', '24h', '--dry-run', '--protect-active')
        self.assertTrue(old.exists())
        self.assertIn('Would remove', result.stdout)
        self.run_cleanup('--older-than', '0m')
        self.assertFalse(old.exists())

    def test_force_never_overrides_active_pinned_or_incomplete(self):
        for name in ('active-file', 'active-lock', 'pinned-file', 'pinned-directory'):
            run = self.run_dir(name)
            marker = run / ('.active' if name.startswith('active') else '.pinned')
            if name.endswith(('lock', 'directory')):
                marker.mkdir()
            else:
                marker.touch()
        pending = self.run_dir('pending', complete=False)
        fresh = self.run_dir('fresh', age=0)
        self.run_cleanup('--force')
        self.assertFalse(fresh.exists())
        self.assertTrue(pending.exists())
        self.assertEqual(len(list(self.managed.iterdir())), 5)

    def test_reject_arbitrary_paths_and_malformed_age(self):
        for arguments in (('--root', str(self.outside)), ('--older-than', '-1d'),
                          ('--older-than', 'seven'), (str(self.outside),)):
            result = subprocess.run(['bash', str(self.repo / 'scripts/cleanup-local-evidence.sh'), *arguments],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_reject_linked_managed_ancestors(self):
        shutil.rmtree(self.repo / '.local')
        (self.repo / '.local').symlink_to(self.outside, target_is_directory=True)
        self.run_cleanup('--force', expected=1)
        (self.repo / '.local').unlink()
        (self.repo / '.local').mkdir()
        self.managed.symlink_to(self.outside, target_is_directory=True)
        self.run_cleanup('--force', expected=1)

    def test_reject_symlinked_run_and_nested_escape_before_removal(self):
        linked = self.managed / 'vault'
        linked.symlink_to(self.outside, target_is_directory=True)
        run = self.run_dir('nested')
        (run / 'output').symlink_to(self.outside, target_is_directory=True)
        self.run_cleanup('--force', expected=1)
        self.assertTrue(linked.is_symlink())
        self.assertTrue((run / 'diagnostics.log').exists())

    def test_reject_linked_completion_and_internal_symlink(self):
        run = self.run_dir('internal-link')
        (run / 'alias').symlink_to(run / 'diagnostics.log')
        self.run_cleanup('--force', expected=1)
        self.assertTrue(run.exists())
        (run / 'alias').unlink()
        other = self.run_dir('marker-link')
        (other / '.complete').unlink()
        (other / '.complete').symlink_to(self.outside / 'keep.md')
        self.run_cleanup('--force', expected=1)
        self.assertTrue(other.exists())

    def test_reject_nested_git_worktree_and_hardlinks(self):
        worktree = self.run_dir('worktree')
        (worktree / 'checkout').mkdir()
        (worktree / 'checkout/.git').write_text('gitdir: /some/real/worktree')
        hardlinked = self.run_dir('hardlink')
        os.link(self.outside / 'keep.md', hardlinked / 'external-link')
        self.run_cleanup('--force', expected=1)
        self.assertTrue((worktree / 'diagnostics.log').exists())
        self.assertTrue((hardlinked / 'diagnostics.log').exists())

    def test_nonmanaged_fixtures_and_vault_never_touched(self):
        for path in ('Tests/fixtures', 'Examples/Demo Vault', 'Resources/Brand', 'validation/fixtures'):
            target = self.repo / path
            target.mkdir(parents=True)
            (target / '.complete').touch()
            (target / 'keep.png').write_bytes(b'canonical')
        self.run_dir('eligible')
        self.run_cleanup('--force')
        for path in ('Tests/fixtures', 'Examples/Demo Vault', 'Resources/Brand', 'validation/fixtures'):
            self.assertEqual((self.repo / path / 'keep.png').read_bytes(), b'canonical')

    def test_path_swap_during_deletion_cannot_follow_symlink(self):
        spec = importlib.util.spec_from_file_location('cleanup_under_test', SOURCE / 'scripts/local_evidence.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        run = self.run_dir('race')
        child = run / 'nested'
        child.mkdir()
        (child / 'evidence.log').write_text('local')
        descriptor = os.open(run, module.DIR_FLAGS)
        original_open = module.open_directory
        def swap(name, parent, create=False):
            if name == 'nested':
                child.rename(run / 'original')
                child.symlink_to(self.outside, target_is_directory=True)
            return original_open(name, parent, create)
        module.open_directory = swap
        try:
            with self.assertRaises(OSError):
                module.remove_contents(descriptor, os.fstat(descriptor).st_dev)
        finally:
            os.close(descriptor)

    def test_capture_lock_completion_and_failure_lifecycle(self):
        binary = self.repo / 'fake-bin'
        binary.mkdir()
        for name, text in (('git', 'echo source-commit'), ('sw_vers', 'echo macOS-test'),
                           ('swift', 'echo Swift-test')):
            executable = binary / name
            executable.write_text('#!/bin/sh\n' + text + '\n')
            executable.chmod(0o755)
        test_script = self.repo / 'scripts/test.sh'
        test_script.write_text('#!/bin/sh\n' +
            'test -d "$NOEMA_TOKEN_SCREENSHOT_DIR/../.active" || exit 90\n' +
            'test ! -e "$NOEMA_TOKEN_SCREENSHOT_DIR/../.complete" || exit 91\n' +
            'echo image > "$NOEMA_TOKEN_SCREENSHOT_DIR/capture.png"\n')
        test_script.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'])
        env.pop('BASELINE_REF', None)
        command = [sys.executable, str(self.repo / 'scripts/local_evidence.py'), 'capture', 'producer', 'after']
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        run = self.managed / 'producer'
        self.assertEqual((run / 'after/source-ref.txt').read_text().strip(), 'source-commit')
        self.assertFalse((run / '.active').exists())
        self.assertFalse((run / '.complete').exists())
        test_script.write_text('#!/bin/sh\nexit 1\n')
        command[-2] = 'failed-producer'
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        failed = self.managed / 'failed-producer'
        self.assertTrue((failed / '.complete').is_file())
        self.assertTrue((failed / '.failed').is_file())
        self.assertFalse((failed / '.active').exists())
        for malicious in ('../user-vault', str(self.outside), 'nested/run', '.hidden'):
            command[-2] = malicious
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_selection_stays_local_and_requires_full_matrix(self):
        fixture = self.repo / 'Tests/NoemaEditorTests/DesignTokenValidationTests.swift'
        fixture.parent.mkdir(parents=True)
        fixture.write_text('// executable fixture retained')
        run = self.run_dir('tokens', complete=False)
        modes = [f'{theme}-{scheme}-{contrast}' for theme in ('system', 'midnightIris')
                 for scheme in ('light', 'dark') for contrast in ('standard', 'increased')]
        selected = [f'workspace-minimum-{mode}.png' for mode in modes]
        selected += [f'inspector-minimum-{mode}.png' for mode in (
            'system-light-standard', 'system-dark-increased', 'midnightIris-dark-standard', 'midnightIris-light-increased')]
        selected += ['sources-native-table-system-light-standard.png', 'workspace-locked-midnightIris-dark-standard.png',
                     'workspace-no-vault-system-light-standard.png', 'vault-creation-sheet-content-midnightIris-dark-standard.png']
        for phase in ('baseline', 'after'):
            directory = run / phase
            directory.mkdir()
            for name in selected + [f'additional-{i}.png' for i in range(120)]:
                (directory / name).write_bytes(b'fixture-image')
            (directory / 'source-ref.txt').write_text(f'{phase}-commit')
            (directory / 'platform.txt').write_text('test fixture environment')
        command = [sys.executable, str(self.repo / 'validation/ui-design-tokens/select-evidence.py'), '--run-id', 'tokens']
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((run / 'capture-manifest.json').read_text())
        self.assertEqual(len(manifest['captures']['baseline']), 136)
        self.assertEqual(len(list((run / 'evidence').rglob('*.png'))), 32)
        self.assertTrue((run / '.complete').is_file())
        self.assertFalse((run / '.active').exists())
        self.assertFalse((self.repo / 'validation/ui-design-tokens/evidence').exists())
        (run / 'after/additional-0.png').unlink()
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((run / '.failed').exists())
        self.assertIn('found 135', result.stderr)


if __name__ == '__main__':
    unittest.main()
