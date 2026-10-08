"""PY-05 synthetic request identity regressions; no backend imports or sockets."""
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

if __package__:
    from . import test_data_safety as base
else:
    import test_data_safety as base


CANARY = 'SYNTHETIC_PRIVATE_TRANSCRIPTION'
AUDIO = b'SYNTHETIC_AUDIO_A'
OTHER_AUDIO = b'SYNTHETIC_AUDIO_B'


class ASRRequestIdentityTests(unittest.TestCase):
    def setUp(self):
        # Synthetic fixtures live only inside the temporary directory and are
        # removed after each test, including every "retired" temporary file.
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-'))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.service = base.source_module('Scripts/qwen_asr_service.py',
            MODEL_STATE_LOCK=threading.Lock(), MODEL_LOCK=threading.Lock(),
            MODELS={}, MODEL_LAST_USED={}, UNLOADING_MODELS=set(),
            REQUEST_STATES={}, COMPLETED_REQUESTS={}, AUTO_SELF_CHECKS={},
            AUTH_TOKEN='synthetic-request-identity-token', MODEL_PATHS={},
            MODEL_ROOT=self.directory, SUPERVISED=False,
            _TEMP_LOCK=threading.RLock(), _TEMPORARY_FILES={}, _TEMP_STOPPING=False,
            _ACL_API=None, INFERENCE_SLOTS=threading.BoundedSemaphore(3))
        self.service.tempfile = SimpleNamespace(NamedTemporaryFile=lambda **kwargs:
            tempfile.NamedTemporaryFile(dir=self.directory, **kwargs))
        self.service.os.unlink = self.retire
        self.service.RequestLog.emit = Mock()
        self.service.model_for = Mock(side_effect=AssertionError('Model loading forbidden'))
        self.service.transcribe_audio = Mock(side_effect=self.transcribe)
        self.service.speech_band_enhance = Mock(side_effect=lambda path:
            (path, {'applied': False, 'reason': 'synthetic'}))
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='py05-synthetic')
        self.addCleanup(executor.shutdown, wait=True)
        self.service.INFERENCE_WORKER = executor

    def retire(self, path):
        destination = self.directory / 'retired'
        destination.mkdir(exist_ok=True)
        Path(path).rename(destination / Path(path).name)

    @staticmethod
    def transcribe(path, model, language=None, probe_input_path=None):
        if language == 'auto':
            return dict(text=CANARY, detected_label='English', language_probability=.99,
                        english_probability=.99, decode='forced')
        return CANARY

    def handler(self, query='model=1.7b', audio=AUDIO, request_id='same-id'):
        handler = object.__new__(self.service.Handler)
        handler.path = '/transcribe?' + query
        handler.server = SimpleNamespace(server_address=('127.0.0.1', 12345))
        handler.headers = Message()
        handler.headers['Content-Length'] = str(len(audio))
        handler.headers['X-LiveLingo-Request-ID'] = request_id
        handler.headers['Host'] = '127.0.0.1:12345'
        handler.headers[self.service.TOKEN_HEADER] = self.service.AUTH_TOKEN
        handler.rfile = io.BytesIO(audio)
        handler.send_json = Mock()
        return handler

    def post(self, **kwargs):
        handler = self.handler(**kwargs)
        handler.do_POST()
        handler.send_json.assert_called_once()
        return handler.send_json.call_args.args

    def assert_duplicate(self, response):
        self.assertEqual(response, (409, {'error': 'Request ID is already in use'}))

    def assert_conflict(self, response, reason):
        status, payload = response
        self.assertEqual(status, 409)
        self.assertEqual(payload.get('reason'), reason)
        self.assertNotIn(CANARY, json.dumps(payload))
        self.assertNotIn('text', payload)
        self.assertNotIn(str(self.directory), json.dumps(payload))
        self.assertNotIn(hashlib.sha256(AUDIO).hexdigest(), json.dumps(payload))

    def assert_finished_once(self, request_id='same-id'):
        self.assertEqual(self.service.transcribe_audio.call_count, 1)
        self.service.model_for.assert_not_called()
        snapshot = self.service.resource_snapshot()
        self.assertNotIn(request_id, snapshot['requests'])
        self.assertEqual(snapshot['completed_requests'][request_id],
                         {'model': '1.7b', 'state': 'finished'})
        self.assertNotIn(CANARY, json.dumps(snapshot))
        self.assertNotIn(CANARY, str(self.service.RequestLog.emit.call_args_list))
        self.assertNotIn(hashlib.sha256(AUDIO).hexdigest(), json.dumps(snapshot))
        self.assertNotIn(hashlib.sha256(AUDIO).hexdigest(),
                         str(self.service.RequestLog.emit.call_args_list))
        for _ in range(3):
            self.assertTrue(self.service.INFERENCE_SLOTS.acquire(blocking=False))
        self.assertFalse(self.service.INFERENCE_SLOTS.acquire(blocking=False))
        for _ in range(3):
            self.service.INFERENCE_SLOTS.release()

    def test_same_audio_path_with_changed_bytes_is_an_audio_conflict(self):
        source = self.directory / 'synthetic.wav'
        source.write_bytes(AUDIO)
        self.assertEqual(self.post(audio=source.read_bytes())[0], 200)
        # Same path and byte count, different content: a path/size binding fails.
        source.write_bytes(OTHER_AUDIO)
        self.assert_conflict(self.post(audio=source.read_bytes()), 'audio_content_mismatch')
        self.assert_finished_once()

    def test_changed_model_is_a_parameter_conflict(self):
        self.assertEqual(self.post()[0], 200)
        self.assert_conflict(self.post(query='model=0.6b'), 'parameters_mismatch')
        self.assert_finished_once()

    def test_changed_enhancement_is_a_parameter_conflict(self):
        self.assertEqual(self.post()[0], 200)
        self.assert_conflict(self.post(query='model=1.7b&enhance=speech'), 'parameters_mismatch')
        self.service.speech_band_enhance.assert_not_called()
        self.assert_finished_once()

    def test_changed_language_is_a_parameter_conflict(self):
        self.assertEqual(self.post()[0], 200)
        self.assert_conflict(self.post(query='model=1.7b&language=auto'), 'parameters_mismatch')
        self.assert_finished_once()

    def test_identical_completed_input_keeps_legacy_duplicate_response(self):
        self.assertEqual(self.post()[0], 200)
        self.assert_duplicate(self.post())
        self.assert_finished_once()

    def test_failed_duplicate_upload_never_answers_with_the_owner_identity(self):
        self.assertEqual(self.post()[0], 200)
        truncated = self.handler()
        truncated.headers.replace_header('Content-Length', str(len(AUDIO) + 8))
        truncated.do_POST()
        truncated.send_json.assert_called_once()
        self.assert_duplicate(truncated.send_json.call_args.args)
        stalled = self.handler()
        stalled.read_audio_body = Mock(side_effect=TimeoutError('Audio upload deadline exceeded'))
        stalled.do_POST()
        stalled.send_json.assert_called_once()
        self.assert_duplicate(stalled.send_json.call_args.args)
        self.assert_finished_once()

    def test_effective_default_parameters_keep_legacy_duplicate_response(self):
        self.assertEqual(self.post()[0], 200)
        self.assert_duplicate(self.post(query='language=English&enhance=off&model=1.7b'))
        self.assert_finished_once()

    def test_identical_bytes_at_another_path_are_still_the_same_input(self):
        paths = [self.directory / name for name in ('first.wav', 'second.wav')]
        for path in paths:
            path.write_bytes(AUDIO)
        self.assertEqual(self.post(audio=paths[0].read_bytes())[0], 200)
        self.assert_duplicate(self.post(audio=paths[1].read_bytes()))
        self.assert_finished_once()

    def running_duplicate(self, changed):
        entered, release = threading.Event(), threading.Event()
        def transcribe(*args, **kwargs):
            entered.set()
            if not release.wait(5):
                raise TimeoutError('Synthetic transcription not released')
            return CANARY
        self.service.transcribe_audio.side_effect = transcribe
        with ThreadPoolExecutor(max_workers=1) as callers:
            owner = callers.submit(self.post)
            try:
                self.assertTrue(entered.wait(2))
                response = self.post(audio=OTHER_AUDIO if changed else AUDIO)
                if changed:
                    self.assert_conflict(response, 'audio_content_mismatch')
                else:
                    self.assert_duplicate(response)
                snapshot = self.service.resource_snapshot()
                self.assertEqual(snapshot['requests']['same-id'],
                                 {'model': '1.7b', 'state': 'running'})
                self.assertNotIn('same-id', snapshot['completed_requests'])
            finally:
                release.set()
            self.assertEqual(owner.result(timeout=2)[0], 200)
        self.assert_finished_once()

    def test_changed_audio_cannot_replace_running_owner(self):
        self.running_duplicate(changed=True)

    def test_identical_running_input_keeps_legacy_duplicate_response(self):
        self.running_duplicate(changed=False)

    def test_disconnected_response_retains_binding_without_replaying_text(self):
        handler = self.handler()
        handler.send_json = self.service.Handler.send_json.__get__(handler)
        handler.send_response, handler.send_header = Mock(), Mock()
        handler.end_headers = Mock(side_effect=BrokenPipeError)
        handler.wfile = io.BytesIO()
        handler.do_POST()
        handler.send_response.assert_called_once_with(200)
        self.assertEqual(handler.wfile.getvalue(), b'')
        self.assert_conflict(self.post(audio=OTHER_AUDIO), 'audio_content_mismatch')
        self.assert_duplicate(self.post())
        self.assert_finished_once()

    def test_upload_in_progress_rejects_unbound_duplicate_without_releasing_owner(self):
        entered, release = threading.Event(), threading.Event()
        owner_handler = self.handler()
        read_audio = owner_handler.read_audio_body
        def read(size):
            entered.set()
            if not release.wait(5):
                raise TimeoutError('Synthetic upload not released')
            return read_audio(size)
        owner_handler.read_audio_body = read
        with ThreadPoolExecutor(max_workers=1) as callers:
            owner = callers.submit(owner_handler.do_POST)
            try:
                self.assertTrue(entered.wait(2))
                status, payload = self.post(audio=OTHER_AUDIO)
                self.assertEqual(status, 409)
                self.assertEqual(payload, {'error': 'Request ID is already in use',
                                           'reason': 'input_identity_pending'})
                self.assertEqual(self.service.resource_snapshot()['requests']['same-id'],
                                 {'model': '1.7b', 'state': 'waiting'})
                self.service.transcribe_audio.assert_not_called()
            finally:
                release.set()
            owner.result(timeout=2)
        self.assert_finished_once()

    def test_identity_is_private_and_evicted_with_its_bounded_receipt(self):
        self.service.MAX_COMPLETION_RECEIPTS = 2
        for index in range(3):
            self.assertEqual(self.post(request_id='bounded-' + str(index))[0], 200)
        receipts = self.service.resource_snapshot()['completed_requests']
        self.assertEqual(list(receipts), ['bounded-1', 'bounded-2'])
        self.assertTrue(all(receipt == {'model': '1.7b', 'state': 'finished'}
                            for receipt in receipts.values()))
        self.assertTrue(hasattr(self.service, '_REQUEST_IDENTITIES'))
        self.assertEqual(set(self.service._REQUEST_IDENTITIES), set(receipts))
        self.assert_conflict(self.post(request_id='bounded-1', audio=OTHER_AUDIO),
                             'audio_content_mismatch')
        # The existing receipt retention limit still permits an evicted ID.
        self.assertEqual(self.post(request_id='bounded-0', audio=OTHER_AUDIO)[0], 200)
        self.assertEqual(set(self.service._REQUEST_IDENTITIES),
                         set(self.service.resource_snapshot()['completed_requests']))
        self.assertEqual(self.service.transcribe_audio.call_count, 4)


class ASRRequestIdentityFixtureTests(unittest.TestCase):
    def test_fixtures_stay_inside_tmpdir_and_are_removed(self):
        case = ASRRequestIdentityTests('test_changed_model_is_a_parameter_conflict')
        case.setUp()
        directory = case.directory
        try:
            temporary_root = os.path.realpath(tempfile.gettempdir())
            self.assertEqual(os.path.commonpath([os.path.realpath(directory), temporary_root]), temporary_root)
            (directory / 'synthetic.wav').write_bytes(AUDIO)
            case.retire(directory / 'synthetic.wav')
            self.assertTrue((directory / 'retired' / 'synthetic.wav').exists())
        finally:
            case.doCleanups()
        self.assertFalse(directory.exists(), 'synthetic fixtures must not outlive the test')


if __name__ == '__main__':
    unittest.main()
