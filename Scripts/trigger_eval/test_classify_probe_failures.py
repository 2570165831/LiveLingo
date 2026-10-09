"""CPU-only checks that probe-failure classification persists no text."""
import json
import unittest

try:
    from . import classify_probe_failures as classifier
except ImportError:
    import classify_probe_failures as classifier

CHECK = {"labels": frozenset({"Chinese", "English", "None"}), "heads": {7: ["Chinese"], 8: ["English"]}}


class ClassificationTests(unittest.TestCase):
    def test_error_class_uses_fixed_service_messages_only(self):
        self.assertEqual(classifier.error_class(ValueError("Unparsed language head")), "Unparsed language head")
        self.assertEqual(classifier.error_class(ValueError("free text 123")), "ValueError:message_omitted")
        self.assertEqual(classifier.error_class(RuntimeError("Unparsed language head")), "RuntimeError:message_omitted")

    def test_head_shape_names_only_exact_language_names(self):
        shape = classifier.describe_head([5, 6], True, lambda tokens: " Cantonese", CHECK)
        self.assertEqual(shape["known_language_name"], "Cantonese")
        self.assertTrue(shape["leading_space"])
        self.assertFalse(shape["label_in_supported_set"])
        self.assertEqual(shape["head_token_count"], 2)
        self.assertEqual(shape["first_token_supported_label_count"], 0)

    def test_head_shape_never_contains_other_decoded_text(self):
        secret = "lorem ipsum"
        shape = classifier.describe_head([7, 9, 9], False, lambda tokens: secret, CHECK)
        serialized = json.dumps(shape)
        self.assertNotIn("lorem", serialized)
        self.assertNotIn("ipsum", serialized)
        self.assertIsNone(shape["known_language_name"])
        self.assertFalse(shape["leading_space"])
        self.assertFalse(shape["terminated_by_asr_text_token"])
        self.assertTrue(shape["label_has_internal_whitespace"])
        self.assertEqual(shape["first_token_supported_label_count"], 1)

    def test_native_script_language_name_is_named_but_other_cjk_is_not(self):
        shape = classifier.describe_head([5, 6], True, lambda tokens: " 中文", CHECK)
        self.assertEqual(shape["known_language_name"], "中文")
        self.assertTrue(shape["label_cjk_ideographs_only"])
        shape = classifier.describe_head([5, 6], True, lambda tokens: " 你好", CHECK)
        self.assertIsNone(shape["known_language_name"])
        self.assertTrue(shape["label_cjk_ideographs_only"])
        self.assertNotIn("\\u4f60", json.dumps(shape))
        self.assertNotIn("你", json.dumps(shape, ensure_ascii=False))

    def test_empty_head_is_described(self):
        shape = classifier.describe_head([], True, lambda tokens: self.fail("decode called"), CHECK)
        self.assertEqual((shape["head_token_count"], shape["label_char_count"]), (0, 0))


if __name__ == "__main__":
    unittest.main()
