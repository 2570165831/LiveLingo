import unittest
from checks import check, review_checks
from latin_numbers import literals
from review_diagnostics import review_input_problem
from test_review_diagnostics import payload, evidence, quote


class LatinNumbersTests(unittest.TestCase):
    def values(self, text, language):
        return [entry[3] for entry in literals(text, language)]

    def test_exact_locale_numbers(self):
        self.assertEqual(self.values('1.000,50 -3,14 +9,01e2', 'es'), ['10005e-1', '-314e-2', '901e0'])
        self.assertEqual(self.values('1\u202f000,50 -3,14', 'fr'), ['10005e-1', '-314e-2'])
        self.assertEqual(self.values('1,000.50', 'en'), ['10005e-1'])
        for language in ('es', 'fr'):
            self.assertEqual(self.values('1,2,3', language), [])
            self.assertEqual(self.values('9007199254740992 9007199254740993', language), ['9007199254740992e0', '9007199254740993e0'])

    def test_explicit_locale_equations(self):
        for language, grouped in (('es', '1.000'), ('fr', '1\u202f000')):
            self.assertEqual(check('3,14 + 0,86 = 4', language)['status'], 'matches')
            self.assertEqual(check('3,14 + 0,86 = 5', language)['status'], 'differs')
            self.assertEqual(check(grouped + ' g = 1 kg', language)['status'], 'matches')
            self.assertEqual(check('3,14 kg = 3140 g', language)['status'], 'matches')
            self.assertEqual(check('2 H2 + O2 -> 2 H2O', language)['status'], 'matches')
        self.assertEqual(check('3,14 + 0,86 = 4')['status'], 'unable')
        self.assertEqual(check('__import__("os") = 0', 'fr')['status'], 'unable')

    def test_review_infers_only_unambiguous_target(self):
        for language in ('es', 'fr'):
            data = {'evidence': [{'quotes': [{'language': 'en'}, {'language': language}]}],
                    'note': {'points': [{'index': 0, 'text': '`3,14 + 0,86 = 4`'}]}}
            self.assertEqual(review_checks(data)['results'][0]['status'], 'matches')
        data['evidence'][0]['quotes'].append({'language': 'es'})
        self.assertEqual(review_checks(data)['results'][0]['status'], 'unable')

    def test_review_quote_whitelist_preserves_root_and_language_checks(self):
        for language in ('es', 'fr'):
            self.assertIsNone(review_input_problem(payload(units=[evidence(0, quotes=[quote(0, language=language)])])))
            bad = {**quote(0, language=language), 'id': 'e0.en.0'}
            self.assertEqual(review_input_problem(payload(units=[evidence(0, quotes=[bad])]))[1], 'evidence[0].quotes[0].id')
        self.assertEqual(review_input_problem(payload(units=[evidence(0, quotes=[quote(0, language='de')])]))[1], 'evidence[0].quotes[0].language')
