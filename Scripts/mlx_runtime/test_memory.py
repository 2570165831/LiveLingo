"""Allocator policy and worker lifecycle checks; no model weights are loaded."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).parent
saved_stdout = sys.stdout
spec = importlib.util.spec_from_file_location('worker_under_test', ROOT/'worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
sys.stdout = saved_stdout

class Backend:
    def __init__(self): self.cache = 100; self.active = 50; self.clears = 0
    def set_cache_limit(self, value): self.limit = value; return 999
    def get_active_memory(self): return self.active
    def get_cache_memory(self): return self.cache
    def get_peak_memory(self): return 150
    def clear_cache(self): self.cache = 0; self.clears += 1

class MemoryTests(unittest.TestCase):
    def test_limit_and_clear_preserve_active(self):
        backend=Backend(); reports=[]
        policy=worker.MlxMemory(backend,write=lambda _:None,report=lambda v,l:reports.append(v))
        self.assertTrue(policy.apply_limit())
        self.assertEqual(backend.limit,2048*1024**2)
        policy.release('done')
        self.assertEqual(backend.active,50)
        self.assertEqual(reports[-1]['cache'],0)

    def test_throttled_log_and_idle_once(self):
        now=[0]; backend=Backend(); lines=[]
        policy=worker.MlxMemory(backend,clock=lambda:now[0],write=lines.append)
        policy.log_event('generating')
        now[0]=1;policy.log_event('generating');self.assertEqual(len(lines),1)
        now[0]=30;self.assertFalse(policy.idle())
        now[0]=31;self.assertTrue(policy.idle());self.assertFalse(policy.idle())
        self.assertEqual(backend.clears,1)

    def test_missing_api_does_not_fail(self):
        policy=worker.MlxMemory(object(),write=lambda _:None)
        self.assertFalse(policy.apply_limit());self.assertFalse(policy.release('done'))

BOOT = r'''
import sys,types,weakref,time,hashlib
from pathlib import Path
sys.path.insert(0,sys.argv[1])
objects=weakref.WeakSet()
class Engine:
    def __init__(self,*args): pass
class Generation:
    def __init__(self,engine,prompt,schema=None,thinking=False,prefix='',**kwargs):
        self.identity=hashlib.sha256(prompt.encode()).hexdigest()
        self.wire=prefix;self.text=prefix;self.thinking_count=0;self.final_count=0
        self.slow=prompt=='slow';objects.add(self)
    def step(self):
        time.sleep(.005);self.wire+='x';self.text=self.wire;self.final_count+=1
        return 'done' if not self.slow and self.final_count>=3 else 'running'
    def save(self,path): Path(path).write_text('checkpoint')
    @classmethod
    def restore(cls,*args): raise AssertionError('hot resume expected')
engine=types.ModuleType('engine');engine.Engine=Engine;engine.Generation=Generation
sys.modules['engine']=engine
import worker
class Backend:
    def set_cache_limit(self,value): return 100
    def get_active_memory(self): return len(objects)*100
    def get_cache_memory(self): return 0
    def get_peak_memory(self): return 200
    def clear_cache(self): pass
worker.discover_mlx=lambda:Backend()
sys.argv=['worker','--model','fake','--state-directory',sys.argv[2]]
worker.main()
'''

class WorkerLifecycleTests(unittest.TestCase):
    def test_pause_interleave_cancel_and_release(self):
        with tempfile.TemporaryDirectory() as directory:
            process=subprocess.Popen([sys.executable,'-B','-c',BOOT,str(ROOT),directory],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            events=queue.Queue()
            def read():
                for line in process.stdout: events.put(json.loads(line))
            thread=threading.Thread(target=read,daemon=True);thread.start()
            def send(**command):
                process.stdin.write(json.dumps(command)+'\n');process.stdin.flush()
            def until(kind,identity=None):
                for _ in range(100):
                    event=events.get(timeout=5)
                    if event['event']==kind and (identity is None or event.get('id')==identity): return event
                self.fail('event not found: '+kind)
            try:
                self.assertEqual(until('ready')['version'],2)
                self.assertEqual(until('memory')['activeBytes'],0)
                send(op='generate',id='a',prompt='slow')
                until('snapshot','a');send(op='pause',id='a',controlID='pause-a')
                receipt=until('paused','a')
                self.assertEqual(receipt['controlID'],'pause-a')
                self.assertEqual(receipt['state'],'saved')
                send(op='generate',id='b',prompt='fast')
                until('done','b')
                # Completed task freed; paused task remains recoverable.
                self.assertEqual(until('memory')['activeBytes'],100)
                send(op='pause',id='b',controlID='pause-completed')
                receipt=until('paused','b')
                self.assertEqual(receipt['controlID'],'pause-completed')
                self.assertEqual(receipt['state'],'completed')
                send(op='pause',id='unknown',controlID='pause-absent')
                self.assertEqual(until('paused','unknown')['state'],'absent')
                send(op='ack',id='b');until('ack','b')
                send(op='generate',id='a2',prompt='slow',prefix='x')
                self.assertTrue(until('snapshot','a2')['recovered'])
                send(op='cancel',id='a2')
                self.assertEqual(until('memory')['activeBytes'],0)
                until('cancel','a2')
                send(op='shutdown',controlID='shutdown-worker')
                receipt=until('shutdown')
                self.assertEqual(receipt['controlID'],'shutdown-worker')
                self.assertEqual(receipt['state'],'ready_to_exit')
                self.assertEqual(process.wait(timeout=5),0)
            finally:
                if process.poll() is None: process.kill();process.wait()
                process.stdin.close();process.stdout.close();process.stderr.close()

if __name__=='__main__': unittest.main()
