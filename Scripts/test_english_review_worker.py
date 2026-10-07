"""Exercise the production worker's English-only preparation and frozen schemas."""
import json
import unittest
import jsonschema
from review_diagnostics import parse_review_input, bind_review_prompt
from schemas import note_schema, review_schema


class EnglishReviewWorkerTests(unittest.TestCase):
    def prepared_review(self):
        return {'reviewVersion': 2, 'note': {'points': [{'index': 0, 'text': 'A variable stores a value.'}]},
                'evidence': [{'index': 0, 'quotes': [{'id': 'e0.en.0', 'language': 'en',
                                                    'text': 'A variable stores a value.'}]}]}

    def test_worker_parses_and_binds_a_single_english_group(self):
        raw = json.dumps(self.prepared_review(), ensure_ascii=False)
        checked = parse_review_input(raw)
        prompt = '<|im_start|>system\nReview English study notes.<|im_end|>\n<|im_start|>user\n' + raw + '<|im_end|>'
        bound = bind_review_prompt(raw, prompt, checked)
        self.assertIn('e0.en.0', bound)
        self.assertEqual([q['language'] for u in checked['evidence'] for q in u['quotes']], ['en'])

    def test_note_schema_keeps_chinese_wire_codes_with_english_evidence(self):
        prepared = {'evidence': [{'id': 'en0s0', 'index': 0, 'language': 'en',
                                 'text': 'A variable stores a value.'}], 'pendingPoints': [{'id': 'q0'}]}
        response = {'sourceVersion': 2, 'topic': 'Variables', 'noNewKnowledge': False,
                    'points': [{'kind': '例子', 'text': 'A variable stores a value.', 'sourceIDs': ['en0s0'],
                                'needsContext': None}],
                    'followUps': {'q0': {'state': '后文补充', 'sourceIDs': ['en0s0'], 'detail': 'The owner is now explicit.'}}}
        jsonschema.validate(response, note_schema(prepared))
        response['points'][0]['kind'] = 'Example'
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response, note_schema(prepared))

    def test_review_schema_accepts_the_actual_english_quote_id(self):
        checked = parse_review_input(json.dumps(self.prepared_review()))
        response = {'reviewVersion': 2, 'corrections': [], 'additions': [{'evidenceIndex': 0,
            'quoteID': 'e0.en.0', 'kind': '例子', 'text': 'A variable can hold a value.',
            'reason': 'The source states this claim.'}]}
        jsonschema.validate(response, review_schema(checked))
        response['additions'][0]['quoteID'] = 'e0.zh.0'
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response, review_schema(checked))


if __name__ == '__main__':
    unittest.main()
