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
import io
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from unittest.mock import Mock, patch
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_asr_service import PEAK_CEILING_DBFS, speech_band_enhance
import qwen_asr_service as service


class AutoLanguageTests(unittest.TestCase):
    """Artificial token streams only; no classroom audio or transcript fixtures."""
    class Tokenizer:
        def __init__(self):
            self.heads = {label: [200 + i] for i, label in enumerate(service.LANGUAGE_CODES)}
            self.heads.update(Cantonese=[300, 301], Macedonian=[302, 303], None_=[304])
            self.heads['None'] = self.heads.pop('None_')

        def encode(self, text, **kwargs):
            if text == '<asr_text>': return [service.ASR_TEXT_TOKEN]
            return list(self.heads[text[1:]])

        def decode(self, tokens, skip_special_tokens=False):
            for label, head in self.heads.items():
                if list(tokens) == head: return ' ' + label
            if skip_special_tokens:
                return ''.join(chr(0x4E00 + token - 400) for token in tokens if token != service.ASR_TEXT_TOKEN)
            return '?'

    class Inner:
        def __init__(self, tokenizer, label, p_label, p_english):
            self._tokenizer = tokenizer
            self.config = SimpleNamespace(support_languages=list(service.LANGUAGE_CODES))
            self.head = tokenizer.encode(' ' + label) + [service.ASR_TEXT_TOKEN]
            self.p_label = p_label
            self.p_english = p_english
            self.calls = []

        def _build_prompt(self, count, language):
            return np.array([[7, 8, service.LANGUAGE_TOKEN,
                              self._tokenizer.encode(' English')[0], service.ASR_TEXT_TOKEN]])

        def _preprocess_audio(self, audio): return audio, None, 1
        def get_audio_features(self, features, mask): return features
        def _build_inputs_embeds(self, ids, features): return np.zeros((*ids.shape, 2))
        def make_cache(self): return {'position': 0}

        def __call__(self, ids, cache, input_embeddings=None):
            self.calls.append((ids.tolist(), input_embeddings is not None, cache))
            position = cache['position']
            cache['position'] += 1
            logits = np.full(151800, -np.inf)
            if position == 0:
                logits[self.head[0]] = np.log(self.p_label)
                english = self._tokenizer.encode(' English')[0]
                if english != self.head[0]: logits[english] = np.log(self.p_english)
                logits[999] = np.log(max(1e-12, 1 - self.p_label - (self.p_english if english != self.head[0] else 0)))
            else:
                logits[self.head[position]] = 0
            return logits[None, None, :]

    def setUp(self):
        self.enterContext(patch.object(service, 'AUTO_SELF_CHECKS', {}))
        self.enterContext(patch.object(service, 'version', side_effect=lambda name: {'mlx-audio': '0.3.1', 'mlx-lm': '0.30.5'}[name]))
        def softmax(logits):
            weights = np.exp(logits - np.max(logits))
            return weights / weights.sum()
        self.core = SimpleNamespace(array=np.array, argmax=np.argmax, float32=np.float32,
                                    softmax=softmax, eval=lambda *args: None)
        self.load_audio = Mock(return_value=np.zeros(16))
        self.generate_step = Mock(return_value=iter([(400, None), (401, None), (151645, None)]))
        self.enterContext(patch.dict(sys.modules, {
            'mlx': SimpleNamespace(core=self.core), 'mlx.core': self.core,
            'mlx_audio': SimpleNamespace(), 'mlx_audio.stt': SimpleNamespace(),
            'mlx_audio.stt.utils': SimpleNamespace(load_audio=self.load_audio),
            'mlx_lm': SimpleNamespace(), 'mlx_lm.generate': SimpleNamespace(generate_step=self.generate_step),
        }))

    def model(self, label='Chinese', p_label=.95, p_english=.02):
        tokenizer = self.Tokenizer()
        inner = self.Inner(tokenizer, label, p_label, p_english)
        return SimpleNamespace(_model=inner, generate=Mock(return_value=SimpleNamespace(text='x', generation_tokens=1)))

    def auto(self, model):
        self.assertNotIn('_build_prompt', model._model.__dict__)
        result = service.transcribe_auto(model, 'enhanced.wav', 'raw.wav', '1.7b')
        self.assertNotIn('_build_prompt', model._model.__dict__)
        return result

    def assert_forced(self, model, result):
        self.assertEqual(result['decode'], 'forced')
        self.assertEqual(result['language'], 'en')
        model.generate.assert_called_once_with('enhanced.wav', language='English', max_tokens=256,
                                               temperature=0.0, verbose=False)

    def test_default_and_explicit_english_keep_legacy_generate_arguments(self):
        for mode in (None, 'English'):
            with self.subTest(mode=mode):
                model = self.model()
                with patch.object(service, 'model_for', return_value=model):
                    self.assertEqual(service.transcribe_audio('enhanced.wav', '1.7b', mode, 'raw.wav'), 'x')
                model.generate.assert_called_once_with('enhanced.wav', language='English', max_tokens=256,
                                                       temperature=0.0, verbose=False)
                self.assertFalse(service.AUTO_SELF_CHECKS)

    def test_english_none_and_low_confidence_force_legacy_english(self):
        for label, p, p_en in [('English', .95, .95), ('None', .95, .02), ('Chinese', .8999, .02),
                               ('Chinese', .95, .0501), ('Spanish', .969, .01)]:
            with self.subTest(label=label, p=p, p_en=p_en):
                model = self.model(label, p, p_en)
                self.assert_forced(model, self.auto(model))

    def test_switch_probability_boundaries(self):
        for label, p, p_en, expected in [
            ('Chinese', .8999, .05, False), ('Chinese', .90, .05, True),
            ('Chinese', .90, .0501, False), ('Spanish', .969, .01, False),
            ('Spanish', .97, .01, True), ('Spanish', .97, .0101, False),
            ('English', 1, 0, False), ('None', 1, 0, False),
        ]:
            with self.subTest(label=label, p=p, p_en=p_en):
                self.assertEqual(service.should_decode_detected(label, p, p_en), expected)

    def test_detected_uses_raw_audio_and_continues_the_same_cache(self):
        model = self.model()
        result = self.auto(model)
        self.assertEqual(result['decode'], 'detected')
        self.assertEqual(result['language'], 'zh')
        self.assertEqual(result['generated_tokens'], 2)
        self.assertFalse(result['truncated'])
        self.assertNotIn('<asr_text>', result['text'])
        self.assertNotIn('language ', result['text'])
        self.load_audio.assert_called_once_with('raw.wav', sr=16000)
        model.generate.assert_not_called()
        inner = model._model
        self.assertEqual(inner.calls[0][:2], ([[7, 8, service.LANGUAGE_TOKEN]], True))
        arguments = self.generate_step.call_args.kwargs
        self.assertIs(arguments['prompt_cache'], inner.calls[0][2])
        self.assertEqual(arguments['prompt'].tolist(), [service.ASR_TEXT_TOKEN])
        self.assertEqual(arguments['max_tokens'], 256)

    def test_multitoken_language_heads_are_greedily_parsed(self):
        for label, code in [('Cantonese', 'yue'), ('Macedonian', 'mk')]:
            with self.subTest(label=label):
                self.generate_step.return_value = iter([(400, None), (151643, None)])
                result = self.auto(self.model(label))
                self.assertEqual((result['detected_label'], result['language']), (label, code))

    def test_probe_prefills_through_language_and_leaves_delimiter_unconsumed(self):
        model = self.model('Cantonese')
        check = service.auto_self_check(model, '1.7b')
        probe = service.probe_language(model, 'raw.wav', check)
        calls = model._model.calls
        self.assertEqual([call[:2] for call in calls], [
            ([[7, 8, service.LANGUAGE_TOKEN]], True),
            ([[300]], False), ([[301]], False),
        ])
        self.assertTrue(all(call[2] is probe['cache'] for call in calls))
        self.assertEqual(probe['detected_label'], 'Cantonese')

    def test_unparsed_ambiguous_failed_check_and_probe_exception_force_english(self):
        for failure in ('unparsed', 'ambiguous', 'version', 'suffix', 'delimiter', 'exception'):
            with self.subTest(failure=failure):
                service.AUTO_SELF_CHECKS.clear()
                model = self.model()
                if failure == 'unparsed': model._model.head = [999, service.ASR_TEXT_TOKEN]
                if failure == 'ambiguous': model._model._tokenizer.heads['Cantonese'] = model._model._tokenizer.heads['Chinese'] + [301]
                with patch.object(service, 'version', side_effect=lambda name: '0' if failure == 'version' else {'mlx-audio': '0.3.1', 'mlx-lm': '0.30.5'}[name]):
                    if failure == 'suffix': model._model._build_prompt = lambda *args: np.array([[7, 8, 9]])
                    if failure == 'delimiter': model._model._tokenizer.encode = lambda *args, **kwargs: [42]
                    if failure == 'exception': model._model._preprocess_audio = Mock(side_effect=RuntimeError('synthetic'))
                    # The suffix fixture replaces a method only on the fake, never on a real model.
                    result = service.transcribe_auto(model, 'enhanced.wav', 'raw.wav', '1.7b')
                self.assert_forced(model, result)
                self.assertIsNone(result['detected_label'])

    def test_self_check_is_cached_per_loaded_model_and_failure(self):
        model = self.model()
        with patch.object(service, 'version', wraps=service.version) as versions:
            first = service.auto_self_check(model, '1.7b')
            self.assertIs(service.auto_self_check(model, '1.7b'), first)
            self.assertEqual(versions.call_count, 2)
            other = self.model()
            self.assertIsNot(service.auto_self_check(other, '1.7b'), first)
            self.assertEqual(versions.call_count, 4)
        with patch.object(service, 'version', return_value='0') as versions:
            other = self.model()
            self.assertIsNone(service.auto_self_check(other, '1.7b'))
            self.assertIsNone(service.auto_self_check(other, '1.7b'))
            versions.assert_called_once()

    def test_body_limit_marks_truncated_without_eos(self):
        self.generate_step.return_value = iter([(400, None)] * 256)
        result = self.auto(self.model())
        self.assertEqual(result['generated_tokens'], 256)
        self.assertTrue(result['truncated'])

    def test_swift_probability_constants_and_language_table_match_server(self):
        source = Path(__file__).resolve().parents[1] / 'LiveLingo' / 'Sources'
        policy = (source / 'SourceLanguagePolicy.swift').read_text()
        for name, expected in {
            'nonLatinMinProbability': service.NON_LATIN_MIN_PROBABILITY,
            'nonLatinMaxEnglishProbability': service.NON_LATIN_MAX_ENGLISH_PROBABILITY,
            'latinMinProbability': service.LATIN_MIN_PROBABILITY,
            'latinMaxEnglishProbability': service.LATIN_MAX_ENGLISH_PROBABILITY,
        }.items():
            match = service.re.search(r'static let ' + name + r'\s*=\s*([0-9.]+)', policy)
            self.assertIsNotNone(match, name)
            self.assertEqual(float(match.group(1)), expected, name)
        table = (source / 'SpokenLanguage.swift').read_text()
        matches = service.re.findall(r'code: "([a-z]+)", qwenLabel: "([A-Za-z]+)", writingSystem: \.([a-z]+)', table)
        self.assertEqual({label: code for code, label, _ in matches}, service.LANGUAGE_CODES)
        self.assertEqual({code for code, _, script in matches if script == 'latin' and code != 'en'},
                         service.LATIN_LANGUAGE_CODES)


class ProbePrecisionTests(unittest.TestCase):
    def test_bfloat16_logits_normalize_to_one_with_float32_precision(self):
        import mlx.core as mx

        tokenizer = AutoLanguageTests.Tokenizer()
        chinese = tokenizer.encode(' Chinese')[0]
        english = tokenizer.encode(' English')[0]
        check = {'labels': frozenset(service.LANGUAGE_CODES) | {'None'},
                 'english_token': english,
                 'heads': {tokens[0]: [label] for label, tokens in tokenizer.heads.items()}}
        for top, runner_up, floor in ((16.0, 12.5, -8.0),
                                     (1000.0, 992.0, 968.0),
                                     (-1000.0, -1008.0, -1024.0)):
            with self.subTest(top=top):
                fixture = np.full(151800, floor, dtype=np.float32)
                fixture[chinese], fixture[english] = top, runner_up
                logits = mx.array(fixture, dtype=mx.bfloat16)
                quantized = np.asarray(logits.astype(mx.float32)).astype(np.float64)
                weights = np.exp(quantized - quantized.max())
                expected = weights / weights.sum()
                captured = []
                real_softmax = mx.softmax

                def normalize(values):
                    probabilities = real_softmax(values)
                    mx.eval(probabilities)
                    captured.append((values.dtype, np.asarray(probabilities)))
                    return probabilities

                class Inner(AutoLanguageTests.Inner):
                    def __call__(self, ids, cache, input_embeddings=None):
                        position = cache['position']
                        cache['position'] += 1
                        if position == 0:
                            return logits[None, None, :]
                        tail = np.full(151800, -np.inf, dtype=np.float32)
                        tail[service.ASR_TEXT_TOKEN] = 0
                        return mx.array(tail)[None, None, :]

                model = SimpleNamespace(_model=Inner(tokenizer, 'Chinese', .95, .02))
                with patch.dict(sys.modules, {
                    'mlx_audio.stt.utils': SimpleNamespace(load_audio=Mock(return_value=np.zeros(16))),
                }), patch.object(mx, 'softmax', side_effect=normalize):
                    probe = service.probe_language(model, 'raw.wav', check)
                self.assertEqual(len(captured), 1)
                dtype, probabilities = captured[0]
                self.assertEqual(dtype, mx.float32)
                self.assertEqual(probabilities.dtype, np.float32)
                self.assertAlmostEqual(float(probabilities.sum(dtype=np.float64)), 1.0, places=6)
                np.testing.assert_allclose(probabilities, expected, rtol=1e-6, atol=1e-9)
                self.assertAlmostEqual(probe['language_probability'], expected[chinese], places=6)
                self.assertAlmostEqual(probe['english_probability'], expected[english], places=7)
                if top == 16.0:
                    legacy = mx.exp(logits - mx.logsumexp(logits)).astype(mx.float32)
                    self.assertGreater(abs(float(mx.sum(legacy).item()) - 1.0), .01)


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
        if os.environ.get('LIVELINGO_ASR_TEST_IN_PROCESS') == '1':
            self.use_inprocess_requests()

    def use_inprocess_requests(self):
        """Exercise the handlers and worker without binding any sockets.

        Opt in for offline validation; the default still tests real HTTP.
        This fixture does not prove HTTP transport behavior.
        """
        from email.message import Message
        from urllib.parse import urlparse

        servers = {}

        class InProcessServer:
            def __init__(self, address, handler):
                self.server_address = (address[0], 12345)
                self.server_port = 12345
                self.stopped = threading.Event()
                servers[self.server_port] = self

            def serve_forever(self): self.stopped.wait()
            def shutdown(self): self.stopped.set()
            def server_close(self): self.stopped.set()

        def open_request(request, timeout=None):
            if isinstance(request, str): request = Request(request)
            parsed = urlparse(request.full_url)
            handler = object.__new__(service.Handler)
            handler.server = servers[parsed.port]
            handler.path = parsed.path + ('?' + parsed.query if parsed.query else '')
            handler.headers = Message()
            for key, value in request.header_items(): handler.headers[key] = value
            body = request.data or b''
            handler.headers['Content-Length'] = str(len(body))
            handler.rfile, handler.wfile = io.BytesIO(body), io.BytesIO()
            status = []
            handler.send_response = lambda code: status.append(code)
            handler.send_header = Mock()
            handler.end_headers = Mock()
            handler.do_GET() if request.get_method() == 'GET' else handler.do_POST()
            response = io.BytesIO(handler.wfile.getvalue())
            if status[-1] >= 400:
                raise HTTPError(request.full_url, status[-1], 'in-process response', {}, response)
            return response

        self.enterContext(patch.object(service, 'ThreadingHTTPServer', InProcessServer))
        self.enterContext(patch.object(sys.modules[__name__], 'urlopen', side_effect=open_request))

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

    def test_default_http_response_has_exactly_legacy_keys(self):
        # Blank legacy parameters retain parse_qs' original default handling.
        for index, (query, expected_model) in enumerate((
            ('model=1.7b', '1.7b'), ('model=&enhance=', '0.6b'),
            ('model=&model=1.7b&enhance=&enhance=off', '1.7b'),
            ('model=1.7b&language=English', '1.7b'),
        )):
            with self.subTest(query=query):
                handler = self.synthetic_handler(query)
                handler.headers['X-LiveLingo-Request-ID'] = f'synthetic-{index}'
                model = SimpleNamespace(generate=Mock(return_value=SimpleNamespace(text='x')))
                with patch.object(service, 'model_for', return_value=model) as load:
                    handler.do_POST()
                status, result = handler.send_json.call_args.args
                self.assertEqual(status, 200)
                self.assertEqual(set(result), {'text', 'model', 'request_id', 'audio_enhancement'})
                self.assertEqual(result['model'], expected_model)
                load.assert_called_once_with(expected_model)
                self.assertEqual(model.generate.call_count, 1)
                self.assertEqual(model.generate.call_args.kwargs,
                                 {'language': 'English', 'max_tokens': 256, 'temperature': 0.0, 'verbose': False})

    def test_invalid_language_is_rejected_before_admission_or_loading(self):
        slots = Mock()
        with patch.object(service, 'INFERENCE_SLOTS', slots), patch.object(service, 'model_for') as load:
            for query in ('model=parakeet&language=auto', 'model=1.7b&language=xx',
                          'model=1.7b&language=Chinese', 'model=1.7b&language=',
                          'model=1.7b&language=auto&language=English'):
                with self.subTest(query=query):
                    handler = self.synthetic_handler(query)
                    handler.do_POST()
                    self.assertEqual(handler.send_json.call_args.args[0], 400)
            slots.acquire.assert_not_called()
            slots.release.assert_not_called()
            load.assert_not_called()

    def test_auto_http_passes_raw_and_enhanced_paths_and_only_logs_metadata(self):
        handler = self.synthetic_handler('model=1.7b&enhance=speech&language=auto')
        canary = chr(0x4E00) + chr(0x4E01)
        def transcribe(path, model, language_mode=None, probe_input_path=None):
            self.assertEqual((path, model, language_mode), ('enhanced.wav', '1.7b', 'auto'))
            self.assertNotEqual(path, probe_input_path)
            return {'text': canary, 'language_mode': 'auto', 'language': 'zh', 'decode': 'detected',
                    'detected_label': 'Chinese', 'language_probability': .95, 'english_probability': .02,
                    'generated_tokens': 2, 'truncated': False, 'policy': 1}
        with patch.object(service, 'speech_band_enhance', return_value=('enhanced.wav', {})), \
             patch.object(service, 'transcribe_audio', side_effect=transcribe), \
             patch.object(service.os, 'unlink'), patch('builtins.print') as output:
            handler.do_POST()
        status, result = handler.send_json.call_args.args
        self.assertEqual(status, 200)
        self.assertEqual(result['language'], 'zh')
        self.assertNotIn(canary, str(output.call_args_list))

    def synthetic_handler(self, query):
        handler = object.__new__(service.Handler)
        handler.path = '/transcribe?' + query
        handler.headers = {'Content-Length': '1', 'X-LiveLingo-Request-ID': 'synthetic'}
        handler.rfile = io.BytesIO(b'x')
        handler.send_json = Mock()
        return handler

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
            if os.environ.get('LIVELINGO_ASR_TEST_IN_PROCESS') == '1':
                handler = self.synthetic_handler('model=parakeet')
                handler.headers['X-LiveLingo-Request-ID'] = 'disconnected'
                handler.send_json = service.Handler.send_json.__get__(handler)
                handler.send_response = Mock()
                handler.send_header = Mock()
                handler.end_headers = Mock(side_effect=BrokenPipeError)
                with ThreadPoolExecutor(max_workers=1) as clients:
                    job = clients.submit(handler.do_POST)
                    try:
                        self.assertTrue(entered.wait(2))
                        with urlopen(base + '/health', timeout=2) as response:
                            during = json.load(response)
                        self.assertEqual(during['requests']['disconnected']['state'], 'running')
                        self.assertNotIn('disconnected', during['completed_requests'])
                    finally:
                        release.set()
                    job.result(timeout=5)
                handler.send_response.assert_called_once_with(200)
                completed = service.resource_snapshot()
                self.assertNotIn('disconnected', completed['requests'])
                self.assertEqual(completed['completed_requests']['disconnected'],
                                 {'model': 'parakeet', 'state': 'finished'})
                return
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
            command = [sys.executable, '-u', service.__file__]
            in_process = os.environ.get('LIVELINGO_ASR_TEST_IN_PROCESS') == '1'
            if in_process:
                # Run the real CLI/watchdog in a child with an unbound server.
                # Closing its parent pipe must still terminate that process.
                command = [sys.executable, '-u', '-c', '''
import sys, threading
import qwen_asr_service as service
class UnboundServer:
    server_address = ('127.0.0.1', 12345)
    def serve_forever(self): threading.Event().wait()
    def server_close(self): pass
service.create_server = lambda host, port: (UnboundServer(), host, 12345)
sys.exit(service.main(sys.argv[1:]))
''']
            child = subprocess.Popen(
                command + ["--supervised", "--port", "0", "--models-dir", models],
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
                if in_process:
                    def open_request(request, timeout=None):
                        handler = object.__new__(service.Handler)
                        handler.path = service.urlparse(request.full_url).path
                        handler.server = SimpleNamespace(server_address=('127.0.0.1', ready['port']))
                        handler.headers = {service.TOKEN_HEADER: request.get_header('X-livelingo-token', '')}
                        handler.send_json = Mock()
                        with patch.object(service, 'AUTH_TOKEN', token), \
                             patch.object(service, 'MODEL_ROOT', Path(models)), \
                             patch.object(service, 'MODELS', {}):
                            handler.do_GET() if request.data is None else handler.do_POST()
                        status, payload = handler.send_json.call_args.args
                        response = io.BytesIO(json.dumps(payload).encode())
                        if status >= 400:
                            raise HTTPError(request.full_url, status, 'in-process response', {}, response)
                        return response
                    self.enterContext(patch.object(sys.modules[__name__], 'urlopen', side_effect=open_request))
                for endpoint, body in [("/health", None), ("/transcribe", b"invalid audio")]:
                    with self.assertRaises(HTTPError) as caught:
                        urlopen(Request(base + endpoint, data=body), timeout=3)
                    self.assertEqual(caught.exception.code, 401)
                with urlopen(Request(base + "/health", headers={service.TOKEN_HEADER: token}), timeout=3) as response:
                    health = json.load(response)
                self.assertEqual(health["pid"], os.getpid() if in_process else child.pid)
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
