"""Synthetic model directories only; no real weights are read and no model is loaded."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

from Scripts import model_files


ROOT = Path(__file__).resolve().parent.parent


def safetensors(names):
    """A tiny valid safetensors file holding one 4-byte F32 tensor per name."""
    header = json.dumps({name: {"dtype": "F32", "shape": [1], "data_offsets": [4 * i, 4 * i + 4]}
                         for i, name in enumerate(names)}).encode()
    return struct.pack("<Q", len(header)) + header + b"\x00" * (4 * len(names))


def write_model(directory, required, shards=None):
    """Write required loader files plus weights: {shard: [tensor names]} with an index, or one model.safetensors."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name in required:
        (directory / name).write_text('{"model_type":"synthetic"}' if name.endswith(".json") else "synthetic")
    if shards is None:
        (directory / "model.safetensors").write_bytes(safetensors(["weight"]))
        return directory
    for shard, names in shards.items():
        (directory / shard).write_bytes(safetensors(names))
    weight_map = {name: shard for shard, names in shards.items() for name in names}
    (directory / model_files.INDEX_NAME).write_text(json.dumps({"metadata": {}, "weight_map": weight_map}))
    return directory


def write_app_models(app_root):
    for relative, required in model_files.REQUIRED_MODEL_FILES.items():
        write_model(Path(app_root) / model_files.APP_MODELS_ROOT / relative, required)


class ModelFilesTests(unittest.TestCase):
    SHARDS = {"model-00001-of-00002.safetensors": ["a.weight", "a.scales"],
              "model-00002-of-00002.safetensors": ["b.weight"]}

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="model-files-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.model = self.root / "model"

    def tearDown(self):
        self.temporary.cleanup()

    def rejected(self, required=("config.json",)):
        with self.assertRaises(model_files.ModelFilesError) as raised:
            model_files.check_model_files(self.model, required)
        message = raised.exception.args[0]
        self.assertNotIn(str(self.root), message)
        return message

    def test_complete_sharded_single_file_and_indexed_single_file_models_pass(self):
        write_model(self.model, ("config.json", "tokenizer.json"), self.SHARDS)
        self.assertEqual(model_files.check_model_files(self.model, ("config.json", "tokenizer.json")),
                         sorted(self.SHARDS))
        single = write_model(self.root / "single", ("config.json",))
        self.assertEqual(model_files.check_model_files(single, ("config.json",)), ["model.safetensors"])
        indexed = write_model(self.root / "indexed", ("config.json",), {"model.safetensors": ["w", "x"]})
        self.assertEqual(model_files.check_model_files(indexed, ("config.json",)), ["model.safetensors"])

    def test_missing_indexed_shard_is_rejected_by_name(self):
        write_model(self.model, ("config.json",), self.SHARDS)
        (self.model / "model-00002-of-00002.safetensors").unlink()
        self.assertEqual(self.rejected(), "missing weight file: model-00002-of-00002.safetensors")

    def test_index_cannot_reference_files_outside_the_model_or_symlinks(self):
        outside = self.root / "outside.safetensors"
        outside.write_bytes(safetensors(["w"]))
        for target in ("../outside.safetensors", "nested/model.safetensors", ".hidden.safetensors", "model.bin"):
            with self.subTest(target=target):
                write_model(self.model, ("config.json",), {"model.safetensors": ["w"]})
                (self.model / model_files.INDEX_NAME).write_text(json.dumps({"weight_map": {"w": target}}))
                self.assertIn("outside the model directory", self.rejected())
        write_model(self.model, ("config.json",), {"model.safetensors": ["w"]})
        (self.model / "model.safetensors").unlink()
        (self.model / "model.safetensors").symlink_to(outside)
        self.assertEqual(self.rejected(), "missing weight file: model.safetensors")

    def test_unparsable_empty_or_malformed_index_is_rejected(self):
        for index in ("not json", "{}", '{"weight_map": {}}', '{"weight_map": []}',
                      '{"weight_map": {"w": 1}}', '[]', '{"weight_map": {"w": "model.safetensors"}, '
                                                          '"weight_map": {"w": "model.safetensors"}}'):
            with self.subTest(index=index):
                write_model(self.model, ("config.json",), {"model.safetensors": ["w"]})
                (self.model / model_files.INDEX_NAME).write_text(index)
                self.assertIn(model_files.INDEX_NAME, self.rejected())

    def test_index_tensor_missing_from_every_shard_is_rejected(self):
        write_model(self.model, ("config.json",), self.SHARDS)
        index = self.model / model_files.INDEX_NAME
        value = json.loads(index.read_text())
        value["weight_map"]["c.weight"] = "model-00001-of-00002.safetensors"
        index.write_text(json.dumps(value))
        self.assertEqual(self.rejected(), "1 tensor(s) in %s are absent from its shards" % model_files.INDEX_NAME)

    def test_model_without_weights_is_rejected(self):
        write_model(self.model, ("config.json",))
        (self.model / "model.safetensors").unlink()
        self.assertIn("no model*.safetensors weights", self.rejected())
        # Loaders only glob model*.safetensors, so an unrelated name does not count.
        (self.model / "adapters.safetensors").write_bytes(safetensors(["w"]))
        self.assertIn("no model*.safetensors weights", self.rejected())

    def test_pointer_truncated_and_empty_weight_files_are_rejected(self):
        pointer = b"version https://git-lfs.github.com/spec/v1\noid sha256:0\nsize 5\n"
        for name, data in (("pointer", pointer), ("truncated", safetensors(["w", "x"])[:-1]),
                           ("empty-header", struct.pack("<Q", 2) + b"{}")):
            with self.subTest(name=name):
                write_model(self.model, ("config.json",))
                (self.model / "model.safetensors").write_bytes(data)
                self.assertIn("model.safetensors", self.rejected())

    def test_required_loader_files_follow_each_model(self):
        write_model(self.model, ("config.json", "tokenizer_config.json"))
        (self.model / "tokenizer_config.json").unlink()
        self.assertEqual(self.rejected(("config.json", "tokenizer_config.json")),
                         "missing required file(s): tokenizer_config.json")
        (self.model / "tokenizer_config.json").write_text("")
        self.assertIn("tokenizer_config.json", self.rejected(("config.json", "tokenizer_config.json")))
        required = model_files.REQUIRED_MODEL_FILES
        for relative in ("mlx-community/Qwen3.5-4B-MLX-8bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"):
            self.assertIn("tokenizer.json", required[relative])
        # The ASR models ship no tokenizer.json, so requiring it would reject real releases.
        for relative in ("mlx-community/parakeet-tdt-0.6b-v2", "mlx-community/Qwen3-ASR-1.7B-4bit"):
            self.assertNotIn("tokenizer.json", required[relative])
            write_model(self.root / relative, required[relative])
            model_files.check_model_files(self.root / relative, required[relative])

    def test_app_check_and_cli_report_each_incomplete_model(self):
        app = self.root / "LiveLingo.app"
        write_app_models(app)
        self.assertEqual(model_files.check_app_models(app), [])
        command = [sys.executable, "-B", str(ROOT / "Scripts/model_files.py"), "check", "--app", str(app)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"modelFiles": "passed", "models": 4})
        (app / model_files.APP_MODELS_ROOT / "mlx-community/parakeet-tdt-0.6b-v2/model.safetensors").unlink()
        os.remove(app / model_files.APP_MODELS_ROOT / "mlx-community/Qwen3.5-4B-MLX-8bit/tokenizer.json")
        problems = model_files.check_app_models(app)
        self.assertEqual(problems, [
            "mlx-community/Qwen3.5-4B-MLX-8bit: missing required file(s): tokenizer.json",
            "mlx-community/parakeet-tdt-0.6b-v2: no model*.safetensors weights",
        ])
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.splitlines(), ["model-files: " + problem for problem in problems])
        self.assertNotIn(str(self.root), result.stderr)


if __name__ == "__main__":
    unittest.main()
