#!/usr/bin/env python3
"""Synthetic parser/extraction tests; never build, sign, or launch the probe.

Run with: python3 -B Scripts/test_sandbox_probe.py
"""
import sys

sys.dont_write_bytecode = True

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("run-sandbox-probe.py")
SPEC = importlib.util.spec_from_loader("sandbox_probe_under_test", loader=None,
                                      origin=str(SCRIPT))
PROBE = importlib.util.module_from_spec(SPEC)
PROBE.__file__ = str(SCRIPT)
# Compile and import entirely in memory, without a loader's bytecode cache or main().
exec(compile(SCRIPT.read_bytes(), str(SCRIPT), "exec"), PROBE.__dict__)

BUNDLE_ID = "com.jianhongli.LiveLingo.sandboxprobe." + "0123456789abcdef" * 2
# Independent contract: a missing case in the implementation must not shrink fixtures.
CASE_NAMES = (
    "open_existing", "missing_without_create", "create_private_components",
    "reject_leaf_symlink", "reject_ancestor_symlink", "reject_missing_below_symlink",
    "reject_non_directory", "atomic_write_read", "atomic_replace_permissions",
    "append_read", "reject_file_symlink", "assert_path_identity", "move_remove_directory",
    "recovery_scan", "temporary_session_cleanup", "pending_cleanup_retry",
    "recording_recovery_index",
)
CHECK_NAMES = ("sandbox_identity", "container_parent_tracking") + tuple(
    f"{root}.{case}" for root in ("tmp", "support") for case in CASE_NAMES
)
NON_BOOLEANS = (0, 1, -1, 0.0, 1.0, "true", "false", "", None, [], {})


def result(*failed):
    """Build a fresh JSON-compatible result containing every required check."""
    return {
        "version": 1,
        "bundle_id": BUNDLE_ID,
        "passed": not failed,
        "checks": [
            {"name": name, "passed": name not in failed, "detail": None}
            for name in CHECK_NAMES
        ],
    }


class ValidateResultTests(unittest.TestCase):
    def assert_rejected(self, value, reason, returncode=0, bundle_id=BUNDLE_ID):
        with self.assertRaisesRegex(ValueError, reason):
            PROBE.validate_result(value, returncode, bundle_id)

    def test_required_check_contract(self):
        self.assertEqual(PROBE.EXPECTED, set(CHECK_NAMES))
        self.assertEqual(len(CHECK_NAMES), len(set(CHECK_NAMES)))

    def test_complete_green_result(self):
        value = json.loads(json.dumps(result()))
        before = copy.deepcopy(value)
        self.assertIs(PROBE.validate_result(value, 0, BUNDLE_ID), True)
        self.assertEqual(value, before)

    def test_complete_red_result(self):
        value = json.loads(json.dumps(result("support.atomic_write_read")))
        self.assertIs(PROBE.validate_result(value, 1, BUNDLE_ID), False)

    def test_complete_result_with_every_storage_check_red(self):
        value = result(*CHECK_NAMES[1:])
        self.assertIs(PROBE.validate_result(value, 1, BUNDLE_ID), False)

    def test_check_order_is_not_significant(self):
        for failed, returncode in (((), 0), (("tmp.append_read",), 1)):
            with self.subTest(failed=failed):
                value = result(*failed)
                value["checks"].reverse()
                self.assertIs(PROBE.validate_result(value, returncode, BUNDLE_ID),
                              not failed)

    def test_reject_non_object_result(self):
        for value in (None, [], [result()], "result", 1, True):
            with self.subTest(value=value):
                self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_missing_identity_fields(self):
        for field in ("version", "bundle_id"):
            with self.subTest(field=field):
                value = result()
                del value[field]
                self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_wrong_schema_version(self):
        for version in (0, 2, -1, "1", None, False, [], {}):
            with self.subTest(version=version):
                value = result()
                value["version"] = version
                self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_boolean_schema_version(self):
        value = result()
        value["version"] = True
        self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_float_schema_version(self):
        value = result()
        value["version"] = 1.0
        self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_wrong_bundle(self):
        for bundle in (BUNDLE_ID + "other", "", None, 1, True, []):
            with self.subTest(bundle=bundle):
                value = result()
                value["bundle_id"] = bundle
                self.assert_rejected(value, "invalid probe identity or schema")

    def test_reject_result_for_a_different_expected_bundle(self):
        self.assert_rejected(result(), "invalid probe identity or schema",
                             bundle_id=BUNDLE_ID + "other")

    def test_reject_missing_checks(self):
        value = result()
        del value["checks"]
        self.assert_rejected(value, "invalid probe checks")

    def test_reject_non_list_checks(self):
        for checks in (None, {}, "checks", 1, True, tuple(result()["checks"])):
            with self.subTest(checks_type=type(checks).__name__):
                value = result()
                value["checks"] = checks
                self.assert_rejected(value, "invalid probe checks")

    def test_reject_non_object_check_row(self):
        for row in (None, [], "sandbox_identity", 0, True):
            with self.subTest(row=row):
                value = result()
                value["checks"][0] = row
                self.assert_rejected(value, "invalid probe checks")

    def test_reject_missing_check_name(self):
        value = result()
        del value["checks"][0]["name"]
        self.assert_rejected(value, "invalid probe checks")

    def test_reject_non_string_check_name(self):
        for name in (None, 0, True, [], {}):
            with self.subTest(name=name):
                value = result()
                value["checks"][0]["name"] = name
                self.assert_rejected(value, "invalid probe checks")

    def test_reject_missing_check_passed(self):
        value = result()
        del value["checks"][-1]["passed"]
        self.assert_rejected(value, "invalid probe checks")

    def test_reject_non_boolean_check_passed(self):
        for name in ("sandbox_identity", "tmp.atomic_write_read", "support.append_read"):
            for passed in NON_BOOLEANS:
                with self.subTest(name=name, passed=passed):
                    value = result()
                    next(row for row in value["checks"] if row["name"] == name)["passed"] = passed
                    self.assert_rejected(value, "invalid probe checks")

    def test_reject_every_individually_missing_check(self):
        for missing in CHECK_NAMES:
            with self.subTest(missing=missing):
                value = result()
                value["checks"] = [row for row in value["checks"] if row["name"] != missing]
                self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_empty_checks(self):
        value = result()
        value["checks"] = []
        self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_appended_duplicate_check(self):
        for name in ("sandbox_identity", "tmp.append_read", "support.atomic_write_read"):
            with self.subTest(name=name):
                value = result()
                value["checks"].append(copy.deepcopy(next(
                    row for row in value["checks"] if row["name"] == name)))
                self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_duplicate_replacing_a_required_check(self):
        value = result()
        value["checks"][-1] = copy.deepcopy(value["checks"][-2])
        self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_unexpected_extra_check(self):
        value = result()
        value["checks"].append({"name": "tmp.unknown_case", "passed": True})
        self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_unknown_check_replacing_a_required_check(self):
        value = result()
        value["checks"][-1]["name"] = "support.unknown_case"
        self.assert_rejected(value, "incomplete or duplicate probe checks")

    def test_reject_missing_summary(self):
        value = result()
        del value["passed"]
        self.assert_rejected(value, "inconsistent probe summary")

    def test_reject_non_boolean_summary(self):
        for failed, returncode in (((), 0), (("tmp.append_read",), 1)):
            for passed in NON_BOOLEANS:
                with self.subTest(failed=failed, passed=passed):
                    value = result(*failed)
                    value["passed"] = passed
                    self.assert_rejected(value, "inconsistent probe summary", returncode)

    def test_reject_summary_contradicting_checks(self):
        for failed, returncode in (((), 0), (("support.append_read",), 1)):
            with self.subTest(failed=failed):
                value = result(*failed)
                value["passed"] = not value["passed"]
                self.assert_rejected(value, "inconsistent probe summary", returncode)

    def test_reject_green_result_with_nonzero_or_invalid_exit(self):
        for returncode in (1, 2, -9, None, "0"):
            with self.subTest(returncode=returncode):
                self.assert_rejected(result(), "probe exit code does not match", returncode)

    def test_reject_red_result_with_zero_or_invalid_exit(self):
        for returncode in (0, 2, -9, None, "1"):
            with self.subTest(returncode=returncode):
                self.assert_rejected(result("tmp.append_read"),
                                     "probe exit code does not match", returncode)

    def test_reject_unsandboxed_host_even_with_consistent_red_result(self):
        self.assert_rejected(result("sandbox_identity"),
                             "probe did not establish a real isolated sandbox", 1)

    def test_reject_every_check_red_including_sandbox_identity(self):
        self.assert_rejected(result(*CHECK_NAMES),
                             "probe did not establish a real isolated sandbox", 1)


WORKSPACE_BEFORE = """enum SessionWorkspaceError: Error { case synthetic }
enum SessionWorkspace {
    static func persist() { SensitiveFileIO.keepOriginalCall() }
"""
PROMOTE_METHOD = """    static func promoteTemporarySession(
    ) { Migration.promoteOnly() }
"""
WORKSPACE_MIDDLE = """    static func discardTemporarySession(
    ) { SensitiveFileIO.discardOriginalCall() }
"""
COPY_METHOD = """    static func copyTemporarySession(
    ) { Migration.copyOnly() }
"""
WORKSPACE_AFTER = """    private static func validateTemporarySession(
    ) { SensitiveFileIO.validateOriginalCall() }
}
"""
STORE_ERRORS = "enum SessionStoreError: Error { case synthetic }\n"
ARCHIVE_CODING = """enum SessionArchiveCoding {
    static func encode() { SensitiveFileIO.encodeOriginalCall() }
}
"""
EXPORTER_SOURCE = (
    "import Foundation\nstruct UnrelatedExporterModel {}\n"
    + WORKSPACE_BEFORE + PROMOTE_METHOD + WORKSPACE_MIDDLE + COPY_METHOD + WORKSPACE_AFTER
    + "enum SessionExporter { static func unrelatedExport() {} }\n"
)
ARCHIVE_SOURCE = (
    "struct UnrelatedArchiveModel {}\n" + STORE_ERRORS
    + "struct SessionLoadResult: Codable {}\n" + ARCHIVE_CODING
    + "/// A grammar check distinguishes unrelated UI/model declarations.\n"
    + "struct UnrelatedArchiveUI {}\n"
)
EXPECTED_DECLARATIONS = (
    "import Foundation\nimport Darwin\nimport CryptoKit\n"
    + WORKSPACE_BEFORE + WORKSPACE_MIDDLE + WORKSPACE_AFTER + STORE_ERRORS + ARCHIVE_CODING
)
ARTIFACT_ROOT = SCRIPT.parent.parent.parent / "work" / "sandboxfix" / "parser-tests"


class StorageSourcesTests(unittest.TestCase):
    def setUp(self):
        ARTIFACT_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="synthetic-", dir=ARTIFACT_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        self.output = self.root / "output"
        self.output.mkdir()
        self.sources = {
            "LiveLingo/Sources/SessionExporter.swift": EXPORTER_SOURCE,
            "LiveLingo/Sources/SessionArchive.swift": ARCHIVE_SOURCE,
            "LiveLingo/Sources/SensitiveFileIO.swift": "enum SensitiveFileIO {}\n",
            "LiveLingo/Sources/ExitDeadline.swift": "enum ExitDeadline {}\n",
            "Scripts/sandbox-probe.swift": "// Synthetic probe source; never compiled.\n",
        }
        for name, text in self.sources.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        original_repo = PROBE.REPO
        self.addCleanup(setattr, PROBE, "REPO", original_repo)
        PROBE.REPO = self.repo

    def test_extract_verbatim_declarations_without_mocks_or_migration_methods(self):
        paths, manifest = PROBE.storage_sources(self.output)
        selected = self.output / "StorageDeclarations.swift"
        self.assertEqual(selected.read_bytes(), EXPECTED_DECLARATIONS.encode("utf-8"))
        self.assertEqual(paths, [
            self.repo / "LiveLingo/Sources/SensitiveFileIO.swift",
            self.repo / "LiveLingo/Sources/ExitDeadline.swift",
            selected,
            self.repo / "Scripts/sandbox-probe.swift",
        ])
        self.assertEqual(manifest["omitted_workspace_methods"],
                         ["promoteTemporarySession", "copyTemporarySession"])
        for excluded in (PROMOTE_METHOD, COPY_METHOD, "Migration.", "Unrelated", "Mock", "Stub"):
            with self.subTest(excluded=excluded):
                self.assertNotIn(excluded, selected.read_text(encoding="utf-8"))
        for name, text in self.sources.items():
            with self.subTest(source=name):
                self.assertEqual((self.repo / name).read_bytes(), text.encode("utf-8"))

    def test_manifest_hashes_bind_whole_and_selected_sources(self):
        _, manifest = PROBE.storage_sources(self.output)

        def digest(text):
            return hashlib.sha256(text.encode("utf-8")).hexdigest()

        self.assertEqual(manifest["whole_sources"], {
            name: digest(self.sources[name]) for name in (
                "LiveLingo/Sources/SensitiveFileIO.swift",
                "LiveLingo/Sources/ExitDeadline.swift",
                "Scripts/sandbox-probe.swift",
            )
        })
        self.assertEqual(manifest["declaration_sources"], {
            name: digest(self.sources[name]) for name in (
                "LiveLingo/Sources/SessionExporter.swift",
                "LiveLingo/Sources/SessionArchive.swift",
            )
        })
        self.assertEqual(manifest["selected_declarations_sha256"], digest(EXPECTED_DECLARATIONS))

    def test_changed_or_duplicate_declaration_boundaries_fail_before_output(self):
        for name, marker in (
            ("LiveLingo/Sources/SessionExporter.swift", "enum SessionWorkspaceError:"),
            ("LiveLingo/Sources/SessionExporter.swift", "enum SessionExporter {"),
            ("LiveLingo/Sources/SessionExporter.swift", "    static func promoteTemporarySession("),
            ("LiveLingo/Sources/SessionExporter.swift", "    static func copyTemporarySession("),
            ("LiveLingo/Sources/SessionArchive.swift", "enum SessionStoreError:"),
            ("LiveLingo/Sources/SessionArchive.swift", "struct SessionLoadResult:"),
            ("LiveLingo/Sources/SessionArchive.swift", "enum SessionArchiveCoding {"),
            ("LiveLingo/Sources/SessionArchive.swift", "/// A grammar check distinguishes"),
        ):
            for duplicate in (False, True):
                with self.subTest(source=name, marker=marker, duplicate=duplicate):
                    path = self.repo / name
                    original = self.sources[name]
                    changed = (original.replace(marker, marker + marker, 1) if duplicate
                               else original.replace(marker, "CHANGED_DECLARATION", 1))
                    path.write_text(changed, encoding="utf-8")
                    try:
                        with self.assertRaisesRegex(ValueError, "declaration boundaries changed"):
                            PROBE.storage_sources(self.output)
                        self.assertFalse((self.output / "StorageDeclarations.swift").exists())
                    finally:
                        path.write_text(original, encoding="utf-8")


if __name__ == "__main__":
    unittest.main(verbosity=2)
