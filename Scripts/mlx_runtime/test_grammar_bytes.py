"""Strict ByteLevel boundaries, especially unmapped Latin-1 characters."""
import unittest

from grammar_vocabulary import _byte_decoder, build_vocabulary
from test_grammar_vocabulary import FakeTokenizer


class ByteConversionBoundaryTests(unittest.TestCase):
    def test_every_invalid_latin1_character_is_rejected(self):
        valid = _byte_decoder()
        for value in range(256):
            character = chr(value)
            if character in valid:
                continue
            with self.subTest(value=value):
                class Tokenizer(FakeTokenizer):
                    def get_vocab(self):
                        return {**super().get_vocab(), 'a'+character+'z': 1200}
                with self.assertRaisesRegex(ValueError, 'non-ByteLevel BPE token'):
                    build_vocabulary(Tokenizer())

    def test_other_unmapped_unicode_and_surrogates_are_rejected(self):
        for character in ['\u0144', '中', '\ud800', '\udfff', '\uffff', '\U0010ffff']:
            with self.subTest(codepoint=ord(character)):
                class Tokenizer(FakeTokenizer):
                    def get_vocab(self):
                        return {**super().get_vocab(), 'a'+character+'z': 1200}
                with self.assertRaisesRegex(ValueError, 'non-ByteLevel BPE token'):
                    build_vocabulary(Tokenizer())

    def test_ordinary_added_tokens_keep_literal_spaces_newlines_and_unicode(self):
        literal = 'a b\n中🧪'
        class Tokenizer(FakeTokenizer):
            def __init__(self):
                super().__init__()
                self.definition['added_tokens'].append({'id': 1200, 'content': literal, 'special': False})
            def get_vocab(self):
                return {**super().get_vocab(), literal: 1200}
        vocabulary = build_vocabulary(Tokenizer())
        self.assertEqual(vocabulary.get(literal.encode('utf-8')), [1200])

    def test_unmapped_characters_in_special_tokens_are_still_excluded(self):
        class Tokenizer(FakeTokenizer):
            def get_vocab(self):
                return {**super().get_vocab(), '\x00\n中': 998}
        self.assertFalse(build_vocabulary(Tokenizer()).get('\x00\n中'.encode('utf-8')))


if __name__ == '__main__':
    unittest.main()
