"""Independent target-specific integrity regressions; no model invocation."""
import hashlib
import json
from pathlib import Path
import unittest
from test_learning_quality_target import scorer


class SpanishFrenchLearningTests(unittest.TestCase):
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
