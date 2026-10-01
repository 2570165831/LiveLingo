"""Prefix reuse regression tests with real MLX attention and recurrent caches.

No weights are loaded. The separate benchmark compares real-model output tokens.
"""
import types
import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import Mock

import mlx.core as mx
from mlx_lm.models.cache import ArraysCache, KVCache

from engine import Generation, PromptPrefixCache, prefix_cache_for_model


class PrefixCacheTests(unittest.TestCase):
    def states(self, length=256):
        attention = KVCache()
        values = mx.arange(length * 2).reshape(1, 1, length, 2)
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

    def test_measured_9b_policy_keeps_note_and_translation_states_independent(self):
        config = {
            'model_type': 'qwen3_5',
            'text_config': {'hidden_size': 4096, 'num_hidden_layers': 32,
                            'head_dim': 256, 'num_key_value_heads': 4,
                            'linear_num_value_heads': 32},
            'quantization': {'bits': 4, 'group_size': 64},
        }
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'config.json').write_text(json.dumps(config))
            cache = prefix_cache_for_model(directory)
        translation = tuple(range(768))
        note = tuple(range(2000, 2256))
        self.assertTrue(cache.remember(translation, self.states(length=768)))
        self.assertTrue(cache.remember(note, self.states(), low_priority=True))
        for _ in range(3):
            state, count = cache.fetch(translation + (999,))
            self.assertEqual(count, 768)
            self.assertEqual(state[0].offset, 768)
            self.assertEqual(cache.fetch(note + (999,), low_priority=True)[1], 256)
        self.assertLessEqual(cache.nbytes, cache.max_bytes)
        self.assertEqual(len(cache._entries), 2)
        self.assertTrue(cache.remember(tuple(range(3000, 3256)), self.states(), low_priority=True))
        self.assertEqual(cache.fetch(translation + (999,))[1], 768)

    def test_other_and_unreadable_model_configs_keep_the_original_cache_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            for value in [None, '{broken', json.dumps({'model_type': 'qwen3_5', 'text_config': {'hidden_size': 2560}}),
                          json.dumps({'model_type': 'qwen3_5', 'text_config': None}),
                          json.dumps({'model_type': 'unknown'})]:
                if value is not None:
                    path.write_text(value)
                cache = prefix_cache_for_model(directory)
                self.assertTrue(cache.remember(range(512), self.states()))
                self.assertFalse(cache.remember(range(768), self.states()))
                self.assertLessEqual(cache.nbytes, 128 * 1024**2)

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
