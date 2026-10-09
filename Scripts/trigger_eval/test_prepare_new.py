from pathlib import Path
import tempfile
import unittest

try:
    from . import prepare_new
    from .prepare import sha256
except ImportError:
    import prepare_new
    from prepare import sha256


class IndependentReceiptTests(unittest.TestCase):
    def test_bound_receipt_and_changed_download(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "public.txt"
            source.write_bytes(b"public source")
            receipt = {"path": "public.txt", "sha256": sha256(source)}
            self.assertEqual(prepare_new.receipt_path(root, receipt), source)
            source.write_bytes(b"changed source")
            with self.assertRaises(ValueError):
                prepare_new.receipt_path(root, receipt)

    def test_relative_escape_is_not_in_authorized_audio_root(self):
        with tempfile.TemporaryDirectory() as name:
            parent = Path(name)
            root = parent / "audio"
            root.mkdir()
            outside = parent / "elsewhere.txt"
            outside.write_bytes(b"public source")
            with self.assertRaises(ValueError):
                prepare_new.receipt_path(root, {"path": "../elsewhere.txt", "sha256": sha256(outside)})


if __name__ == "__main__":
    unittest.main()
