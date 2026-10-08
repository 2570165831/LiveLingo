"""Focused N07-N11 synthetic regressions; production imports/startup stay excluded.

Run with TMPDIR set to the authorized work directory. Keep fixtures there for
review rather than writing test artifacts into the source checkout.
"""
import ast
from concurrent.futures import Future
import errno
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

if __package__:
    from . import test_data_safety as base
else:
    import test_data_safety as base


class ReauditFiles(base.SyntheticFiles):
    def setUp(self):
        # The runner supplies tempfile.tempdir without consulting environment.
        self.directory = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-'))
        self.addCleanup(self.archive)

    def archive(self):
        destination = self.directory.parent / 'python-reaudit-preserved'
        destination.mkdir(exist_ok=True)
        self.directory.rename(destination / self.directory.name)


class ASRReauditTests(ReauditFiles):
    service = base.ASRDataSafetyTests.service
    handler = base.ASRDataSafetyTests.handler
    assert_slots_free = base.ASRDataSafetyTests.assert_slots_free

    def blocked_log(self, prefix, language=False, http_log=False):
        module = self.service()
        module.INFERENCE_TIMEOUT_SECONDS = .02
        handler = self.handler(module)
        entered, release = threading.Event(), threading.Event()

        def blocked_print(message, *args, **kwargs):
            if message.startswith(prefix):
                entered.set()
                release.wait()

        module.print = blocked_print
        future = Future()
        if language:
            handler.path = '/transcribe?model=1.7b&language=auto'
            future.set_result(dict(text='synthetic text', detected_label='French',
                                   language_probability=.99, english_probability=.01,
                                   decode='synthetic'))
        else:
            future.set_result('synthetic text')
        module.INFERENCE_WORKER = Mock()
        module.INFERENCE_WORKER.submit.return_value = future
        module.request_shutdown = Mock()
        if http_log:
            handler.log_date_time_string = lambda: 'synthetic date'
            def response_log(*args):
                handler.log_message('status %s', 200)
                # Privacy disables raw HTTP access logs. A fixed response
                # diagnostic still exercises the real nonblocking writer.
                module.RequestLog.emit('[synthetic response status=200]')
            handler.send_json.side_effect = response_log
        logger = module.RequestLog
        log_thread = logger.start()
        thread = threading.Thread(target=handler.do_POST, daemon=True)
        thread.start()
        try:
            self.assertTrue(entered.wait(1), 'The synthetic log gate must actually be entered')
            thread.join(timeout=.2)
            self.assertFalse(thread.is_alive(), 'A blocked diagnostic must not retain the handler')
            module.INFERENCE_WORKER.submit.assert_called_once()
            self.assertEqual(handler.send_json.call_args.args[0], 200)
            module.request_shutdown.assert_not_called()
            self.assertFalse(module.REQUEST_STATES)
            self.assert_slots_free(module)
            self.assertEqual(list(self.directory.glob('*.wav')), [])
        finally:
            release.set()
            thread.join(timeout=2)
            logger.messages.put(None)
            log_thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        if log_thread is not None:
            self.assertFalse(log_thread.is_alive())

    def test_n07_request_log_cannot_delay_submission_or_release(self):
        self.blocked_log('ASR request ')

    def test_n07_completion_log_cannot_retain_input_or_slot(self):
        self.blocked_log('ASR completed ')

    def test_n07_language_log_cannot_retain_input_or_slot(self):
        self.blocked_log('ASR language ', language=True)

    def test_n07_http_log_cannot_retain_input_or_slot(self):
        self.blocked_log('[', http_log=True)

    def test_n07_saturated_logger_drops_diagnostics_without_retaining_request(self):
        module = self.service()
        logger = module.RequestLog
        entered, release = threading.Event(), threading.Event()
        module.print = lambda *args, **kwargs: (entered.set(), release.wait())
        log_thread = logger.start()
        self.assertIs(logger.start(), log_thread, 'Logging must reuse one writer')
        logger.emit('synthetic blocked diagnostic')
        handler = self.handler(module)
        future = Future()
        future.set_result('synthetic text')
        module.INFERENCE_WORKER = Mock()
        module.INFERENCE_WORKER.submit.return_value = future
        thread = threading.Thread(target=handler.do_POST, daemon=True)
        try:
            self.assertTrue(entered.wait(1))
            for _ in range(logger.messages.maxsize * 2):
                logger.emit('synthetic excess diagnostic')
            self.assertTrue(logger.messages.full())
            thread.start()
            thread.join(timeout=.2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(handler.send_json.call_args.args[0], 200)
            self.assertFalse(module.REQUEST_STATES)
            self.assert_slots_free(module)
            self.assertEqual(list(self.directory.glob('*.wav')), [])
        finally:
            release.set()
            if thread.ident is not None:
                thread.join(timeout=2)
            logger.messages.put(None)
            log_thread.join(timeout=2)
        self.assertFalse(log_thread.is_alive())

    def completed_race(self, error=None, before_done=False):
        module = self.service()

        class CompleteInRace(Future):
            first_result = True
            complete_on_done = True

            def result(self, timeout=None):
                if self.first_result:
                    self.first_result = False
                    raise TimeoutError('synthetic expired wait')
                return super().result(timeout)

            def done(self):
                observed = super().done()
                if not observed and self.complete_on_done:
                    self.complete_on_done = False
                    if error is None:
                        self.set_result('synthetic completed text')
                    else:
                        self.set_exception(error)
                return super().done() if before_done else observed

        future = CompleteInRace()
        future.set_running_or_notify_cancel()
        module.INFERENCE_WORKER = Mock()
        module.INFERENCE_WORKER.submit.return_value = future
        module.request_shutdown = Mock()
        handler = self.handler(module)
        handler.do_POST()
        module.request_shutdown.assert_not_called()
        self.assertEqual(handler.send_json.call_count, 1)
        status, payload = handler.send_json.call_args.args
        self.assertEqual(status, 200 if error is None else 500)
        # Keep the inference/wait distinction while honoring privacy's fixed
        # error classifications; never expect dependency exception text.
        expected_error = 'timeout' if isinstance(error, TimeoutError) else 'inference_failed'
        self.assertEqual(payload.get('text') if error is None else payload.get('error'),
                         'synthetic completed text' if error is None else expected_error)
        if error is not None:
            self.assertNotIn(str(error), payload.get('error', ''))
        self.assertFalse(module.REQUEST_STATES)
        self.assert_slots_free(module)
        self.assertEqual(list(self.directory.glob('*.wav')), [])

    def test_n08_completion_between_done_and_cancel_returns_text(self):
        self.completed_race()

    def test_n08_completion_before_first_done_returns_text(self):
        self.completed_race(before_done=True)

    def test_n08_completion_error_does_not_retire_other_requests(self):
        self.completed_race(RuntimeError('synthetic inference error'))

    def test_n08_inference_timeout_error_remains_an_inference_error(self):
        self.completed_race(TimeoutError('synthetic inference timeout'))


class WorkerReauditTests(ReauditFiles):
    def run_worker(self, save_error, periodic=False, step_error=False):
        # Reuse the original synthetic harness, altering only its fake serializer
        # exception (and, for the negative control, its fake step). Production
        # function/class bodies still come from source_module without rewriting.
        path = base.ROOT / 'Scripts/test_data_safety.py'
        tree = ast.parse(path.read_text(), filename=str(path))
        cls = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                   and node.name == 'WorkerDataSafetyTests')
        function = next(node for node in cls.body if isinstance(node, ast.FunctionDef)
                        and node.name == 'run_worker')

        class SyntheticError(ast.NodeTransformer):
            def visit_Raise(self, node):
                if (isinstance(node.exc, ast.Call) and isinstance(node.exc.func, ast.Name)
                        and node.exc.func.id == 'OSError'):
                    node.exc = ast.Call(func=ast.Name(id='save_error_factory', ctx=ast.Load()),
                                        args=[], keywords=[])
                return node

            def visit_FunctionDef(self, node):
                node = self.generic_visit(node)
                if node.name == 'step' and step_error:
                    node.body = [ast.Raise(exc=ast.Call(
                        func=ast.Name(id='RuntimeError', ctx=ast.Load()),
                        args=[ast.Constant('synthetic broken step')], keywords=[]), cause=None)]
                return node

        function = SyntheticError().visit(function)
        scope = dict(vars(base), save_error_factory=save_error)
        exec(compile(ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[])),
                     str(path), 'exec'), scope)
        return scope['run_worker'](self, 'synthetic-A', fail_save=True, periodic=periodic)

    def check_retry(self, error, periodic=False):
        events, saves, steps, checkpoint = self.run_worker(error, periodic)
        error_index = next(index for index, item in enumerate(events) if item['event'] == 'error')
        snapshots = [item['wire'] for item in events[:error_index] if item['event'] == 'snapshot']
        self.assertEqual(snapshots[-1], 'synthetic-A|tail', 'The latest valid text precedes the error')
        self.assertTrue(events[error_index]['recoverable'])
        self.assertEqual(next(item for item in events if item['event'] == 'checkpoint')['state'], 'saved')
        self.assertEqual(checkpoint.read_text(), 'synthetic-A|tail')
        self.assertEqual(saves, ['synthetic-A|tail', 'synthetic-A|tail'])
        self.assertEqual(len(steps), 1, 'Checkpoint retry must not rerun inference')

    def test_n09_completed_runtimeerror_save_keeps_latest_retryable_text(self):
        self.check_retry(lambda: RuntimeError('synthetic serializer failure'))

    def test_n09_periodic_runtimeerror_save_keeps_latest_retryable_text(self):
        self.check_retry(lambda: RuntimeError('synthetic serializer failure'), periodic=True)

    def test_n09_serializer_typeerror_is_a_retryable_save_failure(self):
        self.check_retry(lambda: TypeError('synthetic serializer failure'))

    def test_n09_serializer_valueerror_is_a_retryable_save_failure(self):
        self.check_retry(lambda: ValueError('synthetic serializer failure'))

    def test_n09_step_failure_does_not_cache_an_invalid_generation(self):
        events, saves, _, checkpoint = self.run_worker(lambda: RuntimeError('synthetic save'), step_error=True)
        self.assertEqual(next(item for item in events if item['event'] == 'checkpoint')['state'], 'absent')
        self.assertEqual([item['wire'] for item in events if item['event'] == 'snapshot'], ['synthetic-A'])
        self.assertFalse(checkpoint.exists())
        self.assertEqual(saves, [])

    def run_control_worker(self, save_error, *, before_step=False, shutdown=False,
                           control_id=None, invalid_control=False, step_failure=False,
                           existing_checkpoint=False):
        events, saves, steps = [], [], []
        state = Path(tempfile.mkdtemp(prefix='state-', dir=self.directory))
        identity = base.hashlib.sha256(b'synthetic').hexdigest()
        checkpoint = state / (identity + '.safetensors')
        if existing_checkpoint:
            checkpoint.write_text('synthetic-A')
        failed_saves = 0 if step_failure else 1 if before_step else 2

        class Generation:
            def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', **kwargs):
                self.identity = identity
                self.wire = self.text = prefix
                self.thinking_count = self.final_count = 0
                self.done = False

            def step(self):
                steps.append(self.wire)
                self.wire += '|invalid-step-tail' if step_failure else '|tail'
                self.text = self.wire
                if step_failure:
                    raise OSError(errno.EIO, 'synthetic broken step')
                self.done = True
                return 'done'

            def save(self, path):
                saves.append(self.wire)
                if len(saves) <= failed_saves:
                    raise save_error()
                Path(path).write_text(self.wire)

            @classmethod
            def restore(cls, engine, path, expected_identity):
                return cls(engine, 'synthetic', prefix=Path(path).read_text())

        engine = base.types.ModuleType('engine')
        engine.Engine = lambda *args: object()
        engine.Generation = Generation
        schemas = base.types.ModuleType('schemas')
        schemas.note_schema = schemas.review_schema = lambda data: {}
        worker = base.source_module('Scripts/mlx_runtime/worker.py', discover_mlx=lambda: None)
        worker.protocol = base.io.StringIO()
        worker.os.unlink = self.retire
        controls = [dict(op='shutdown' if shutdown else 'checkpoint', id='request',
                         controlID=control_id)]
        if not shutdown:
            if invalid_control:
                controls.append(dict(op='synthetic-invalid', id='request', controlID='invalid-control'))
            controls.extend([dict(op='checkpoint', id='request', controlID='retry-control'),
                             dict(op='shutdown', controlID='finish-control')])
        command_queue = None
        controls_sent = before_step

        def reader(input_fd, stop_fd, stopping, destination):
            nonlocal command_queue
            command_queue = destination
            destination.put(dict(op='generate', id='request', prompt='synthetic',
                                 prefix='synthetic-A', purpose='note', input='{}'))
            if before_step:
                for command in controls:
                    destination.put(command)

        def send(kind, request_id=None, **fields):
            nonlocal controls_sent
            events.append(dict(event=kind, id=request_id, **fields))
            if kind == 'error' and not controls_sent:
                controls_sent = True
                for command in controls:
                    command_queue.put(command)

        worker.read_commands = reader
        worker.send = send
        with patch.dict(sys.modules, engine=engine, schemas=schemas), \
                patch.object(sys, 'argv', ['worker', '--model', 'synthetic',
                                          '--state-directory', str(state)]), \
                base.contextlib.redirect_stderr(base.io.StringIO()):
            worker.main()
        return events, saves, steps, checkpoint

    def check_control_save_retry(self, *, before_step=False, control_id=None,
                                 invalid_control=False):
        for error_type in (TypeError, ValueError, RuntimeError, OSError):
            with self.subTest(error=error_type.__name__, controlID=control_id):
                factory = lambda: error_type('synthetic control serializer failure')
                events, saves, steps, checkpoint = self.run_control_worker(
                    factory, before_step=before_step, control_id=control_id,
                    invalid_control=invalid_control)
                errors = [item for item in events if item['event'] == 'error']
                save_errors = [item for item in errors if item.get('controlID') != 'invalid-control']
                self.assertEqual(len(save_errors), 1 if before_step else 2)
                self.assertTrue(all(item['recoverable'] for item in save_errors),
                                'A serializer failure retains valid progress regardless of exception type')
                self.assertEqual(save_errors[-1]['controlID'], control_id)
                if invalid_control:
                    invalid = next(item for item in errors if item.get('controlID') == 'invalid-control')
                    self.assertFalse(invalid['recoverable'], 'Save-stage classification must not leak to validation')
                retry = next(item for item in events if item.get('controlID') == 'retry-control')
                self.assertEqual((retry['event'], retry['state']), ('checkpoint', 'saved'))
                expected_wire = 'synthetic-A' if before_step else 'synthetic-A|tail'
                self.assertEqual(checkpoint.read_text(), expected_wire)
                self.assertEqual(saves, [expected_wire] * 3)
                self.assertEqual(steps, [] if before_step else ['synthetic-A'],
                                 'Control retries must not rerun inference')
                self.assertEqual(events[-1]['state'], 'ready_to_exit')

    def test_p2_checkpoint_save_failure_without_control_id_is_retryable(self):
        self.check_control_save_retry()

    def test_p2_checkpoint_save_failure_with_control_id_is_retryable(self):
        self.check_control_save_retry(control_id='checkpoint-control')

    def test_p2_active_checkpoint_save_failure_is_retryable_without_leaking_to_validation(self):
        self.check_control_save_retry(before_step=True, control_id='active-checkpoint', invalid_control=True)

    def test_p2_paused_checkpoint_save_failure_is_retryable_without_leaking_to_validation(self):
        self.check_control_save_retry(control_id='paused-checkpoint', invalid_control=True)

    def test_p2_shutdown_save_failure_is_retryable_with_and_without_control_id(self):
        for control_id in (None, 'shutdown-control'):
            for error_type in (TypeError, ValueError, RuntimeError, OSError):
                with self.subTest(error=error_type.__name__, controlID=control_id):
                    events, saves, steps, checkpoint = self.run_control_worker(
                        lambda: error_type('synthetic shutdown serializer failure'),
                        shutdown=True, control_id=control_id)
                    receipt = next(item for item in events if item['event'] == 'shutdown')
                    self.assertEqual(receipt['state'], 'checkpoint_failed')
                    self.assertEqual(receipt['failedRequests'], ['request'])
                    self.assertEqual(receipt['controlID'], control_id)
                    self.assertTrue(receipt.get('recoverable'), 'Shutdown save failure keeps valid progress retryable')
                    self.assertFalse(checkpoint.exists())
                    self.assertEqual(saves, ['synthetic-A|tail'] * 2)
                    self.assertEqual(steps, ['synthetic-A'])

    def test_p3_oserror_step_mutation_is_not_cached_or_saved(self):
        for control_id in (None, 'step-checkpoint'):
            for existing_checkpoint in (False, True):
                with self.subTest(controlID=control_id, existing_checkpoint=existing_checkpoint):
                    events, saves, steps, checkpoint = self.run_control_worker(
                        lambda: RuntimeError('synthetic unused serializer'), step_failure=True,
                        control_id=control_id, existing_checkpoint=existing_checkpoint)
                    receipts = [item for item in events if item['event'] == 'checkpoint']
                    self.assertEqual(len(receipts), 2)
                    self.assertTrue(all(item['state'] == 'absent' for item in receipts))
                    self.assertEqual(receipts[0]['controlID'], control_id)
                    self.assertEqual([item['wire'] for item in events if item['event'] == 'snapshot'],
                                     ['synthetic-A'], 'No snapshot may publish the invalid tail')
                    self.assertEqual(saves, [], 'Neither checkpoint nor shutdown may save the invalid generation')
                    self.assertEqual(steps, ['synthetic-A'])
                    self.assertFalse(any(item['event'] == 'done' for item in events))
                    self.assertEqual(checkpoint.exists(), existing_checkpoint)
                    if existing_checkpoint:
                        self.assertEqual(checkpoint.read_text(), 'synthetic-A')
                    self.assertEqual(events[-1]['state'], 'ready_to_exit')


class RecoveryReauditTests(ReauditFiles):
    recovery = base.RecoveryDataSafetyTests.recovery
    recording = base.RecoveryDataSafetyTests.recording

    def pending_bytes(self, name, directory_fd):
        # os.link receives a leaf name relative to the held output directory.
        # Read that exact inode, without resolving a pathname through cwd.
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        with os.fdopen(descriptor, 'rb') as handle:
            return handle.read()

    def fail_exclusive_rename(self, module, code):
        def fail(source_fd, source_name, target_fd, target_name, flags):
            self.assertTrue(stat.S_ISDIR(os.fstat(source_fd).st_mode))
            self.assertTrue(stat.S_ISDIR(os.fstat(target_fd).st_mode))
            self.assertFalse(os.path.isabs(source_name))
            self.assertFalse(os.path.isabs(target_name))
            self.assertEqual(flags, 0x00000004)  # RENAME_EXCL.
            base.ctypes.set_errno(code)
            return -1

        syscall = Mock(side_effect=fail)
        ctypes_proxy = base.types.SimpleNamespace(**vars(base.ctypes))
        ctypes_proxy.CDLL = lambda *args, **kwargs: base.types.SimpleNamespace(renameatx_np=syscall)
        # The production helper imports ctypes locally. Replace only this
        # subject's importer, leaving the real private-file/ACL helpers intact.
        subject_builtins = module.__dict__['__builtins__']
        original_import = subject_builtins['__import__']
        def fault_import(name, globals=None, locals=None, fromlist=(), level=0):
            if name == 'ctypes' and level == 0:
                return ctypes_proxy
            return original_import(name, globals, locals, fromlist, level)
        subject_builtins['__import__'] = fault_import
        module.rename_no_replace = Mock(wraps=module.rename_no_replace)
        return syscall

    def fallback_export(self, link_errno, occupied=False, directory_failure=False):
        module = self.recovery()
        source = self.recording(module)
        original = source.read_bytes()
        layout = module.inspect(source)
        target = self.directory / 'recovered.wav'
        expected = module.header_bytes(layout.fmt_chunk, layout.usable) + original[layout.data_offset:]
        events = []
        real_sync = os.fsync

        def fail_link(pending, final, **kwargs):
            # Production now passes fd-relative names; inspect the same owned
            # synthetic pending without changing the complete-byte assertion.
            pending = target.parent / pending
            self.assertFalse(target.exists(), 'Nothing occupies final before atomic publication')
            self.assertEqual(self.pending_bytes(pending, kwargs['src_dir_fd']), expected)
            events.append('publish')
            if occupied:
                target.write_bytes(b'competing complete output')
            raise OSError(link_errno, 'synthetic hardlink unavailable')

        def sync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                events.append('directory')
                self.assertEqual(target.read_bytes(), expected)
                if directory_failure:
                    raise OSError(errno.EIO, 'synthetic directory sync failure')
            else:
                events.append('file')
                self.assertFalse(target.exists(), 'File sync happens while only pending exists')
            real_sync(fd)

        module.os.link = Mock(side_effect=fail_link)
        module.os.fsync = sync
        if occupied or directory_failure:
            with self.assertRaises(OSError) as caught:
                module.export_recording(source, layout, target)
            self.assertEqual(caught.exception.errno, errno.EEXIST if occupied else errno.EIO)
            if occupied:
                self.assertEqual(target.read_bytes(), b'competing complete output')
            else:
                self.assertFalse(target.exists())
            incomplete = list(self.directory.glob('recovered.wav.*.incomplete'))
            self.assertEqual(len(incomplete), 1)
            self.assertEqual(incomplete[0].read_bytes(), expected)
        else:
            self.assertEqual(module.export_recording(source, layout, target), layout.usable)
            self.assertEqual(target.read_bytes(), expected)
            self.assertEqual(events, ['file', 'publish', 'directory'])
            self.assertEqual(list(self.directory.glob('*.pending')), [])
            self.assertEqual(list(self.directory.glob('*.incomplete')), [])
        self.assertEqual(source.read_bytes(), original)
        module.os.link.assert_called_once()

    def test_n10_enotsup_uses_atomic_complete_publication(self):
        self.fallback_export(errno.ENOTSUP)

    def test_n10_exdev_uses_atomic_complete_publication(self):
        self.fallback_export(errno.EXDEV)

    def test_n10_fallback_never_overwrites_a_competing_final(self):
        self.fallback_export(errno.ENOTSUP, occupied=True)

    def test_n10_failed_directory_sync_preserves_complete_incomplete(self):
        self.fallback_export(errno.ENOTSUP, directory_failure=True)

    def test_n10_exclusive_rename_failure_never_copies_into_final(self):
        source = self.recording(self.recovery())
        for code in (errno.ENOTSUP, errno.EXDEV):
            with self.subTest(rename_errno=code):
                module = self.recovery()
                before = source.read_bytes()
                layout = module.inspect(source)
                target = self.directory / f'rename-failed-{code}.wav'
                expected = module.header_bytes(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
                module.os.link = Mock(side_effect=OSError(errno.ENOTSUP, 'synthetic unavailable hardlink'))
                failed_rename = self.fail_exclusive_rename(module, code)
                with self.assertRaises(OSError) as caught:
                    module.export_recording(source, layout, target)
                self.assertEqual(caught.exception.errno, code)
                self.assertFalse(target.exists())
                incomplete = list(self.directory.glob(target.name + '.*.incomplete'))
                self.assertEqual(len(incomplete), 1)
                self.assertEqual(incomplete[0].read_bytes(), expected)
                self.assertEqual(source.read_bytes(), before)
                module.rename_no_replace.assert_called_once()
                failed_rename.assert_called_once()

    def swap_directory(self, source):
        outside = self.directory / 'other-synthetic-root'
        outside.mkdir()
        moved = outside / source.parent.name
        source.parent.rename(moved)
        source.parent.symlink_to(moved, target_is_directory=True)
        return moved / source.name

    def test_n11_scan_to_inspect_directory_symlink_swap_is_rejected(self):
        module = self.recovery()
        source = self.recording(module)
        approved = list(module.candidates([source.parent.parent]))[0]
        moved = self.swap_directory(approved)
        before = moved.read_bytes()
        with self.assertRaises((OSError, module.SourceChanged, module.NotRecoverable)):
            module.inspect(approved)
        self.assertEqual(moved.read_bytes(), before)

    def test_n11_inspect_to_export_directory_symlink_swap_is_rejected(self):
        module = self.recovery()
        source = self.recording(module)
        layout = module.inspect(source)
        moved = self.swap_directory(source)
        before = moved.read_bytes()
        target = self.directory / 'recovered.wav'
        with self.assertRaises((OSError, module.SourceChanged)):
            module.export_recording(source, layout, target)
        self.assertFalse(target.exists())
        self.assertEqual(moved.read_bytes(), before)

    def test_n11_directory_symlink_swap_during_copy_preserves_complete_pending(self):
        module = self.recovery()
        source = self.recording(module)
        layout = module.inspect(source)
        before = source.read_bytes()
        target = self.directory / 'recovered.wav'
        make_header = module.header_bytes
        expected = make_header(layout.fmt_chunk, layout.usable) + before[layout.data_offset:]
        moved = []

        def swap_before_copy(*args):
            moved.append(self.swap_directory(source))
            return make_header(*args)

        module.header_bytes = swap_before_copy
        with self.assertRaises(module.SourceChanged):
            module.export_recording(source, layout, target)
        self.assertFalse(target.exists())
        incomplete = list(self.directory.glob('recovered.wav.*.incomplete'))
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(incomplete[0].read_bytes(), expected)
        self.assertEqual(moved[0].read_bytes(), before)

    def test_n11_swap_between_directory_and_file_open_never_opens_redirect(self):
        module = self.recovery()
        source = self.recording(module)
        outside = self.directory / 'other-synthetic-root'
        outside.mkdir()
        redirected = outside / 'recording.wav'
        redirected.write_bytes(source.read_bytes().replace(b'\x03\x00', b'\x09\x00'))
        redirect_identity = (redirected.stat().st_dev, redirected.stat().st_ino)
        moved = self.directory / 'original-directory'
        real_open = os.open
        swapped = False
        redirects_opened = []

        def raced_open(path, flags, *args, **kwargs):
            nonlocal swapped
            if Path(path).name == 'recording.wav' and not swapped:
                swapped = True
                source.parent.rename(moved)
                source.parent.symlink_to(outside, target_is_directory=True)
            fd = real_open(path, flags, *args, **kwargs)
            state = os.fstat(fd)
            if (state.st_dev, state.st_ino) == redirect_identity:
                redirects_opened.append(fd)
            return fd

        module.os.open = raced_open
        with self.assertRaises((OSError, module.SourceChanged, module.NotRecoverable)):
            module.inspect(source)
        self.assertTrue(swapped, 'The test must hit the check/open race')
        self.assertEqual(redirects_opened, [], 'An anchored directory handle must not follow the replacement')


if __name__ == '__main__':
    unittest.main(verbosity=2)
