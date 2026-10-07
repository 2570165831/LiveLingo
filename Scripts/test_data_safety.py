"""Synthetic Python durability regressions; no model imports or sockets.

Execute production function/class ASTs with fake inference and serialization.
Fixtures are retained under superseded instead of permanently deleting them.
"""
import argparse
import ast
import builtins
from collections import OrderedDict
from concurrent.futures import Future, ThreadPoolExecutor
import contextlib
import copy
import ctypes
from datetime import datetime
from email.message import Message
import errno
import gc
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler
import io
import ipaddress
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import select
import stat
import struct
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import MagicMock, Mock, patch
from urllib.parse import parse_qs, urlparse
from typing import Iterator, NamedTuple
import uuid

ROOT = Path(__file__).resolve().parents[1]


def source_module(relative, **overrides):
    """Keep production bodies, replacing only imports/startup and dependencies."""
    path = ROOT / relative
    tree = ast.parse(path.read_text(), filename=str(path))
    names = dict(globals())
    source_os = types.SimpleNamespace(**{name: getattr(os, name) for name in dir(os)
                                         if name != 'environ'})
    source_os.environ = {}
    helper_paths = {
        'checkpoints': ROOT / 'Scripts/mlx_runtime/checkpoints.py',
        'review_diagnostics': ROOT / 'Scripts/mlx_runtime/review_diagnostics.py',
        'private_files': ROOT / 'Scripts/private_files.py',
        'privacy_cli': ROOT / 'Scripts/privacy_cli.py',
    }
    helpers = {}

    def production_import(name, globals=None, locals=None, fromlist=(), level=0):
        if level == 0 and name in helper_paths:
            if name not in helpers:
                helper_path = helper_paths[name]
                helper = types.ModuleType(name)
                helper.__dict__.update(__file__=str(helper_path),
                                       __builtins__=isolated_builtins)
                helpers[name] = helper
                # Execute these trusted, backend-free helpers unchanged. Sharing
                # the syscall proxy makes FD faults reach the actual writer,
                # including local imports, without patching process-wide os.
                exec(compile(helper_path.read_text(), str(helper_path), 'exec',
                             dont_inherit=True), helper.__dict__)
                if 'os' in helper.__dict__:
                    helper.os = source_os
            return helpers[name]
        if name.split('.')[0] in {'mlx', 'mlx_lm', 'mlx_audio', 'torch', 'transformers'}:
            raise AssertionError('Backend import forbidden in data-safety fixtures')
        return builtins.__import__(name, globals, locals, fromlist, level)

    isolated_builtins = dict(vars(builtins), __import__=production_import)
    names.update(os=source_os, __file__=str(path), __name__='data_safety_subject',
                 __builtins__=isolated_builtins,
                 measure=lambda stage: contextlib.nullcontext(), generation_stage=lambda purpose: None)
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module in {*helper_paths, 'contextlib'}:
            helper = production_import(node.module, fromlist=tuple(item.name for item in node.names))
            for item in node.names:
                names[item.asname or item.name] = getattr(helper, item.name)
        if isinstance(node, ast.Assign):
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                allowed = (ast.Constant, ast.BinOp, ast.UnaryOp, ast.operator, ast.unaryop,
                           ast.List, ast.Tuple, ast.Set, ast.Dict, ast.Load, ast.Call, ast.Name)
                if any(not isinstance(item, allowed) or
                       (isinstance(item, ast.Name) and item.id != 'frozenset') or
                       (isinstance(item, ast.Call) and not
                        (isinstance(item.func, ast.Name) and item.func.id == 'frozenset'))
                       for item in ast.walk(node.value)):
                    continue
                value = eval(compile(ast.Expression(node.value), str(path), 'eval'),
                             {'__builtins__': {}, 'frozenset': frozenset})
            for target in node.targets:
                if isinstance(target, ast.Name):
                    names[target.id] = value
    nodes = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))
             or (isinstance(node, ast.ImportFrom) and node.module == '__future__')]
    module = types.ModuleType('data_safety_subject')
    module.__dict__.update(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec',
                 dont_inherit=True), module.__dict__)
    module.__dict__.update(overrides)
    return module


class SyntheticFiles(unittest.TestCase):
    def setUp(self):
        active = ROOT / '.data-safety-fixtures'
        active.mkdir(exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-', dir=active))
        self.addCleanup(self.archive)

    def archive(self):
        destination = ROOT / 'superseded' / 'python-data-safety'
        destination.mkdir(parents=True, exist_ok=True)
        self.directory.rename(destination / self.directory.name)

    def retire(self, path, *args, **kwargs):
        path = Path(path)
        directory = kwargs.get('dir_fd')
        try:
            os.stat(path, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            if kwargs.get('missing_ok'): return
            raise FileNotFoundError(path.name)
        destination = self.directory / 'retired'
        destination.mkdir(exist_ok=True)
        os.rename(path, destination / (path.name + '.' + uuid.uuid4().hex),
                  src_dir_fd=directory)


class WorkerDataSafetyTests(SyntheticFiles):
    def run_worker(self, prefix='', saved_prefix=None, fail_save=False, periodic=False):
        events, saves, steps = [], [], []
        state = self.directory / 'state'
        state.mkdir()
        command_queue = None
        identity = hashlib.sha256(b'synthetic').hexdigest()
        if saved_prefix is not None:
            (state / (identity + '.safetensors')).write_text(saved_prefix)

        class Generation:
            def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', **kwargs):
                self.identity = identity
                self.wire = self.text = prefix
                self.thinking_count = self.final_count = 0
                self.done = False

            def step(self):
                steps.append(self.wire)
                self.wire += '|tail'
                self.text = self.wire
                self.done = not periodic
                return 'token' if periodic else 'done'

            def save(self, path):
                saves.append(self.wire)
                if fail_save and len(saves) == 1:
                    raise OSError(errno.ENOSPC, 'synthetic full disk')
                Path(path).write_text(self.wire)

            @classmethod
            def restore(cls, engine, path, expected_identity):
                return cls(engine, 'synthetic', prefix=Path(path).read_text())

        engine = types.ModuleType('engine')
        engine.Engine = lambda *args: object()
        engine.Generation = Generation
        schemas = types.ModuleType('schemas')
        schemas.note_schema = schemas.review_schema = lambda data: {}
        worker = source_module('Scripts/mlx_runtime/worker.py', discover_mlx=lambda: None)
        worker.protocol = io.StringIO()
        # Synthetic operations never permanently delete a fixture.
        worker.os.unlink = self.retire
        commands = [dict(op='generate', id='request', prompt='synthetic', prefix=prefix,
                         purpose='note', input='{}')]
        if saved_prefix is not None: commands.append(dict(op='shutdown'))

        def reader(input_fd, stop_fd, stopping, destination):
            nonlocal command_queue
            command_queue = destination
            for command in commands: destination.put(command)

        def send(kind, request_id=None, **fields):
            events.append(dict(event=kind, id=request_id, **fields))
            if kind == 'error' and fail_save:
                command_queue.put(dict(op='checkpoint', id='request'))
                command_queue.put(dict(op='shutdown'))

        worker.read_commands = reader
        worker.send = send
        if periodic:
            clock = iter(range(0, 10000, 31))
            worker.time = types.SimpleNamespace(monotonic=lambda: next(clock))
        with patch.dict(sys.modules, engine=engine, schemas=schemas), \
                patch.object(sys, 'argv', ['worker', '--model', 'synthetic',
                                          '--state-directory', str(state)]), \
                contextlib.redirect_stderr(io.StringIO()):
            worker.main()
        return events, saves, steps, state / (identity + '.safetensors')

    def test_py01_disk_checkpoint_cannot_shorten_caller_prefix(self):
        prefix = 'synthetic-A|newer-B'
        events, saves, _, path = self.run_worker(prefix, 'synthetic-A')
        snapshot = next(item for item in events if item['event'] == 'snapshot')
        self.assertEqual(snapshot['wire'], prefix)
        self.assertFalse(snapshot['recovered'])
        self.assertEqual(path.read_text(), prefix)

    def test_py01_newer_checkpoint_remains_reusable(self):
        events, _, _, _ = self.run_worker('synthetic-A', 'synthetic-A|newer-B')
        snapshot = next(item for item in events if item['event'] == 'snapshot')
        self.assertEqual(snapshot['wire'], 'synthetic-A|newer-B')
        self.assertTrue(snapshot['recovered'])

    def test_py02_completed_save_failure_keeps_retryable_result(self):
        events, saves, steps, path = self.run_worker('synthetic-A', fail_save=True)
        self.assertEqual(next(item for item in events if item['event'] == 'checkpoint')['state'], 'saved')
        self.assertGreaterEqual(len(saves), 2)
        self.assertEqual(path.read_text(), 'synthetic-A|tail')
        self.assertEqual(len(steps), 1, 'Saving a completed result must not rerun inference')

    def test_py02_periodic_save_failure_emits_latest_progress_before_error(self):
        events, _, _, _ = self.run_worker('synthetic-A', fail_save=True, periodic=True)
        error = next(index for index, item in enumerate(events) if item['event'] == 'error')
        snapshots = [item['wire'] for item in events[:error] if item['event'] == 'snapshot']
        self.assertEqual(snapshots[-1], 'synthetic-A|tail')
        self.assertEqual(next(item for item in events if item['event'] == 'checkpoint')['state'], 'saved')


class CheckpointDataSafetyTests(SyntheticFiles):
    def generation(self, done):
        def serialize(path, cache, metadata):
            payload = json.dumps(metadata).encode('utf-8')
            if hasattr(path, 'write'):
                path.write(payload)
            else:
                Path(path).write_bytes(payload)
        engine = source_module('Scripts/mlx_runtime/engine.py',
                               mx=types.SimpleNamespace(save_safetensors=serialize), save_prompt_cache=serialize)
        generation = engine.Generation.__new__(engine.Generation)
        for name, value in dict(identity='synthetic', spec={}, initial_prefix='', pending=[], ids=[],
                                final_ids=[], key=types.SimpleNamespace(tolist=lambda: [1]), phase='final',
                                thinking_count=0, final_count=1, done=done, cache=[]).items():
            setattr(generation, name, value)
        return engine, generation

    def check_sync(self, done):
        engine, generation = self.generation(done)
        events = []
        replace = os.replace
        engine.os.fsync = lambda fd: events.append('directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file')
        engine.os.replace = lambda source, target, **kwargs: (events.append('publish'), replace(source, target, **kwargs))[-1]
        generation.save(self.directory / 'checkpoint.safetensors')
        self.assertEqual(events, ['file', 'publish', 'directory'])

    def test_py03_completed_checkpoint_syncs_before_and_after_publish(self): self.check_sync(True)

    def test_py03_unfinished_checkpoint_syncs_before_and_after_publish(self): self.check_sync(False)

    def test_py03_failed_file_sync_preserves_previous_checkpoint(self):
        engine, generation = self.generation(True)
        path = self.directory / 'checkpoint.safetensors'
        path.write_bytes(b'previous synthetic checkpoint')
        engine.os.fsync = Mock(side_effect=OSError(errno.ENOSPC, 'synthetic sync failure'))
        with self.assertRaises(OSError): generation.save(path)
        self.assertEqual(path.read_bytes(), b'previous synthetic checkpoint')


class ASRDataSafetyTests(SyntheticFiles):
    def service(self):
        module = source_module('Scripts/qwen_asr_service.py',
            MODEL_STATE_LOCK=threading.Lock(), MODEL_LOCK=threading.Lock(),
            MODELS={}, MODEL_LAST_USED={}, UNLOADING_MODELS=set(), REQUEST_STATES={}, COMPLETED_REQUESTS={},
            AUTO_SELF_CHECKS={}, AUTH_TOKEN='synthetic-data-safety-token',
            MODEL_PATHS={}, MODEL_ROOT=self.directory, SUPERVISED=False,
            _TEMP_LOCK=threading.RLock(), _TEMPORARY_FILES={}, _TEMP_STOPPING=False, _ACL_API=None,
            INFERENCE_SLOTS=threading.BoundedSemaphore(3))
        module.tempfile = types.SimpleNamespace(NamedTemporaryFile=lambda **kwargs:
                                               tempfile.NamedTemporaryFile(dir=self.directory, **kwargs))
        module.os.unlink = self.retire
        module.print = lambda *args, **kwargs: None
        return module

    def handler(self, module):
        handler = object.__new__(module.Handler)
        handler.path = '/transcribe?model=parakeet'
        handler.headers = Message()
        handler.headers['Content-Length'] = '2'
        handler.headers['X-LiveLingo-Request-ID'] = 'synthetic'
        handler.headers[module.TOKEN_HEADER] = module.AUTH_TOKEN
        handler.headers['Host'] = '127.0.0.1:12345'
        handler.rfile = io.BytesIO(b'xx')
        handler.send_json = Mock()
        handler.connection = types.SimpleNamespace(settimeout=Mock())
        handler.server = types.SimpleNamespace(server_address=('127.0.0.1', 12345))
        return handler

    def assert_slots_free(self, module):
        for _ in range(3): self.assertTrue(module.INFERENCE_SLOTS.acquire(blocking=False))
        self.assertFalse(module.INFERENCE_SLOTS.acquire(blocking=False))

    def test_py04_body_deadline_releases_admission_without_inference(self):
        module = self.service()
        handler = self.handler(module)
        now = [0.0]
        module.time = types.SimpleNamespace(monotonic=lambda: now[0])
        def read(size):
            now[0] += 1000.0
            return b'x' * size
        handler.rfile = types.SimpleNamespace(read=read, read1=read)
        module.INFERENCE_WORKER = Mock()
        handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 408)
        module.INFERENCE_WORKER.submit.assert_not_called()
        self.assert_slots_free(module)
        self.assertFalse(module.REQUEST_STATES)
        self.assertTrue(handler.connection.settimeout.called)

    def deadline_future(self, module, running):
        class DeadlineFuture(Future):
            observed_timeout = None
            def result(self, timeout=None):
                self.observed_timeout = timeout
                if timeout is None:
                    self.set_result('synthetic late text')
                    return super().result()
                raise TimeoutError('synthetic deadline')
        future = DeadlineFuture()
        if running:
            future.set_running_or_notify_cancel()
        def submit(*args):
            if running: module.REQUEST_STATES['synthetic']['state'] = 'running'
            return future
        module.INFERENCE_WORKER = types.SimpleNamespace(submit=submit)
        return future

    def test_py04_queued_inference_deadline_cancels_and_releases(self):
        module = self.service()
        future = self.deadline_future(module, running=False)
        handler = self.handler(module)
        handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 504)
        self.assertIsNotNone(future.observed_timeout)
        self.assertTrue(future.cancelled())
        self.assert_slots_free(module)
        self.assertFalse(module.REQUEST_STATES)

    def test_py04_running_deadline_requests_exit_without_false_release(self):
        module = self.service()
        future = self.deadline_future(module, running=True)
        handler = self.handler(module)
        module.request_shutdown = Mock()
        handler.do_POST()
        module.request_shutdown.assert_called_once()
        self.assertIsNotNone(future.observed_timeout)
        self.assertEqual(module.REQUEST_STATES['synthetic']['state'], 'running')
        self.assertNotIn('synthetic', module.COMPLETED_REQUESTS)
        self.assertEqual(len(list(self.directory.glob('*.wav'))), 1)
        self.assertTrue(module.INFERENCE_SLOTS.acquire(blocking=False))
        self.assertTrue(module.INFERENCE_SLOTS.acquire(blocking=False))
        self.assertFalse(module.INFERENCE_SLOTS.acquire(blocking=False))
        future.set_result('synthetic finished text')
        self.assertFalse(module.REQUEST_STATES)
        self.assertEqual(len(list(self.directory.glob('*.wav'))), 0)

    def test_py04_inference_exception_is_not_misreported_as_upload_timeout(self):
        module = self.service()
        future = Future()
        future.set_exception(TimeoutError('synthetic inference failure'))
        module.INFERENCE_WORKER = Mock()
        module.INFERENCE_WORKER.submit.return_value = future
        module.request_shutdown = Mock()
        handler = self.handler(module)
        handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 500)
        module.request_shutdown.assert_not_called()
        self.assert_slots_free(module)

    def test_py06_partial_raw_write_does_not_leave_unmanaged_temp(self):
        module = self.service()
        handler = self.handler(module)
        def temporary(**kwargs):
            handle = tempfile.NamedTemporaryFile(dir=self.directory, **kwargs)
            write = handle.write
            def fail(data):
                write(data[:1]); handle.flush()
                raise OSError(errno.ENOSPC, 'synthetic full disk')
            handle.write = fail
            return handle
        module.tempfile.NamedTemporaryFile = temporary
        module.INFERENCE_WORKER = Mock()
        handler.do_POST()
        self.assertEqual(handler.send_json.call_args.args[0], 500)
        self.assertEqual(list(self.directory.glob('*.wav')), [])
        module.INFERENCE_WORKER.submit.assert_not_called()

    def test_py06_partial_enhancement_write_does_not_leave_unmanaged_temp(self):
        module = self.service()
        audio, mono, band = MagicMock(), MagicMock(), MagicMock()
        audio.shape, mono.size, band.size = (1600, 1), 1600, 1600
        module.np = types.SimpleNamespace(mean=Mock(return_value=mono), float32=float, float64=float,
            sqrt=Mock(), square=Mock(), percentile=lambda *args: .05, log10=math.log10,
            clip=lambda value, low, high: min(high, max(low, value)), max=lambda value: .1, abs=lambda value: value)
        def write(path, *args, **kwargs):
            Path(path).write_bytes(b'x')
            raise OSError(errno.ENOSPC, 'synthetic enhancement write failure')
        module.sf = types.SimpleNamespace(read=lambda *args, **kwargs: (audio, 16000), write=write)
        module.butter = lambda *args, **kwargs: []
        module.sosfiltfilt = lambda *args, **kwargs: band
        with self.assertRaises(OSError): module.speech_band_enhance('synthetic.wav')
        self.assertEqual(list(self.directory.glob('*.wav')), [])

    def test_c08_watchdog_exit_does_not_wait_for_full_stdout(self):
        module = self.service()
        exit_called, release = threading.Event(), threading.Event()
        module.print = lambda *args, **kwargs: release.wait(1)
        module.os._exit = lambda code: exit_called.set()
        thread = threading.Thread(target=module.request_shutdown, args=(object(), 'synthetic parent EOF'))
        thread.start()
        try:
            self.assertTrue(exit_called.wait(.1), 'Exit must not depend on stdout becoming writable')
        finally:
            release.set()
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())


class RecoveryDataSafetyTests(SyntheticFiles):
    def recovery(self):
        module = source_module('Scripts/recover-orphan-recordings.py')
        module.os.unlink = self.retire
        return module

    def recording(self, module, frames=600):
        fmt = struct.pack('<HHIIHH', 1, 1, 48000, 96000, 2, 16)
        path = self.directory / 'scan' / 'LiveLingo-Live-SYNTHETIC' / 'recording.wav'
        path.parent.mkdir(parents=True)
        payload = b'\x03\x00' * frames
        path.write_bytes(b'RIFF' + struct.pack('<I', 36) + b'WAVEfmt ' + struct.pack('<I', 16)
                         + fmt + b'data' + struct.pack('<I', 0) + payload)
        return path

    def test_py07_abrupt_exit_never_leaves_partial_final_name(self):
        module = self.recovery()
        source = self.recording(module, frames=module.COPY_BLOCK // 2 + 1)
        layout = module.inspect(source)
        target = self.directory / 'recovered.wav'
        original_fdopen = module.os.fdopen
        class InterruptedOutput:
            def __init__(self, handle): self.handle, self.writes = handle, 0
            def __enter__(self): return self
            def __exit__(self, *args): self.handle.close()
            def __getattr__(self, name): return getattr(self.handle, name)
            def write(self, data):
                self.writes += 1
                if self.writes == 3: os._exit(73)
                value = self.handle.write(data)
                self.handle.flush()
                return value
        def opened(descriptor, mode='r', *args, **kwargs):
            handle = original_fdopen(descriptor, mode, *args, **kwargs)
            return InterruptedOutput(handle) if mode in ('wb', 'xb') else handle
        pid = os.fork()
        if pid == 0:
            try:
                with patch.object(module.os, 'fdopen', opened): module.export_recording(source, layout, target)
            except BaseException:
                os._exit(75)
            os._exit(74)
        _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 73)
        self.assertFalse(target.exists(), 'A crash must only leave a pending artifact')
        self.assertEqual(len(list(self.directory.glob('*.pending'))), 1)
        self.assertEqual(module.inspect(source).usable, layout.usable)

    def test_py07_export_syncs_file_and_directory_around_publication(self):
        module = self.recovery()
        source = self.recording(module)
        events = []
        link = os.link
        module.os.fsync = lambda fd: events.append('directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file')
        module.os.link = lambda pending, final, **kwargs: (events.append('publish'), link(pending, final, **kwargs))[-1]
        module.export_recording(source, module.inspect(source), self.directory / 'recovered.wav')
        self.assertEqual(events, ['file', 'publish', 'directory'])

    def test_py07_failed_file_sync_never_publishes_final_name(self):
        module = self.recovery()
        source = self.recording(module)
        before = source.read_bytes()
        target = self.directory / 'recovered.wav'
        module.os.fsync = Mock(side_effect=OSError(errno.ENOSPC, 'synthetic sync failure'))
        with self.assertRaises(OSError): module.export_recording(source, module.inspect(source), target)
        self.assertFalse(target.exists())
        self.assertEqual(source.read_bytes(), before)

    def test_py10_scan_does_not_follow_directory_or_file_symlinks(self):
        module = self.recovery()
        source = self.recording(module)
        scan = self.directory / 'selected'
        scan.mkdir()
        (scan / 'LiveLingo-Live-DIRECTORY').symlink_to(source.parent, target_is_directory=True)
        directory = scan / 'LiveLingo-Live-FILE'
        directory.mkdir()
        (directory / 'recording.wav').symlink_to(source)
        self.assertEqual(list(module.candidates([scan])), [])

    def test_py10_inspection_rejects_a_symlink_source(self):
        module = self.recovery()
        source = self.recording(module)
        link = self.directory / 'linked.wav'
        link.symlink_to(source)
        with self.assertRaises((module.NotRecoverable, OSError)): module.inspect(link)


if __name__ == '__main__': unittest.main()
