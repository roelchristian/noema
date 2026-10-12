#!/usr/bin/env python3
"""Adversarial regressions for retention, references and warning-only limits."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('hygiene', Path(__file__).with_name('check-repository-hygiene.py'))
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class HygieneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = []
        self.write(hygiene.REGISTRY, '[]')

    def write(self, path, text=''):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        if path not in self.files:
            self.files.append(path)

    def inspect(self):
        return hygiene.inspect(self.root, self.files)

    def test_root_allowlist_and_markdown_case(self):
        for path in ['README.md', 'AGENTS.md']:
            self.assertFalse(hygiene.path_errors(path, set()))
        for path in ['TASK.md', 'notes.MD', 'journal.markdown']:
            self.assertTrue(hygiene.path_errors(path, set()))

    def test_local_never_approved(self):
        self.assertTrue(hygiene.path_errors('.local/agent-runs/test/output.swift', {'.local/agent-runs/test/output.swift'}))
        self.assertTrue(hygiene.path_errors('AGENTS.local.md', set()))

    def test_generated_paths_and_extensions(self):
        for path in ['validation/tokens/shot.png', 'validation/log.txt', 'validation/evidence/data.json', 'validation/capture-manifest.json', 'validation/notes.md', 'validation/report.html']:
            self.assertTrue(hygiene.path_errors(path, set()), path)
        for path in ['validation/tokens/capture.sh', 'validation/tokens/.gitignore', 'Tests/sample.png', 'Resources/Brand/Icon.png', 'Examples/Protected Fixture/Wiki/Story.md']:
            self.assertFalse(hygiene.path_errors(path, set()), path)

    def test_docs_evidence_directories_do_not_bypass_retention(self):
        for directory in ['screenshots', 'evidence', 'generated', 'captures', 'reports']:
            self.assertTrue(hygiene.path_errors(f'docs/{directory}/output.png', set()))
            self.assertTrue(hygiene.path_errors(f'docs/{directory}/run.md', set()))
        self.assertFalse(hygiene.path_errors('docs/diagrams/storage.svg', set()))
        self.assertFalse(hygiene.path_errors('Resources/Brand/Canonical.png', set()))
        self.assertFalse(hygiene.path_errors('Tests/Fixtures/Expected.png', set()))
        self.write('docs/screenshots/fixture.png')
        self.write(hygiene.REGISTRY, '[{"path":"docs/screenshots/fixture.png","reason":"Reviewed exact golden fixture"}]')
        self.assertFalse(self.inspect()[0])

    def test_reviewed_fixture_needs_valid_exact_owner(self):
        self.write('validation/fixture.png')
        self.write(hygiene.REGISTRY, '[{"path":"validation/fixture.png","reason":"Reviewed render regression input"}]')
        self.assertFalse(self.inspect()[0])
        for registry in ['[{"path":"validation/fixture.png","reason":""}]', '[{"path":"validation/missing.png","reason":"review"}]', '[{"path":"validation/../README.md","reason":"review"}]']:
            self.write(hygiene.REGISTRY, registry)
            self.assertTrue(self.inspect()[0])

    def test_malformed_registry_is_hard_failure(self):
        self.write(hygiene.REGISTRY, '{}')
        self.assertTrue(self.inspect()[0])

    def test_historical_names_anywhere(self):
        self.assertTrue(hygiene.path_errors('docs/decisions/task-report.md', set()))
        self.assertTrue(hygiene.path_errors('docs/milestone-07.md', set()))
        self.assertFalse(hygiene.path_errors('docs/contracts/storage-boundary.md', set()))

    def test_milestone_reports_do_not_become_new_permanent_documents(self):
        for path in ['docs/UI_TBR_VALIDATION.md', 'docs/UI_TBR_ARCHITECTURE_AUDIT.md', 'docs/D02_RECONSTRUCTION_REPORT.md', 'docs/MAINT.CL02_retention_completion.md', 'docs/UI.TK07_visual_evidence.md']:
            self.assertTrue(hygiene.path_errors(path, set()), path)
        for path in ['docs/validation.md', 'docs/contracts/storage-boundary.md', 'docs/contracts/UI_TBR_toolbar.md', 'docs/decisions/D02_schema-selection.md', 'Resources/Brand/CONTRACT.md']:
            self.assertFalse(hygiene.path_errors(path, set()), path)

    def test_relative_links_escaped_spaces_fragments_and_references(self):
        self.write('docs/contracts/storage.md', '# Storage\n\n<a id="review"></a>')
        self.write('docs/A Guide.md', '# A Guide')
        self.write('README.md', '[contract](docs/contracts/storage.md#review)\n[guide](<docs/A Guide.md>)\n[ref]: docs/A%20Guide.md#a-guide\n[external](https://example.com/no.md)')
        self.assertFalse(self.inspect()[0])
        self.write('README.md', '[missing](docs/missing.md)\n[anchor](docs/contracts/storage.md#absent)\n[escape](../outside.md)')
        errors = "\n".join(self.inspect()[0])
        for target in ["docs/missing.md", "storage.md#absent", "../outside.md"]:
            self.assertIn(target, errors)

    def test_source_script_and_test_document_references(self):
        self.write('docs/validation.md', '# Validation')
        for path in ['Sources/App.swift', 'scripts/check.py', 'Tests/AppTests.swift']:
            self.write(path, '"docs/validation.md"')
        self.assertFalse(self.inspect()[0])
        self.write('scripts/check.py', '"OLD' + '_CONTRACT.md"')
        self.assertTrue(self.inspect()[0])

    def test_examples_do_not_require_wiki_link_resolution(self):
        self.write('Examples/Protected Fixture/Wiki/Page.md', '[personal](missing.md)')
        self.assertFalse(self.inspect()[0])

    def test_linked_sources_and_scripts_must_exist(self):
        self.write('docs/validation.md', '[test](../Tests/Missing.swift)\n[command](../scripts/missing.sh)')
        self.assertEqual(len(self.inspect()[0]), 2)

    def test_size_warning_is_not_failure(self):
        self.write('AGENTS.md', 'instruction\n' * 121)
        self.write('docs/validation.md', 'baseline\n' * 301)
        errors, warnings = self.inspect()
        self.assertFalse(errors)
        self.assertEqual(len(warnings), 2)
        self.write('docs/validation.md', 'x' * 30001)
        self.assertEqual(len(self.inspect()[1]), 2)

    def test_tracked_broken_and_directory_symlinks_cannot_hide_artifacts(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name, target in [('.local/escape', self.root), ('validation/screenshots/escape', self.root / 'missing')]:
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(target)
            subprocess.run(['git', 'add', '-f', name], cwd=self.root, check=True)
        files = hygiene.repository_files(self.root)
        self.assertIn('.local/escape', files)
        self.assertIn('validation/screenshots/escape', files)
        errors, _ = hygiene.inspect(self.root, files + [hygiene.REGISTRY])
        self.assertTrue(any('Private/local' in error for error in errors))
        self.assertTrue(any('Generated validation artifact' in error for error in errors))

    def test_symlink_text_does_not_read_outside_repository(self):
        target = self.root.parent / (self.root.name + '-private')
        target.write_text('private')
        self.addCleanup(target.unlink)
        (self.root / 'README.md').symlink_to(target)
        errors, _ = hygiene.inspect(self.root, self.files + ['README.md'])
        self.assertTrue(any('escaping repository symlink' in error for error in errors))

    def test_git_inventory_excludes_deleted_includes_new_only_on_request(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.write('README.md')
        subprocess.run(['git', 'add', 'README.md'], cwd=self.root, check=True)
        self.write('NEW.md')
        self.assertNotIn('NEW.md', hygiene.repository_files(self.root))
        self.assertIn('NEW.md', hygiene.repository_files(self.root, True))
        (self.root / 'README.md').unlink()
        self.assertNotIn('README.md', hygiene.repository_files(self.root))


if __name__ == '__main__':
    unittest.main()
