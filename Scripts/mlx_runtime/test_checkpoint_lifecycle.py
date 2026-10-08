"""Checkpoint pruning regressions for worker.persist; no MLX and no weights.

Every test runs the real ``worker.main()`` in its own subprocess with a stub
``engine``/``schemas`` pair, so nothing here imports MLX or touches the network.
The stub ``Generation.save`` materialises a checkpoint with ``truncate``: the
placeholder has a 3 GiB nominal size - the only number ``worker.persist``
measures - while occupying almost no disk space.

Budget arithmetic: two 3 GiB checkpoints are 6 GiB nominal, so the second
completion triggers the prune loop while the first result is still waiting for
the app's acknowledgement. Before the fix, the loop protected only the
generation being persisted plus the ``active``/``paused`` identities, so a
completed but unacknowledged checkpoint was treated as a removable cache entry.
Only an explicit ACK or CANCEL may release a completed result.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent
GIB = 1024 ** 3
CHECKPOINT_BYTES = 3 * GIB
PRUNE_BUDGET_BYTES = 4 * GIB
STALE_NAMES = ('1' * 64, '2' * 64)
CHECKPOINT_MTIME = 1_700_000_000

BOOT = r'''
import hashlib
import os
import sys
import time
import types
from pathlib import Path

sys.path.insert(0, sys.argv[1])
state = Path(sys.argv[2])
checkpoint_bytes = int(os.environ['FAKE_CHECKPOINT_BYTES'])


class Engine:
    identity = 'stub-engine'
    def __init__(self, *args, **kwargs):
        pass


class Generation:
    def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', **kwargs):
        self.identity = hashlib.sha256(prompt.encode()).hexdigest()
        self.wire = prefix
        self.text = prefix
        self.thinking_count = 0
        self.final_count = 0
        self.slow = prompt.startswith('slow-')

    def step(self):
        if self.slow:
            time.sleep(0.005)
            self.wire += 'x'
            self.text = self.wire
            self.final_count += 1
            return 'running'
        self.wire += 'ok'
        self.text = self.wire
        self.final_count = 1
        return 'done'

    def save(self, path):
        # Sparse on purpose: nominal size drives the worker's prune budget.
        with open(path, 'ab') as handle:
            handle.truncate(checkpoint_bytes)
        os.utime(path, (1_700_000_000, 1_700_000_000))

    @classmethod
    def restore(cls, engine, path, expected_identity):
        raise AssertionError('checkpoint restore is not exercised by this test')


engine = types.ModuleType('engine')
engine.Engine = Engine
engine.Generation = Generation
sys.modules['engine'] = engine

schemas = types.ModuleType('schemas')
schemas.note_schema = lambda data: {'type': 'object', 'stub': True}
schemas.review_schema = lambda data: {'type': 'object', 'stub': True}
sys.modules['schemas'] = schemas

import worker


class Backend:
    def set_cache_limit(self, value): return 100
    def get_active_memory(self): return 50
    def get_cache_memory(self): return 0
    def get_peak_memory(self): return 100
    def clear_cache(self): return None


worker.discover_mlx = lambda: Backend()
sys.argv = ['worker', '--model', 'stub', '--state-directory', str(state)]
worker.main()
'''

_sparse_supported = None


def sparse_placeholders_supported():
    """Probe the filesystem once with a bounded 256 MiB truncate."""
    global _sparse_supported
    if _sparse_supported is None:
        with tempfile.TemporaryDirectory(prefix='livelingo-sparse-probe-') as directory:
            probe = Path(directory) / 'probe'
            create_placeholder(probe, size=256 * 1024 * 1024)
            _sparse_supported = probe.stat().st_blocks * 512 < 64 * 1024 * 1024
    return _sparse_supported


def create_placeholder(path, size=CHECKPOINT_BYTES, mtime=None):
    """A cache-shaped file with a nominal size but (almost) no allocated blocks."""
    path = Path(path)
    with open(path, 'ab') as handle:
        handle.truncate(size)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def checkpoint_path(directory, prompt):
    """The stub identity rule: sha256(prompt), matching BOOT's Generation."""
    return Path(directory) / (hashlib.sha256(prompt.encode()).hexdigest() + '.safetensors')


def note_command(request_id, prompt):
    payload = json.dumps({'evidence': [], 'pendingPoints': []})
    return dict(op='generate', id=request_id, prompt=prompt, purpose='note', input=payload)


class WorkerSession:
    """One worker subprocess with a timeout-bounded JSONL reader and teardown."""

    def __init__(self, state_directory, checkpoint_bytes=CHECKPOINT_BYTES, boot=BOOT):
        self.state = Path(state_directory)
        self.protocol_errors = []
        self.stderr_lines = []
        self._pending = []
        self._events = queue.Queue()
        environment = dict(os.environ, FAKE_CHECKPOINT_BYTES=str(checkpoint_bytes))
        for name in ('LIVELINGO_MLX_CACHE_LIMIT_MB', 'LIVELINGO_MLX_MEMORY_LOG_SECONDS',
                     'LIVELINGO_MLX_IDLE_CACHE_RELEASE_SECONDS', 'LIVELINGO_SCOREBOARD_TIMINGS'):
            environment.pop(name, None)
        self.process = subprocess.Popen(
            [sys.executable, '-B', '-c', boot, str(ROOT), str(self.state)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        self._threads = [threading.Thread(target=self._read_protocol, daemon=True),
                         threading.Thread(target=self._read_stderr, daemon=True)]
        for thread in self._threads:
            thread.start()

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()
        return False

    def _read_protocol(self):
        try:
            for line in self.process.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    self._events.put(json.loads(line))
                except json.JSONDecodeError:
                    self.protocol_errors.append(line)
                    self._events.put({'event': '<protocol-error>', 'line': line})
        except (ValueError, OSError):
            return

    def _read_stderr(self):
        try:
            for line in self.process.stderr:
                self.stderr_lines.append(line.rstrip('\n'))
        except (ValueError, OSError):
            return

    def send(self, op, **fields):
        command = dict(op=op, **fields)
        try:
            self.process.stdin.write(json.dumps(command, ensure_ascii=False) + '\n')
            self.process.stdin.flush()
        except (BrokenPipeError, ValueError, OSError) as error:
            raise AssertionError(f'worker stdin closed before {op!r} ({error})\n{self.describe()}') from None

    def wait_for(self, event, request_id=None, timeout=15.0):
        """Return the matching event; fail loudly on timeout or a worker error."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f'timed out after {timeout}s waiting for {event!r} id={request_id!r}\n{self.describe()}')
            try:
                item = self._events.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                continue
            if item.get('event') == 'error' and (request_id is None or item.get('id') == request_id):
                raise AssertionError(
                    f'worker reported an error while waiting for {event!r}: {item}\n{self.describe()}')
            if item.get('event') == event and (request_id is None or item.get('id') == request_id):
                return item
            self._pending.append(item)

    def await_ready(self):
        receipt = self.wait_for('ready')
        if receipt.get('version') != 2:
            raise AssertionError(f'stub worker announced an unexpected protocol version: {receipt}')
        return receipt

    def shutdown(self, timeout=15.0):
        self.send('shutdown', controlID='shutdown-test')
        receipt = self.wait_for('shutdown', timeout=timeout)
        if receipt.get('controlID') != 'shutdown-test':
            raise AssertionError(f'shutdown receipt lost its controlID: {receipt}')
        code = self.process.wait(timeout=timeout)
        if code != 0:
            raise AssertionError(f'worker exited with {code}\n{self.describe()}')
        self._pending.append(receipt)
        return receipt

    def describe(self, limit=25):
        seen = [f"{item.get('event')}:{item.get('id')}" for item in self._pending[-limit:]]
        stderr = '\n'.join(self.stderr_lines[-limit:])
        return (f'state={self.state} returncode={self.process.poll()} '
                f'protocol_errors={self.protocol_errors[-5:]}\n'
                f'recent events={seen}\nworker stderr tail:\n{stderr}')

    def close(self):
        """Close only this session's process and handles; never another path."""
        process = self.process
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        finally:
            for stream in (process.stdin, process.stdout, process.stderr):
                with contextlib.suppress(Exception):
                    if stream is not None:
                        stream.close()
            for thread in self._threads:
                thread.join(timeout=5)


class CheckpointLifecycleTests(unittest.TestCase):
    def setUp(self):
        if not sparse_placeholders_supported():
            self.skipTest('filesystem does not back truncate with sparse blocks; '
                          'refusing to write GiB placeholders')

    @contextlib.contextmanager
    def worker_state(self, checkpoint_bytes=CHECKPOINT_BYTES):
        with tempfile.TemporaryDirectory(prefix='livelingo-checkpoint-') as directory:
            with WorkerSession(directory, checkpoint_bytes) as worker:
                worker.await_ready()
                yield Path(directory), worker

    def test_completed_unacknowledged_checkpoint_survives_another_persist(self):
        """The regression: a later persist must not prune an unacknowledged result."""
        prompt_a, prompt_b = 'note-alpha', 'note-beta'
        with self.worker_state() as (directory, worker):
            first = checkpoint_path(directory, prompt_a)
            second = checkpoint_path(directory, prompt_b)
            worker.send(**note_command('a', prompt_a))
            worker.wait_for('snapshot', 'a')
            worker.wait_for('done', 'a')
            self.assertTrue(first.is_file(), f'first note never persisted a checkpoint\n{worker.describe()}')
            nominal = first.stat().st_size
            self.assertGreater(nominal * 2, PRUNE_BUDGET_BYTES,
                               'checkpoint placeholder is too small to cross the 4 GiB prune budget')
            worker.send(**note_command('b', prompt_b))
            worker.wait_for('snapshot', 'b')
            worker.wait_for('done', 'b')
            self.assertTrue(second.is_file(), f'second note never persisted a checkpoint\n{worker.describe()}')
            # The worker still classifies 'a' as a completed result awaiting the
            # app's journal write, which is exactly the state that must survive.
            worker.send(op='pause', id='a', controlID='probe-a')
            self.assertEqual(worker.wait_for('paused', 'a')['state'], 'completed')
            owned = {f'id=a prompt={prompt_a}': first, f'id=b prompt={prompt_b}': second}
            missing = [label for label, path in owned.items() if not path.is_file()]
            self.assertEqual(
                missing, [],
                'worker.persist pruned completed-but-unacknowledged checkpoints when another '
                f'request persisted ({len(missing)} of {len(owned)} gone, nominal total '
                f'{2 * nominal / GIB:.1f} GiB above the {PRUNE_BUDGET_BYTES / GIB:.0f} GiB budget): {missing}\n'
                f'{worker.describe()}')
            # An ACK releases exactly the acknowledged result.
            worker.send(op='ack', id='a')
            self.assertEqual(worker.wait_for('ack', 'a')['state'], 'released')
            self.assertFalse(first.exists(), 'ACK left the acknowledged checkpoint behind')
            self.assertTrue(second.is_file(), 'ACK deleted a checkpoint that was never acknowledged')
            worker.send(op='ack', id='b')
            worker.wait_for('ack', 'b')
            self.assertEqual(worker.shutdown()['state'], 'ready_to_exit')

    def test_unowned_stale_cache_is_pruned_above_the_budget(self):
        """Pruning stays live: an unowned old cache file is still reclaimable."""
        prompt = 'note-keep'
        with self.worker_state() as (directory, worker):
            kept = checkpoint_path(directory, prompt)
            now = CHECKPOINT_MTIME
            stale = [create_placeholder(directory / (name + '.safetensors'), mtime=now - 3600)
                     for name in STALE_NAMES]
            worker.send(**note_command('a', prompt))
            worker.wait_for('snapshot', 'a')
            worker.wait_for('done', 'a')
            self.assertEqual(kept.stat().st_size, CHECKPOINT_BYTES)
            still_there = [path.name for path in stale if path.exists()]
            self.assertEqual(still_there, [],
                             f'unowned checkpoints above the 4 GiB budget were not pruned: {still_there}')
            worker.send(op='ack', id='a')
            worker.wait_for('ack', 'a')
            self.assertEqual(worker.shutdown()['state'], 'ready_to_exit')

    def test_paused_checkpoint_survives_pruning_when_oldest(self):
        """A paused checkpoint is protected even when it is the oldest file."""
        prompt_pause, prompt_note = 'slow-pause-alpha', 'note-gamma'
        with self.worker_state() as (directory, worker):
            paused_path = checkpoint_path(directory, prompt_pause)
            completed_path = checkpoint_path(directory, prompt_note)
            worker.send(**note_command('slow', prompt_pause))
            worker.wait_for('snapshot', 'slow')
            worker.send(op='pause', id='slow', controlID='pause-slow')
            self.assertEqual(worker.wait_for('paused', 'slow')['state'], 'saved')
            self.assertTrue(paused_path.is_file())
            now = CHECKPOINT_MTIME
            os.utime(paused_path, (now - 3600, now - 3600))
            stale = create_placeholder(directory / ('3' * 64 + '.safetensors'), mtime=now - 1800)
            worker.send(**note_command('b', prompt_note))
            worker.wait_for('snapshot', 'b')
            worker.wait_for('done', 'b')
            self.assertTrue(paused_path.is_file(),
                            f'a paused checkpoint was pruned as an unowned cache file\n{worker.describe()}')
            self.assertFalse(stale.exists(), 'the unowned cache file above the budget was not pruned')
            # CANCEL releases only the canceled completed result.
            worker.send(op='cancel', id='b')
            self.assertEqual(worker.wait_for('cancel', 'b')['state'], 'released')
            self.assertFalse(completed_path.exists(), 'cancel left the canceled checkpoint behind')
            self.assertTrue(paused_path.is_file(), 'cancel deleted a checkpoint that was never canceled')
            self.assertEqual(worker.shutdown()['state'], 'ready_to_exit')

    def test_active_checkpoint_survives_pruning_when_oldest(self):
        """An in-flight checkpoint is protected even when it is the oldest file."""
        prompt_active, prompt_note = 'slow-active-delta', 'note-epsilon'
        with self.worker_state() as (directory, worker):
            active_path = checkpoint_path(directory, prompt_active)
            completed_path = checkpoint_path(directory, prompt_note)
            worker.send(**note_command('slow', prompt_active))
            worker.wait_for('snapshot', 'slow')
            worker.send(op='checkpoint', id='slow', controlID='checkpoint-slow')
            self.assertEqual(worker.wait_for('checkpoint', 'slow')['state'], 'saved')
            self.assertTrue(active_path.is_file())
            now = CHECKPOINT_MTIME
            os.utime(active_path, (now - 3600, now - 3600))
            stale = create_placeholder(directory / ('4' * 64 + '.safetensors'), mtime=now - 1800)
            worker.send(**note_command('b', prompt_note))
            worker.wait_for('snapshot', 'b')
            worker.wait_for('done', 'b')
            self.assertTrue(active_path.is_file(),
                            f'an in-flight checkpoint was pruned as an unowned cache file\n{worker.describe()}')
            self.assertFalse(stale.exists(), 'the unowned cache file above the budget was not pruned')
            self.assertTrue(completed_path.is_file())
            worker.send(op='cancel', id='slow')
            worker.wait_for('cancel', 'slow')
            self.assertFalse(active_path.exists(), 'cancel left the canceled checkpoint behind')
            worker.send(op='ack', id='b')
            worker.wait_for('ack', 'b')
            self.assertEqual(worker.shutdown()['state'], 'ready_to_exit')

    def test_ack_releases_only_the_acknowledged_completed_checkpoint(self):
        """ACK scope: an unrelated checkpoint is untouched."""
        prompt_pause, prompt_note = 'slow-pause-zeta', 'note-eta'
        with self.worker_state() as (directory, worker):
            paused_path = checkpoint_path(directory, prompt_pause)
            completed_path = checkpoint_path(directory, prompt_note)
            worker.send(**note_command('slow', prompt_pause))
            worker.wait_for('snapshot', 'slow')
            worker.send(op='pause', id='slow', controlID='pause-slow')
            self.assertEqual(worker.wait_for('paused', 'slow')['state'], 'saved')
            worker.send(**note_command('b', prompt_note))
            worker.wait_for('snapshot', 'b')
            worker.wait_for('done', 'b')
            self.assertTrue(paused_path.is_file())
            self.assertTrue(completed_path.is_file())
            worker.send(op='ack', id='b', controlID='ack-b')
            receipt = worker.wait_for('ack', 'b')
            self.assertEqual(receipt['controlID'], 'ack-b')
            self.assertEqual(receipt['state'], 'released')
            self.assertFalse(completed_path.exists(), 'ACK did not release the acknowledged checkpoint')
            self.assertTrue(paused_path.is_file(), 'ACK deleted a checkpoint that was never acknowledged')
            self.assertEqual(worker.shutdown()['state'], 'ready_to_exit')


if __name__ == '__main__':
    unittest.main()
