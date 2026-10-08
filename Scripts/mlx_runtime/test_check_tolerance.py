"""CPU-only Pint comparison: relative at any magnitude, rounding from written digits."""
import unittest

from checks import check, review_checks


class CheckToleranceTests(unittest.TestCase):
    def assertStatus(self, expression, status, language=None):
        with self.subTest(expression=expression, language=language):
            result = check(expression, language)
            self.assertEqual(result['status'], status)
            self.assertEqual(result['method'], 'Pint')

    def test_tiny_magnitude_errors_differ(self):
        for expression in ('1e-27 kg = 1e-24 kg', '5e-22 kg = 9e-22 kg',
                           '9.11e-31 kg = 9.11e-28 kg', '9.11e-31 kg = 9.11e-30 kg',
                           '6.63e-34 J*s = 6.63e-31 J*s', '1.0e-13 kg = 1.1e-13 kg'):
            self.assertStatus(expression, 'differs')

    def test_opposite_signs_differ(self):
        for expression in ('-1e-27 kg = 1e-27 kg', '1e-27 kg = -1e-27 kg',
                           '-1.6e-19 J = 1.6e-19 J', '-1 m = 1 m'):
            self.assertStatus(expression, 'differs')

    def test_result_does_not_depend_on_the_written_unit(self):
        self.assertStatus('5e-22 kg = 9e-22 kg', 'differs')
        self.assertStatus('5e-19 g = 9e-19 g', 'differs')
        self.assertStatus('1e-25 kg = 1e-22 g', 'matches')
        self.assertStatus('1e-25 kg = 1e-19 g', 'differs')
        self.assertStatus('1e-27 kg = 1e-27 kg', 'matches')

    def test_exact_conversions_still_match(self):
        for expression in ('0 m = 0 km', '1 km = 1000 m', '1 inch = 2.54 cm', '1e12 m = 1e9 km',
                           '273.15 K = 0 degC'):
            self.assertStatus(expression, 'matches')
        self.assertStatus('1 km = 1001 m', 'differs')

    def test_rounding_follows_the_written_digits(self):
        for expression in ('1 eV = 1.602e-19 J', '1 eV = 1.6e-19 J', '1 u = 1.66e-27 kg',
                           '1 mile = 1.609 km', '1.609 km = 1 mile', '1 mile = 1609.3 m',
                           '1 mile = 1609 m'):
            self.assertStatus(expression, 'matches')
        # Too far for the digits written.
        for expression in ('1 eV = 1.7e-19 J', '1 eV = 1.603e-19 J', '1 u = 1.67e-27 kg',
                           '1 mile = 1.5 km', '1 mile = 1.62 km', '1 mile = 2 km',
                           '1e-27 kg = 0 kg', '1e-27 kg = 0.0 kg'):
            self.assertStatus(expression, 'differs')

    def test_written_integers_round_like_decimals(self):
        # 1609 m carries the same four written digits as 1.609 km, so the
        # verdict may not depend on which unit the result is written in.
        for expression in ('1 mile = 1609 m', '1609 m = 1 mile', '1 lb = 454 g',
                           '1 hp = 746 W', '1 atm = 101 kPa', '1 Btu = 1055 J'):
            self.assertStatus(expression, 'matches')
        for expression in ('1 lb = 455 g', '1 mile = 1608 m', '1 km = 1001 m'):
            self.assertStatus(expression, 'differs')
        # One digit and trailing zeros stay exact, so 1 X = ... is a definition.
        for expression in ('1 yd = 1 m', '1 mile = 2 km', '1 mile = 1610 m'):
            self.assertStatus(expression, 'differs')
        for language in ('es', 'fr'):
            self.assertStatus('1 lb = 454 g', 'matches', language)
            self.assertStatus('1 lb = 455 g', 'differs', language)
        self.assertStatus('1 mile = 1.609 m', 'matches', 'es')
        self.assertStatus('1 mile = 1.608 m', 'differs', 'es')
        self.assertStatus('1 mile = 1 609 m', 'matches', 'fr')

    def test_rounding_ties_do_not_depend_on_float_noise(self):
        # 0.13 - 0.125 is 0.0050000000000000044 in float.
        for expression in ('12.5 cm = 0.13 m', '12.5 cm = 0.12 m', '2.5 dm = 0.3 m',
                           '0.13 m = 12.5 cm'):
            self.assertStatus(expression, 'matches')
        self.assertStatus('12.5 cm = 0.14 m', 'differs')
        for language in ('es', 'fr'):
            self.assertStatus('12,5 cm = 0,13 m', 'matches', language)

    def test_locale_precision_comes_from_the_typed_literal(self):
        for language in ('es', 'fr'):
            # Normalization turns 3140 into 314e1 and 1,50 into 15e-1. Neither
            # may widen the allowance to the stripped trailing zero.
            self.assertStatus('3140 g = 3,15 kg', 'differs', language)
            self.assertStatus('20 m = 21 m', 'differs', language)
            self.assertStatus('1,50 kg = 1,54 kg', 'differs', language)
            self.assertStatus('1,5 kg = 1,54 kg', 'matches', language)
            self.assertStatus('3,14 kg = 3140 g', 'matches', language)
            self.assertStatus('1 mile = 1,609 km', 'matches', language)
            self.assertStatus('1 mile = 1,5 km', 'differs', language)
            self.assertStatus('1 eV = 1,602e-19 J', 'matches', language)
            self.assertStatus('1e-27 kg = 1e-24 kg', 'differs', language)
        self.assertStatus('1.000 g = 1 kg', 'matches', 'es')
        self.assertStatus('1.001 g = 1 kg', 'differs', 'es')
        self.assertStatus('1 000 g = 1 kg', 'matches', 'fr')

    def test_review_reports_tiny_magnitude_error(self):
        data = {'note': {'points': [{'index': 0, 'text': '`1e-27 kg = 1e-24 kg`'},
                                    {'index': 1, 'text': '`1 eV = 1.602e-19 J`'}]}}
        results = review_checks(data)['results']
        self.assertEqual([(r['pointIndex'], r['status']) for r in results],
                         [(0, 'differs'), (1, 'matches')])


if __name__ == '__main__':
    unittest.main()
