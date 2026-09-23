"""Focused review-diagnostics tests; no model weights, MLX or user data needed."""
import json
import unittest

from review_diagnostics import (MAX_QUOTE_ID, bind_review_prompt, clean_detail, describe_json_error,
                                failure_line, generation_detail, parse_review_input,
                                review_input_problem, stage_error)


def quote(index, language='en', fragment=0, text='Source A.', **fields):
    entry = {'id': f'e{index}.{language}.{fragment}', 'language': language, 'text': text}
    entry.update(fields)
    return entry


def evidence(index, quotes=None, **fields):
    if quotes is None:
        quotes = [quote(index, 'en', text='Source A.'), quote(index, 'zh', text='原文甲。')]
    unit = {'index': index, 'quotes': quotes}
    unit.update(fields)
    return unit


def payload(points=None, units=None, **extra):
    data = {
        'reviewVersion': 2,
        'note': {'points': points if points is not None else [{'index': 0, 'text': '原笔记'}]},
        'evidence': units if units is not None else [evidence(0)],
    }
    data.update(extra)
    return data


def review_input(points=None, units=None):
    return json.dumps(payload(points, units), ensure_ascii=False, sort_keys=True)


class FailureLineTests(unittest.TestCase):
    def test_record_names_stage_code_and_field(self):
        line = failure_line('schema', 'missing_field', 'point text must be a string', field='note.points[2].text')
        self.assertTrue(line.startswith('review failure stage=schema code=missing_field'))
        self.assertIn('field=note.points[2].text', line)
        self.assertIn('detail=point text must be a string', line)

    def test_payload_like_detail_is_redacted_and_bounded(self):
        payload_text = json.dumps({'corrections': [{'text': '模型的原始回答' * 200}]}, ensure_ascii=False)
        line = failure_line('decode', 'invalid_json', payload_text)
        self.assertNotIn('模型的原始回答', line)
        self.assertIn('<redacted', line)
        long_line = failure_line('generation', 'generation_failed', 'x' * 5_000)
        self.assertLessEqual(len(long_line), 400)

    def test_field_values_cannot_smuggle_free_text(self):
        line = failure_line('schema', 'invalid_item', '', field='note.points[0]\n注入内容 ')
        self.assertNotIn('\n', line)
        self.assertNotIn('注入内容', line)

    def test_stage_error_is_a_value_error_with_structured_message(self):
        error = stage_error('prompt_binding', 'input_not_in_prompt', 'review input not found',
                            input_bytes=12, prompt_bytes=34)
        self.assertIsInstance(error, ValueError)
        self.assertIn('stage=prompt_binding', str(error))
        self.assertIn('input_bytes=12', str(error))


class InputProblemTests(unittest.TestCase):
    def test_whitespace_fragments_preserve_original_spacing(self):
        self.assertIsNone(review_input_problem(payload(units=[evidence(0, quotes=[quote(0, text=" " * 2400)])])))

    def test_valid_v2_input_has_no_problem(self):
        self.assertIsNone(review_input_problem(payload()))
        # 引文为空的证据仍然合法，只是不能作为引文来源。
        self.assertIsNone(review_input_problem(payload(units=[evidence(0, quotes=[])])))

    def test_missing_or_empty_structures_report_a_field(self):
        cases = [
            ({}, 'note'),
            ({'note': {'points': 'not-an-array'}, 'evidence': []}, 'note.points'),
            ({'note': {'points': [{'index': 0}]}, 'evidence': []}, 'note.points[0].text'),
            ({'note': {'points': [{'index': 0, 'text': 'ok'}]}}, 'evidence'),
            ({'note': {'points': [{'index': 0, 'text': 'ok'}]},
              'evidence': [{'index': 'zero', 'quotes': []}]}, 'evidence[0].index'),
            ({'note': {'points': [{'index': 0, 'text': 'ok'}]},
              'evidence': [{'index': 0, 'quotes': 'not-an-array'}]}, 'evidence[0].quotes'),
        ]
        for partial, expected_field in cases:
            data = {'reviewVersion': 2, **partial}
            problem = review_input_problem(data)
            self.assertIsNotNone(problem, data)
            self.assertEqual(problem[1], expected_field)
        # An empty point list still builds a valid (empty) review schema.
        self.assertIsNone(review_input_problem(payload(points=[])))

    def test_legacy_input_reports_a_compatibility_error(self):
        legacy = {'note': {'points': [{'index': 0, 'text': '原笔记'}]},
                  'evidence': [{'index': 0, 'english': 'Source A.', 'chinese': '原文甲。'}]}
        problem = review_input_problem(legacy)
        self.assertEqual(problem[0], 'legacy_input')
        self.assertEqual(problem[1], 'reviewVersion')
        self.assertNotIn('原笔记', problem[2])
        with self.assertRaises(ValueError) as error:
            parse_review_input(json.dumps(legacy, ensure_ascii=False))
        self.assertIn('stage=schema', str(error.exception))
        self.assertIn('code=legacy_input', str(error.exception))
        self.assertIn('field=reviewVersion', str(error.exception))
        self.assertNotIn('Source A.', str(error.exception))

    def test_other_versions_are_refused_explicitly(self):
        for version in (1, 3, '2', True, None):
            data = payload()
            data['reviewVersion'] = version
            problem = review_input_problem(data)
            self.assertIsNotNone(problem, version)
            self.assertEqual(problem[0], 'legacy_input' if version is None else 'unsupported_review_version')
            self.assertEqual(problem[1], 'reviewVersion')

    def test_mixed_legacy_and_v2_evidence_is_refused(self):
        mixed = payload(units=[{'index': 0, 'english': 'Source A.', 'chinese': '原文甲。',
                                'quotes': [quote(0)]}])
        problem = review_input_problem(mixed)
        self.assertEqual(problem[0], 'legacy_input')
        self.assertEqual(problem[1], 'evidence[0]')
        legacy_only = payload(units=[{'index': 0, 'english': 'Source A.', 'chinese': '原文甲。'}])
        self.assertEqual(review_input_problem(legacy_only)[0], 'legacy_input')
        self.assertEqual(review_input_problem(legacy_only)[1], 'evidence[0]')

    def test_quote_ids_must_be_unique_across_the_whole_input(self):
        data = payload(units=[evidence(0), evidence(1, quotes=[quote(0), quote(1, 'zh', text='原文乙。')])])
        problem = review_input_problem(data)
        self.assertIsNotNone(problem)
        self.assertEqual(problem[1], 'evidence[1].quotes[0].id')
        self.assertIn('unique', problem[2])

    def test_evidence_indexes_must_be_unique(self):
        data = payload(units=[evidence(0), evidence(0, quotes=[quote(1, 'en', text='Source C.')])])
        problem = review_input_problem(data)
        self.assertEqual(problem[1], 'evidence[1].index')
        self.assertIn('unique', problem[2])

    def test_quote_language_and_text_are_checked(self):
        cases = [
            (payload(units=[evidence(0, quotes=[quote(0, language='fr')])]), 'evidence[0].quotes[0].language'),
            (payload(units=[evidence(0, quotes=[{**quote(0), 'language': 2}])]), 'evidence[0].quotes[0].language'),
            (payload(units=[evidence(0, quotes=[quote(0, text='')])]), 'evidence[0].quotes[0].text'),
            (payload(units=[evidence(0, quotes=[quote(0, text=None)])]), 'evidence[0].quotes[0].text'),
            (payload(units=[evidence(0, quotes=[{'id': 'e0.en.0', 'language': 'en'}])]), 'evidence[0].quotes[0].text'),
            (payload(units=[evidence(0, quotes=[{'id': 'e0.en.0', 'text': 'Source A.'}])]), 'evidence[0].quotes[0].language'),
        ]
        for data, expected_field in cases:
            problem = review_input_problem(data)
            self.assertIsNotNone(problem, expected_field)
            self.assertEqual(problem[1], expected_field)

    def test_short_id_bound_and_rooting(self):
        # 过长的 ID 会被拒绝（DFA 只放短 ID）。
        long_id = {'id': 'e' * (MAX_QUOTE_ID + 1), 'language': 'en', 'text': 'Source A.'}
        problem = review_input_problem(payload(units=[evidence(0, quotes=[long_id])]))
        self.assertEqual(problem[1], 'evidence[0].quotes[0].id')
        self.assertIn('short ASCII identifier', problem[2])
        unicode_id = {'id': 'e0.英.0', 'language': 'en', 'text': 'Source A.'}
        self.assertEqual(review_input_problem(payload(units=[evidence(0, quotes=[unicode_id])]))[1],
                         'evidence[0].quotes[0].id')
        # ID 必须属于它所在的证据条目，语言也必须自洽。
        foreign = dict(quote(0), id='e3.en.0')
        self.assertEqual(review_input_problem(payload(units=[evidence(0, quotes=[foreign])]))[1],
                         'evidence[0].quotes[0].id')
        mismatched = dict(quote(0), id='e0.en.0', language='zh')
        self.assertEqual(review_input_problem(payload(units=[evidence(0, quotes=[mismatched])]))[1],
                         'evidence[0].quotes[0].id')

    def test_unexpected_fields_are_rejected(self):
        problem = review_input_problem(payload(units=[evidence(0, quotes=[quote(0, **{'characters': 2})])]))
        self.assertEqual(problem[1], 'evidence[0].quotes[0].characters')
        self.assertIn('unexpected field', problem[2])
        problem = review_input_problem(payload(units=[evidence(0, startTime=1.5)]))
        self.assertEqual(problem[1], 'evidence[0].startTime')

    def test_chinese_warning_must_be_text_when_present(self):
        self.assertIsNone(review_input_problem(payload(units=[evidence(0, chineseWarning='译文可能不完整')])))
        problem = review_input_problem(payload(units=[evidence(0, chineseWarning={'text': 'x'})]))
        self.assertEqual(problem[1], 'evidence[0].chineseWarning')

    def test_fragments_longer_than_the_swift_fragment_limit_are_kept(self):
        # 一个 Swift Character 可能是多个 Unicode 标量：不能再用 Python len 当 2400 上限，
        # 否则长片段会被误判。这里覆盖远超 2400 码点的片段。
        combined = 'a' + '\u0301' * 3_000
        self.assertGreater(len(combined), 2_400)
        units = [evidence(0, quotes=[quote(0, text=combined)])]
        self.assertIsNone(review_input_problem(payload(units=units)))
        parsed = parse_review_input(review_input(units=units))
        self.assertEqual(parsed['evidence'][0]['quotes'][0]['text'], combined)
        plain = 'x' * 4_000
        self.assertIsNone(review_input_problem(payload(units=[evidence(0, quotes=[quote(0, text=plain)])])))

    def test_parse_review_input_raises_structured_errors(self):
        with self.assertRaises(ValueError) as malformed:
            parse_review_input('{"note": ')
        self.assertIn('stage=input', str(malformed.exception))
        self.assertIn('code=invalid_json', str(malformed.exception))
        self.assertIn('JSON syntax error at line 1', str(malformed.exception))
        with self.assertRaises(ValueError) as wrong_shape:
            parse_review_input(json.dumps({'reviewVersion': 2, 'note': {'points': 'not-an-array'}}))
        self.assertIn('stage=schema', str(wrong_shape.exception))
        self.assertIn('field=note.points', str(wrong_shape.exception))
        with self.assertRaises(ValueError) as not_text:
            parse_review_input({'note': 'object, not text'})
        self.assertIn('code=invalid_json', str(not_text.exception))
        self.assertEqual(parse_review_input(review_input())['note']['points'][0]['text'], '原笔记')

    def test_json_error_description_carries_position_not_content(self):
        try:
            json.loads('{"topic": "秘密内容", }')
        except json.JSONDecodeError as error:
            text = describe_json_error(error)
        self.assertIn('line 1', text)
        self.assertNotIn('秘密内容', text)


class PromptBindingTests(unittest.TestCase):
    def test_bound_prompt_contains_checked_input_once(self):
        raw = review_input()
        original = '<|im_start|>system\nreview<|im_end|>\n<|im_start|>user\n' + raw + '<|im_end|>\n<|im_start|>assistant\n'
        data = json.loads(raw)
        data['calculationChecks'] = {'version': 1, 'results': []}
        bound = bind_review_prompt(raw, original, data)
        self.assertNotIn(raw, bound)
        self.assertIn('"calculationChecks"', bound)
        self.assertEqual(bound.count('<|im_start|>user\n'), 1)

    def test_missing_marker_reports_binding_stage(self):
        with self.assertRaises(ValueError) as error:
            bind_review_prompt(review_input(), 'system prompt without the user turn', {})
        self.assertIn('stage=prompt_binding', str(error.exception))
        self.assertIn('code=input_not_in_prompt', str(error.exception))
        self.assertNotIn('原笔记', str(error.exception))


class GenerationDetailTests(unittest.TestCase):
    def test_generation_detail_is_bounded_and_content_free(self):
        detail = generation_detail(RuntimeError('out of memory ' + 'z' * 500))
        self.assertTrue(detail.startswith('RuntimeError: out of memory'))
        self.assertLessEqual(len(detail), 140)
        payload_text = generation_detail(ValueError('{"text": "模型输出"}'))
        self.assertNotIn('模型输出', payload_text)

    def test_clean_detail_keeps_plain_messages(self):
        self.assertEqual(clean_detail('  cache limit   exceeded '), 'cache limit exceeded')


class GrammarErrorTests(unittest.TestCase):
    def test_long_private_regex_is_not_in_error_but_cause_survives(self):
        from review_diagnostics import grammar_error
        error = grammar_error(ValueError("PRIVATE_CLASS_TEXT" * 2000 + " Found no transitions from state 123. encoding issue in your vocabulary"))
        self.assertIn('code=vocabulary_encoding', str(error))
        self.assertNotIn('PRIVATE_CLASS_TEXT', str(error))
        self.assertLess(len(str(error)), 200)


if __name__ == '__main__':
    unittest.main()
