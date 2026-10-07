"""ASR privacy regressions using synthetic audio and unbound handlers only."""
from concurrent.futures import Future
from email.message import Message
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np
import soundfile as sf
import qwen_asr_service as service

CANARY = 'SYNTHETIC_PRIVATE_SENTENCE'
TOKEN = 'synthetic-test-token'


class ASRPrivacyTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='ll-asr-privacy-')
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.enterContext(patch.object(tempfile, 'tempdir', str(self.directory)))
        for name, value in {
            'AUTH_TOKEN': TOKEN, 'REQUEST_STATES': {}, 'COMPLETED_REQUESTS': {},
            'INFERENCE_SLOTS': threading.BoundedSemaphore(service.MAX_INFERENCE_REQUESTS),
            '_TEMPORARY_FILES': {}, '_TEMP_STOPPING': False,
        }.items():
            self.enterContext(patch.object(service, name, value, create=True))

    def handler(self, path='/health', token=TOKEN, host='127.0.0.1:12345', origin=None):
        handler = object.__new__(service.Handler)
        handler.path = path
        handler.server = SimpleNamespace(server_address=('127.0.0.1', 12345))
        handler.headers = Message()
        if host is not None:
            handler.headers['Host'] = host
        if token is not None:
            handler.headers[service.TOKEN_HEADER] = token
        if origin is not None:
            handler.headers['Origin'] = origin
        handler.headers['Content-Length'] = '4'
        handler.headers['X-LiveLingo-Request-ID'] = 'synthetic'
        handler.rfile = io.BytesIO(b'test')
        handler.send_json = Mock()
        handler.send_error = Mock()
        return handler

    def test_service_without_a_configured_token_fails_closed(self):
        handler = self.handler(token=None)
        with patch.object(service, 'AUTH_TOKEN', None):
            self.assertFalse(handler.require_authorized())
        self.assertEqual(handler.send_json.call_args.args[0], 401)

    def test_standalone_startup_requires_token_before_binding(self):
        server = Mock(server_address=('127.0.0.1', 12345))
        with patch.dict(service.os.environ, {'LIVELINGO_ASR_TOKEN': ''}), \
             patch.object(service, 'create_server', return_value=(server, '127.0.0.1', 12345)) as create, \
             patch.object(service, 'announce_ready'), patch.object(service, 'start_idle_maintenance', return_value=Mock()):
            self.assertEqual(service.main(['--token', '', '--models-dir', str(self.directory)]), 2)
        create.assert_not_called()

    def test_wrong_or_missing_host_is_rejected(self):
        for host in (None, 'attacker.invalid:12345', '127.0.0.1:12346',
                     '127.0.0.1:12345@attacker.invalid', '127.0.0.1:12345/path'):
            with self.subTest(host=host):
                handler = self.handler(host=host)
                self.assertFalse(handler.require_authorized())
                self.assertEqual(handler.send_json.call_args.args[0], 403)

    def test_foreign_null_or_wrong_port_origin_is_rejected(self):
        for origin in ('https://attacker.invalid', 'null', 'http://127.0.0.1:12346',
                       'http://127.0.0.1:12345/path', 'http://127.0.0.1:12345?private'):
            with self.subTest(origin=origin):
                handler = self.handler(origin=origin)
                self.assertFalse(handler.require_authorized())

    def test_same_origin_and_nonbrowser_callers_keep_working(self):
        for origin in (None, 'http://127.0.0.1:12345'):
            with self.subTest(origin=origin):
                self.assertTrue(self.handler(origin=origin).require_authorized())
        handler = self.handler(token=None)
        handler.headers['Authorization'] = 'Bearer ' + TOKEN
        self.assertTrue(handler.require_authorized())

    def test_duplicate_host_or_origin_is_rejected(self):
        for field, value in (('Host', 'attacker.invalid:12345'), ('Origin', 'http://127.0.0.1:12345')):
            handler = self.handler(origin='http://127.0.0.1:12345')
            handler.headers[field] = value
            self.assertFalse(handler.require_authorized())

    def test_nonascii_supplied_token_is_an_unauthorized_response(self):
        handler = self.handler(token='合成令牌')
        self.assertFalse(handler.require_authorized())
        self.assertEqual(handler.send_json.call_args.args[0], 401)

    def test_request_target_never_reaches_logs(self):
        handler = self.handler('/transcribe?model=' + CANARY)
        handler.log_date_time_string = lambda: 'synthetic time'
        with patch('builtins.print') as output:
            handler.log_message('"%s" %s %s', 'POST ' + handler.path + ' HTTP/1.1', '400', '-')
        self.assertNotIn(CANARY, str(output.call_args_list))

    def test_unsupported_model_is_rejected_before_admission_and_logs(self):
        handler = self.handler('/transcribe?model=' + CANARY)
        with patch.object(service, 'INFERENCE_SLOTS') as slots, patch('builtins.print') as output:
            handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 400)
        self.assertNotIn(CANARY, json.dumps(handler.send_json.call_args.args[1]))
        slots.acquire.assert_not_called()
        self.assertNotIn(CANARY, str(output.call_args_list))

    def test_dependency_error_response_has_only_a_fixed_safe_classification(self):
        handler = self.handler('/transcribe?model=1.7b')
        future = Future()
        future.set_exception(RuntimeError(CANARY + ' private-location'))
        executor = SimpleNamespace(submit=lambda *args: future)
        with patch.object(service, 'INFERENCE_WORKER', executor):
            handler.do_POST()
        status, payload = handler.send_json.call_args.args
        self.assertEqual(status, 500)
        self.assertNotIn(CANARY, json.dumps(payload))
        self.assertNotIn('private-location', json.dumps(payload))
        self.assertEqual(list(self.directory.glob('*.wav')), [])

    def test_partial_raw_wav_write_is_cleaned(self):
        factory = tempfile.NamedTemporaryFile
        class PartialFile:
            def __init__(self, *args, **kwargs):
                self.file = factory(*args, **kwargs)
                self.name = self.file.name
            def __enter__(self): return self
            def __exit__(self, *args): self.file.close()
            def close(self): self.file.close()
            def fileno(self): return self.file.fileno()
            def write(self, content):
                self.file.write(content[:2])
                raise OSError(CANARY)
        handler = self.handler('/transcribe?model=1.7b')
        with patch.object(service.tempfile, 'NamedTemporaryFile', PartialFile):
            handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 500)
        self.assertEqual(list(self.directory.glob('*.wav')), [])

    def synthetic_wav(self):
        source = self.directory / 'source.wav'
        samples = np.arange(16000, dtype=np.float32) / 16000
        sf.write(source, .008 * np.sin(2 * np.pi * 1000 * samples), 16000)
        return source

    def test_partial_enhanced_wav_write_is_cleaned(self):
        source = self.synthetic_wav()
        def fail(path, *args, **kwargs):
            Path(path).write_bytes(b'partial synthetic wav')
            raise OSError(CANARY)
        with patch.object(service.sf, 'write', side_effect=fail):
            with self.assertRaises(OSError):
                service.speech_band_enhance(str(source))
        self.assertEqual(list(self.directory.glob('*.wav')), [source])

    def test_parent_exit_cleans_registered_audio_even_when_logging_fails(self):
        source = self.synthetic_wav()
        enhanced, _ = service.speech_band_enhance(str(source))
        self.assertTrue(Path(enhanced).exists())
        with patch('builtins.print', side_effect=BrokenPipeError), patch.object(service.os, '_exit') as leave:
            service.request_shutdown(Mock(), 'parent stdin closed')
        leave.assert_called_once_with(0)
        self.assertFalse(Path(enhanced).exists())
        self.assertEqual(list(self.directory.glob('*.wav')), [source])

    def test_standalone_ready_log_omits_model_root(self):
        server = SimpleNamespace(server_address=('127.0.0.1', 12345))
        with patch.object(service, 'SUPERVISED', False), \
             patch.object(service, 'MODEL_ROOT', Path(CANARY)), \
             patch.object(service, 'available_model_keys', return_value=[]), \
             patch('builtins.print') as output:
            ready = service.announce_ready(server, '127.0.0.1')
        self.assertNotIn('models_root', ready)
        self.assertNotIn(CANARY, str(output.call_args_list))

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_temporary_wav_does_not_retain_inherited_allow_acl(self):
        source = self.synthetic_wav()
        subprocess.run(['/bin/chmod', '+a',
                        'everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit',
                        str(self.directory)], check=True, capture_output=True)
        enhanced, _ = service.speech_band_enhance(str(source))
        listing = subprocess.run(['/bin/ls', '-le', enhanced], check=True,
                                 capture_output=True, text=True).stdout
        self.assertIsNone(re.search(r'^\s*\d+:\s', listing, re.MULTILINE))

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS extended ACL regression')
    def test_temporary_wav_preserves_inherited_deny_acl(self):
        source = self.synthetic_wav()
        subprocess.run(['/bin/chmod', '+a',
                        'everyone deny writeextattr,file_inherit,directory_inherit', str(self.directory)],
                       check=True, capture_output=True)
        subprocess.run(['/bin/chmod', '+a',
                        'everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit',
                        str(self.directory)], check=True, capture_output=True)
        enhanced, _ = service.speech_band_enhance(str(source))
        entries = subprocess.run(['/bin/ls', '-le', enhanced], check=True,
                                 capture_output=True, text=True).stdout
        self.assertRegex(entries, r'deny .*writeextattr')
        self.assertNotRegex(entries, r'\d+:.*allow')

    def test_zero_return_with_nil_audio_acl_entry_is_empty(self):
        fake = SimpleNamespace(acl_get_fd_np=lambda *args: 1,
                               acl_get_entry=lambda *args: 0, acl_free=lambda *args: 0)
        source = self.synthetic_wav()
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with patch.object(service, '_ACL_API', fake), patch.object(sys, 'platform', 'darwin'):
                service.private_audio_file(fd)
        finally:
            os.close(fd)

    def test_installers_configure_a_private_authenticated_launchagent(self):
        root = Path(__file__).resolve().parents[1]
        for relative in ('Scripts/install-qwen-service.sh', 'Packaging/install.command'):
            with self.subTest(relative=relative):
                text = (root / relative).read_text()
                self.assertIn('secrets.', text)
                self.assertIn('EnvironmentVariables.LIVELINGO_ASR_TOKEN', text)
                self.assertIn('install -m 0600', text)
                self.assertIn('X-LiveLingo-Token', text)


if __name__ == '__main__':
    unittest.main()
