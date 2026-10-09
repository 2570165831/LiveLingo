import unittest
from types import SimpleNamespace

try:
    from . import align
except ImportError:
    import align


class AlignmentTests(unittest.TestCase):
    def test_reference_languages_are_from_notes_and_changes(self):
        doc = {"turns": [{"header": "Mr. Example (spoke in French)",
                           "text": "One two. (spoke in English) Three four."}]}
        actual = align.official_words(doc)
        self.assertEqual([r["language"] for r in actual], ["fr", "fr", "en", "en"])

    def test_subwords_keep_word_times(self):
        tokens = [SimpleNamespace(text=" hello", start=1., end=2.),
                  SimpleNamespace(text=" wor", start=2., end=3.),
                  SimpleNamespace(text="ld!", start=3., end=4.)]
        result = align.timed_words(tokens, 10.)
        self.assertEqual(result, [{"word": "hello", "start_s": 11., "end_s": 12.},
                                  {"word": "world", "start_s": 12., "end_s": 14.}])

    def test_short_accidental_matches_do_not_anchor(self):
        doc = {"turns": [{"header": "The President", "text": "one two three"}]}
        observed = [{"word": w, "start_s": i, "end_s": i + 1}
                    for i, w in enumerate(["one", "two", "three"])]
        anchors, _ = align.make_anchors(doc, observed)
        self.assertEqual(anchors, [])

    def test_bracketed_interior_and_boundary_exclusion(self):
        anchors = [{"time_s": t, "language": "fr" if t < 20 else "en"}
                   for t in [0, 5, 10, 15, 20, 25]]
        self.assertEqual(align.label_window(6, 12, anchors)[:2], ("fr", True))
        self.assertFalse(align.label_window(15, 19, anchors)[1])
        self.assertFalse(align.label_window(26, 28, anchors)[1])

    def test_long_anchor_gap_is_not_ground_truth(self):
        anchors = [{"time_s": 0, "language": "en"}, {"time_s": 100, "language": "en"}]
        self.assertFalse(align.label_window(40, 48, anchors)[1])


if __name__ == "__main__":
    unittest.main()
