"""Static provenance binding regressions; synthetic Mach-O, no signing or models."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import binary_provenance as provenance
from Scripts import reviewed_resources
from Scripts.privacy_package import PrivacyError, inspect_tree
from Scripts.test_macho_paths import image


class BinaryProvenanceTests(unittest.TestCase):
    def setUp(self):
        approval = patch.object(reviewed_resources, "entries", return_value={})
        approval.start()
        self.addCleanup(approval.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="binary-provenance-")
        self.root = Path(self.temporary.name)
        self.python = self.root / "input-python"
        self.app = self.root / "candidate.app"
        self.input = self.python / provenance.INPUT_PATH
        self.final = self.app / provenance.BUNDLED_PATH
        self.notice = self.app / provenance.NOTICE_PATH
        for path in [self.input, self.final, self.notice]:
            path.parent.mkdir(parents=True, exist_ok=True)
        self.input.write_bytes(image())
        self.final.write_bytes(image())
        self.reference = json.loads(provenance.REFERENCE.read_text())
        self.reference["upstreamSHA256"] = hashlib.sha256(image()).hexdigest()
        self.notice.write_text(json.dumps(self.reference))

    def tearDown(self):
        self.temporary.cleanup()

    def record(self):
        return provenance.record_input_provenance(self.python, self.reference)

    def test_record_input_is_bound_to_real_input_and_does_not_claim_final_match(self):
        before = self.input.read_bytes()
        receipt = self.record()
        self.assertEqual(receipt["inputSHA256"], hashlib.sha256(before).hexdigest())
        self.assertTrue(receipt["inputExactMatch"])
        self.assertIsNone(receipt["finalBundledSHA256"])
        self.assertIsNone(receipt["exactMatch"])
        self.assertEqual(receipt["status"], "input-bound-awaiting-final-binding")
        self.assertEqual(provenance.verify_input_provenance(self.python, receipt), receipt)
        self.assertEqual(self.input.read_bytes(), before)

    def test_finalize_true_match_reads_real_candidate_and_only_changes_notice(self):
        before_input, before_final = self.input.read_bytes(), self.final.read_bytes()
        receipt = provenance.finalize_app_provenance(self.app, self.record())
        self.assertTrue(receipt["inputExactMatch"])
        self.assertTrue(receipt["exactMatch"])
        self.assertTrue(receipt["finalMatchesInput"])
        self.assertEqual(receipt["finalBundledPath"], provenance.BUNDLED_PATH)
        self.assertEqual(provenance.verify_app_provenance(self.app), receipt)
        self.assertEqual(self.input.read_bytes(), before_input)
        self.assertEqual(self.final.read_bytes(), before_final)

    def test_real_tree_gate_requires_final_binding_and_rechecks_final_hash(self):
        self.assertEqual(inspect_tree(self.app, phase="prepare")["pending_binary_provenance"], 1)
        with self.assertRaises(PrivacyError):
            inspect_tree(self.app)
        provenance.finalize_app_provenance(self.app, self.record())
        self.assertEqual(inspect_tree(self.app)["bound_binary_provenance"], 1)
        self.final.write_bytes(image(value="@rpath/changed.dylib"))
        with self.assertRaisesRegex(PrivacyError, "final-binary-provenance-hash-mismatch"):
            inspect_tree(self.app)

    def test_modified_final_never_inherits_input_exact_match(self):
        input_receipt = self.record()
        self.final.write_bytes(image(value="@rpath/modified.dylib"))
        receipt = provenance.finalize_app_provenance(self.app, input_receipt)
        self.assertTrue(receipt["inputExactMatch"])
        self.assertFalse(receipt["exactMatch"])
        self.assertFalse(receipt["finalMatchesInput"])
        self.assertNotEqual(receipt["inputSHA256"], receipt["finalBundledSHA256"])
        self.assertEqual(receipt["finalBundledSHA256"], hashlib.sha256(self.final.read_bytes()).hexdigest())

    def test_modified_input_is_honestly_distinct_from_publisher(self):
        changed = image(value="@rpath/input-copy.dylib")
        self.input.write_bytes(changed)
        self.final.write_bytes(changed)
        receipt = provenance.finalize_app_provenance(self.app, self.record())
        self.assertFalse(receipt["inputExactMatch"])
        self.assertFalse(receipt["exactMatch"])
        self.assertTrue(receipt["finalMatchesInput"])

    def test_final_match_can_be_true_while_input_match_is_false(self):
        self.input.write_bytes(image(value="@rpath/different-input.dylib"))
        receipt = provenance.finalize_app_provenance(self.app, self.record())
        self.assertFalse(receipt["inputExactMatch"])
        self.assertTrue(receipt["exactMatch"])
        self.assertFalse(receipt["finalMatchesInput"])

    def test_stale_fields_in_reference_are_not_carried_to_new_input_receipt(self):
        self.reference.update(localSHA256="stale", exactMatch=True, finalBundledSHA256="stale",
                              finalBundledPath="elsewhere/file.dylib")
        receipt = self.record()
        self.assertNotIn("localSHA256", receipt)
        self.assertIsNone(receipt["exactMatch"])
        self.assertIsNone(receipt["finalBundledSHA256"])
        self.assertEqual(receipt["finalBundledPath"], provenance.BUNDLED_PATH)

    def test_missing_input_measurement_and_legacy_receipt_are_rejected(self):
        for reference in [self.reference, {"source": self.reference["source"],
                                          "upstreamSHA256": self.reference["upstreamSHA256"],
                                          "localSHA256": self.reference["upstreamSHA256"], "exactMatch": True}]:
            self.notice.write_text(json.dumps(reference))
            with self.assertRaises(PrivacyError):
                provenance.verify_app_provenance(self.app)
            with self.assertRaises(PrivacyError):
                provenance.bind_final_provenance(self.app, reference)

    def test_later_binary_change_invalidates_final_until_rebound(self):
        input_receipt = self.record()
        provenance.finalize_app_provenance(self.app, input_receipt)
        self.final.write_bytes(image(value="@rpath/later-change.dylib"))
        with self.assertRaisesRegex(PrivacyError, "final-binary-provenance-hash-mismatch"):
            provenance.verify_app_provenance(self.app)
        rebound = provenance.finalize_app_provenance(self.app, input_receipt, final_stage="signed-candidate")
        self.assertEqual(rebound["finalStage"], "signed-candidate")
        self.assertFalse(rebound["exactMatch"])

    def test_input_mutation_is_detected(self):
        receipt = self.record()
        self.input.write_bytes(image(value="@rpath/new-input.dylib"))
        with self.assertRaisesRegex(PrivacyError, "input-binary-provenance-hash-mismatch"):
            provenance.verify_input_provenance(self.python, receipt)

    def test_comparison_flags_must_match_hashes_and_be_booleans(self):
        original = provenance.finalize_app_provenance(self.app, self.record())
        for field in ["inputExactMatch", "exactMatch", "finalMatchesInput"]:
            for flag in [False, 1, None]:
                with self.subTest(field=field, flag=flag):
                    modified = copy.deepcopy(original)
                    modified[field] = flag
                    self.notice.write_text(json.dumps(modified))
                    with self.assertRaises(PrivacyError):
                        provenance.verify_app_provenance(self.app)

    def test_stage_and_path_cannot_be_confused_or_retargeted(self):
        original = self.record()
        for field, value in [("inputPath", provenance.BUNDLED_PATH), ("inputPathBase", "app-root"),
                             ("finalBundledPath", "../outside.dylib"),
                             ("inputStage", "assembled-candidate"), ("finalPathBase", "asr-python-root")]:
            with self.subTest(field=field):
                receipt = copy.deepcopy(original)
                receipt[field] = value
                with self.assertRaises(PrivacyError):
                    provenance.bind_final_provenance(self.app, receipt)

    def test_final_gate_rejects_ambiguous_legacy_hash_or_pending_stage(self):
        original = provenance.finalize_app_provenance(self.app, self.record())
        for field, value in [("localSHA256", original["upstreamSHA256"]), ("finalStage", "pending-assembly"),
                             ("status", "input-bound-awaiting-final-binding")]:
            with self.subTest(field=field):
                receipt = copy.deepcopy(original)
                receipt[field] = value
                self.notice.write_text(json.dumps(receipt))
                with self.assertRaises(PrivacyError):
                    provenance.verify_app_provenance(self.app)

    def test_symlinks_and_non_macho_inputs_are_rejected(self):
        self.input.write_bytes(b"not a Mach-O")
        with self.assertRaisesRegex(PrivacyError, "non-macho-provenance-input"):
            self.record()
        link = self.root / "linked-python"
        link.symlink_to(self.python, target_is_directory=True)
        with self.assertRaises(PrivacyError):
            provenance.record_input_provenance(link, self.reference)

    def test_pure_binding_does_not_write_notice(self):
        before = self.notice.read_bytes()
        provenance.bind_final_provenance(self.app, self.record())
        self.assertEqual(self.notice.read_bytes(), before)


class BundledAuditReferenceTests(unittest.TestCase):
    def test_every_audit_document_reference_resolves_from_bundled_license_root(self):
        license_root = provenance.REFERENCE.parent.parent
        audit = json.loads((license_root / "AUDIT.json").read_text())
        for field in ["reviewedResources", "correspondingSourceAudit"]:
            with self.subTest(field=field):
                relative = Path(audit[field])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                path = license_root / relative
                self.assertTrue(path.is_file())
                self.assertTrue(path.resolve().is_relative_to(license_root.resolve()))
                self.assertIsInstance(json.loads(path.read_text()), dict)


if __name__ == "__main__":
    unittest.main()
