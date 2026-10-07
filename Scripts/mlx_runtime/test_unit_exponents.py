"""CPU-only unit power bounds and the production review helper chain."""
import json
import unittest
from unittest.mock import patch

import jsonschema

from checks import check, review_checks
from review_diagnostics import bind_review_prompt, parse_review_input
from schemas import review_schema


OUT_OF_RANGE = ('13', '-13', '+13', '20', '-20', '+20', '1000', '-1000', '+1000')


class UnitExponentTests(unittest.TestCase):
    def test_locale_powers_over_limit_are_unable(self):
        for language in ('es', 'fr'):
            for exponent in OUT_OF_RANGE:
                for operator in ('^', '**'):
                    for coefficient in ('1', '1,5'):
                        with self.subTest(language=language, exponent=exponent,
                                          operator=operator, coefficient=coefficient):
                            quantity = f'{coefficient} m{operator}{exponent}'
                            result = check(f'{quantity} = {quantity}', language)
                            self.assertEqual(result['status'], 'unable')
                            self.assertIn('单位指数超出核算范围', result['scope'])

    def test_locale_powers_at_limit_are_supported(self):
        for language in ('es', 'fr'):
            for exponent in ('12', '-12', '+12'):
                for operator in ('^', '**'):
                    with self.subTest(language=language, exponent=exponent, operator=operator):
                        quantity = f'1,5 m{operator}{exponent}'
                        result = check(f'{quantity} = {quantity}', language)
                        self.assertEqual(result['status'], 'matches')
                        self.assertEqual(result['method'], 'Pint')

    def test_both_sides_are_checked_before_pint(self):
        for language in ('es', 'fr'):
            for exponent in ('20', '-20', '1000', '-1000'):
                for expression in (f'1 m^{exponent} = 1 m^2', f'1 m^2 = 1 m^{exponent}'):
                    with self.subTest(language=language, expression=expression):
                        with patch('checks.UNITS.Quantity') as quantity:
                            result = check(expression, language)
                            self.assertEqual(result['status'], 'unable')
                            self.assertIn('单位指数超出核算范围', result['scope'])
                            quantity.assert_not_called()

    def test_scientific_powers_use_the_whole_value(self):
        for language in (None, 'zh', 'en', 'es', 'fr'):
            for exponent in ('2e1', '-2e1', '1e3', '-1e3', '2e0001', '-2e0001'):
                with self.subTest(language=language, exponent=exponent):
                    quantity = f'1 m^{exponent}'
                    result = check(f'{quantity} = {quantity}', language)
                    self.assertEqual(result['status'], 'unable')
                    self.assertIn('单位指数超出核算范围', result['scope'])

    def test_default_chinese_and_english_integer_bounds_are_preserved(self):
        for language in (None, 'zh', 'en'):
            for exponent, status in (('12', 'matches'), ('-12', 'matches'),
                                     ('13', 'unable'), ('-13', 'unable'),
                                     ('20', 'unable'), ('-20', 'unable'),
                                     ('1000', 'unable'), ('-1000', 'unable')):
                with self.subTest(language=language, exponent=exponent):
                    quantity = f'1 m^{exponent}'
                    self.assertEqual(check(f'{quantity} = {quantity}', language)['status'], status)


class ReviewUnitExponentTests(unittest.TestCase):
    def bind_review(self, language, exponent):
        expression = f'1 m^{exponent} = 1 m^{exponent}'
        text = f'`{expression}`'
        quote_id = f'e0.{language}.0'
        original = {'reviewVersion': 2,
                    'note': {'points': [{'index': 7, 'text': text}]},
                    'evidence': [{'index': 0, 'quotes': [
                        {'id': 'e0.en.0', 'language': 'en', 'text': expression},
                        {'id': quote_id, 'language': language, 'text': expression}]}]}
        raw = json.dumps(original, ensure_ascii=False)
        data = parse_review_input(raw)
        schema = review_schema(data)
        jsonschema.validate({'reviewVersion': 2, 'corrections': [], 'additions': [{
            'evidenceIndex': 0, 'quoteID': quote_id, 'kind': '例子',
            'text': expression, 'reason': 'Explicit source expression.'}]}, schema)
        data['calculationChecks'] = review_checks(data)
        prompt = '<|im_start|>system\nReview explicit expressions.<|im_end|>\n'
        prompt += '<|im_start|>user\n' + raw + '<|im_end|>'
        bound = bind_review_prompt(raw, prompt, data)
        bound_data = json.loads(bound.split('<|im_start|>user\n', 1)[1].split('<|im_end|>', 1)[0])
        self.assertEqual(bound_data, data)
        results = bound_data['calculationChecks']['results']
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]['pointIndex'], 7)
        self.assertEqual(results[0]['expression'], expression)
        return results[0], bound

    def test_v2_locale_reviews_bind_unable_for_out_of_range_powers(self):
        for language in ('es', 'fr'):
            for exponent in OUT_OF_RANGE:
                with self.subTest(language=language, exponent=exponent):
                    result, bound = self.bind_review(language, exponent)
                    self.assertEqual(result['status'], 'unable')
                    self.assertIn('单位指数超出核算范围', result['scope'])
                    self.assertIn('"status": "unable"', bound)
                    self.assertNotIn('"status": "matches"', bound)

    def test_v2_locale_reviews_keep_the_boundary_supported(self):
        for language in ('es', 'fr'):
            for exponent in ('12', '-12', '+12'):
                with self.subTest(language=language, exponent=exponent):
                    result, bound = self.bind_review(language, exponent)
                    self.assertEqual(result['status'], 'matches')
                    self.assertEqual(result['method'], 'Pint')
                    self.assertIn('"status": "matches"', bound)


if __name__ == '__main__':
    unittest.main()
