import importlib.util
from pathlib import Path
import tempfile
import unittest

try:
    from . import prepare
except ImportError:
    import prepare


class PreparationTests(unittest.TestCase):
    def test_cache_prefix_is_read_without_modifying_source(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "audio.m4s"
            raw = b"000000000" + (24).to_bytes(4, "big") + b"ftyp" + b"isom" + b"\0" * 12
            path.write_bytes(raw)
            self.assertEqual(prepare.m4s_offset(path), 9)
            self.assertEqual(path.read_bytes(), raw)

    def test_invalid_box_size_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "audio.m4s"
            path.write_bytes((9999).to_bytes(4, "big") + b"ftyp")
            with self.assertRaises(ValueError):
                prepare.m4s_offset(path)

    @unittest.skipUnless(importlib.util.find_spec("soundfile") and importlib.util.find_spec("numpy"),
                         "CPU audio libraries unavailable")
    def test_acoustic_windows_cover_whole_input_without_gaps(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "tone.wav"
            samples = np.full(19 * 16000, .1, dtype="float32")
            samples[6 * 16000:7 * 16000] = 0
            sf.write(path, samples, 16000, subtype="PCM_16")
            rows = prepare.energy_windows(path)
            self.assertEqual(rows[0]["end_s"], 6.5)
            self.assertEqual(rows[-1]["end_s"], 19)
            self.assertTrue(all(a["end_s"] == b["start_s"] for a, b in zip(rows, rows[1:])))
            self.assertTrue(all(0 < r["end_s"] - r["start_s"] <= 8 for r in rows))


if __name__ == "__main__":
    unittest.main()
