"""Tiny synthetic data only; no interpreter/runtime or real model execution."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from Scripts import model_storage_manifest as manifest
from Scripts.test_model_files import write_app_models


class ModelStorageManifestTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="model-storage-manifest-"))
        self.models = self.root / "Models"
        self.model = self.models / "author/tiny-model"
        self.model.mkdir(parents=True)
        (self.model / "config.json").write_bytes(b'{"model":"synthetic"}')
        (self.model / "weights.bin").write_bytes(b"small synthetic weights")

    def build(self):
        return manifest.build_manifest(self.models, ["author/tiny-model"])

    def test_schema_files_sizes_and_complete_sha256(self):
        value = self.build()
        self.assertEqual(value["schemaVersion"], 1)
        self.assertEqual(value["sampleAlgorithm"], "first-middle-last-64KiB-v1")
        self.assertEqual(value["fullHashMaxBytes"], 1 << 20)
        model = value["models"][0]
        self.assertEqual(model["name"], "tiny-model")
        self.assertEqual(model["sourceRelativePath"], "author/tiny-model")
        self.assertEqual([row["path"] for row in model["files"]], ["config.json", "weights.bin"])
        for row in model["files"]:
            data = (self.model / row["path"]).read_bytes()
            self.assertEqual(row["size"], len(data))
            self.assertEqual(row["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(row["sampleSHA256"], row["sha256"])
        canonical_model = dict(model)
        del canonical_model["version"]
        canonical = json.dumps(canonical_model, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        self.assertEqual(model["version"], "sha256-" + hashlib.sha256(canonical).hexdigest())

    def test_inventory_is_deterministic_and_has_no_host_metadata(self):
        self.assertEqual(self.build(), self.build())
        value = json.dumps(self.build())
        self.assertNotIn(str(self.root), value)
        for field in ("mtime", "author", "hostname", "createdAt"):
            self.assertNotIn('"' + field + '"', value)

    def test_changed_bytes_change_version_even_with_same_size(self):
        before = self.build()["models"][0]["version"]
        (self.model / "weights.bin").write_bytes(b"SMALL SYNTHETIC WEIGHTS")
        self.assertNotEqual(before, self.build()["models"][0]["version"])

    def test_large_file_samples_first_middle_last(self):
        data = bytes(range(256)) * 5000
        path = self.model / "large.bin"
        path.write_bytes(data)
        row = manifest.file_record(path, "large.bin")
        expected = b"".join(data[offset:offset + (64 << 10)]
                            for offset in (0, (len(data) - (64 << 10)) // 2, len(data) - (64 << 10)))
        self.assertEqual(row["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(row["sampleSHA256"], hashlib.sha256(expected).hexdigest())
        self.assertNotEqual(row["sampleSHA256"], row["sha256"])

    def test_nested_members_are_included(self):
        nested = self.model / "tokenizer/merges.txt"
        nested.parent.mkdir()
        nested.write_bytes(b"merge data")
        self.assertIn("tokenizer/merges.txt", [row["path"] for row in self.build()["models"][0]["files"]])

    def test_empty_model_is_rejected(self):
        empty = self.models / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(ValueError, "empty model"):
            manifest.build_manifest(self.models, ["empty"])

    def test_reserved_receipt_name_is_rejected_as_file_or_directory(self):
        for directory in (False, True):
            models = self.root / ("reserved-directory" if directory else "reserved-file")
            model = models / "tiny"
            model.mkdir(parents=True)
            path = model / "preclone-state.json"
            if directory:
                path.mkdir()
                (path / "weights.bin").write_bytes(b"data")
            else:
                path.write_bytes(b"data")
            with self.subTest(directory=directory), self.assertRaisesRegex(ValueError, "unsafe model member"):
                manifest.build_manifest(models, ["tiny"])

    def test_file_symlink_is_rejected(self):
        (self.model / "link.bin").symlink_to(self.model / "weights.bin")
        with self.assertRaisesRegex(ValueError, "unsafe model member"):
            self.build()

    def test_directory_symlink_is_rejected(self):
        (self.models / "linked-author").symlink_to(self.models / "author", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "real directories"):
            manifest.build_manifest(self.models, ["linked-author/tiny-model"])

    def test_nested_directory_symlink_is_rejected(self):
        (self.model / "linked").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "unsafe model member"):
            self.build()

    def test_hard_link_is_rejected(self):
        (self.model / "linked.bin").hardlink_to(self.model / "weights.bin")
        with self.assertRaisesRegex(ValueError, "hard-linked"):
            self.build()

    def test_fifo_is_rejected_without_opening(self):
        import os
        os.mkfifo(self.model / "fifo")
        with self.assertRaisesRegex(ValueError, "non-regular"):
            self.build()

    def test_path_traversal_is_rejected(self):
        for relative in ("../outside", "/outside", "author//tiny-model", "author/./tiny-model"):
            with self.subTest(relative=relative), self.assertRaisesRegex(ValueError, "unsafe model source"):
                manifest.build_manifest(self.models, [relative])

    def test_model_name_collision_is_rejected(self):
        second = self.models / "other/tiny-model"
        second.mkdir(parents=True)
        (second / "weight.bin").write_bytes(b"data")
        with self.assertRaisesRegex(ValueError, "names collide"):
            manifest.build_manifest(self.models, ["author/tiny-model", "other/tiny-model"])

    def test_final_app_inventory_covers_all_packaged_models(self):
        app = self.root / "Synthetic.app"
        write_app_models(app)
        path = manifest.write_app_manifest(app)
        value = json.loads(path.read_text())
        self.assertEqual(len(value["models"]), len(manifest.REQUIRED_MODEL_FILES))
        for model in value["models"]:
            self.assertTrue(any(row["path"].endswith(".safetensors") for row in model["files"]))

    def test_existing_inventory_is_never_overwritten(self):
        app = self.root / "Synthetic.app"
        write_app_models(app)
        path = manifest.write_app_manifest(app)
        before = path.read_bytes()
        with self.assertRaises(FileExistsError):
            manifest.write_app_manifest(app)
        self.assertEqual(path.read_bytes(), before)

    def test_missing_packaged_model_is_rejected(self):
        app = self.root / "Synthetic.app"
        app.mkdir()
        with self.assertRaisesRegex(ValueError, "incomplete packaged models"):
            manifest.write_app_manifest(app)


if __name__ == "__main__":
    unittest.main()
