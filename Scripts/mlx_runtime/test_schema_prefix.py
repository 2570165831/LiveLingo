"""Schema-cache admission must preserve foreground state and resume boundaries."""
import importlib.util
import tempfile
from pathlib import Path
import types
import unittest
from unittest.mock import Mock

# Check optional packages before any runtime import. Installed-but-broken APIs
# must still fail, and every synthetic tensor must run on the CPU.
for dependency in ('mlx', 'mlx_lm', 'outlines_core', 'safetensors'):
    if importlib.util.find_spec(dependency) is None:
        raise unittest.SkipTest(f'CPU tensor tests require optional dependency {dependency}')

import mlx.core as mx
mx.set_default_device(mx.cpu)
from mlx_lm.models.cache import ArraysCache, KVCache
from engine import Generation, PromptPrefixCache


def states(value=1, length=256):
    attention = KVCache()
    data = mx.full((1, 1, length, 2), value)
    attention.update_and_fetch(data, data)
    recurrent = ArraysCache(1)
    recurrent[0] = mx.array([value])
    mx.eval(attention.state, recurrent.state)
    return [attention, recurrent]


class SchemaPrefixAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.a, self.b, self.c, self.d = [tuple(range(i, i + 256)) for i in (0, 300, 600, 900)]

    def test_note_cannot_evict_two_foreground_snapshots(self):
        cache = PromptPrefixCache()
        cache.remember(self.a, states(7))
        cache.remember(self.b, states(19))
        before = cache.nbytes
        self.assertFalse(cache.remember(self.c, states(41), low_priority=True))
        self.assertEqual(cache.nbytes, before)
        for key, value in [(self.a, 7), (self.b, 19)]:
            restored, count = cache.fetch(key + (999,))
            self.assertEqual(count, 256)
            self.assertEqual(restored[1][0].tolist(), [value])

    def test_foreground_evicts_note_even_when_note_was_most_recent(self):
        cache = PromptPrefixCache()
        cache.remember(self.a, states())
        cache.remember(self.b, states(), low_priority=True)
        cache.fetch(self.b + (999,), low_priority=True)
        cache.remember(self.c, states())
        self.assertEqual(cache.fetch(self.a + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.b + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.c + (999,))[1], 256)

    def test_note_hit_does_not_change_foreground_eviction_order(self):
        cache = PromptPrefixCache()
        cache.remember(self.a, states())
        cache.remember(self.b, states())
        cache.fetch(self.a + (999,), low_priority=True)
        cache.remember(self.c, states())
        self.assertEqual(cache.fetch(self.a + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.b + (999,))[1], 256)

    def test_byte_limit_rejects_note_without_discarding_existing_state(self):
        small = states()
        size = sum(item.nbytes for item in small)
        cache = PromptPrefixCache(max_bytes=size * 2)
        cache.remember(self.a, small)
        cache.remember(self.b, small, low_priority=True)
        before = cache.nbytes
        self.assertFalse(cache.remember(self.c, states(length=512), low_priority=True))
        self.assertEqual(cache.nbytes, before)
        self.assertEqual(cache.fetch(self.a + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.b + (999,), low_priority=True)[1], 256)

    def test_notes_can_replace_each_other_without_discarding_foreground(self):
        cache = PromptPrefixCache()
        cache.remember(self.a, states())
        cache.remember(self.b, states(), low_priority=True)
        cache.remember(self.c, states(), low_priority=True)
        self.assertEqual(cache.fetch(self.a + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.b + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.c + (999,), low_priority=True)[1], 256)
        self.assertLessEqual(cache.nbytes, cache.max_bytes)

    def test_restore_never_fetches_a_fresh_input_snapshot(self):
        tokenizer = Mock()
        tokenizer.encode.return_value = list(range(768)) + [999]
        model = Mock()
        model.make_cache.return_value = []
        cache = PromptPrefixCache()
        engine = types.SimpleNamespace(tokenizer=tokenizer, model=model,
                                       identity='synthetic-model', prefix_cache=cache)
        generation = Generation(engine, 'long input', seed=42)
        generation.cache = states()
        generation.pending = tokenizer.encode.return_value[256:]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'checkpoint.safetensors'
            generation.save(path)
            cache.fetch = Mock(side_effect=AssertionError('Restore fetched fresh input state'))
            restored = Generation.restore(engine, path, generation.identity)
            self.assertEqual(restored.pending, generation.pending)
            self.assertIsNone(restored._prefix_cache)
            cache.fetch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
