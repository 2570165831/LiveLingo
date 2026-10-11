"""Synthetic loader inputs only; no real weights or models are loaded."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import model_prepare as prepare
from Scripts.privacy_package import PrivacyError
from Scripts import reviewed_resources
from Scripts.test_model_files import write_model


class ModelPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="model-prepare-")
        self.root = Path(self.temporary.name)
        self.base = self.root / "base"
        self.output = self.root / "output"
        # The production manifest binds real model bytes. Synthetic loader
        # fixtures exercise the ordinary gate; approval tests use their own map.
        self.approvals = patch.object(reviewed_resources, "entries", return_value={})
        self.approvals.start()
        for identifier, required in prepare.REQUIRED_MODEL_FILES.items():
            path = write_model(self.base / identifier, required)
            if identifier == prepare.PARAKEET:
                (path / "config.json").write_text(json.dumps({"joint": {"vocabulary": ["a", "b"]},
                                                           "tokenizer": {"dir": "/synthetic/build"}}))
                (path / "tokenizer.model").write_bytes(b"unused training data")
            elif "tokenizer.json" in required:
                (path / "tokenizer_config.json").write_text('{"chat_template":"unused template"}')
                (path / "chat_template.jinja").write_text("unused template")
                (path / "processor_config.json").write_text('{"processor_class":"synthetic"}')

    def tearDown(self):
        self.approvals.stop()
        self.temporary.cleanup()

    def snapshot(self, tree):
        return {p.relative_to(tree).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in tree.rglob("*") if p.is_file()}

    def test_preserves_weights_and_vocabulary_and_input_bytes(self):
        before = self.snapshot(self.base)
        prepare.prepare(self.base, self.output)
        self.assertEqual(before, self.snapshot(self.base))
        for identifier in prepare.REQUIRED_MODEL_FILES:
            self.assertEqual((self.base / identifier / "model.safetensors").read_bytes(),
                             (self.output / identifier / "model.safetensors").read_bytes())
            self.assertFalse((self.output / identifier / "chat_template.jinja").exists())
            if (self.base / identifier / "processor_config.json").exists():
                self.assertEqual((self.base / identifier / "processor_config.json").read_bytes(),
                                 (self.output / identifier / "processor_config.json").read_bytes())
        config = json.loads((self.output / prepare.PARAKEET / "config.json").read_text())
        self.assertEqual(config["joint"]["vocabulary"], ["a", "b"])
        self.assertNotIn("dir", config["tokenizer"])
        self.assertFalse((self.output / prepare.PARAKEET / "tokenizer.model").exists())

    def test_other_private_fields_are_still_rejected(self):
        path = self.base / prepare.PARAKEET / "config.json"
        value = json.loads(path.read_text())
        value["rawText"] = "synthetic private content"
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(PrivacyError, "classroom-content-metadata"):
            prepare.prepare(self.base, self.output)

    def test_unknown_file_is_rejected(self):
        (self.base / prepare.PARAKEET / "unexpected.bin").write_bytes(b"unknown")
        with self.assertRaisesRegex(PrivacyError, "unreviewed-model-input-entry"):
            prepare.prepare(self.base, self.output)

    def test_malformed_parakeet_metadata_is_rejected(self):
        (self.base / prepare.PARAKEET / "config.json").write_text('{"joint": []}')
        with self.assertRaisesRegex(PrivacyError, "unreviewed-parakeet-vocabulary-layout"):
            prepare.prepare(self.base, self.output)

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        marker = self.output / "marker"
        marker.write_text("keep")
        with self.assertRaisesRegex(PrivacyError, "invalid-model-preparation-path"):
            prepare.prepare(self.base, self.output)
        self.assertEqual(marker.read_text(), "keep")

    def test_metadata_without_unused_template_is_copied_verbatim(self):
        identifier = next(k for k, v in prepare.REQUIRED_MODEL_FILES.items() if "tokenizer.json" in v)
        source = self.base / identifier / "tokenizer_config.json"
        source.write_bytes(b'{ "tokenizer_class" : "synthetic" }\n')
        report = prepare.prepare(self.base, self.output)
        self.assertEqual(source.read_bytes(), (self.output / identifier / source.name).read_bytes())
        self.assertFalse(any(r["model"] == identifier and r["file"] == source.name for r in report))
