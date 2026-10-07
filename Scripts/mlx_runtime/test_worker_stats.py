"""Token statistics from the real worker with fake engines; no MLX imports."""
import ast
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import types
import unittest

ROOT = Path(__file__).resolve().parent

BOOT = r'''
import hashlib
import sys
import types

class NoModelImports:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in {'mlx', 'mlx_lm', 'torch', 'transformers', 'huggingface_hub'}:
            raise AssertionError('Model backend import is forbidden in this test')

sys.meta_path.insert(0, NoModelImports())
sys.path.insert(0, sys.argv[1])

class Engine:
    def __init__(self, *args):
        pass

class Generation:
    def __init__(self, engine, prompt, schema=None, thinking=False, prefix='', **kwargs):
        self.identity = hashlib.sha256(prompt.encode()).hexdigest()
        self.wire = '  answer  '
        self.text = 'answer'
        self.thinking_count = 3
        self.final_count = 5
        if prompt in ('cold', 'warm', 'input-only'):
            self.input_tokens = 11
        if prompt in ('cold', 'warm', 'reuse-only'):
            self.reused_prefix_tokens = 7 if prompt == 'warm' else 0
        if prompt == 'unknown':
            self.input_tokens = self.reused_prefix_tokens = None

    def step(self):
        return 'done'

    def save(self, path):
        raise AssertionError('Text statistics must not create a checkpoint')

    @classmethod
    def restore(cls, *args):
        raise AssertionError('This test must not restore a checkpoint')

engine = types.ModuleType('engine')
engine.Engine, engine.Generation = Engine, Generation
sys.modules['engine'] = engine
schemas = types.ModuleType('schemas')
schemas.note_schema = schemas.review_schema = lambda data: {}
sys.modules['schemas'] = schemas

import worker
worker.discover_mlx = lambda: None
sys.argv = ['worker', '--model', 'fake', '--state-directory', sys.argv[2],
            '--idle-cache-release-seconds', '0', '--idle-model-seconds', '0']
worker.main()
'''


class WorkerStatsTests(unittest.TestCase):
    def setUp(self):
        output = os.environ.get('LIVELINGO_WORKER_STATS_OUTPUT')
        if output:
            self.path = Path(output) / self._testMethodName
            self.path.mkdir(parents=True, exist_ok=False)
        else:
            temporary = tempfile.TemporaryDirectory(prefix='livelingo-worker-stats-')
            self.addCleanup(temporary.cleanup)
            self.path = Path(temporary.name)
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        environment.pop('LIVELINGO_SCOREBOARD_TIMINGS', None)
        self.process = subprocess.Popen(
            [sys.executable, '-B', '-c', BOOT, str(ROOT), str(self.path / 'state')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        self.events = queue.Queue()
        self.reader = threading.Thread(target=self.read_events, daemon=True)
        self.addCleanup(self.close_worker)
        self.reader.start()
        self.assertEqual(self.until('ready')['version'], 2)

    def read_events(self):
        try:
            for line in self.process.stdout:
                try:
                    self.events.put(json.loads(line))
                except Exception as error:
                    self.events.put(error)
        finally:
            self.events.put(None)

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()

    def until(self, kind, request_id=None):
        for _ in range(30):
            event = self.events.get(timeout=3)
            self.assertIsNotNone(event, 'Worker exited before ' + kind)
            if isinstance(event, Exception):
                raise event
            self.assertNotEqual(event['event'], 'error', event)
            if event['event'] == kind and (request_id is None or event.get('id') == request_id):
                return event
        self.fail('Missing worker event: ' + kind)

    def close_worker(self):
        try:
            if self.process.poll() is None:
                self.send(op='shutdown', controlID='stats-shutdown')
                receipt = self.until('shutdown')
                self.assertEqual(receipt['state'], 'ready_to_exit')
                self.assertEqual(receipt['controlID'], 'stats-shutdown')
            self.assertEqual(self.process.wait(timeout=3), 0)
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=3)
            self.reader.join(timeout=1)
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                stream.close()

    def done(self, prompt):
        self.send(op='generate', id=prompt, prompt=prompt)
        event = self.until('done', prompt)
        legacy = {key: value for key, value in event.items()
                  if key not in ('inputTokens', 'reusedPrefixTokens')}
        self.assertEqual(legacy, dict(event='done', id=prompt, wire='  answer  ',
                                      text='answer', thinkingTokens=3, finalTokens=5))
        (self.path / ('done-' + prompt + '.json')).write_text(json.dumps(event) + '\n')
        self.send(op='ack', id=prompt, controlID='ack-' + prompt)
        self.assertEqual(self.until('ack', prompt)['state'], 'released')
        return event

    def test_done_reports_input_and_cold_or_reused_prefix_counts(self):
        for prompt, reused in (('cold', 0), ('warm', 7)):
            with self.subTest(prompt=prompt):
                event = self.done(prompt)
                self.assertEqual(event['inputTokens'], 11)
                self.assertEqual(event['reusedPrefixTokens'], reused)

    def test_legacy_generation_without_statistics_remains_compatible(self):
        event = self.done('legacy')
        self.assertIsNone(event['inputTokens'])
        self.assertIsNone(event['reusedPrefixTokens'])

    def test_partial_or_unknown_statistics_do_not_turn_missing_values_into_zero(self):
        for prompt, expected in (('input-only', (11, None)),
                                 ('reuse-only', (None, 0)), ('unknown', (None, None))):
            with self.subTest(prompt=prompt):
                event = self.done(prompt)
                self.assertEqual((event['inputTokens'], event['reusedPrefixTokens']), expected)


class GenerationInputStatsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise the production constructor without importing MLX or loading
        # weights. Only the tokenizer/cache interfaces are supplied by fakes.
        tree = ast.parse((ROOT / 'engine.py').read_text())
        generation = next(node for node in tree.body
                          if isinstance(node, ast.ClassDef) and node.name == 'Generation')
        step = next(node for node in tree.body
                    if isinstance(node, ast.Assign)
                    and any(isinstance(name, ast.Name) and name.id == 'PREFILL_STEP'
                            for name in node.targets))
        namespace = dict(hashlib=hashlib, json=json,
                         PREFILL_STEP=ast.literal_eval(step.value),
                         mx=types.SimpleNamespace(random=types.SimpleNamespace(key=lambda seed: seed)),
                         make_prompt_cache=lambda model: [])
        exec(compile(ast.Module(body=[generation], type_ignores=[]), str(ROOT / 'engine.py'), 'exec'),
             namespace)
        cls.generation = namespace['Generation']

    def engine(self, prefix_cache=None):
        detokenizer = types.SimpleNamespace(reset=lambda: None)
        tokenizer = types.SimpleNamespace(
            encode=lambda text, add_special_tokens: list(text.encode()), detokenizer=detokenizer)
        return types.SimpleNamespace(identity='fake', model=object(), tokenizer=tokenizer,
                                     prefix_cache=prefix_cache)

    def test_input_count_is_captured_before_cache_reuse_and_pending_mutation(self):
        prefix_cache = types.SimpleNamespace(max_tokens=256,
                                             fetch=lambda tokens, low_priority: ([], 256))
        generation = self.generation(self.engine(prefix_cache), 'x' * 513, seed=0)
        self.assertEqual(generation.input_tokens, 513)
        self.assertEqual(generation.reused_prefix_tokens, 256)
        self.assertEqual(len(generation.pending), 257)
        generation.pending = [42]
        self.assertEqual(generation.input_tokens, 513)

    def test_input_count_includes_the_initial_output_prefix(self):
        generation = self.generation(self.engine(), 'prompt', prefix='prefix', seed=0)
        self.assertEqual(generation.input_tokens, len('promptprefix'.encode()))
        self.assertEqual(generation.reused_prefix_tokens, 0)
        self.assertEqual(generation.VERSION, 2)


if __name__ == '__main__':
    unittest.main()
