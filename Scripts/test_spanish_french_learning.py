"""Independent target-specific integrity regressions; no model invocation."""
import hashlib
import json
from pathlib import Path
import unittest
from test_learning_quality_target import scorer


class SpanishFrenchLearningTests(unittest.TestCase):
    def report(self, claim, source, target, elsewhere=False):
        return scorer.numeric_report(claim, [] if elsewhere else [source], [], [source], target=target)

    def test_measurement_sign_conflicts_in_both_scopes(self):
        for target in ('es', 'fr'):
            for claim, source in [('5 °C', '-5 °C'), ('-5 °C', '5 °C'),
                                  ('5 °C', 'menos 5 grados Celsius' if target == 'es' else 'moins 5 degrés Celsius')]:
                for elsewhere in (False, True):
                    with self.subTest(target=target, claim=claim, source=source, elsewhere=elsewhere):
                        difference, gap = self.report(claim, source, target, elsewhere)
                        self.assertTrue(difference)
                        self.assertIn('正负号', gap)

    def test_spoken_signs_preserve_operator_and_count_behavior(self):
        for target in ('es', 'fr'):
            minus = 'menos' if target == 'es' else 'moins'
            below = '5 grados Celsius bajo cero' if target == 'es' else '5 degrés Celsius au-dessous de zéro'
            for source in ['−5 °C', '－5 °C', '﹣5 °C', minus + ' 5 °C', below, '-5e0 °C']:
                with self.subTest(target=target, source=source):
                    self.assertEqual(self.report('-5 °C', source, target), (False, None))
            for source in ['3-5 °C', '20 - 5 °C', '±5 °C',
                           ('más o menos' if target == 'es' else 'plus ou moins') + ' 5 °C',
                           '10 °C ' + minus + ' 5 °C']:
                self.assertEqual(self.report('5 °C', source, target), (False, None))
            for noun in ('', ' ejemplos' if target == 'es' else ' exemples'):
                self.assertEqual(self.report('5' + noun, '-5' + noun, target), (False, None))

    def test_complete_units_reject_shorter_and_unknown_forms(self):
        for target in ('es', 'fr'):
            for claim, source in [('9,8 m/s', '9,8 m/s²'), ('5 m', '5 m²'),
                                  ('2 kg', '2 kg/m³'), ('2 kg', '2 kg/ft³'), ('5 m', '5 m^q')]:
                with self.subTest(target=target, claim=claim, source=source):
                    difference, gap = self.report(claim, source, target)
                    self.assertTrue(difference)
                    self.assertIn('单位不同', gap)

    def test_localized_unit_powers_match_in_both_directions(self):
        cases = {'es': [('9,8 metros por segundo cuadrado', '9,8 m/s²'),
                        ('9,8 metros por segundo al cuadrado', '9,8 m/s^2'),
                        ('2 kilogramos por metro cúbico', '2 kg/m³'),
                        ('1,5 gramos por centímetro cúbico', '1,5 g/cm³'),
                        ('5 metros cuadrados', '5 m2')],
                 'fr': [('9,8 mètres par seconde carrée', '9,8 m/s²'),
                        ('2 kilogrammes par mètre cube', '2 kg/m³'),
                        ('1,5 grammes par centimètre cube', '1,5 g/cm³'),
                        ('5 mètres carrés', '5 m2')]}
        for target, pairs in cases.items():
            for claim, source in pairs:
                for left, right in ((claim, source), (source, claim)):
                    with self.subTest(target=target, claim=left, source=right):
                        self.assertEqual(self.report(left, right, target), (False, None))

    def test_repeated_denominators_fold_only_matching_units(self):
        for target in ('es', 'fr'):
            spoken = 'metros por segundo por segundo' if target == 'es' else 'mètres par seconde par seconde'
            for source in ['9,8 ' + spoken, '9,8 m/s/s']:
                self.assertEqual(self.report('9,8 m/s²', source, target), (False, None))
            self.assertEqual(self.report('9,8 m/s³', '9,8 m/s²/s', target), (False, None))
            self.assertTrue(self.report('9,8 m/s²', '9,8 m/s/min', target)[0])

    def test_scientific_notation_and_exponent_digits_are_one_mention(self):
        for target in ('es', 'fr'):
            for claim, source in [('3000000 m/s', '3 × 10⁶ m/s'), ('3e6 m/s', '3 × 10^6 m/s'),
                                  ('1000000 Hz', '10^6 Hz'), ('0,0015 m', '1,5×10⁻³ m'),
                                  ('-300 m/s', '-3 × 10² m/s')]:
                with self.subTest(target=target, claim=claim, source=source):
                    self.assertEqual(self.report(claim, source, target), (False, None))
            for source in ['2 kg/m3', '3 × 10^3 m', '2^3 m', 'K3']:
                self.assertIsNotNone(self.report('3', source, target)[1], source)

    def test_scientific_zero_and_raw_powers_preserve_signs(self):
        from latin_learning import signed_mentions
        for target in ('es', 'fr'):
            self.assertEqual(self.report('0 m', '0 × 10² m', target), (False, None))
            difference, gap = self.report('2^10 m', '-2^10 m', target)
            self.assertTrue(difference)
            self.assertIn('正负号', gap)
            for source in ['2^999999999999999999999999 m', '2^−9223372036854775808 m']:
                self.assertEqual(len(list(signed_mentions(source, target, scorer.UNIT_ALIASES))), 1)

    def test_scientific_scale_overflow_keeps_the_whole_expression(self):
        from latin_learning import signed_mentions
        for target in ('es', 'fr'):
            mentions = list(signed_mentions('3e9223372036854775807 × 10^2 m', target, scorer.UNIT_ALIASES))
            self.assertEqual(len(mentions), 1)
            self.assertEqual(mentions[0][0], '3e9223372036854775807×10^2')

    def test_default_and_english_contracts_remain_explicit(self):
        self.assertEqual(scorer.CAPTION_TRANSLATION_TARGET, 'zh-Hans')
        self.assertEqual(scorer.source_text_groups({'english': 'Water.', 'chinese': '旧中文'}, target='en'), [('en', 'Water.')])

    def test_target_groups_and_same_language_ignore_foreign_storage(self):
        for target, text in (('es', 'El agua fluye.'), ('fr', 'L’eau coule.')):
            self.assertEqual(scorer.source_text_groups({'english': text, 'chinese': '旧中文', 'sourceLanguage': target}, target=target), [(target, text)])
            self.assertEqual(scorer.source_text_groups({'english': 'Water flows.', 'chinese': text, 'sourceLanguage': 'en'}, target=target), [('en', 'Water flows.'), (target, text)])
            self.assertEqual(scorer.source_text_groups({'english': '水流动。', 'chinese': text, 'sourceLanguage': 'zh'}, target=target), [(target, text)])

    def test_locale_numeric_scope_and_advisory(self):
        for target, text in (('es', 'La masa es 1.000 gramos.'), ('fr', 'La masse est de 1\u202f000 grammes.')):
            english = 'The mass is 1,000 grams.'
            self.assertEqual(scorer.numeric_report(text, [english], [english, text], [english, text], target=target, language_groups=[('en', english), (target, text)]), (False, None))
            wrong = text.replace('1.000', '3,14').replace('1\u202f000', '3,14')
            difference, gap = scorer.numeric_report(wrong, [english], [english, text], [english, text], target=target, language_groups=[('en', english), (target, text)])
            self.assertTrue(difference)
            self.assertIn('3,14', gap)

    def test_source_unit_owner_whitelist_is_target_specific(self):
        for target, text in (('es', 'El agua fluye.'), ('fr', 'L’eau coule.')):
            source = {'english': text, 'chinese': '旧中文', 'sourceLanguage': target}
            unit = {'id': target + '0s0', 'index': 0, 'language': target, 'text': text}
            self.assertEqual(list(scorer.verify_units([unit], [source], target=target)), [target + '0s0'])
            with self.assertRaisesRegex(ValueError, 'source-unit-owner'):
                scorer.verify_units([unit], [source], target='zh-Hans')
            with self.assertRaisesRegex(ValueError, 'source-unit-owner'):
                scorer.verify_units([unit], [source], target='en')

    def test_kind_and_state_labels_preserve_wire_codes(self):
        for target, label in (('es', 'Ejemplo'), ('fr', 'Exemple')):
            point = {'kind': '例子', 'text': 'Payload'}
            self.assertEqual(scorer.point_line(point, target=target), '- **' + label + '**: Payload')
            self.assertEqual(point['kind'], '例子')
            self.assertNotEqual(scorer.followup_state_label('缺信息', target=target), '缺信息')

    def test_synthetic_public_fixture_manifest_and_limits(self):
        for target in ('es', 'fr'):
            root = Path(__file__).parent / 'Fixtures' / ('learning-quality-public-' + target)
            manifest = json.loads((root / 'manifest.json').read_text())
            for entry in manifest['files']:
                self.assertEqual(hashlib.sha256((root / entry['file']).read_bytes()).hexdigest(), entry['sha256'])
            gold = json.loads((root / 'gold.json').read_text())
            self.assertEqual(gold['targetLocale'], target)
            self.assertFalse(gold['referenceVerification']['networkUsed'])
            self.assertEqual(len(gold['cases']), 3)
