"""CPU-only ASR scheduling tests; no model imports, listener or process startup.

Repeat the logical before/after probe with --measure --baseline SOURCE. SOURCE
must be the saved pre-change service. Virtual seconds count scheduler work,
not elapsed wall time, OS wakeups or energy consumption.
"""
import argparse
import ast
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import contextmanager, nullcontext
import ctypes
import errno
import gc
import hmac
from http.server import BaseHTTPRequestHandler
import ipaddress
import io
import json
import os
from pathlib import Path
import queue
import re
import selectors
import socket
import socketserver
import stat
import sys
import tempfile
import threading
import time
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlparse
import uuid


SOURCE = Path(__file__).with_name('qwen_asr_service.py')


def load_subject(path=SOURCE):
    """Execute production definitions with synthetic state and environment.

    This follows the existing data-safety AST loader's dependency boundary.
    Imports/startup assignments never run, and os.environ is never read.
    """
    tree = ast.parse(Path(path).read_text())
    subject = ModuleType('asr_scheduling_subject')
    subject.__dict__.update(globals())
    subject.os = SimpleNamespace(**{name: getattr(os, name) for name in dir(os)
                                   if name != 'environ'}, environ={})
    for node in tree.body:
        if isinstance(node, ast.Assign):
            try:
                value = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                continue
            for target in node.targets:
                if isinstance(target, ast.Name):
                    subject.__dict__[target.id] = value
    subject.__dict__.update(
        MODEL_STATE_LOCK=threading.Lock(), MODEL_LOCK=threading.Lock(),
        MODELS={}, MODEL_LAST_USED={}, UNLOADING_MODELS=set(),
        REQUEST_STATES={}, COMPLETED_REQUESTS={}, AUTO_SELF_CHECKS={},
        MODEL_PATHS={}, MODEL_ROOT=Path('synthetic-models'),
        INFERENCE_SLOTS=threading.BoundedSemaphore(3),
        MAX_AUDIO_BYTES=64 * 1024 * 1024,
        _TEMP_LOCK=threading.RLock(), _TEMPORARY_FILES={}, _TEMP_STOPPING=False,
        measure=lambda stage: nullcontext())
    nodes = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef))]
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), subject.__dict__)
    subject.RequestLog.emit = Mock()
    return subject


class RecordingCondition:
    def __init__(self, lock):
        self.inner = threading.Condition(lock)
        self.waits = []
        self.entered = threading.Event()

    def __enter__(self): return self.inner.__enter__()
    def __exit__(self, *args): return self.inner.__exit__(*args)
    def notify_all(self): return self.inner.notify_all()

    def wait(self, timeout=None):
        self.waits.append(timeout)
        self.entered.set()
        return self.inner.wait(timeout)


class UnboundHTTPBase:
    """Anonymous request fd only; no bind, accept, HTTP request or connection."""
    def __init__(self, *args):
        self.request_read, self.request_write = socket.socketpair()
        self.handled = threading.Event()
        self.actions = 0

    def fileno(self): return self.request_read.fileno()
    def service_actions(self): self.actions += 1
    def _handle_request_noblock(self):
        self.request_read.recv(1)
        self.handled.set()

    def server_close(self):
        self.request_read.close()
        self.request_write.close()


class SchedulingTests(unittest.TestCase):
    def setUp(self):
        self.service = load_subject()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='asr-scheduling-fake')
        self.addCleanup(self.executor.shutdown, wait=True)
        self.service.INFERENCE_WORKER = self.executor
        fake_core = SimpleNamespace(clear_cache=Mock())
        self.enterContext(patch.dict(sys.modules, {'mlx': SimpleNamespace(core=fake_core),
                                                 'mlx.core': fake_core}))
        self.core = fake_core

    def settle(self, predicate):
        deadline = time.monotonic() + 2
        while not predicate():
            self.assertLess(time.monotonic(), deadline, 'Synthetic scheduler did not settle')
            threading.Event().wait(.002)

    def maintenance(self):
        controller = self.service.start_idle_maintenance()
        self.addCleanup(lambda: (controller.set(), controller.thread.join(timeout=2)))
        return controller

    def recorded_maintenance(self):
        controller = self.service.IdleMaintenance()
        controller.condition = RecordingCondition(self.service.MODEL_STATE_LOCK)
        self.service.IDLE_MAINTENANCE = controller
        controller.thread = threading.Thread(target=controller.run, daemon=True)
        controller.thread.start()
        self.addCleanup(lambda: (controller.set(), controller.thread.join(timeout=2)))
        self.assertTrue(controller.condition.entered.wait(2))
        return controller

    def test_cold_maintenance_blocks_once_and_stop_wakes_it(self):
        controller = self.recorded_maintenance()
        threading.Event().wait(.06)
        self.assertEqual(controller.condition.waits, [None])
        controller.set()
        controller.thread.join(timeout=1)
        self.assertFalse(controller.thread.is_alive())
        self.core.clear_cache.assert_not_called()

    def test_deadline_is_earliest_model_and_busy_owners_block_maintenance(self):
        service = self.service
        service.MODELS.update(early=object(), late=object(), unknown=object())
        service.MODEL_LAST_USED.update(early=10, late=40)
        with service.MODEL_STATE_LOCK:
            self.assertEqual(service.idle_maintenance_deadline(100), 130)
            service.REQUEST_STATES['owner'] = {'model': 'early', 'state': 'finished'}
            self.assertIsNone(service.idle_maintenance_deadline(200))
            service.REQUEST_STATES.clear()
            service.UNLOADING_MODELS.add('retired')
            self.assertEqual(service.idle_maintenance_deadline(200), 200)

    def test_cold_wait_rearms_when_loaded_and_unloads_once_on_executor(self):
        service = self.service
        controller = self.recorded_maintenance()
        threads = []
        self.core.clear_cache.side_effect = lambda: threads.append(threading.get_ident())
        with service.MODEL_STATE_LOCK:
            service.MODELS['synthetic'] = object()
            service.MODEL_LAST_USED['synthetic'] = time.monotonic() - service.IDLE_MODEL_SECONDS + .06
            service.signal_idle_maintenance()
        self.settle(lambda: len(threads) == 1 and not service.MODELS)
        self.settle(lambda: len(controller.condition.waits) >= 3)
        self.assertIsNone(controller.condition.waits[0])
        self.assertGreater(controller.condition.waits[1], 0)
        self.assertIsNone(controller.condition.waits[-1])
        self.assertEqual(threads, [self.executor.submit(threading.get_ident).result(timeout=1)])

    def test_finished_handler_keeps_expired_model_until_finish_notification(self):
        service = self.service
        service.MODELS['synthetic'] = object()
        service.MODEL_LAST_USED['synthetic'] = 0
        service.REQUEST_STATES['owner'] = {'model': 'synthetic', 'state': 'finished'}
        controller = self.recorded_maintenance()
        self.assertEqual(controller.condition.waits, [None])
        service.finish_request('owner', 'synthetic')
        self.settle(lambda: not service.MODELS and len(controller.condition.waits) >= 2)
        self.core.clear_cache.assert_called_once()
        self.assertEqual(service.COMPLETED_REQUESTS['owner'], {'model': 'synthetic', 'state': 'finished'})

    def test_last_used_notification_extends_deadline_before_unload(self):
        service = self.service
        service.MODELS['synthetic'] = object()
        service.MODEL_LAST_USED['synthetic'] = time.monotonic() - service.IDLE_MODEL_SECONDS + .05
        controller = self.recorded_maintenance()
        with service.MODEL_STATE_LOCK:
            service.MODEL_LAST_USED['synthetic'] = time.monotonic()
            service.signal_idle_maintenance()
        self.settle(lambda: len(controller.condition.waits) >= 2)
        self.assertGreater(controller.condition.waits[-1], service.IDLE_MODEL_SECONDS - 1)
        threading.Event().wait(.07)
        self.assertIn('synthetic', service.MODELS)
        self.core.clear_cache.assert_not_called()

    def test_expired_deadline_rechecks_ownership_on_inference_executor(self):
        service = self.service
        entered, release = threading.Event(), threading.Event()
        self.executor.submit(lambda: (entered.set(), release.wait(2)))
        self.assertTrue(entered.wait(1))
        service.MODELS['synthetic'] = object()
        service.MODEL_LAST_USED['synthetic'] = 0
        controller = self.maintenance()
        try:
            with service.MODEL_STATE_LOCK:
                service.REQUEST_STATES['owner'] = {'model': 'synthetic', 'state': 'waiting'}
                service.signal_idle_maintenance()
        finally:
            release.set()
        self.executor.submit(lambda: None).result(timeout=2)
        self.assertIn('synthetic', service.MODELS)
        self.core.clear_cache.assert_not_called()
        controller.set()

    def test_failed_cache_release_retries_after_delay_without_spinning(self):
        report = measure_maintenance(SOURCE, 'loaded', fail_once=True)
        self.assertEqual(report['maintenance_submissions'], 2)
        self.assertEqual(report['wait_timeouts'], [120.0, 5.0, None])
        self.assertEqual(report['pending_release'], [])

    def test_transcription_state_and_finalizer_signal_under_lock(self):
        service = self.service
        service.MODELS['synthetic'] = object()
        service.MODEL_LAST_USED['synthetic'] = 0
        notify = Mock()
        service.IDLE_MAINTENANCE = SimpleNamespace(condition=SimpleNamespace(notify_all=notify))
        service.model_for = Mock(return_value=SimpleNamespace(generate=lambda *a, **k: SimpleNamespace(text=' fake ')))
        self.assertEqual(service.run_registered_transcription('owner', 'fake.wav', 'synthetic'), 'fake')
        service.finish_request('owner', 'synthetic')
        self.assertEqual(notify.call_count, 4)
        self.assertGreater(service.MODEL_LAST_USED['synthetic'], 0)

    def test_http_indefinite_selector_dispatch_and_prompt_shutdown(self):
        server = self.service.wakeable_http_server_class(UnboundHTTPBase)()
        self.addCleanup(server.server_close)
        original = selectors.DefaultSelector
        calls, entered = [], threading.Event()
        class RecordingSelector(original):
            def select(self, timeout=None):
                calls.append(timeout)
                entered.set()
                return super().select(timeout)
        with patch.object(selectors, 'DefaultSelector', RecordingSelector):
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 30}, daemon=True)
            thread.start()
            try:
                self.assertTrue(entered.wait(1))
                threading.Event().wait(.06)
                self.assertEqual(calls, [None])
                server.request_write.send(b'x')
                self.assertTrue(server.handled.wait(1))
                self.settle(lambda: len(calls) == 2)
                started = time.monotonic()
                server.shutdown()
                self.assertLess(time.monotonic() - started, 1)
            finally:
                server.shutdown()
                thread.join(timeout=1)
            self.assertFalse(thread.is_alive())
        self.assertEqual(calls, [None, None])
        self.assertEqual(server.actions, 1)

    def test_http_shutdown_before_first_wait_is_not_lost(self):
        server = self.service.wakeable_http_server_class(UnboundHTTPBase)()
        self.addCleanup(server.server_close)
        stopping = threading.Thread(target=server.shutdown, daemon=True)
        stopping.start()
        self.assertTrue(server._http_stopping.wait(1))
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        stopping.join(timeout=1)
        serving.join(timeout=1)
        self.assertFalse(stopping.is_alive())
        self.assertFalse(serving.is_alive())

    def test_http_initialization_failure_closes_wakeup_descriptors(self):
        pair = socket.socketpair()
        class FailingBase:
            def __init__(self): raise OSError('synthetic init failure')
        with patch.object(socket, 'socketpair', return_value=pair):
            with self.assertRaises(OSError):
                self.service.wakeable_http_server_class(FailingBase)()
        self.assertEqual([endpoint.fileno() for endpoint in pair], [-1, -1])

    def watchdog(self, monitor, ppid=lambda: 123, poll_seconds=5):
        service = self.service
        release, started = threading.Event(), threading.Event()
        class Input:
            def read(self, size):
                started.set()
                release.wait(2)
                return b''
        service.sys = SimpleNamespace(stdin=Input())
        service.os.getppid = ppid
        service.ParentExitMonitor = monitor
        service.request_shutdown = Mock()
        threads = service.start_parent_watchdog(object(), parent_pid=123, poll_seconds=poll_seconds)
        self.assertTrue(started.wait(1))
        self.addCleanup(lambda: (release.set(), [thread.join(timeout=2) for thread in threads]))
        return release, threads

    def test_stdin_eof_wakes_native_parent_wait_and_exits_once(self):
        entered, wake = threading.Event(), threading.Event()
        monitor = SimpleNamespace(wait=lambda: (entered.set(), wake.wait(2), False)[-1],
                                  wake=wake.set, close=Mock())
        release, threads = self.watchdog(lambda pid: monitor)
        self.assertTrue(entered.wait(1))
        release.set()
        for thread in threads: thread.join(timeout=1)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.service.request_shutdown.assert_called_once()
        self.assertEqual(self.service.request_shutdown.call_args.args[1], 'parent stdin closed')
        monitor.close.assert_called_once()

    def test_parent_exit_event_requests_exit_with_stdin_still_open(self):
        monitor = SimpleNamespace(wait=lambda: True, wake=Mock(), close=Mock())
        _, threads = self.watchdog(lambda pid: monitor)
        threads[1].join(timeout=1)
        self.assertFalse(threads[1].is_alive())
        self.service.request_shutdown.assert_called_once()
        self.assertEqual(self.service.request_shutdown.call_args.args[1], 'parent process exited')

    def test_reparenting_after_native_registration_is_checked_before_wait(self):
        monitor = SimpleNamespace(wait=Mock(), wake=Mock(), close=Mock())
        _, threads = self.watchdog(lambda pid: monitor, ppid=lambda: 1)
        threads[1].join(timeout=1)
        self.service.request_shutdown.assert_called_once()
        monitor.wait.assert_not_called()

    def test_unavailable_parent_event_keeps_interruptible_fallback(self):
        def unavailable(pid): raise OSError('synthetic unavailable event')
        release, threads = self.watchdog(unavailable)
        release.set()
        for thread in threads: thread.join(timeout=1)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.service.request_shutdown.assert_called_once()

    def test_failed_parent_event_falls_back_and_detects_reparenting(self):
        checks = iter([123, 1])
        monitor = SimpleNamespace(wait=Mock(side_effect=OSError('synthetic wait failure')),
                                  wake=Mock(), close=Mock())
        _, threads = self.watchdog(lambda pid: monitor, ppid=lambda: next(checks))
        threads[1].join(timeout=1)
        self.service.request_shutdown.assert_called_once()
        self.assertEqual(self.service.request_shutdown.call_args.args[1], 'parent process exited')

    def test_kqueue_registers_exit_and_explicit_wakeup_without_timeout(self):
        service = self.service
        calls = []
        event = SimpleNamespace(filter=-5, fflags=1)
        watcher = SimpleNamespace(control=lambda changes, count, timeout:
                                  (calls.append((changes, count, timeout)), [event] if count else [])[-1],
                                  close=Mock())
        fake_select = SimpleNamespace(kqueue=lambda: watcher,
                                      kevent=lambda ident, **kwargs: dict(ident=ident, **kwargs),
                                      KQ_FILTER_PROC=-5, KQ_FILTER_READ=-1,
                                      KQ_EV_ADD=1, KQ_EV_ENABLE=2, KQ_EV_ONESHOT=4, KQ_NOTE_EXIT=1)
        with patch.dict(sys.modules, {'select': fake_select}):
            monitor = service.ParentExitMonitor(123)
            try:
                self.assertTrue(monitor.wait())
                monitor.wake()
                self.assertEqual(monitor.wake_read.recv(1), b'\0')
            finally:
                monitor.close()
        self.assertEqual(calls[0][0][0], {'ident': 123, 'filter': -5, 'flags': 7, 'fflags': 1})
        self.assertEqual(calls[1], (None, 2, None))
        watcher.close.assert_called_once()

    def test_native_registration_failure_closes_owned_descriptors(self):
        pair = socket.socketpair()
        watcher = SimpleNamespace(control=Mock(side_effect=OSError('synthetic registration failure')),
                                  close=Mock())
        with patch.object(socket, 'socketpair', return_value=pair), \
             patch.dict(sys.modules, {'select': SimpleNamespace(kqueue=lambda: watcher,
                        kevent=lambda *a, **k: None, KQ_FILTER_PROC=1, KQ_FILTER_READ=2,
                        KQ_EV_ADD=1, KQ_EV_ENABLE=2, KQ_EV_ONESHOT=4, KQ_NOTE_EXIT=8)}):
            with self.assertRaises(OSError): self.service.ParentExitMonitor(123)
        self.assertEqual([endpoint.fileno() for endpoint in pair], [-1, -1])
        watcher.close.assert_called_once()

    def test_initial_ready_precedes_serving_and_does_not_load_models(self):
        service = self.service
        events = []
        class Server:
            server_address = ('127.0.0.1', 12345)
            def serve_forever(self): events.append('serve')
            def server_close(self): events.append('close')
        service.create_server = lambda *args: (Server(), '127.0.0.1', 12345)
        service.RequestLog.start = lambda: None
        service.start_idle_maintenance = lambda: SimpleNamespace(set=lambda: events.append('stop-maintenance'))
        service.announce_ready = lambda *args: events.append('ready')
        service.cleanup_temporary_audio = lambda: None
        service.model_for = Mock(side_effect=AssertionError('model load forbidden'))
        self.assertEqual(service.main(['--token', 'synthetic-token', '--models-dir', 'synthetic-models']), 0)
        self.assertEqual(events, ['ready', 'serve', 'stop-maintenance', 'close'])
        service.model_for.assert_not_called()


class ProbeEnd(BaseException):
    """End the virtual observation window without a production exception path."""


def measure_maintenance(path, state, horizon=600.0, fail_once=False):
    service = load_subject(path)
    clock = [0.0]
    counts = {'wait_calls': 0, 'timed_wait_completions': 0, 'maintenance_submissions': 0,
              'maintenance_checks': 0, 'wait_timeouts': []}
    service.time = SimpleNamespace(monotonic=lambda: clock[0])
    if state in ('loaded', 'busy'):
        service.MODELS['synthetic'] = object()
        service.MODEL_LAST_USED['synthetic'] = 0
    if state == 'busy':
        service.REQUEST_STATES['owner'] = {'model': 'synthetic', 'state': 'running'}

    def wait(timeout):
        counts['wait_calls'] += 1
        counts['wait_timeouts'].append(timeout)
        if timeout is None or clock[0] + timeout > horizon:
            clock[0] = horizon
            raise ProbeEnd()
        clock[0] += timeout
        counts['timed_wait_completions'] += 1

    class VirtualEvent:
        def wait(self, timeout):
            wait(timeout)
            return False
        def set(self): pass

    class VirtualCondition:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def notify_all(self): pass
        def wait(self, timeout=None): return wait(timeout)

    def submit(action):
        counts['maintenance_submissions'] += 1
        future = Future()
        try:
            future.set_result(action())
        except Exception as error:
            future.set_exception(error)
        return future

    releases = []
    def clear_cache():
        releases.append(clock[0])
        if fail_once and len(releases) == 1: raise RuntimeError('synthetic release failure')
    service.INFERENCE_WORKER = SimpleNamespace(submit=submit)
    service.threading = SimpleNamespace(Event=VirtualEvent,
                                       Thread=lambda target, **kwargs: SimpleNamespace(start=target))
    if hasattr(service, 'IdleMaintenance'):
        controller = service.IdleMaintenance.__new__(service.IdleMaintenance)
        controller.condition, controller.stopped = VirtualCondition(), False
        service.IDLE_MAINTENANCE = controller
        deadline = service.idle_maintenance_deadline
        def checked(now):
            counts['maintenance_checks'] += 1
            return deadline(now)
        service.idle_maintenance_deadline = checked
        run = controller.run
    else:
        # Only the maintenance thread acquires this counting proxy; model
        # cleanup acquires its real state lock through the action wrapper.
        real_lock = service.MODEL_STATE_LOCK
        class CountingLock:
            def __enter__(self):
                counts['maintenance_checks'] += 1
                return real_lock.__enter__()
            def __exit__(self, *args): return real_lock.__exit__(*args)
        service.MODEL_STATE_LOCK = CountingLock()
        original_submit = service.INFERENCE_WORKER.submit
        def unlocked_submit(action):
            proxy = service.MODEL_STATE_LOCK
            service.MODEL_STATE_LOCK = real_lock
            try: return original_submit(action)
            finally: service.MODEL_STATE_LOCK = proxy
        service.INFERENCE_WORKER.submit = unlocked_submit
        run = service.start_idle_maintenance
    core = SimpleNamespace(clear_cache=clear_cache)
    with patch.dict(sys.modules, {'mlx': SimpleNamespace(core=core), 'mlx.core': core}):
        try: run()
        except ProbeEnd: pass
    return {**counts, 'virtual_seconds': clock[0], 'cache_releases_at': releases,
            'loaded_models': sorted(service.MODELS), 'pending_release': sorted(service.UNLOADING_MODELS)}


def measure_http(path, horizon=600.0):
    service = load_subject(path)
    counts = {'select_calls': 0, 'timeout_completions': 0, 'service_actions': 0}
    clock = [0.0]
    class Base(socketserver.BaseServer):
        def service_actions(self): counts['service_actions'] += 1
    server = (service.wakeable_http_server_class(Base) if hasattr(service, 'wakeable_http_server_class') else Base)(None, None)
    class Selector:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def register(self, *args): pass
        def select(self, timeout=None):
            counts['select_calls'] += 1
            if timeout is None:
                clock[0] = horizon
                server._http_stopping.set()
            else:
                clock[0] += timeout
                counts['timeout_completions'] += 1
                if clock[0] >= horizon: server._BaseServer__shutdown_request = True
            return []
    try:
        with patch.object(selectors, 'DefaultSelector', Selector), \
             patch.object(socketserver, '_ServerSelector', Selector):
            server.serve_forever()
    finally:
        server.server_close()
    return {**counts, 'virtual_seconds': clock[0]}


def measure_parent(path, native, horizon=600.0):
    service = load_subject(path)
    clock = [0.0]
    counts = {'pid_checks': 0, 'timed_waits': 0, 'blocking_waits': 0}
    def getppid():
        counts['pid_checks'] += 1
        return 123
    def timed_wait(timeout):
        counts['timed_waits'] += 1
        clock[0] += timeout
        if clock[0] >= horizon: raise ProbeEnd()
        return False
    class Event:
        def is_set(self): return False
        def set(self): pass
        def wait(self, timeout): return timed_wait(timeout)
    class Thread:
        def __init__(self, target, name, **kwargs): self.target, self.name = target, name
        def start(self):
            if self.name == 'asr-parent-pid': self.target()
    def native_wait():
        counts['blocking_waits'] += 1
        clock[0] = horizon
        raise ProbeEnd()
    def monitor(pid):
        if not native: raise NotImplementedError('synthetic portable fallback')
        return SimpleNamespace(wait=native_wait, wake=lambda: None, close=lambda: None)
    service.ParentExitMonitor = monitor
    service.os.getppid = getppid
    service.time = SimpleNamespace(sleep=timed_wait)
    service.threading = SimpleNamespace(Thread=Thread, Event=Event, Lock=threading.Lock)
    try: service.start_parent_watchdog(object(), parent_pid=123)
    except ProbeEnd: pass
    return {**counts, 'virtual_seconds': clock[0]}


def measure_all(baseline, repeats=3):
    rows = []
    for _ in range(repeats):
        rows.append({
            'maintenance': {state: {'before': measure_maintenance(baseline, state),
                                    'after': measure_maintenance(SOURCE, state)}
                            for state in ('cold', 'loaded', 'busy')},
            'http': {'before': measure_http(baseline), 'after': measure_http(SOURCE)},
            'parent': {'before': measure_parent(baseline, False),
                       'after_native': measure_parent(SOURCE, True),
                       'after_fallback': measure_parent(SOURCE, False)}})
    if any(row != rows[0] for row in rows[1:]):
        raise AssertionError('Logical counts were not repeatable')
    return {'repeats': repeats, 'identical': True, 'observation': rows[0],
            'boundary': 'Executed production scheduling with virtual time and fake selector/model dependencies; no OS wakeup or power measurement.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--measure', action='store_true')
    parser.add_argument('--baseline', type=Path)
    arguments, remaining = parser.parse_known_args()
    if arguments.measure:
        if arguments.baseline is None: parser.error('--measure requires --baseline')
        print(json.dumps(measure_all(arguments.baseline), indent=2))
    else:
        unittest.main(argv=[sys.argv[0], *remaining])
