"""CPU-only explicit-Chinese protocol and quality regressions.

Production definitions use the existing AST fixture boundary. No backend,
third-party native extension, classroom data or app process is loaded. HTTP
regressions use an ephemeral loopback listener and synthetic audio/model work.
Synthetic input files are retained in to-trash for recoverable cleanup.
"""
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
from http.server import ThreadingHTTPServer
import io
import json
import math
import os
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, ProxyHandler, build_opener

if __package__:
    from . import test_data_safety as base
else:
    import test_data_safety as base


CHINESE = '今天讨论加速度与作用力的关系。'
MIXED = '今天讨论Newton第二定律，force等于质量乘以加速度。'
AUDIO = b'SYNTHETIC_SENTENCE_AUDIO'


class ExplicitChineseTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix='asr-explicit-chinese-'))
        self.addCleanup(self.archive)
        self.service = base.source_module('Scripts/qwen_asr_service.py',
            MODEL_STATE_LOCK=threading.Lock(), MODEL_LOCK=threading.Lock(),
            MODELS={}, MODEL_LAST_USED={}, UNLOADING_MODELS=set(),
            REQUEST_STATES={}, COMPLETED_REQUESTS={}, _REQUEST_IDENTITIES={},
            AUTO_SELF_CHECKS={}, MODEL_PATHS={}, MODEL_ROOT=self.directory,
            AUTH_TOKEN='synthetic-explicit-chinese-token', SUPERVISED=False,
            _TEMP_LOCK=threading.RLock(), _TEMPORARY_FILES={}, _TEMP_STOPPING=False,
            _ACL_API=None, INFERENCE_SLOTS=threading.BoundedSemaphore(3),
            MANUAL_INFERENCE_SLOTS=threading.BoundedSemaphore(1),
            sf=SimpleNamespace(info=Mock(return_value=SimpleNamespace(
                frames=80_000, samplerate=16_000))))
        self.service.tempfile = SimpleNamespace(NamedTemporaryFile=lambda **kwargs:
            tempfile.NamedTemporaryFile(dir=self.directory, **kwargs))
        self.service.os.unlink = self.retire
        self.service.RequestLog.emit = Mock()
        self.service.speech_band_enhance = Mock(side_effect=self.enhance)
        self.model = SimpleNamespace(generate=Mock(return_value=SimpleNamespace(
            text=CHINESE, generation_tokens=18)))
        self.service.model_for = Mock(return_value=self.model)
        self.service.transcribe_auto = Mock(side_effect=AssertionError('No automatic decode'))
        self.service.probe_language_only = Mock(side_effect=AssertionError('No language probe'))
        self.service.probe_language = Mock(side_effect=AssertionError('No language probe'))
        self.service.should_decode_detected = Mock(side_effect=AssertionError('No probability gate'))
        self.service.transcribe_parakeet = Mock(side_effect=AssertionError('No Parakeet'))
        self.executor = self.service.PriorityInferenceExecutor()
        self.addCleanup(self.executor.shutdown, wait=True)
        self.service.INFERENCE_WORKER = self.executor

    def archive(self):
        root = Path(os.environ.get('LIVELINGO_TARGET_EVAL_OUTPUT_ROOT', str(self.directory.parent)))
        destination = root / 'to-trash'
        destination.mkdir(parents=True, exist_ok=True)
        self.directory.rename(destination / self.directory.name)

    def retire(self, path):
        path = Path(path)
        self.assertEqual(path.parent, self.directory)
        destination = self.directory / 'retired'
        destination.mkdir(exist_ok=True)
        path.rename(destination / path.name)

    def enhance(self, path):
        enhanced = self.directory / 'enhanced.wav'
        enhanced.write_bytes(Path(path).read_bytes())
        return str(enhanced), {'applied': True, 'reason': 'synthetic'}

    def handler(self, query='model=1.7b&language=Chinese&enhance=speech',
                request_id='chinese-id', audio=AUDIO):
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

    def assert_no_other_decoder(self):
        for function in (self.service.transcribe_auto, self.service.probe_language_only,
                         self.service.probe_language, self.service.should_decode_detected,
                         self.service.transcribe_parakeet):
            function.assert_not_called()

    def assert_chinese_call(self, path='enhanced.wav'):
        self.model.generate.assert_called_once()
        args, kwargs = self.model.generate.call_args
        self.assertEqual(Path(args[0]).name, path)
        self.assertEqual(kwargs, dict(language='Chinese', max_tokens=256,
                                     temperature=0.0, verbose=False))
        self.assert_no_other_decoder()

    def assert_released(self, request_id='chinese-id'):
        snapshot = self.service.resource_snapshot()
        self.assertNotIn(request_id, snapshot['requests'])
        self.assertEqual(snapshot['completed_requests'][request_id]['state'], 'finished')
        self.assertEqual(self.service._TEMPORARY_FILES, {})
        self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 3)
        self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 1)

    def assert_slot_capacity(self, slots, count):
        acquired = 0
        try:
            for _ in range(count):
                self.assertTrue(slots.acquire(blocking=False))
                acquired += 1
            extra = slots.acquire(blocking=False)
            if extra:
                acquired += 1
            self.assertFalse(extra)
        finally:
            for _ in range(acquired):
                slots.release()

    def settle(self, predicate):
        deadline = time.monotonic() + 2
        while not predicate():
            self.assertLess(time.monotonic(), deadline, 'Synthetic request did not settle')
            threading.Event().wait(.002)

    def start_http_server(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), self.service.Handler)
        thread = threading.Thread(target=server.serve_forever,
                                  kwargs={'poll_interval': .01}, daemon=True)
        thread.start()
        def close():
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
        self.addCleanup(close)
        self.http_base = 'http://127.0.0.1:' + str(server.server_port)
        self.http_client = build_opener(ProxyHandler({}))

    def http_request(self, request_id=None, language=None, audio=AUDIO):
        endpoint = '/health' if request_id is None else '/transcribe?model=1.7b'
        if language is not None:
            endpoint += '&language=' + language
        headers = {self.service.TOKEN_HEADER: self.service.AUTH_TOKEN}
        if request_id is not None:
            headers['X-LiveLingo-Request-ID'] = request_id
        request = Request(self.http_base + endpoint,
                          data=audio if request_id is not None else None, headers=headers)
        try:
            response = self.http_client.open(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            return response.code, json.load(response)

    def test_http_realtime_a_then_queued_chinese_b_then_realtime_c_runs_a_c_b(self):
        self.start_http_server()
        entered, release = threading.Event(), threading.Event()
        manual_queued, realtime_queued = threading.Event(), threading.Event()
        order, tensor_threads = [], []
        def generate(path, **kwargs):
            label = Path(path).read_bytes().decode('ascii')
            order.append(label)
            tensor_threads.append(threading.get_ident())
            if label == 'A':
                entered.set()
                if not release.wait(2):
                    raise TimeoutError('Synthetic realtime A not released')
            return SimpleNamespace(text=CHINESE if kwargs['language'] == 'Chinese' else label,
                                   generation_tokens=18)
        self.model.generate.side_effect = generate
        def track(submit, event):
            def enqueue(*args, **kwargs):
                future = submit(*args, **kwargs)
                event.set()
                return future
            return enqueue
        with ThreadPoolExecutor(max_workers=3) as requests:
            try:
                a = requests.submit(self.http_request, 'realtime-a', None, b'A')
                self.assertTrue(entered.wait(1))
                with patch.object(self.executor, 'submit_manual',
                                  side_effect=track(self.executor.submit_manual, manual_queued)), \
                     patch.object(self.executor, 'submit',
                                  side_effect=track(self.executor.submit, realtime_queued)):
                    b = requests.submit(self.http_request, 'manual-b', 'Chinese', b'B')
                    self.assertTrue(manual_queued.wait(1))
                    self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 2)
                    self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 0)
                    c = requests.submit(self.http_request, 'realtime-c', None, b'C')
                    self.assertTrue(realtime_queued.wait(1))
                    self.assertEqual(order, ['A'])
                    status, snapshot = self.http_request()
                    self.assertEqual(status, 200)
                    self.assertEqual(snapshot['requests'], {
                        'realtime-a': {'model': '1.7b', 'state': 'running'},
                        'manual-b': {'model': '1.7b', 'state': 'waiting'},
                        'realtime-c': {'model': '1.7b', 'state': 'waiting'}})
                    self.assertEqual(snapshot['completed_requests'], {})
                    release.set()
                    self.assertEqual(a.result(timeout=2)[0], 200)
                    self.assertEqual(c.result(timeout=2)[0], 200)
                    self.assertEqual(b.result(timeout=2)[0], 200)
            finally:
                release.set()
        self.assertEqual(order, ['A', 'C', 'B'])
        self.assertEqual(len(set(tensor_threads)), 1)
        self.settle(lambda: not self.service.REQUEST_STATES and not self.service._TEMPORARY_FILES)
        for request_id in ('realtime-a', 'manual-b', 'realtime-c'):
            self.assert_released(request_id)

    def test_http_manual_limit_leaves_all_three_realtime_slots_available(self):
        self.start_http_server()
        entered, release = threading.Event(), threading.Event()
        queued = [threading.Event() for _ in range(3)]
        order = []
        def generate(path, **kwargs):
            label = Path(path).read_bytes().decode('ascii')
            order.append(label)
            if kwargs['language'] == 'Chinese':
                entered.set()
                if not release.wait(2):
                    raise TimeoutError('Synthetic manual inference not released')
            return SimpleNamespace(text=CHINESE if kwargs['language'] == 'Chinese' else label,
                                   generation_tokens=18)
        self.model.generate.side_effect = generate
        submit = self.executor.submit
        def enqueue(function, request_id, *args, **kwargs):
            future = submit(function, request_id, *args, **kwargs)
            queued[int(request_id[-1])].set()
            return future
        with ThreadPoolExecutor(max_workers=4) as requests:
            try:
                manual = requests.submit(self.http_request, 'manual-owner', 'Chinese', b'M')
                self.assertTrue(entered.wait(1))
                self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 3)
                self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 0)
                for index in range(3):
                    self.assertEqual(self.http_request('manual-overflow-' + str(index), 'Chinese'),
                                     (503, {'error': 'ASR queue is full', 'retryable': True}))
                # A cross-pool duplicate must release only its own admission,
                # without publishing a completion receipt for the running owner.
                self.assertEqual(self.http_request('manual-owner', 'English', b'M'),
                                 (409, {'error': 'Request ID is already in use',
                                        'reason': 'parameters_mismatch'}))
                self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 3)
                self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 0)
                with patch.object(self.executor, 'submit', side_effect=enqueue):
                    realtime = []
                    for index in range(3):
                        realtime.append(requests.submit(self.http_request,
                            'realtime-' + str(index), None, str(index).encode('ascii')))
                        self.assertTrue(queued[index].wait(1))
                    self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 0)
                    status, snapshot = self.http_request()
                    self.assertEqual(status, 200)
                    self.assertEqual(set(snapshot['requests']),
                                     {'manual-owner', 'realtime-0', 'realtime-1', 'realtime-2'})
                    self.assertEqual(snapshot['completed_requests'], {})
                    release.set()
                    self.assertEqual(manual.result(timeout=2)[0], 200)
                    for request in realtime:
                        self.assertEqual(request.result(timeout=2)[0], 200)
            finally:
                release.set()
        self.assertEqual(order, ['M', '0', '1', '2'])
        self.settle(lambda: not self.service.REQUEST_STATES and not self.service._TEMPORARY_FILES)
        for request_id in ('manual-owner', 'realtime-0', 'realtime-1', 'realtime-2'):
            self.assert_released(request_id)

    def test_manual_admission_errors_release_only_the_manual_slot(self):
        self.assertEqual(self.post(request_id='invalid id'),
                         (400, {'error': 'Invalid request ID'}))
        self.assertEqual(self.service.resource_snapshot()['requests'], {})
        self.assertEqual(self.service.resource_snapshot()['completed_requests'], {})
        self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 3)
        self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 1)
        for index, error in enumerate((TimeoutError('Synthetic upload timeout'),
                                       ValueError('Synthetic incomplete upload'))):
            with self.subTest(error=type(error).__name__):
                request_id = 'manual-upload-' + str(index)
                handler = self.handler(request_id=request_id)
                handler.read_audio_body = Mock(side_effect=error)
                handler.do_POST()
                self.assertEqual(handler.send_json.call_args.args[0],
                                 408 if isinstance(error, TimeoutError) else 500)
                self.assert_released(request_id)
        self.model.generate.assert_not_called()

    def test_explicit_chinese_uses_enhanced_same_sentence_and_returns_source(self):
        status, payload = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(payload, dict(model='1.7b', request_id='chinese-id',
            audio_enhancement={'applied': True, 'reason': 'synthetic'}, text=CHINESE,
            language_mode='explicit', language='zh', decode='forced',
            generated_tokens=18, truncated=False, policy=1))
        self.service.model_for.assert_called_once_with('1.7b')
        self.service.speech_band_enhance.assert_called_once()
        self.assert_chinese_call()
        self.assertNotIn(CHINESE, str(self.service.RequestLog.emit.call_args_list))
        self.assert_released()

    def test_explicit_mode_accepts_mixed_source_without_a_probability_gate(self):
        self.model.generate.return_value.text = MIXED
        status, payload = self.post()
        self.assertEqual(status, 200)
        self.assertEqual(payload['text'], MIXED)
        self.assertEqual(payload['language'], 'zh')
        self.assert_chinese_call()

    def test_chinese_06b_and_disabled_enhancement_use_original_audio(self):
        status, payload = self.post(query='model=0.6b&language=Chinese')
        self.assertEqual(status, 200)
        self.assertEqual(payload['model'], '0.6b')
        self.assertEqual(payload['audio_enhancement'], {'applied': False, 'reason': 'disabled'})
        self.service.speech_band_enhance.assert_not_called()
        self.service.model_for.assert_called_once_with('0.6b')
        self.assert_no_other_decoder()
        self.assertEqual(self.model.generate.call_args.kwargs['language'], 'Chinese')

    def test_failed_quality_returns_fixed_reason_without_rejected_text(self):
        for index, (text, tokens, reason) in enumerate([
            ('   ', 0, 'empty_transcript'),
            ('\uFFFD隐私合成文本', 18, 'invalid_text'),
            ('？！', 2, 'invalid_text'),
            ('加速度' * 4, 18, 'repeated_loop'),
            ('甲' * 61, 18, 'runaway_text'),
            (CHINESE, 256, 'truncated_transcript'),
            (CHINESE, 257, 'truncated_transcript'),
            (CHINESE, -1, 'invalid_metadata'),
            (CHINESE, True, 'invalid_metadata'),
            (CHINESE, 1.5, 'invalid_metadata'),
            (CHINESE, None, 'invalid_metadata'),
            (None, 18, 'invalid_text'),
        ]):
            with self.subTest(reason=reason, index=index):
                self.model.generate.reset_mock()
                self.model.generate.return_value = SimpleNamespace(text=text, generation_tokens=tokens)
                request_id = 'quality-' + str(index)
                # No enhancement file-name reuse between fixtures.
                status, payload = self.post(query='model=1.7b&language=Chinese', request_id=request_id)
                self.assertEqual(status, 422)
                self.assertEqual(payload, {'error': 'ASR quality check failed', 'reason': reason,
                                          'request_id': request_id, 'model': '1.7b'})
                self.assertNotIn('text', payload)
                self.assertEqual(self.model.generate.call_count, 1)
                self.assertEqual(self.model.generate.call_args.kwargs['language'], 'Chinese')
                self.assert_no_other_decoder()
                self.assert_released(request_id)

    def test_audio_duration_and_generation_limit_boundaries(self):
        quality = self.service.chinese_quality_reason
        unique = ''.join(chr(0x4E00 + i) for i in range(72))
        self.assertIsNone(quality(unique[:60], 1.0, 255))
        self.assertEqual(quality(unique[:61], 1.0, 255), 'runaway_text')
        self.assertIsNone(quality(unique, 6.0, 255))
        self.assertEqual(quality(unique, 5.99, 255), 'runaway_text')
        for duration in (0.0, -1.0, math.nan, math.inf):
            self.assertEqual(quality(CHINESE, duration, 18), 'invalid_audio')

    def test_long_audio_single_character_is_short_but_mixed_terms_are_counted(self):
        quality = self.service.chinese_quality_reason
        self.assertIsNone(quality('力', 7.99, 1))
        for text in ('力', 'A', '1'):
            self.assertEqual(quality(text, 8.0, 1), 'implausibly_short')
        self.assertIsNone(quality('研究Newton', 8.0, 4))
        self.assertIsNone(quality('加速度', 8.0, 3))
        self.service.sf.info.return_value.frames = 128_000
        self.model.generate.return_value = SimpleNamespace(text='力', generation_tokens=1)
        status, payload = self.post()
        self.assertEqual(status, 422)
        self.assertEqual(payload['reason'], 'implausibly_short')
        self.assertNotIn('text', payload)
        self.assert_no_other_decoder()
        self.assert_released()

    def test_loop_gate_keeps_emphasis_and_legitimate_mixed_language(self):
        quality = self.service.chinese_quality_reason
        for text in ('是是是，接下来分析加速度与作用力的关系。', MIXED,
                     '质质质质质质质甲乙丙丁戊', '加速度加速度加速度'):
            self.assertIsNone(quality(text, 5, 18), text)
        self.assertEqual(quality('加速度加速度加速度加速度', 5, 18), 'repeated_loop')
        # Eight non-overlapping repeats in twelve characters exceed 60%.
        self.assertEqual(quality('质质质质质质质质甲乙丙丁', 5, 18), 'repeated_loop')

    def test_invalid_audio_is_rejected_before_generation(self):
        for index, (frames, rate) in enumerate([(0, 16000), (10, 0), (-1, 16000),
                                               (10, -1), (math.inf, 16000)]):
            with self.subTest(frames=frames, rate=rate):
                self.service.sf.info.return_value = SimpleNamespace(frames=frames, samplerate=rate)
                status, payload = self.post(query='model=1.7b&language=Chinese',
                                            request_id='invalid-audio-' + str(index))
                self.assertEqual(status, 422)
                self.assertEqual(payload['reason'], 'invalid_audio')
                self.model.generate.assert_not_called()

    def test_model_error_has_no_english_fallback_and_private_message(self):
        self.model.generate.side_effect = RuntimeError('SYNTHETIC_PRIVATE_ERROR')
        status, payload = self.post()
        self.assertEqual(status, 500)
        self.assertEqual(payload, dict(error='inference_failed', request_id='chinese-id', model='1.7b'))
        self.assertNotIn('SYNTHETIC_PRIVATE_ERROR', json.dumps(payload))
        self.assert_chinese_call()
        self.assert_released()

    def test_unsupported_chinese_requests_are_rejected_before_admission(self):
        slots = Mock()
        self.service.INFERENCE_SLOTS = slots
        self.service.MANUAL_INFERENCE_SLOTS = slots
        for query in ('model=parakeet&language=Chinese', 'model=1.7b&language=chinese',
                      'model=1.7b&language=Chinese&language=English',
                      'model=1.7b&language=Chinese&confirmed_language=zh',
                      'model=1.7b&language=Chinese&confirmed_language='):
            with self.subTest(query=query):
                self.assertEqual(self.post(query=query)[0], 400)
        slots.acquire.assert_not_called()
        self.service.model_for.assert_not_called()
        self.model.generate.assert_not_called()

    def test_direct_chinese_call_never_routes_through_parakeet(self):
        with self.assertRaises(ValueError):
            self.service.transcribe_audio('synthetic.wav', 'parakeet', 'Chinese')
        with self.assertRaises(ValueError):
            self.service.transcribe_audio('synthetic.wav', '1.7b', 'Chinese', confirmed_language='zh')
        self.service.model_for.assert_not_called()
        self.assert_no_other_decoder()

    def test_input_identity_distinguishes_chinese_and_keeps_duplicate_rules(self):
        self.assertEqual(self.post()[0], 200)
        self.assertEqual(self.post(), (409, {'error': 'Request ID is already in use'}))
        for kwargs, reason in [
            ({'query': 'model=1.7b&language=English&enhance=speech'}, 'parameters_mismatch'),
            ({'query': 'model=1.7b&language=auto&enhance=speech'}, 'parameters_mismatch'),
            ({'query': 'model=0.6b&language=Chinese&enhance=speech'}, 'parameters_mismatch'),
            ({'query': 'model=1.7b&language=Chinese'}, 'parameters_mismatch'),
            ({'audio': b'SYNTHETIC_DIFFERENT_AUDIO'}, 'audio_content_mismatch'),
        ]:
            with self.subTest(reason=reason, kwargs=kwargs):
                self.assertEqual(self.post(**kwargs), (409, {
                    'error': 'Request ID is already in use', 'reason': reason}))
        self.model.generate.assert_called_once()
        self.assert_released()

    def test_quality_rejection_retains_identity_without_replaying_text(self):
        self.model.generate.return_value.text = ''
        self.assertEqual(self.post()[0], 422)
        self.assertEqual(self.post(), (409, {'error': 'Request ID is already in use'}))
        self.assertEqual(self.post(audio=b'OTHER'), (409, {
            'error': 'Request ID is already in use', 'reason': 'audio_content_mismatch'}))
        self.model.generate.assert_called_once()
        self.assert_released()

    def test_disconnected_response_keeps_receipt_and_identity(self):
        handler = self.handler()
        handler.send_json = self.service.Handler.send_json.__get__(handler)
        handler.send_response, handler.send_header = Mock(), Mock()
        handler.end_headers = Mock(side_effect=BrokenPipeError)
        handler.wfile = io.BytesIO()
        handler.do_POST()
        handler.send_response.assert_called_once_with(200)
        self.assertEqual(handler.wfile.getvalue(), b'')
        self.assertEqual(self.post(), (409, {'error': 'Request ID is already in use'}))
        self.assert_released()

    def test_waiting_chinese_cancellation_skips_model_and_releases_files(self):
        entered, release = threading.Event(), threading.Event()
        def blocker():
            entered.set()
            if not release.wait(2):
                raise TimeoutError('Synthetic blocker not released')
        active = self.executor.submit(blocker)
        self.addCleanup(release.set)
        self.assertTrue(entered.wait(1))
        self.service.INFERENCE_TIMEOUT_SECONDS = .02
        try:
            status, payload = self.post()
            self.assertEqual(status, 504)
            self.assertEqual(payload, dict(error='ASR queue deadline exceeded',
                                          request_id='chinese-id', model='1.7b', retryable=True))
            self.model.generate.assert_not_called()
            self.assert_released()
        finally:
            release.set()
            active.result(timeout=2)

    def test_running_timeout_retains_input_until_actual_chinese_completion(self):
        entered, release = threading.Event(), threading.Event()
        result = self.model.generate.return_value
        def generate(*args, **kwargs):
            entered.set()
            if not release.wait(2):
                raise TimeoutError('Synthetic model not released')
            return result
        self.model.generate.side_effect = generate
        self.service.INFERENCE_TIMEOUT_SECONDS = .05
        self.service.request_shutdown = Mock()
        handler = self.handler()
        with ThreadPoolExecutor(max_workers=1) as requests:
            pending = requests.submit(handler.do_POST)
            try:
                self.assertTrue(entered.wait(1))
                pending.result(timeout=1)
                self.service.request_shutdown.assert_called_once_with(handler.server, 'inference deadline exceeded')
                handler.send_json.assert_not_called()
                self.assertEqual(self.service.REQUEST_STATES['chinese-id']['state'], 'running')
                self.assertNotIn('chinese-id', self.service.COMPLETED_REQUESTS)
                self.assertTrue(self.service._TEMPORARY_FILES)
                self.assertTrue(all(Path(path).exists() for path in self.service._TEMPORARY_FILES))
                self.assert_slot_capacity(self.service.INFERENCE_SLOTS, 3)
                self.assert_slot_capacity(self.service.MANUAL_INFERENCE_SLOTS, 0)
                self.assertEqual(self.post(request_id='manual-overflow'),
                                 (503, {'error': 'ASR queue is full', 'retryable': True}))
            finally:
                release.set()
            # The next FIFO future runs after completion callbacks clean up.
            self.executor.submit(lambda: None).result(timeout=2)
        self.assert_chinese_call()
        self.assert_released()

    def test_legacy_english_default_calls_and_response_are_unchanged(self):
        for index, query in enumerate(('model=1.7b', 'model=1.7b&language=English',
                                       'model=&enhance=', 'model=0.6b')):
            with self.subTest(query=query):
                self.model.generate.reset_mock()
                self.model.generate.return_value = SimpleNamespace(text='  exact English sentence.  ')
                request_id = 'english-' + str(index)
                status, payload = self.post(query=query, request_id=request_id)
                self.assertEqual(status, 200)
                self.assertEqual(payload, dict(model='1.7b' if '1.7b' in query else '0.6b',
                    request_id=request_id, text='exact English sentence.',
                    audio_enhancement={'applied': False, 'reason': 'disabled'}))
                self.assertEqual(self.model.generate.call_args.kwargs,
                    dict(language='English', max_tokens=256, temperature=0.0, verbose=False))
        self.service.sf.info.assert_not_called()
        self.assert_no_other_decoder()


if __name__ == '__main__':
    unittest.main()
