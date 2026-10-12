#!/usr/bin/env python3
"""Check graph isolation and wrapper routing without building application sources."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
DOMAIN = {"VaultCoreTests", "NativeAuthenticationTests", "ExternalAITests", "NoemaBrandTests"}
GATES = ("NOEMA_PERFORMANCE_TESTS", "NOEMA_VISUAL_VALIDATION", "NOEMA_FIXTURE_VALIDATION")


class ValidationTierTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.environment = dict(os.environ)
        for key in (*GATES, "NOEMA_TEST_TIER", "NOEMA_TEST_TARGETS"):
            self.environment.pop(key, None)
        self.environment["CLANG_MODULE_CACHE_PATH"] = str(self.root / "modules")
        self.environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(self.root / "modules")

    def graph(self, **selection):
        environment = dict(self.environment, **selection)
        result = subprocess.run([
            "swift", "package", "--disable-sandbox", "--package-path", str(REPO),
            "--scratch-path", str(self.root / "build"), "--cache-path", str(self.root / "cache"),
            "--config-path", str(self.root / "config"), "--security-path", str(self.root / "security"),
            "dump-package",
        ], env=environment, capture_output=True, text=True, check=True)
        package = json.loads(result.stdout)
        return package, {target["name"] for target in package["targets"] if target["type"] == "test"}

    def wrapper(self, arguments, **selection):
        bin_directory = self.root / "bin"
        bin_directory.mkdir(exist_ok=True)
        capture = self.root / "swift.json"
        runner_root = self.root / "runner"
        scripts = runner_root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        (scripts / "test.sh").write_text((REPO / "scripts/test.sh").read_text())
        cleanup = scripts / "cleanup-local-evidence.sh"
        cleanup.write_text("#!/bin/zsh\nexit 0\n")
        cleanup.chmod(0o755)
        for name, body in {
            "python3": "pass",
            "xcode-select": "print('/nonexistent/noema-test-sdk')",
            "swift": "import json, os, sys\nfrom pathlib import Path\nPath(os.environ['NOEMA_RUNNER_CAPTURE']).write_text(json.dumps({'tier': os.environ.get('NOEMA_TEST_TIER'), 'targets': os.environ.get('NOEMA_TEST_TARGETS'), 'args': sys.argv[1:]}))",
        }.items():
            script = bin_directory / name
            script.write_text(f"#!{sys.executable}\n{body}\n")
            script.chmod(0o755)
        environment = dict(self.environment, **selection)
        environment.update(PATH=str(bin_directory) + os.pathsep + self.environment["PATH"], NOEMA_RUNNER_CAPTURE=str(capture))
        result = subprocess.run(["/bin/zsh", str(scripts / "test.sh"), *arguments], env=environment, capture_output=True, text=True)
        return result, json.loads(capture.read_text()) if capture.exists() else None

    def test_quick_excludes_application_and_specialized_sources(self):
        package, tests = self.graph(NOEMA_TEST_TIER="quick", NOEMA_PERFORMANCE_TESTS="1")
        self.assertEqual(tests, DOMAIN)
        self.assertNotIn("noema", {target["name"] for target in package["targets"]})
        self.assertEqual(package["products"], [])

    def test_standard_compiles_only_requested_targets(self):
        package, tests = self.graph(NOEMA_TEST_TIER="standard", NOEMA_TEST_TARGETS="VaultCoreTests,NativeAuthenticationTests")
        self.assertEqual(tests, {"VaultCoreTests", "NativeAuthenticationTests"})
        self.assertNotIn("noema", {target["name"] for target in package["targets"]})
        _, tests = self.graph(NOEMA_TEST_TIER="standard", NOEMA_TEST_TARGETS="NoemaEditorTests")
        self.assertEqual(tests, {"NoemaEditorTests"})

    def test_extended_retains_functional_coverage_only(self):
        _, tests = self.graph(NOEMA_TEST_TIER="extended")
        self.assertEqual(tests, DOMAIN | {"NoemaEditorTests"})

    def test_specialized_gates_are_isolated(self):
        for gate, target in zip(GATES, ("NoemaPerformanceTests", "NoemaVisualValidationTests", "NoemaFixtureValidationTests")):
            with self.subTest(gate=gate):
                _, tests = self.graph(NOEMA_TEST_TIER="specialized", **{gate: "1"})
                self.assertEqual(tests, {target})

    def test_compile_graph_has_executable_without_tests(self):
        package, tests = self.graph(NOEMA_TEST_TIER="compile")
        self.assertEqual(tests, set())
        self.assertIn("noema", {target["name"] for target in package["targets"]})

    def test_legacy_filter_and_quoted_flags_are_preserved(self):
        result, capture = self.wrapper(["--filter", "a pattern|another", "--skip-update"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture["tier"], "extended")
        self.assertEqual(capture["args"][-3:], ["--filter", "a pattern|another", "--skip-update"])

    def test_standard_selection_is_consumed_before_swift(self):
        result, capture = self.wrapper(["standard", "--targets", "VaultCoreTests", "--filter", "SQLite"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture["tier"], "standard")
        self.assertEqual(capture["targets"], "VaultCoreTests")
        self.assertNotIn("--targets", capture["args"])

    def test_missing_or_invalid_standard_targets_fail_before_swift(self):
        for arguments in (["standard"], ["standard", "--targets", "BadTests"], ["standard", "--targets"]):
            with self.subTest(arguments=arguments):
                result, capture = self.wrapper(arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIsNone(capture)

    def test_skip_build_rejects_a_different_or_unbuilt_graph(self):
        result, _ = self.wrapper(["quick", "--skip-build"])
        self.assertEqual(result.returncode, 2)
        result, _ = self.wrapper(["quick"])
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _ = self.wrapper(["quick", "--skip-build"])
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _ = self.wrapper(["extended", "--skip-build"])
        self.assertEqual(result.returncode, 2)

    def test_skip_build_respects_build_directory_and_configuration(self):
        result, _ = self.wrapper(["quick"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for flags in (["--scratch-path", "different-build"], ["--scratch-path=different-build"], ["-c", "release"], ["--configuration=release"]):
            with self.subTest(flags=flags):
                result, _ = self.wrapper(["quick", "--skip-build", *flags])
                self.assertEqual(result.returncode, 2)

    def test_legacy_specialized_harness_is_preserved(self):
        result, capture = self.wrapper(["--filter", "NoemaVisualValidationTests"], NOEMA_VISUAL_VALIDATION="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(capture["tier"], "specialized")


if __name__ == "__main__":
    unittest.main()
