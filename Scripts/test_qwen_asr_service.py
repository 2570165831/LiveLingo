#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest
import threading
import json
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from urllib.request import Request, urlopen
from unittest.mock import patch
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_asr_service import PEAK_CEILING_DBFS, speech_band_enhance
import qwen_asr_service as service


class ServiceResponsivenessTests(unittest.TestCase):
    def test_health_responds_during_serialized_transcription(self):
        entered = threading.Event()
        release = threading.Event()
        calls = []

        def generate(*args, **kwargs):
            calls.append(threading.get_ident())
            entered.set()
            if not release.wait(5):
                raise TimeoutError("test did not release inference")
            return SimpleNamespace(text="test transcript")

        server = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"

        def transcribe():
            with urlopen(Request(base + "/transcribe?model=parakeet", data=b"test"), timeout=5) as response:
                return json.load(response)

        try:
            with patch.object(service, "model_for", return_value=SimpleNamespace(generate=generate)):
                with ThreadPoolExecutor(max_workers=2) as pool:
                    first = pool.submit(transcribe)
                    try:
                        self.assertTrue(entered.wait(2))
                        second = pool.submit(transcribe)
                        with urlopen(base + "/health", timeout=1) as response:
                            self.assertTrue(json.load(response)["ok"])
                        self.assertEqual(len(calls), 1)
                    finally:
                        release.set()
                    self.assertEqual(first.result()["text"], "test transcript")
                    self.assertEqual(second.result()["text"], "test transcript")
                    self.assertEqual(len(set(calls)), 1, "inference must stay on one worker thread")
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join()

    def test_disconnected_caller_does_not_trigger_second_response(self):
        handler = object.__new__(service.Handler)
        with patch.object(handler, "send_response") as send, patch.object(handler, "send_header"), patch.object(handler, "end_headers", side_effect=BrokenPipeError):
            handler.send_json(200, {"text": "done"})
            send.assert_called_once_with(200)


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



class OwnedServiceProtocolTests(unittest.TestCase):
    def test_ephemeral_authenticated_service_exits_on_parent_pipe_eof(self):
        import subprocess
        import secrets
        import selectors
        import time
        from urllib.error import HTTPError
        token = secrets.token_hex(32)
        with tempfile.TemporaryDirectory() as models:
            child = subprocess.Popen(
                [sys.executable, "-u", service.__file__, "--supervised", "--port", "0", "--models-dir", models],
                env=dict(os.environ, LIVELINGO_ASR_TOKEN=token, PYTHONDONTWRITEBYTECODE="1"),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                ready = None
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline and child.poll() is None:
                        if selector.select(1):
                            line = child.stdout.readline()
                            if line.startswith(service.READY_PREFIX + " "):
                                ready = json.loads(line.split(" ", 1)[1])
                                break
                self.assertIsNotNone(ready, "child did not announce readiness")
                self.assertEqual(ready["pid"], child.pid)
                self.assertTrue(ready["auth"])
                self.assertTrue(ready["supervised"])
                self.assertGreater(ready["port"], 0)
                base = f"http://127.0.0.1:{ready['port']}"
                for endpoint, body in [("/health", None), ("/transcribe", b"invalid audio")]:
                    with self.assertRaises(HTTPError) as caught:
                        urlopen(Request(base + endpoint, data=body), timeout=3)
                    self.assertEqual(caught.exception.code, 401)
                with urlopen(Request(base + "/health", headers={service.TOKEN_HEADER: token}), timeout=3) as response:
                    health = json.load(response)
                self.assertEqual(health["pid"], child.pid)
                self.assertEqual(health["models_root"], models)
                self.assertEqual(health["loaded_models"], [])
                child.stdin.close()
                self.assertEqual(child.wait(timeout=8), 0)
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=8)
                if not child.stdin.closed:
                    child.stdin.close()
                child.stdout.close()

if __name__ == "__main__":
    unittest.main()
