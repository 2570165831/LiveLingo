"""Atomic checkpoint and result-only replay checks with real MLX tensors."""
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

import mlx.core as mx
from mlx_lm.models.cache import ArraysCache, KVCache, save_prompt_cache
from safetensors import safe_open

from engine import Generation, OutputBudgetExceeded


class Detokenizer:
    def reset(self): self.text = ''
    def add_token(self, token): self.text += chr(token)
    def finalize(self): pass


class Tokenizer:
    eos_token_ids = {0}

    def encode(self, text, add_special_tokens=False):
        return [ord(c) for c in text]

    @property
    def detokenizer(self):
        return Detokenizer()


class CheckpointTests(unittest.TestCase):
    def test_final_budget_has_a_structured_error_and_never_commits_partial_text(self):
        generation = Generation(self.engine, 'test', seed=42, final_budget=1)
        self.engine.model.return_value = mx.array([[[0.0, 1.0]]])
        with self.assertRaises(OutputBudgetExceeded) as caught:
            generation.step()
        self.assertEqual(caught.exception.code, 'output_budget_exhausted')
        self.assertFalse(generation.done)
        self.assertEqual(generation.final_count, 1)

    def setUp(self):
        model = Mock()
        model.make_cache.return_value = []
        self.engine = types.SimpleNamespace(model=model, tokenizer=Tokenizer(),
                                             identity='checkpoint-test-model')
        self.directory = tempfile.TemporaryDirectory(prefix='ll-checkpoint-test-')
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'state.safetensors'

    def generation(self, done=False):
        generation = Generation(self.engine, 'synthetic lesson', prefix='先前：', seed=42)
        attention = KVCache()
        values = mx.arange(256).reshape(1, 1, 128, 2)
        attention.update_and_fetch(values, values)
        recurrent = ArraysCache(1)
        recurrent[0] = mx.ones((512, 512))
        generation.cache = [attention, recurrent]
        generation.ids = [ord(c) for c in '中文🧪\n结果'] + ([0] if done else [])
        generation.final_ids = [t for t in generation.ids if t]
        generation.final_count = len(generation.final_ids)
        generation.thinking_count = 17
        generation.pending = generation.ids[-1:]
        generation.done = done
        for token in generation.final_ids:
            generation.detokenizer.add_token(token)
        if done:
            generation.detokenizer.finalize()
        mx.eval([c.state for c in generation.cache])
        return generation

    def assert_same_result(self, first, second):
        for attribute in ('ids', 'final_ids', 'pending', 'wire', 'text', 'phase',
                          'final_count', 'thinking_count', 'done', 'spec'):
            self.assertEqual(getattr(first, attribute), getattr(second, attribute), attribute)
        self.assertEqual(first.key.tolist(), second.key.tolist())

    def test_completed_record_replays_exact_result_without_tensors_or_model_step(self):
        generation = self.generation(done=True)
        generation.save(self.path)
        self.assertLess(self.path.stat().st_size, 4096)
        with safe_open(self.path, framework='numpy') as record:
            self.assertEqual(list(record.keys()), [])
        restored = Generation.restore(self.engine, self.path, generation.identity)
        self.assert_same_result(generation, restored)
        self.assertEqual(restored.cache, [])
        self.assertEqual(restored.step(), 'done')
        self.engine.model.assert_not_called()

    def test_unfinished_record_preserves_attention_and_recurrent_state(self):
        generation = self.generation()
        generation.save(self.path)
        self.assertGreater(self.path.stat().st_size, 1024**2)
        restored = Generation.restore(self.engine, self.path, generation.identity)
        self.assert_same_result(generation, restored)
        self.assertEqual(restored.cache[0].offset, 128)
        for original, loaded in zip(generation.cache, restored.cache):
            self.assertIs(type(original), type(loaded))
            for left, right in zip(original.state, loaded.state):
                self.assertTrue(mx.array_equal(left, right).item())

    def test_legacy_completed_tensor_record_remains_readable(self):
        generation = self.generation(done=True)
        generation.save(self.path)
        with safe_open(self.path, framework='numpy') as record:
            state = record.metadata()['livelingo.completed']
        save_prompt_cache(str(self.path), generation.cache, {'generation': state})
        restored = Generation.restore(self.engine, self.path, generation.identity)
        self.assert_same_result(generation, restored)
        self.assertEqual(restored.step(), 'done')
        self.engine.model.assert_not_called()

    def test_result_only_record_requires_complete_state_and_matching_identity(self):
        generation = self.generation(done=True)
        generation.save(self.path)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            Generation.restore(self.engine, self.path, 'another-request')
        with safe_open(self.path, framework='numpy') as record:
            state = json.loads(record.metadata()['livelingo.completed'])
        state['done'] = False
        mx.save_safetensors(str(self.path), {}, {'livelingo.completed': json.dumps(state)})
        with self.assertRaisesRegex(ValueError, 'not complete'):
            Generation.restore(self.engine, self.path, generation.identity)

    def test_interrupted_result_save_keeps_previous_resumable_checkpoint(self):
        generation = self.generation()
        generation.save(self.path)
        previous = self.path.read_bytes()
        generation.done = True

        def fail_after_partial_write(path, *args):
            Path(path).write_bytes(b'incomplete write')
            raise OSError('simulated write failure')

        with patch('engine.mx.save_safetensors', side_effect=fail_after_partial_write):
            with self.assertRaisesRegex(OSError, 'simulated write failure'):
                generation.save(self.path)
        self.assertEqual(self.path.read_bytes(), previous)
        restored = Generation.restore(self.engine, self.path, generation.identity)
        self.assertFalse(restored.done)
        self.assertEqual(restored.cache[0].offset, 128)


if __name__ == '__main__':
    unittest.main()
