#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_asr_service import PEAK_CEILING_DBFS, speech_band_enhance


class SpeechBandEnhancementTests(unittest.TestCase):
    sample_rate = 44_100

    def write_audio(self, audio: np.ndarray) -> str:
        handle = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        handle.close()
        sf.write(handle.name, audio, self.sample_rate, subtype="FLOAT")
        self.addCleanup(lambda: os.path.exists(handle.name) and os.unlink(handle.name))
        return handle.name

    def test_quiet_speech_band_is_boosted_relative_to_low_hum(self):
        seconds = 2
        time = np.arange(self.sample_rate * seconds, dtype=np.float32) / self.sample_rate
        speech = 0.015 * np.sin(2 * np.pi * 1_000 * time)
        hum = 0.080 * np.sin(2 * np.pi * 60 * time)
        source_path = self.write_audio(speech + hum)

        enhanced_path, metadata = speech_band_enhance(source_path)
        self.addCleanup(
            lambda: enhanced_path != source_path
            and os.path.exists(enhanced_path)
            and os.unlink(enhanced_path)
        )
        enhanced, _ = sf.read(enhanced_path, dtype="float32")

        source_speech_projection = abs(np.mean((speech + hum) * np.sin(2 * np.pi * 1_000 * time)))
        source_hum_projection = abs(np.mean((speech + hum) * np.sin(2 * np.pi * 60 * time)))
        enhanced_speech_projection = abs(np.mean(enhanced * np.sin(2 * np.pi * 1_000 * time)))
        enhanced_hum_projection = abs(np.mean(enhanced * np.sin(2 * np.pi * 60 * time)))

        self.assertTrue(metadata["applied"])
        self.assertEqual(metadata["band_hz"], [120, 7_200])
        self.assertGreaterEqual(metadata["requested_gain_db"], 6.0)
        self.assertGreater(enhanced_speech_projection, source_speech_projection * 2.0)
        self.assertGreater(
            enhanced_speech_projection / enhanced_hum_projection,
            (source_speech_projection / source_hum_projection) * 2.0,
        )

    def test_peak_limiter_keeps_enhanced_audio_below_ceiling(self):
        time = np.arange(self.sample_rate * 2, dtype=np.float32) / self.sample_rate
        audio = 0.03 * np.sin(2 * np.pi * 1_000 * time)
        audio[self.sample_rate // 2] = 1.0
        source_path = self.write_audio(audio)

        enhanced_path, metadata = speech_band_enhance(source_path)
        self.addCleanup(
            lambda: enhanced_path != source_path
            and os.path.exists(enhanced_path)
            and os.unlink(enhanced_path)
        )
        enhanced, _ = sf.read(enhanced_path, dtype="float32")
        peak_dbfs = 20 * np.log10(max(float(np.max(np.abs(enhanced))), 1e-9))

        self.assertLessEqual(peak_dbfs, PEAK_CEILING_DBFS + 0.05)
        self.assertIn("limited", metadata)

    def test_silence_is_not_given_positive_gain(self):
        source_path = self.write_audio(np.zeros(self.sample_rate, dtype=np.float32))

        enhanced_path, metadata = speech_band_enhance(source_path)
        self.addCleanup(
            lambda: enhanced_path != source_path
            and os.path.exists(enhanced_path)
            and os.unlink(enhanced_path)
        )
        enhanced, _ = sf.read(enhanced_path, dtype="float32")

        self.assertEqual(metadata["requested_gain_db"], 0.0)
        self.assertEqual(float(np.max(np.abs(enhanced))), 0.0)


if __name__ == "__main__":
    unittest.main()
