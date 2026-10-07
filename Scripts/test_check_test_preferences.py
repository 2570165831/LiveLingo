"""Exercise the preference log guard with isolated files, never real defaults."""

from pathlib import Path
import tempfile
import unittest

import check_test_preferences as guard


SUITE = "LiveLingo-CaptionIdentity-12345678-1234-1234-1234-123456789ABC"
OTHER = "ClassroomPresentation-87654321-1234-1234-1234-123456789ABC"


class TestPreferenceLogGuardTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.preferences = Path(directory)

    def check(self, events, *, succeeded=True):
        lines = [f"TEST_PREFERENCE_{event} suite={suite}\n" for event, suite in events]
        if succeeded:
            lines.append("** TEST SUCCEEDED **\n")
        return guard.check(lines, self.preferences)

    def test_matching_unique_suites_and_absent_files_pass(self):
        events = [("CREATED", SUITE), ("CREATED", OTHER),
                  ("CLEANED", OTHER), ("CLEANED", SUITE)]
        self.assertEqual(self.check(events), (2, 2, []))
        self.assertEqual(self.check(events), (2, 2, []))

    def test_missing_cleanup_and_equal_totals_for_different_suites_fail(self):
        for events in [[("CREATED", SUITE)],
                       [("CREATED", SUITE), ("CLEANED", OTHER)]]:
            with self.subTest(events=events):
                self.assertTrue(self.check(events)[2])

    def test_duplicates_and_cleanup_before_creation_fail(self):
        events = [("CREATED", SUITE), ("CLEANED", SUITE)]
        self.assertTrue(self.check(events * 2)[2])
        self.assertTrue(self.check(list(reversed(events)))[2])

    def test_remaining_file_directory_and_dangling_link_fail(self):
        for kind in ["file", "directory", "link"]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                preferences = Path(directory)
                plist = preferences / (SUITE + ".plist")
                if kind == "file":
                    plist.write_bytes(b"empty")
                elif kind == "directory":
                    plist.mkdir()
                else:
                    plist.symlink_to(preferences / "absent")
                lines = [f"TEST_PREFERENCE_CREATED suite={SUITE}",
                         f"TEST_PREFERENCE_CLEANED suite={SUITE}",
                         "** TEST SUCCEEDED **"]
                self.assertTrue(guard.check(lines, preferences)[2])
                self.assertTrue(plist.exists() or plist.is_symlink())

    def test_invalid_names_and_path_traversal_fail(self):
        for suite in ["../" + SUITE, "LiveLingo-CaptionIdentity-not-a-uuid"]:
            with self.subTest(suite=suite):
                self.assertTrue(self.check([("CREATED", suite), ("CLEANED", suite)])[2])

    def test_empty_and_incomplete_logs_fail(self):
        self.assertTrue(self.check([])[2])
        self.assertTrue(self.check([("CREATED", SUITE), ("CLEANED", SUITE)],
                                   succeeded=False)[2])


if __name__ == "__main__":
    unittest.main()
