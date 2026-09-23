#!/usr/bin/env python3
import os
import sys
import tempfile
import unittest
import threading
import json
import time
import weakref
import socket
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import patch
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_asr_service import PEAK_CEILING_DBFS, speech_band_enhance
import qwen_asr_service as service


class ServiceResponsivenessTests(unittest.TestCase):
    def setUp(self):
        # Every service here owns synthetic state and a test-only executor.
        for name, value in {
            'MODELS': {}, 'MODEL_LAST_USED': {}, 'UNLOADING_MODELS': set(),
            'REQUEST_STATES': {}, 'COMPLETED_REQUESTS': {}, 'AUTH_TOKEN': None,
            'INFERENCE_SLOTS': threading.BoundedSemaphore(service.MAX_INFERENCE_REQUESTS),
        }.items():
            self.enterContext(patch.object(service, name, value))
        self.mlx = SimpleNamespace(clear_cache=lambda: None)
        self.enterContext(patch.dict(sys.modules, {
            'mlx': SimpleNamespace(core=self.mlx), 'mlx.core': self.mlx,
        }))
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='asr-test')
        self.enterContext(patch.object(service, 'INFERENCE_WORKER', self.executor))
        self.addCleanup(self.executor.shutdown, wait=True)

    def wait_for(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.assertLess(time.monotonic(), deadline, 'Synthetic service did not settle')
            time.sleep(.005)

    def start_server(self):
        server = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.addCleanup(close)
        return server, f'http://127.0.0.1:{server.server_port}'

    def post(self, base, request_id, model='parakeet'):
        request = Request(base + f'/transcribe?model={model}', data=b'test',
                          headers={'X-LiveLingo-Request-ID': request_id})
        with urlopen(request, timeout=5) as response:
            return json.load(response)

    def test_idle_unload_keeps_active_and_waiting_model_owners(self):
        class FakeModel: pass
        unused = FakeModel()
        unused_ref = weakref.ref(unused)
        with patch.object(service, 'MODELS', {'unused': unused, 'active': FakeModel(), 'waiting': FakeModel()}), \
             patch.object(service, 'MODEL_LAST_USED', {'unused': 0, 'active': 0, 'waiting': 0}), \
             patch.object(service, 'REQUEST_STATES', {
                 'a': {'model': 'active', 'state': 'running'},
                 'b': {'model': 'waiting', 'state': 'waiting'}}):
            del unused
            retired = service.INFERENCE_WORKER.submit(service.unload_idle_models, 200, 120).result(timeout=5)
            self.assertEqual(retired, ['unused'])
            self.assertIsNone(unused_ref())
            self.assertEqual(service.resource_snapshot()['loaded_models'], ['active', 'waiting'])

    def test_service_bounds_submitted_requests_and_reports_real_ownership(self):
        entered, release = threading.Event(), threading.Event()
        def generate(*args, **kwargs):
            entered.set()
            if not release.wait(5): raise TimeoutError('fixture not released')
            return SimpleNamespace(text='test transcript')
        server = service.ThreadingHTTPServer(('127.0.0.1', 0), service.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        def request(index):
            with urlopen(Request(base + '/transcribe?model=parakeet', data=b'test',
                         headers={'X-LiveLingo-Request-ID': f'bounded-{index}'}), timeout=5) as response:
                return json.load(response)
        try:
            with patch.object(service, 'model_for', return_value=SimpleNamespace(generate=generate)):
                with ThreadPoolExecutor(max_workers=3) as pool:
                    jobs = [pool.submit(request, index) for index in range(3)]
                    try:
                        self.assertTrue(entered.wait(2))
                        deadline = time.monotonic() + 2
                        while time.monotonic() < deadline and len(service.resource_snapshot()['requests']) < 3:
                            time.sleep(.01)
                        snapshot = service.resource_snapshot()['requests']
                        self.assertEqual(len(snapshot), 3)
                        self.assertEqual(sum(row['state'] == 'running' for row in snapshot.values()), 1)
                        self.assertEqual(sum(row['state'] == 'waiting' for row in snapshot.values()), 2)
                        with self.assertRaises(HTTPError) as full: request(4)
                        self.assertEqual(full.exception.code, 503)
                    finally:
                        release.set()
                    for index, job in enumerate(jobs):
                        self.assertEqual(job.result()['request_id'], f'bounded-{index}')
            self.wait_for(lambda: not service.resource_snapshot()['requests'])
        finally:
            release.set()
            server.shutdown(); server.server_close(); thread.join()

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

    def test_disconnected_http_keeps_inference_until_positive_receipt(self):
        entered, release = threading.Event(), threading.Event()
        def generate(*args, **kwargs):
            entered.set()
            if not release.wait(5): raise TimeoutError('fixture not released')
            return SimpleNamespace(text='finished after disconnect')
        server, base = self.start_server()
        with patch.object(service, 'model_for', return_value=SimpleNamespace(generate=generate)):
            client = socket.create_connection(('127.0.0.1', server.server_port), timeout=3)
            try:
                client.sendall(b'POST /transcribe?model=parakeet HTTP/1.0\r\n'
                               b'Content-Length: 4\r\nX-LiveLingo-Request-ID: disconnected\r\n\r\ntest')
                self.assertTrue(entered.wait(2))
                client.close()
                with urlopen(base + '/health', timeout=2) as response:
                    during = json.load(response)
                self.assertEqual(during['requests']['disconnected']['state'], 'running')
                self.assertNotIn('disconnected', during['completed_requests'])
            finally:
                client.close()
                release.set()
            self.wait_for(lambda: 'disconnected' in service.resource_snapshot()['completed_requests'])
        completed = service.resource_snapshot()
        self.assertNotIn('disconnected', completed['requests'])
        self.assertEqual(completed['completed_requests']['disconnected'],
                         {'model': 'parakeet', 'state': 'finished'})

    def test_duplicate_id_does_not_replace_running_or_completed_owner(self):
        entered, release = threading.Event(), threading.Event()
        calls = []
        def generate(*args, **kwargs):
            calls.append(threading.get_ident())
            entered.set()
            if not release.wait(5): raise TimeoutError('fixture not released')
            return SimpleNamespace(text='one result')
        _, base = self.start_server()
        with patch.object(service, 'model_for', return_value=SimpleNamespace(generate=generate)):
            with ThreadPoolExecutor(max_workers=1) as clients:
                result = clients.submit(self.post, base, 'same-id')
                try:
                    self.assertTrue(entered.wait(2))
                    with self.assertRaises(HTTPError) as duplicate:
                        self.post(base, 'same-id', model='0.6b')
                    self.assertEqual(duplicate.exception.code, 409)
                    self.assertEqual(service.resource_snapshot()['requests']['same-id'],
                                     {'model': 'parakeet', 'state': 'running'})
                finally:
                    release.set()
                self.assertEqual(result.result(timeout=5)['text'], 'one result')
            self.wait_for(lambda: 'same-id' in service.resource_snapshot()['completed_requests'])
            with self.assertRaises(HTTPError) as duplicate:
                self.post(base, 'same-id')
            self.assertEqual(duplicate.exception.code, 409)
            self.assertEqual(len(calls), 1)
        self.assertEqual(service.resource_snapshot()['completed_requests']['same-id']['model'], 'parakeet')

    def test_completion_receipts_are_bounded_and_keep_model_identity(self):
        with patch.object(service, 'MAX_COMPLETION_RECEIPTS', 3):
            for index in range(5):
                service.finish_request(f'finished-{index}', '0.6b')
        receipts = service.resource_snapshot()['completed_requests']
        self.assertEqual(list(receipts), ['finished-2', 'finished-3', 'finished-4'])
        self.assertTrue(all(value == {'model': '0.6b', 'state': 'finished'} for value in receipts.values()))

    def test_finished_handler_retains_model_until_finalizer(self):
        service.MODELS['0.6b'] = SimpleNamespace()
        service.MODEL_LAST_USED['0.6b'] = 0
        service.REQUEST_STATES['returning'] = {'model': '0.6b', 'state': 'finished'}
        self.assertEqual(self.executor.submit(service.unload_idle_models, 200, 120).result(timeout=3), [])
        service.finish_request('returning', '0.6b')
        self.assertEqual(self.executor.submit(service.unload_idle_models, 200, 120).result(timeout=3), ['0.6b'])

    def test_unloading_remains_visible_until_cache_release_completes(self):
        entered, release = threading.Event(), threading.Event()
        def clear_cache():
            entered.set()
            if not release.wait(5): raise TimeoutError('fixture not released')
        service.MODELS['0.6b'] = SimpleNamespace()
        service.MODEL_LAST_USED['0.6b'] = 0
        with patch.object(self.mlx, 'clear_cache', side_effect=clear_cache):
            job = self.executor.submit(service.unload_idle_models, 200, 120)
            try:
                self.assertTrue(entered.wait(2))
                snapshot = service.resource_snapshot()
                self.assertEqual(snapshot['loaded_models'], [])
                self.assertEqual(snapshot['unloading_models'], ['0.6b'])
            finally:
                release.set()
            self.assertEqual(job.result(timeout=3), ['0.6b'])
        self.assertEqual(service.resource_snapshot()['unloading_models'], [])

    def test_failed_cache_release_stays_pending_and_can_be_retried(self):
        service.MODELS['0.6b'] = SimpleNamespace()
        service.MODEL_LAST_USED['0.6b'] = 0
        with patch.object(self.mlx, 'clear_cache', side_effect=RuntimeError('synthetic cache failure')):
            with self.assertRaises(RuntimeError):
                self.executor.submit(service.unload_idle_models, 200, 120).result(timeout=3)
        self.assertEqual(service.resource_snapshot()['unloading_models'], ['0.6b'])
        self.executor.submit(service.unload_idle_models, 201, 120).result(timeout=3)
        self.assertEqual(service.resource_snapshot()['unloading_models'], [])

    def test_fallback_loads_on_demand_and_all_model_work_uses_one_thread(self):
        events = []
        def load_model(path):
            events.append(('load', Path(path).name, threading.get_ident()))
            def generate(*args, **kwargs):
                events.append(('generate', Path(path).name, threading.get_ident()))
                return SimpleNamespace(text='synthetic transcript')
            return SimpleNamespace(generate=generate)
        def clear_cache():
            events.append(('unload', 'cache', threading.get_ident()))
        with tempfile.TemporaryDirectory() as directory:
            paths = {key: Path(directory) / key for key in ('parakeet', '0.6b')}
            for path in paths.values(): path.mkdir()
            with patch.object(service, 'MODEL_PATHS', paths), \
                 patch.dict(sys.modules, {'mlx_audio.stt.utils': SimpleNamespace(load_model=load_model)}), \
                 patch.object(self.mlx, 'clear_cache', side_effect=clear_cache):
                self.assertEqual(service.resource_snapshot()['loaded_models'], [])
                self.executor.submit(service.transcribe_audio, 'synthetic.wav', 'parakeet').result(timeout=3)
                self.assertEqual(service.resource_snapshot()['loaded_models'], ['parakeet'])
                for _ in range(2):
                    self.executor.submit(service.transcribe_audio, 'synthetic.wav', '0.6b').result(timeout=3)
                self.assertEqual([row[1] for row in events if row[0] == 'load'], ['parakeet', '0.6b'])
                with service.MODEL_STATE_LOCK:
                    service.MODEL_LAST_USED.update({'parakeet': 10, '0.6b': 10})
                self.assertEqual(self.executor.submit(service.unload_idle_models, 129, 120).result(timeout=3), [])
                self.assertEqual(self.executor.submit(service.unload_idle_models, 130, 120).result(timeout=3),
                                 ['0.6b', 'parakeet'])
        self.assertEqual(service.resource_snapshot()['loaded_models'], [])
        self.assertEqual(len({row[2] for row in events}), 1)


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
                # A real parent exit closes both pipes. The watchdog must exit
                # even if its shutdown diagnostic cannot be written to stdout.
                child.stdout.close()
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
