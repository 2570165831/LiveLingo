"""Final-stage provenance failures through the real package gate."""
import json
from pathlib import Path
import tempfile
import unittest
import importlib.util
import sys
from unittest.mock import patch
from Scripts import binary_provenance as provenance
from Scripts import runtime_prepare
from Scripts import privacy_package as privacy
from Scripts import reviewed_resources
from Scripts import signed_resource_review as signed_review
from Scripts.test_macho_paths import image


class FinalProvenanceTests(unittest.TestCase):
    def setUp(self):
        approval = patch.object(reviewed_resources, "entries", return_value={})
        approval.start()
        self.addCleanup(approval.stop)

    def test_fixed_publisher_comparison_is_bound_to_its_reviewed_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            python = root / "input"
            binary = python / provenance.INPUT_PATH
            binary.parent.mkdir(parents=True)
            binary.write_bytes(image())
            document = json.loads(provenance.REFERENCE.read_text())
            receipt = provenance.record_input_provenance(python, document)
            self.assertFalse(receipt["publisherComparisonApplicableToInput"])
            receipt["publisherComparisonApplicableToInput"] = True
            with self.assertRaises(privacy.PrivacyError):
                provenance.verify_input_provenance(python, receipt)

    def test_signing_rebinds_after_native_files_and_before_outer_seal(self):
        source = Path(__file__).resolve().parent / "sign-offline-app.py"
        spec = importlib.util.spec_from_file_location("signing_order_fixture", source)
        signing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(signing)
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "LiveLingo.app"
            (app / "Contents/Resources/ASRRuntime").mkdir(parents=True)
            main = app / "Contents/MacOS/LiveLingo"
            native = app / "Contents/Resources/library.dylib"
            events = []
            result = type("Result", (), {"returncode": 0})()
            with patch.dict(sys.modules, {"binary_provenance": provenance, "signed_resource_review": signed_review,
                                         "privacy_package": privacy, "runtime_prepare": runtime_prepare}), \
                 patch.object(runtime_prepare, "normalize_native_signature", side_effect=lambda _: events.append("normalize-native")), \
                 patch.object(signed_review, "capture_before_signing", side_effect=lambda _: events.append("capture") or {}), \
                 patch.object(signed_review, "write_capture_receipt", side_effect=lambda *a: events.append("host-capture")), \
                 patch.object(signed_review, "finalize_signed_review", side_effect=lambda *a: events.append("signed-review")), \
                 patch.object(privacy, "inspect_tree", side_effect=lambda *a, **k: events.append("signed-gate-" + k["phase"]) or {}), \
                 patch.object(signing, "main_executable_path", return_value=main), \
                 patch.object(signing, "nested_bundles", return_value=[]), \
                 patch.object(provenance, "verify_app_provenance", side_effect=lambda _: events.append("verify-input") or {}), \
                 patch.object(provenance, "finalize_app_provenance", side_effect=lambda *a, **k: events.append("rebind-" + k["final_stage"])), \
                 patch.object(signing, "run", side_effect=lambda command: events.append("outer" if command[-1] == str(app) else "native")), \
                 patch.object(signing.subprocess, "run", return_value=result):
                signing.sign(app, "fixture", "fixture", "fixture", "fixture", [(native, [{"filetype": 6}])],
                             Path(temporary) / "before-sign.json")
            self.assertEqual(events, ["capture", "host-capture", "verify-input", "normalize-native", "native",
                                     "rebind-signed-candidate", "signed-review", "signed-gate-signed", "outer"])

    def test_final_gate_rejects_missing_pending_and_old_schema(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reference = json.loads(provenance.REFERENCE.read_text())
            for index, document in enumerate((None, reference, {"schemaVersion": 1})):
                app = root / (str(index) + ".app")
                binary = app / provenance.BUNDLED_PATH
                binary.parent.mkdir(parents=True)
                binary.write_bytes(image())
                if document is not None:
                    notice = app / provenance.NOTICE_PATH
                    notice.parent.mkdir(parents=True)
                    notice.write_text(json.dumps(document))
                with self.subTest(document=document), self.assertRaises(privacy.PrivacyError):
                    privacy.inspect_tree(app)

    def test_final_hash_and_status_are_rechecked_for_parent_layouts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "LiveLingo.app"
            python = root / "input"
            for path in (app / provenance.BUNDLED_PATH, python / provenance.INPUT_PATH):
                path.parent.mkdir(parents=True)
                path.write_bytes(image())
            notice = app / provenance.NOTICE_PATH
            notice.parent.mkdir(parents=True)
            notice.write_text(provenance.REFERENCE.read_text())
            receipt = provenance.record_input_provenance(python)
            provenance.finalize_app_provenance(app, receipt)
            self.assertEqual(privacy.inspect_tree(app)["bound_binary_provenance"], 1)
            self.assertEqual(privacy.inspect_tree(root)["bound_binary_provenance"], 1)
            document = json.loads(notice.read_text())
            document["status"] = "input-bound-awaiting-final-binding"
            notice.write_text(json.dumps(document))
            with self.assertRaises(privacy.PrivacyError):
                privacy.inspect_tree(root)
