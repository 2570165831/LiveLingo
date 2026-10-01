"""Prefix reuse regression tests with real MLX attention and recurrent caches.

No weights are loaded. The separate benchmark compares real-model output tokens.
"""
import types
import tempfile
from pathlib import Path
import unittest
from unittest.mock import Mock

import mlx.core as mx
from mlx_lm.models.cache import ArraysCache, KVCache

from engine import Generation, PromptPrefixCache


class PrefixCacheTests(unittest.TestCase):
    def states(self):
        attention = KVCache()
        values = mx.arange(512).reshape(1, 1, 256, 2)
        attention.update_and_fetch(values, values)
        recurrent = ArraysCache(1)
        recurrent[0] = mx.array([3, 7])
        mx.eval(attention.state, recurrent.state)
        return [attention, recurrent]

    def test_original_and_interleaved_requests_cannot_mutate_snapshot(self):
        tokens = list(range(256))
        states = self.states()
        prefix = PromptPrefixCache()
        self.assertTrue(prefix.remember(tokens, states))
        states[0].update_and_fetch(mx.zeros((1, 1, 1, 2)), mx.zeros((1, 1, 1, 2)))
        states[1][0][0] = 99
        first, count = prefix.fetch(tokens + [999])
        self.assertEqual(count, 256)
        self.assertEqual(first[0].offset, 256)
        self.assertEqual(first[0].state[0][0, 0, -1].tolist(), [510, 511])
        self.assertEqual(first[1][0].tolist(), [3, 7])
        first[0].update_and_fetch(mx.ones((1, 1, 1, 2)), mx.ones((1, 1, 1, 2)))
        first[1][0][1] = 88
        second, _ = prefix.fetch(tokens + [777])
        self.assertEqual(second[0].offset, 256)
        self.assertEqual(second[1][0].tolist(), [3, 7])

    def test_only_exact_prefixes_with_remaining_input_are_reused(self):
        tokens = list(range(256))
        prefix = PromptPrefixCache()
        prefix.remember(tokens, self.states())
        self.assertEqual(prefix.fetch(tokens), (None, 0))
        self.assertEqual(prefix.fetch(tokens[:-1]), (None, 0))
        self.assertEqual(prefix.fetch(tokens[:-1] + [-1, 999]), (None, 0))
        self.assertEqual(prefix.fetch(tokens + [999])[1], 256)

    def test_snapshot_is_bounded_and_replaced_not_accumulated(self):
        states = self.states()
        size = sum(state.nbytes for state in states)
        prefix = PromptPrefixCache(max_bytes=size - 1)
        self.assertFalse(prefix.remember(range(256), states))
        self.assertEqual(prefix.nbytes, 0)
        prefix = PromptPrefixCache(max_bytes=size)
        self.assertFalse(prefix.remember(range(255), states))
        self.assertFalse(prefix.remember(range(768), states))
        self.assertTrue(prefix.remember(range(256), states))
        self.assertTrue(prefix.remember(range(256, 512), states))
        self.assertEqual(prefix.fetch(list(range(256)) + [999]), (None, 0))
        self.assertEqual(prefix.nbytes, size)

    def test_partial_resume_and_thinking_do_not_use_translation_cache(self):
        tokenizer = Mock()
        tokenizer.encode.return_value = list(range(256)) + [999]
        model = Mock()
        model.make_cache.return_value = []
        prefix = PromptPrefixCache()
        prefix.remember(range(256), self.states())
        engine = types.SimpleNamespace(tokenizer=tokenizer, model=model,
                                       identity='synthetic-model', prefix_cache=prefix)
        plain = Generation(engine, 'translation')
        self.assertEqual(plain.reused_prefix_tokens, 256)
        self.assertEqual(plain.pending, [999])
        for options in ({'thinking': True}, {'prefix': 'saved output'}, {'_use_prefix_cache': False}):
            generation = Generation(engine, 'translation', **options)
            self.assertEqual(generation.reused_prefix_tokens, 0)
            self.assertEqual(len(generation.pending), 257)
        self.assertEqual(prefix.fetch(list(range(256)) + [999])[1], 256)

    def test_mid_prefill_checkpoint_cannot_publish_a_mislabeled_prefix(self):
        tokenizer = Mock()
        tokens = list(range(768)) + [999]
        tokenizer.encode.return_value = tokens
        model = Mock()
        model.make_cache.return_value = []
        prefix = PromptPrefixCache()
        engine = types.SimpleNamespace(tokenizer=tokenizer, model=model,
                                       identity='synthetic-model', prefix_cache=prefix)
        generation = Generation(engine, 'long input', seed=42)
        generation.cache = self.states()  # checkpoint already consumed 256 tokens
        generation.pending = tokens[256:]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'checkpoint.safetensors'
            generation.save(path)
            restored = Generation.restore(engine, path, generation.identity)
            self.assertEqual(restored.step(), 'prefill')
            self.assertEqual(restored.step(), 'prefill')
        fresh = Generation(engine, 'long input', seed=42)
        self.assertEqual(fresh.reused_prefix_tokens, 0)


if __name__ == '__main__':
    unittest.main()
