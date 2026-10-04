"""Reject native-invalid LF titles during sampling, without repairing output."""
from collections import OrderedDict
import copy
import json
import unittest

import jsonschema
from outlines_core import Guide, Index
from outlines_core.json_schema import build_regex_from_schema

from grammar_vocabulary import build_vocabulary
from schemas import NOTE_TOPIC, build_generation_regex, note_schema, review_schema
from test_grammar_vocabulary import FakeTokenizer
from test_schemas import note, note_input, review_input


def accepts(index, raw):
    guide = Guide(index)
    for token in raw.encode('utf-8'):
        if token not in guide.get_tokens():
            return False
        guide.advance(token, return_tokens=False)
    return guide.is_finished() and 999 in guide.get_tokens()


class NoteTitleGrammarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = note_schema(note_input())
        cls.vocabulary = build_vocabulary(FakeTokenizer())
        cls.regex = build_generation_regex(cls.schema)
        cls.index = Index(cls.regex, cls.vocabulary)
        baseline = copy.deepcopy(cls.schema)
        baseline['oneOf'][0]['properties']['topic'] = {'type': 'string'}
        cls.baseline = Index(build_regex_from_schema(json.dumps(baseline)), cls.vocabulary)

    def check_title(self, title, expected):
        value = note()
        value['topic'] = title
        raw = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
        self.assertTrue(accepts(self.baseline, raw), title)
        self.assertEqual(accepts(self.index, raw), expected, title)
        self.assertEqual(jsonschema.Draft202012Validator(self.schema).is_valid(value), expected)

    def test_standalone_lf_is_blocked_including_last_character(self):
        for title in ('a\nb', '\na', 'a\n', 'a\n\r', 'a\r\n\nb', '\\n\n', 'a\\\nb'):
            with self.subTest(title=title):
                self.check_title(title, False)

    def test_crlf_retains_existing_swift_character_boundary(self):
        for title in ('a\r\nb', '\r\na', 'a\r\n', 'a\r\r\nb', 'a\r\n\r\nb', 'a\rb'):
            with self.subTest(title=title):
                self.check_title(title, True)

    def test_code_escapes_quotes_and_unicode_remain_exact(self):
        for title in ('literal \\n', 'literal \\u000a', 'C:\\new', 'x="quoted"',
                      'slash\\', '\\\\n', '中文𠮷👩‍💻e\u0301', 'a\tb', 'a\u2028b', 'a\u2029b'):
            with self.subTest(title=title):
                self.check_title(title, True)

    def test_body_context_and_followup_still_allow_lf(self):
        schema = note_schema(note_input(aliases=['q0']))
        value = note({'q0': {'state': '缺信息', 'sourceIDs': [], 'detail': 'a\nb'}})
        value['points'][0].update(text='line1\nline2', needsContext='a\nb')
        jsonschema.validate(value, schema)
        self.assertTrue(accepts(Index(build_generation_regex(schema), self.vocabulary),
                                json.dumps(value, ensure_ascii=False, separators=(',', ':'))))

    def test_invalid_json_and_encoded_lf_cannot_bypass(self):
        # Unicode escapes were already outside the generic string grammar.
        # Their rejection is not new coverage for the LF fix.
        template = json.dumps(note(), ensure_ascii=False, separators=(',', ':'))
        for title_wire in ('"a\\u000ab"', '"a\\u000Ab"', '"a"b"', '"a\\qb"', '"a\nb"'):
            raw = template.replace('"主题"', title_wire, 1)
            with self.subTest(raw=title_wire):
                self.assertFalse(accepts(self.baseline, raw))
                self.assertFalse(accepts(self.index, raw))

    def test_backslash_parity_does_not_confuse_code_with_newline(self):
        template = json.dumps(note(), ensure_ascii=False, separators=(',', ':'))
        for count in range(1, 9):
            raw = template.replace('"主题"', '"a' + '\\' * count + 'nb"', 1)
            with self.subTest(count=count):
                self.assertTrue(accepts(self.baseline, raw))
                self.assertEqual(accepts(self.index, raw), count % 2 == 0)

    def test_empty_branch_and_other_native_limits_are_not_changed(self):
        # These intentionally remain the Swift validator's responsibility.
        for title in ('', '  ', 'x' * 81, '<|marker|>'):
            self.check_title(title, True)
        empty = note(no_new_knowledge=True)
        # The empty branch deliberately places points before noNewKnowledge.
        ordered = {key: empty[key] for key in self.schema['oneOf'][1]['properties']}
        self.assertTrue(accepts(self.index, json.dumps(ordered, ensure_ascii=False,
                                                     separators=(',', ':'))))

    def test_schema_order_and_literal_schema_shaped_data_are_preserved(self):
        before = json.dumps(self.schema, ensure_ascii=False)
        self.assertEqual(build_generation_regex(self.schema), self.regex)
        self.assertEqual(json.dumps(self.schema, ensure_ascii=False), before)
        for schema in (review_schema(review_input()), {'const': NOTE_TOPIC}, {'enum': [NOTE_TOPIC]}):
            with self.subTest(schema=schema):
                self.assertEqual(build_generation_regex(schema),
                                 build_regex_from_schema(json.dumps(schema, ensure_ascii=False)))

    def test_unrecognized_negative_constraint_fails_instead_of_being_ignored(self):
        changed = copy.deepcopy(self.schema)
        changed['oneOf'][0]['properties']['topic']['maxLength'] = 80
        with self.assertRaisesRegex(ValueError, 'Unsupported negative constraint'):
            build_generation_regex(changed)

    def test_unsupported_applicators_cannot_hide_title_constraints(self):
        for key in ('dependentSchemas', 'dependencies', 'unevaluatedProperties',
                    'unevaluatedItems', 'additionalItems'):
            with self.subTest(key=key):
                value = {'x': NOTE_TOPIC} if key in ('dependentSchemas', 'dependencies') else NOTE_TOPIC
                with self.assertRaisesRegex(ValueError, 'Unsupported generation schema keyword'):
                    build_generation_regex({'type': 'object', key: value})

    def test_engine_uses_the_constraint_and_reuses_its_index(self):
        # Uses the real Engine.index path, without constructing a model.
        from engine import Engine
        engine = Engine.__new__(Engine)
        engine.indices = OrderedDict()
        engine.vocabulary = self.vocabulary
        first = engine.index(self.schema)
        self.assertIs(engine.index(self.schema), first)
        value = note()
        value['topic'] = 'left\nright'
        self.assertFalse(accepts(first, json.dumps(value, ensure_ascii=False, separators=(',', ':'))))
        value['topic'] = 'left\\nright'
        self.assertTrue(accepts(first, json.dumps(value, ensure_ascii=False, separators=(',', ':'))))


if __name__ == '__main__':
    unittest.main()
