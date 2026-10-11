"""CPU-only: written multiplication, division and minus signs reach the same checks as ASCII."""
import unittest

from checks import check, review_checks


class CheckOperatorTests(unittest.TestCase):
    def assertStatus(self, expression, status, language=None, method='SymPy'):
        with self.subTest(expression=expression, language=language):
            result = check(expression, language)
            self.assertEqual(result['status'], status, result['scope'])
            self.assertEqual(result.get('method'), method)

    def test_written_operators_are_checked(self):
        for expression, status in (('3 + 2 × 4 = 11', 'matches'), ('3 + 2 × 4 = 12', 'differs'),
                                   ('12 ÷ 4 = 3', 'matches'), ('12 ÷ 4 = 4', 'differs'),
                                   ('5 − 2 = 3', 'matches'), ('−2 + 5 = 3', 'matches'),
                                   ('3 \\times 4 = 12', 'matches'), ('3\\times4 = 13', 'differs'),
                                   ('12 \\div 3 = 4', 'matches'), ('2 \\cdot 3 = 6', 'matches'),
                                   ('2 ⋅ 3 = 6', 'matches')):
            self.assertStatus(expression, status)

    def test_written_operators_match_ascii(self):
        for written, ascii_form in (('(1 + 2) × 3^2 = 27', '(1 + 2) * 3^2 = 27'),
                                    ('(1 + 2) × 3^2 = 28', '(1 + 2) * 3^2 = 28'),
                                    ('7 ÷ 2 = 3.5', '7 / 2 = 3.5'),
                                    ('10 − 2 × 3 = 4', '10 - 2 * 3 = 4')):
            with self.subTest(written=written):
                self.assertEqual(check(written)['status'], check(ascii_form)['status'])
        written, ascii_form = check('1.5 kg × 2 = 3 kg'), check('1.5 kg * 2 = 3 kg')
        self.assertEqual((written['status'], written.get('method')),
                         (ascii_form['status'], ascii_form.get('method')))

    def test_ambiguous_or_unsupported_forms_stay_unable(self):
        for expression in ('2·3 = 6', '2 x 3 = 6', 'a × b = c', '1 ÷ 0 = 0',
                           '1 × ' * 41 + '1 = 1'):
            with self.subTest(expression=expression):
                self.assertEqual(check(expression)['status'], 'unable')

    def test_limits_apply_to_the_normalized_text(self):
        self.assertGreater(len('1 × ' * 41 + '1'), 160)
        self.assertIn('表达式过长', check('1 × ' * 41 + '1 = 1')['scope'])
        self.assertIn('数值超出核算范围', check('2000000000000 × 1 = 2000000000000')['scope'])

    def test_result_keeps_the_written_expression(self):
        self.assertEqual(check('  3 + 2 × 4 = 11 ')['expression'], '3 + 2 × 4 = 11')

    def test_review_checks_extracts_written_operators(self):
        data = {'note': {'points': [{'index': 0, 'text': '答案 $3 + 2 × 4 = 12$'},
                                    {'index': 1, 'text': '每组 `12 ÷ 4 = 3`'}]}}
        results = review_checks(data)['results']
        self.assertEqual([(r['pointIndex'], r['status']) for r in results],
                         [(0, 'differs'), (1, 'matches')])

    def test_locale_numbers_with_written_operators(self):
        self.assertStatus('1,5 × 2 = 3', 'matches', 'es')
        self.assertStatus('1,5 × 2 = 4', 'differs', 'fr')


if __name__ == '__main__':
    unittest.main()
