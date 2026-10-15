"""Bounded, location-specific ticket handling; no signing or Apple tools."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy


TICKET = b"s8ch" + bytes(range(256)) * 8


class StapledTicketTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "LiveLingo.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.ticket = self.app / "Contents/CodeResources"

    def inspect(self, phase="signed", root=None):
        # This synthetic bundle has no native resources or signature receipt.
        # Keep the real tree and ticket gates, without inventing native approval.
        with patch("Scripts.signed_resource_review.approvals_for_app", return_value={}):
            return privacy.inspect_tree(root or self.app, phase=phase)

    def test_exact_top_level_signed_ticket_is_opaque_and_counted(self):
        self.ticket.write_bytes(TICKET)
        for root in (self.app, self.root):
            with self.subTest(root=root):
                counts = self.inspect(root=root)
                self.assertEqual(counts["stapled_tickets"], 1)
                self.assertEqual(counts["opaque_binary_files"], 1)
                self.assertEqual(counts["files"], 1)

    def test_ticket_rejected_before_signing(self):
        self.ticket.write_bytes(TICKET)
        for phase in ("prepare", "final"):
            with self.subTest(phase=phase), self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
                self.inspect(phase=phase)

    def test_wrong_magic_empty_and_oversized_tickets_rejected(self):
        for data in (b"", b"bad!" + TICKET[4:], b"s8ch" + b"\0" * (64 * 1024 - 3)):
            self.ticket.write_bytes(data)
            with self.subTest(length=len(data)), self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
                self.inspect()

    def test_limit_is_inclusive(self):
        self.ticket.write_bytes(b"s8ch" + b"\0" * (64 * 1024 - 4))
        self.assertEqual(self.inspect()["stapled_tickets"], 1)

    def test_same_name_elsewhere_and_nested_apps_rejected(self):
        for relative in ("Contents/MacOS/CodeResources", "CodeResources",
                         "Contents/PlugIns/LiveLingo.app/Contents/CodeResources"):
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(TICKET)
            with self.subTest(relative=relative), self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
                self.inspect()
            path.unlink()

    def test_symlink_and_directory_cannot_be_tickets(self):
        target = self.app / "Contents/z-ticket"
        target.write_bytes(TICKET)
        self.ticket.symlink_to(target.name)
        with self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
            self.inspect()
        self.ticket.unlink()
        self.ticket.mkdir()
        with self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
            self.inspect()

    def test_another_app_name_is_not_approved(self):
        self.ticket.write_bytes(TICKET)
        renamed = self.root / "Other.app"
        self.app.rename(renamed)
        with self.assertRaisesRegex(privacy.PrivacyError, "invalid-stapled-ticket"):
            self.inspect(root=renamed)

    def test_signature_seal_keeps_its_structured_validation(self):
        seal = self.app / "Contents/_CodeSignature/CodeResources"
        seal.parent.mkdir()
        seal.write_bytes(TICKET)
        with self.assertRaises(privacy.PrivacyError):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
