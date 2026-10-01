"""Real worker control flow with fake weights; measure waits, not energy."""
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
WORKER = Path(os.environ.get('LIVELINGO_IDLE_WORKER_SOURCE', ROOT / 'worker.py'))

BOOT = r'''
import hashlib,importlib.util,json,os,sys,threading,time,types,weakref
from pathlib import Path
sys.path.insert(0,sys.argv[1])
trace_fd=os.open(sys.argv[4],os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
def trace(kind,**values):
    os.write(trace_fd,(json.dumps(dict(kind=kind,at=time.monotonic(),**values))+'\n').encode())
engines=weakref.WeakSet()
class Engine:
    def __init__(self,*args): engines.add(self);trace('engine_loaded')
class Generation:
    def __init__(self,engine,prompt,schema=None,thinking=False,prefix='',**kwargs):
        self.engine=engine;self.prompt=prompt
        self.identity=hashlib.sha256(prompt.encode()).hexdigest()
        self.wire=prefix;self.text=prefix;self.thinking_count=0;self.final_count=len(prefix)
    def step(self):
        time.sleep(.005);self.wire+='x';self.text=self.wire;self.final_count+=1
        return 'done' if self.prompt!='slow' and self.final_count>=3 else 'running'
    def save(self,path):
        Path(path).write_text(json.dumps(dict(prompt=self.prompt,wire=self.wire,identity=self.identity)))
    @classmethod
    def restore(cls,engine,path,expected):
        data=json.loads(Path(path).read_text());assert data['identity']==expected
        result=cls(engine,data['prompt'],prefix=data['wire']);trace('restored');return result
engine=types.ModuleType('engine');engine.Engine=Engine;engine.Generation=Generation
sys.modules['engine']=engine
schemas=types.ModuleType('schemas');schemas.note_schema=lambda data:{};schemas.review_schema=lambda data:{}
sys.modules['schemas']=schemas
spec=importlib.util.spec_from_file_location('idle_worker_under_test',sys.argv[2])
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
original_select=worker.select.select
def traced_select(read,write,error,timeout=None):
    trace('reader_wait',timeout=timeout)
    value=original_select(read,write,error,timeout)
    if not any(value): trace('reader_timeout')
    return value
worker.select.select=traced_select
original_get=worker.queue.Queue.get
def traced_get(self,block=True,timeout=None):
    if block and threading.current_thread() is threading.main_thread(): trace('main_wait',timeout=timeout)
    return original_get(self,block,timeout)
worker.queue.Queue.get=traced_get
class Backend:
    cache=100
    def set_cache_limit(self,value): return 100
    def get_active_memory(self): return len(engines)*100
    def get_cache_memory(self): return self.cache
    def get_peak_memory(self): return 200
    def clear_cache(self): self.cache=0;trace('cache_cleared')
worker.discover_mlx=lambda:Backend()
sys.argv=['worker','--model','fake','--state-directory',sys.argv[3],*json.loads(sys.argv[5])]
try: worker.main()
finally:
    trace('worker_exited',reader_threads=sum(t.is_alive() and t is not threading.main_thread() for t in threading.enumerate()))
    os.close(trace_fd)
'''


class Worker:
    def __init__(self, path, *args, read_stdout=True):
        self.trace_path = path / 'waits.jsonl'
        self.events = queue.Queue()
        self.pending = []
        self.errors = []
        self.process = subprocess.Popen(
            [sys.executable, '-B', '-c', BOOT, str(ROOT), str(WORKER),
             str(path / 'state'), str(self.trace_path), json.dumps(args)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.reader = threading.Thread(target=self._read, daemon=True) if read_stdout else None
        if self.reader is not None: self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except Exception as error:
                self.errors.append(str(error))

    def send_bytes(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def send(self, **command):
        self.send_bytes((json.dumps(command) + '\n').encode())

    def until(self, kind, request_id=None, timeout=3):
        def matches(event):
            return event.get('event') == kind and (request_id is None or event.get('id') == request_id)
        for index, event in enumerate(self.pending):
            if matches(event): return self.pending.pop(index)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise AssertionError(f'No {kind}/{request_id}: {self.pending}')
            event = self.events.get(timeout=remaining)
            if matches(event): return event
            self.pending.append(event)

    def traces(self):
        return [json.loads(line) for line in self.trace_path.read_text().splitlines()]

    def shutdown(self):
        self.send(op='shutdown', controlID='test-shutdown')
        receipt = self.until('shutdown')
        assert receipt['controlID'] == 'test-shutdown'
        assert receipt['state'] == 'ready_to_exit'
        assert self.process.wait(timeout=3) == 0
        last = self.traces()[-1]
        assert last['kind'] == 'worker_exited' and last['reader_threads'] == 0

    def close(self):
        if self.process.poll() is None:
            if not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
        if self.reader is not None: self.reader.join(timeout=1)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr): stream.close()


class IdleWorkerTests(unittest.TestCase):
    def setUp(self):
        output = os.environ.get('LIVELINGO_IDLE_TEST_OUTPUT')
        if output:
            self.path = Path(output) / self._testMethodName
            self.path.mkdir(parents=True, exist_ok=False)
        else:
            self.temporary = tempfile.TemporaryDirectory(prefix='livelingo-idle-')
            self.addCleanup(self.temporary.cleanup)
            self.path = Path(self.temporary.name)

    def worker(self, *args):
        worker = Worker(self.path, *args)
        self.addCleanup(worker.close)
        self.assertEqual(worker.until('ready')['version'], 2)
        worker.until('memory')
        return worker

    def test_reader_does_not_poll_when_no_commands_arrive(self):
        worker = self.worker('--idle-cache-release-seconds', '0')
        time.sleep(.7)
        worker.shutdown()
        self.assertEqual(sum(t['kind'] == 'reader_timeout' for t in worker.traces()), 0)
        self.assertTrue(all(t['timeout'] is None for t in worker.traces() if t['kind'] == 'main_wait'))

    def test_cache_deadline_then_indefinite_wait(self):
        worker = self.worker('--idle-cache-release-seconds', '.05')
        worker.until('memory', timeout=.6)
        time.sleep(.07)
        waits = [t for t in worker.traces() if t['kind'] == 'main_wait']
        self.assertIsNone(waits[-1]['timeout'])
        self.assertEqual(sum(t['kind'] == 'cache_cleared' for t in worker.traces()), 1)
        worker.shutdown()

    def test_idle_unload_keeps_paused_work_and_can_resume(self):
        worker = self.worker('--idle-cache-release-seconds', '.03', '--idle-model-seconds', '.08')
        worker.send(op='generate', id='a', prompt='slow', purpose='note', input='{}')
        worker.until('snapshot', 'a')
        # A nonempty prefix is needed to request recovery.
        snapshot = worker.until('snapshot', 'a')
        self.assertTrue(snapshot['wire'])
        worker.send(op='pause', id='a', controlID='pause-a')
        self.assertEqual(worker.until('paused', 'a')['state'], 'saved')
        while worker.until('model_state', timeout=.8).get('loaded'): pass
        checkpoints = list((self.path / 'state').glob('*.safetensors'))
        self.assertEqual(len(checkpoints), 1)
        worker.send(op='generate', id='resumed', prompt='slow', prefix=snapshot['wire'], purpose='note', input='{}')
        self.assertTrue(worker.until('snapshot', 'resumed')['recovered'])
        self.assertTrue(any(t['kind'] == 'restored' for t in worker.traces()))
        worker.send(op='cancel', id='resumed')
        worker.until('cancel', 'resumed')
        self.assertEqual(list((self.path / 'state').glob('*.safetensors')), [])
        worker.shutdown()

    def test_partial_and_multiple_commands_preserve_order(self):
        worker = self.worker('--idle-cache-release-seconds', '0')
        worker.send_bytes(b'{"op":"pause","id":"one",')
        time.sleep(.05)
        worker.send_bytes(b'"controlID":"p1"}\n{"op":"pause","id":"two","controlID":"p2"}\n')
        self.assertEqual(worker.until('paused', 'one')['controlID'], 'p1')
        self.assertEqual(worker.until('paused', 'two')['controlID'], 'p2')
        worker.shutdown()

    def test_eof_checkpoints_active_note_and_exits(self):
        worker = self.worker()
        worker.send(op='generate', id='note', prompt='slow', purpose='note', input='{}')
        worker.until('snapshot', 'note')
        worker.process.stdin.close()
        self.assertEqual(worker.until('shutdown')['state'], 'ready_to_exit')
        self.assertEqual(worker.process.wait(timeout=3), 0)
        self.assertEqual(len(list((self.path / 'state').glob('*.safetensors'))), 1)

    def test_malformed_line_stops_without_new_generation(self):
        worker = self.worker()
        worker.send_bytes(b'not-json\n')
        self.assertEqual(worker.until('shutdown')['state'], 'ready_to_exit')
        self.assertEqual(worker.process.wait(timeout=3), 0)
        self.assertFalse(any(t['kind'] == 'engine_loaded' for t in worker.traces()))

    def test_shutdown_wakes_reader_with_parent_input_still_open(self):
        worker = self.worker('--idle-cache-release-seconds', '0')
        worker.shutdown()
        self.assertFalse(worker.process.stdin.closed)

    def test_extreme_idle_deadlines_still_accept_commands(self):
        worker = self.worker('--idle-cache-release-seconds', 'inf', '--idle-model-seconds', 'inf')
        worker.send(op='generate', id='fast', prompt='fast')
        self.assertEqual(worker.until('done', 'fast')['text'], 'xxx')
        worker.shutdown()

    def test_broken_output_pipe_wakes_reader_before_exit(self):
        worker = Worker(self.path, '--idle-cache-release-seconds', '0', read_stdout=False)
        self.addCleanup(worker.close)
        self.assertEqual(json.loads(worker.process.stdout.readline())['event'], 'ready')
        self.assertEqual(json.loads(worker.process.stdout.readline())['event'], 'memory')
        worker.process.stdout.close()
        worker.send(op='generate', id='closed-output', prompt='fast')
        self.assertEqual(worker.process.wait(timeout=3), 0)
        self.assertFalse(worker.process.stdin.closed)
        self.assertEqual(worker.traces()[-1]['reader_threads'], 0)


if __name__ == '__main__': unittest.main()
