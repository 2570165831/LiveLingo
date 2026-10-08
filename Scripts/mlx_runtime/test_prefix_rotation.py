"""Exact prefix reuse across task rotation, with real MLX cache objects."""
import importlib.util
import unittest

# Check optional packages before any runtime import. Installed-but-broken APIs
# must still fail, and every synthetic tensor must run on the CPU.
for dependency in ('mlx', 'mlx_lm', 'outlines_core', 'safetensors'):
    if importlib.util.find_spec(dependency) is None:
        raise unittest.SkipTest(f'CPU tensor tests require optional dependency {dependency}')

import mlx.core as mx
mx.set_default_device(mx.cpu)
from mlx_lm.models.cache import ArraysCache, KVCache

from engine import PromptPrefixCache


def states(length=256, value=7):
    attention = KVCache()
    values = mx.arange(length * 2).reshape(1, 1, length, 2)
    attention.update_and_fetch(values, values)
    recurrent = ArraysCache(1)
    recurrent[0] = mx.array([value, value + 1])
    mx.eval(attention.state, recurrent.state)
    return [attention, recurrent]


class PrefixRotationTests(unittest.TestCase):
    a = tuple(range(256))
    b = tuple(range(256, 512))
    c = tuple(range(512, 768))

    def test_alternating_tasks_reuse_their_own_exact_states(self):
        cache = PromptPrefixCache()
        cache.remember(self.a, states(value=7))
        cache.remember(self.b, states(value=19))
        for key, value in [(self.a, 7), (self.b, 19), (self.a, 7), (self.b, 19)]:
            restored, count = cache.fetch(key + (999,))
            self.assertEqual(count, 256)
            if restored is not None:
                self.assertEqual(restored[0].offset, 256)
                self.assertEqual(restored[1][0].tolist(), [value, value + 1])

    def test_a_hit_keeps_that_entry_when_a_third_task_arrives(self):
        cache = PromptPrefixCache()
        for key in [self.a, self.b]: cache.remember(key, states())
        cache.fetch(self.a + (999,))
        cache.remember(self.c, states())
        self.assertEqual(cache.fetch(self.a + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.b + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.c + (999,))[1], 256)

    def test_duplicate_publication_refreshes_recency_without_growing_bytes(self):
        cache = PromptPrefixCache()
        for key in [self.a, self.b]: cache.remember(key, states())
        before = cache.nbytes
        cache.remember(self.a, states())
        self.assertEqual(cache.nbytes, before)
        cache.remember(self.c, states())
        self.assertEqual(cache.fetch(self.a + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.b + (999,)), (None, 0))

    def test_total_byte_limit_applies_across_entries(self):
        snapshot = states()
        size = sum(x.nbytes for x in snapshot)
        cache = PromptPrefixCache(max_bytes=2 * size - 1)
        for key in [self.a, self.b, self.c]:
            self.assertTrue(cache.remember(key, snapshot))
            self.assertLessEqual(cache.nbytes, cache.max_bytes)
        self.assertEqual(cache.nbytes, size)
        self.assertEqual(cache.fetch(self.a + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.b + (999,)), (None, 0))
        self.assertEqual(cache.fetch(self.c + (999,))[1], 256)

    def test_longest_exact_boundary_wins_but_shorter_inputs_still_reuse(self):
        cache = PromptPrefixCache()
        long = tuple(range(512))
        cache.remember(self.a, states(value=7))
        cache.remember(long, states(length=512, value=19))
        restored, count = cache.fetch(long + (999,))
        self.assertEqual(count, 512)
        self.assertEqual(restored[0].offset, 512)
        self.assertEqual(restored[1][0].tolist(), [19, 20])
        restored, count = cache.fetch(self.a + (-1,))
        self.assertEqual(count, 256)
        if restored is not None: self.assertEqual(restored[1][0].tolist(), [7, 8])

    def test_returned_states_cannot_mutate_either_stored_task(self):
        original = states(value=7)
        cache = PromptPrefixCache()
        cache.remember(self.a, original)
        cache.remember(self.b, original)
        original[1][0][0] = 99
        restored, count = cache.fetch(self.a + (999,))
        self.assertEqual(count, 256)
        if restored is not None:
            restored[0].update_and_fetch(mx.ones((1, 1, 1, 2)), mx.ones((1, 1, 1, 2)))
            restored[1][0][1] = 88
        for key in [self.a, self.b]:
            restored, count = cache.fetch(key + (999,))
            self.assertEqual(count, 256)
            if restored is not None:
                self.assertEqual(restored[0].offset, 256)
                self.assertEqual(restored[1][0].tolist(), [7, 8])

    def test_oversize_rejection_does_not_discard_useful_tasks(self):
        snapshot = states()
        size = sum(x.nbytes for x in snapshot)
        cache = PromptPrefixCache(max_bytes=2 * size)
        for key in [self.a, self.b]: cache.remember(key, snapshot)
        self.assertFalse(cache.remember(self.c, snapshot * 3))
        for key in [self.a, self.b]: self.assertEqual(cache.fetch(key + (999,))[1], 256)
        self.assertEqual(cache.fetch(self.c + (999,)), (None, 0))


if __name__ == '__main__':
    unittest.main()
