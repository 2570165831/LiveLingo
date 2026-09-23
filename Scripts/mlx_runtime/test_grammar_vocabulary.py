"""Tokenizer-only regression tests; no MLX import or model weights required.

Set LIVELINGO_TEST_TOKENIZER to a local bundled model directory for full-vocab
tests. These use the real tokenizer's emitted IDs, including split UTF-8 bytes.
"""
import json
import os
import unittest

from outlines_core import Guide, Index
from outlines_core.json_schema import build_regex_from_schema

from grammar_vocabulary import _byte_decoder, build_vocabulary


class FakeTokenizer:
    eos_token_id = 999
    all_special_ids = [999, 998]

    def __init__(self):
        self.backend_tokenizer = self
        self.definition = {
            'model': {'type': 'BPE'}, 'decoder': {'type': 'ByteLevel'},
            'added_tokens': [
                {'id': 997, 'content': '😀', 'special': False},
                {'id': 998, 'content': '<special>', 'special': True},
            ],
        }

    def to_str(self):
        return json.dumps(self.definition)

    def get_vocab(self):
        vocab = {character: byte for character, byte in _byte_decoder().items()}
        vocab.update({'<eos>': 999, '<special>': 998, '😀': 997})
        return vocab


def accept_text(test, tokenizer, vocabulary, text):
    schema = {'type': 'object', 'properties': {'quote': {'const': text}},
              'required': ['quote'], 'additionalProperties': False}
    guide = Guide(Index(build_regex_from_schema(json.dumps(schema, ensure_ascii=False)), vocabulary))
    output = json.dumps({'quote': text}, ensure_ascii=False, separators=(',', ':'))
    for token in tokenizer.encode(output, add_special_tokens=False):
        test.assertIn(token, guide.get_tokens())
        guide.advance(token, return_tokens=False)
    test.assertIn(tokenizer.eos_token_id, guide.get_tokens())
    # EOS is a stop signal, not a grammar state transition (as in Engine.step).
    test.assertTrue(guide.is_finished())


class ByteVocabularyTests(unittest.TestCase):
    def test_alphabet_is_reversible_and_preserves_partial_utf8(self):
        decoder = _byte_decoder()
        self.assertEqual(len(decoder), 256)
        self.assertEqual(set(decoder.values()), set(range(256)))
        self.assertEqual(decoder['Ġ'], 32)
        self.assertEqual(decoder['Ċ'], 10)
        self.assertEqual(decoder['è'], 0xe8)
        vocabulary = build_vocabulary(FakeTokenizer())
        self.assertEqual(vocabulary.get(b'\xe8'), [0xe8])

    def test_added_tokens_are_literal_and_special_tokens_excluded(self):
        vocabulary = build_vocabulary(FakeTokenizer())
        self.assertEqual(vocabulary.get('😀'.encode()), [997])
        self.assertFalse(vocabulary.get(b'<special>'))
        self.assertFalse(vocabulary.get(b'<eos>'))
        self.assertEqual(vocabulary.get_eos_token_id(), 999)

    def test_rejects_other_decoder_encodings(self):
        tokenizer = FakeTokenizer()
        tokenizer.definition['decoder']['type'] = 'WordPiece'
        with self.assertRaisesRegex(ValueError, 'ByteLevel'):
            build_vocabulary(tokenizer)

    def test_mlx_style_wrapper(self):
        class Wrapper:
            def __init__(self):
                self._tokenizer = FakeTokenizer()

            def __getattr__(self, name):
                return getattr(self._tokenizer, name)

        self.assertEqual(build_vocabulary(Wrapper()).get(b'\xe8'), [0xe8])


@unittest.skipUnless(os.environ.get('LIVELINGO_TEST_TOKENIZER'), 'local tokenizer directory not supplied')
class BundledTokenizerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from transformers import AutoTokenizer
        cls.tokenizer = AutoTokenizer.from_pretrained(
            os.environ['LIVELINGO_TEST_TOKENIZER'], local_files_only=True)
        cls.vocabulary = build_vocabulary(cls.tokenizer)

    def test_chinese_rare_characters_chemistry_and_emoji(self):
        for text in ['课堂复查与蕈类', '𠮷龘鱻', 'Fe³⁺ + OH⁻ → Fe(OH)₃↓',
                     '🧪😀👩🏽‍🔬', '引号“示例”与换行\n第二行\\路径']:
            with self.subTest(text=text):
                accept_text(self, self.tokenizer, self.vocabulary, text)

    def test_raw_byte_coverage(self):
        for byte in range(256):
            self.assertTrue(self.vocabulary.get(bytes([byte])), hex(byte))


if __name__ == '__main__':
    unittest.main()
