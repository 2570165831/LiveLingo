"""Review v2 response binding regressions; no model weights or user data required."""
import importlib.util
import json
import unittest

import jsonschema

from schemas import note_schema, review_schema


def quote(evidence_index, language='en', fragment=0, text=None):
    return {'id': f'e{evidence_index}.{language}.{fragment}', 'language': language,
            'text': text if text is not None else f'SOURCE-{evidence_index}-{language}-MARKER'}


def review_input(units=None, points=None):
    if units is None:
        units = [{'index': 0, 'quotes': [quote(0, 'en', text='Source A.'), quote(0, 'zh', text='原文甲。')]},
                 {'index': 1, 'quotes': [quote(1, 'en', text='Source B.'), quote(1, 'zh', text='原文乙。')]}]
    if points is None:
        points = [{'index': 0, 'text': '原笔记甲'}, {'index': 1, 'text': '原笔记乙'}]
    return {'reviewVersion': 2, 'note': {'points': points}, 'evidence': units}


def response(corrections=None, additions=None, version=2):
    payload = {'reviewVersion': version, 'corrections': corrections or [], 'additions': additions or []}
    if version is None:
        payload.pop('reviewVersion')
    return payload


def addition(evidence_index, quote_id, **overrides):
    entry = {'evidenceIndex': evidence_index, 'quoteID': quote_id, 'kind': '补充理解',
             'text': '建议', 'reason': '理由'}
    entry.update(overrides)
    return entry


def note_input(unit_ids=None, aliases=None):
    if unit_ids is None:
        unit_ids = ['en0s0', 'en0s1', 'zh0s0']
    return {'evidence': [{'id': value} for value in unit_ids],
            'pendingPoints': [{'id': value} for value in (aliases or [])]}


def followup(state='缺信息', source_ids=None, detail='后文没有给出补充。'):
    return {'state': state, 'sourceIDs': source_ids if source_ids is not None else [], 'detail': detail}


def note(follow_ups=None, points=None, no_new_knowledge=False):
    if points is None:
        points = [{'kind': '核心结论', 'text': '保留正文', 'sourceIDs': ['en0s0'], 'needsContext': None}]
    return {'sourceVersion': 2, 'topic': '无新增学习知识' if no_new_knowledge else '主题',
            'noNewKnowledge': no_new_knowledge,
            'points': [] if no_new_knowledge else points, 'followUps': follow_ups if follow_ups is not None else {}}


class NoteSchemaTests(unittest.TestCase):
    def test_note_source_count_matches_production_binding(self):
        schema = note_schema(note_input())
        point = {'kind': '核心结论', 'text': '保留正文', 'sourceIDs': ['en0s0', 'en0s1'],
                 'needsContext': None}
        value = {'sourceVersion': 2, 'topic': '主题', 'noNewKnowledge': False, 'points': [point],
                 'followUps': {}}
        jsonschema.validate(value, schema)
        point['sourceIDs'].append('zh0s0')
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(value, schema)
        point['sourceIDs'] = ['missing']
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(value, schema)
        point['kind'] = '补充理解'
        point['sourceIDs'] = []
        jsonschema.validate(value, schema)

    def test_note_source_bound_compiles_to_real_grammar(self):
        if importlib.util.find_spec('outlines_core') is None:
            self.skipTest('outlines_core is not installed in this interpreter')
        from outlines_core import Index, Vocabulary
        from outlines_core.json_schema import build_regex_from_schema
        schema = note_schema(note_input(unit_ids=['en0s0', 'zh0s0']))
        regex = build_regex_from_schema(json.dumps(schema, ensure_ascii=False))
        vocabulary = Vocabulary(0, {c: [i + 1] for i, c in enumerate(
            sorted(set(regex + ''.join(chr(i) for i in range(32, 127)))))})
        self.assertIsNotNone(Index(regex, vocabulary))


class NoteFollowUpSchemaTests(unittest.TestCase):
    """2026-09-22：后文已经明确给答案时，旧缺信息提示不能长期挂着。

    协议上的保证：每个已提供的 q 编号都必须是**必填键**，缺一个、改名或
    多写一个都会被语法挡住；`后文补充` 只能用本次响应的 sourceIDs 绑定。
    """

    def setUp(self):
        self.data = note_input(aliases=['q0', 'q1'])
        self.schema = note_schema(self.data)

    def test_every_provided_alias_is_required_exactly_once(self):
        jsonschema.validate(note({'q0': followup('后文补充', ['en0s0'], '同一对象有了新依据。'),
                                  'q1': followup('缺信息')}), self.schema)
        for incomplete in ({'q0': followup('缺信息')}, {'q1': followup('缺信息')}, {}):
            with self.assertRaises(jsonschema.ValidationError, msg=repr(incomplete)):
                jsonschema.validate(note(incomplete), self.schema)
        for renamed in ({'q0': followup('缺信息'), 'q2': followup('缺信息')},
                        {'q0': followup('缺信息'), 'q1': followup('缺信息'), 'followUps': followup('缺信息')}):
            with self.assertRaises(jsonschema.ValidationError, msg=repr(renamed)):
                jsonschema.validate(note(renamed), self.schema)

    def test_states_and_sources_are_bounded(self):
        for state in ('缺信息', '后文补充', '前后冲突', '关系不明'):
            jsonschema.validate(note({'q0': followup(state), 'q1': followup(state)}), self.schema)
        for state in ('已解决', '补充', 'unknown', None, 1):
            with self.assertRaises(jsonschema.ValidationError, msg=repr(state)):
                jsonschema.validate(note({'q0': followup(state), 'q1': followup('缺信息')}), self.schema)
        # 只能用本次响应的短 ID：旧问题自己的引文和编造编号都无效。
        for source_ids in (['missing'], ['Source A.'], ['q0'], ['en0s0', 'en0s1', 'zh0s0']):
            with self.assertRaises(jsonschema.ValidationError, msg=repr(source_ids)):
                jsonschema.validate(note({'q0': followup('后文补充', source_ids),
                                          'q1': followup('缺信息')}), self.schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(note({'q0': {'state': '缺信息', 'sourceIDs': []},
                                      'q1': followup('缺信息')}), self.schema)

    def test_note_without_pending_points_requires_an_empty_object(self):
        schema = note_schema(note_input(aliases=[]))
        jsonschema.validate(note({}), schema)
        jsonschema.validate(note({}, no_new_knowledge=True), schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(note({'q0': followup('缺信息')}), schema)

    def test_points_no_longer_carry_clarifies(self):
        # 跟进判断已经拆到顶层 followUps；旧的逐点 clarifies 不再进语法。
        legacy = {'kind': '核心结论', 'text': '保留正文', 'sourceIDs': ['en0s0'],
                  'needsContext': None, 'clarifies': 'q0'}
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(note({'q0': followup('后文补充', ['en0s0']), 'q1': followup('缺信息')},
                                     points=[legacy]), self.schema)

    def test_legacy_response_without_follow_ups_is_refused(self):
        # 旧版响应结构（没有 followUps）必须被挡住，而不是静默通过。
        value = note(None)
        value.pop('followUps')
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(value, self.schema)
        value['followUps'] = {}
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(value, self.schema)


class ReviewSchemaTests(unittest.TestCase):
    def setUp(self):
        self.data = review_input()
        self.schema = review_schema(self.data)

    def test_quote_ids_bind_evidence_without_copying_source_text(self):
        grammar = json.dumps(self.schema, ensure_ascii=False)
        # 原文只存在于模型输入与冻结 catalog 中；DFA 只保留短 ID。
        for marker in ('Source A.', '原文甲。', 'Source B.', '原文乙。'):
            self.assertNotIn(marker, grammar)
        for quote_id in ('e0.en.0', 'e0.zh.0', 'e1.en.0', 'e1.zh.0'):
            self.assertIn(quote_id, grammar)
        jsonschema.validate(response(additions=[addition(0, 'e0.en.0')]), self.schema)
        jsonschema.validate(response(additions=[addition(1, 'e1.zh.0')]), self.schema)
        jsonschema.validate(response(), self.schema)

    def test_fabricated_quote_ids_are_rejected(self):
        for evidence_index, quote_id in [(0, 'e0.en.9'), (0, 'invented'), (0, 'Source A.'), (0, 'e1.en.0')]:
            with self.assertRaises(jsonschema.ValidationError, msg=f'{evidence_index}/{quote_id}'):
                jsonschema.validate(response(additions=[addition(evidence_index, quote_id)]), self.schema)

    def test_cross_evidence_quote_id_is_invalid(self):
        # 每个证据条目只接受自己的短 ID：跨证据引用必须被语法挡住。
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(additions=[addition(1, 'e0.zh.0')]), self.schema)

    def test_evidence_without_quotes_contributes_no_addition(self):
        units = [{'index': 0, 'quotes': []},
                 {'index': 1, 'quotes': [quote(1, 'en', text='Source B.')]}]
        schema = review_schema(review_input(units=units))
        jsonschema.validate(response(additions=[addition(1, 'e1.en.0')]), schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(additions=[addition(0, 'e1.en.0')]), schema)

    def test_quote_and_quote_id_cannot_be_mixed(self):
        mixed = addition(0, 'e0.en.0')
        mixed['quote'] = 'Source A.'
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(additions=[mixed]), self.schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(additions=[addition(0, 'e0.en.0', extra='x')]), self.schema)

    def test_response_root_requires_review_version_two(self):
        for version in (None, 1, 3, '2'):
            with self.assertRaises(jsonschema.ValidationError, msg=repr(version)):
                jsonschema.validate(response(version=version), self.schema)
        payload = response()
        payload.pop('additions')
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, self.schema)

    def test_corrections_keep_their_original_interface(self):
        correction = {'index': 0, 'original': '原笔记甲', 'kind': '核心结论', 'text': '建议', 'reason': '理由'}
        jsonschema.validate(response(corrections=[correction]), self.schema)
        correction['index'] = 1
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(corrections=[correction]), self.schema)
        correction['index'] = 0
        correction['original'] = '编造的原笔记'
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(corrections=[correction]), self.schema)

    def test_empty_points_and_evidence_keep_empty_sides(self):
        schema = review_schema(review_input(units=[], points=[]))
        jsonschema.validate(response(), schema)
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(response(additions=[addition(0, 'e0.en.0')]), schema)

    def test_legacy_input_is_refused_by_the_schema_builder(self):
        legacy = {'note': {'points': [{'index': 0, 'text': '原笔记甲'}]},
                  'evidence': [{'index': 0, 'english': 'Source A.', 'chinese': '原文甲。'}]}
        with self.assertRaises(ValueError) as error:
            review_schema(legacy)
        self.assertIn('legacy_input', str(error.exception))
        plain = review_input()
        del plain['reviewVersion']
        with self.assertRaises(ValueError):
            review_schema(plain)

    def test_long_fragments_are_not_dropped(self):
        # 片段长度以 Swift Character 计（可达 2400），Python 码点数可能更多；
        # 任何长度的片段都必须继续可被短 ID 引用，不能因为 len() 被丢掉。
        combined = 'a' + '\u0301' * 3_000
        self.assertGreater(len(combined), 2_400)
        units = [{'index': 0, 'quotes': [quote(0, 'en', text='x' * 4_000),
                                        quote(0, 'zh', fragment=1, text=combined)]}]
        schema = review_schema(review_input(units=units))
        grammar = json.dumps(schema, ensure_ascii=False)
        self.assertIn('e0.zh.1', grammar)
        jsonschema.validate(response(additions=[addition(0, 'e0.zh.1')]), schema)

    def test_outlines_dfa_builds(self):
        if importlib.util.find_spec('outlines_core') is None:
            self.skipTest('outlines_core is not installed in this interpreter')
        from outlines_core import Index, Vocabulary
        from outlines_core.json_schema import build_regex_from_schema
        units = [{'index': i, 'quotes': [quote(i, 'en', text='Source %d.' % i),
                                         quote(i, 'zh', text='原文%d。' % i)]} for i in range(6)]
        points = [{'index': i, 'text': '原笔记%d' % i} for i in range(3)]
        schema = review_schema(review_input(units=units, points=points))
        regex = build_regex_from_schema(json.dumps(schema, ensure_ascii=False))
        vocabulary = Vocabulary(0, {c: [i + 1] for i, c in enumerate(
            sorted(set(regex + ''.join(chr(i) for i in range(32, 127))))) })
        self.assertIsNotNone(Index(regex, vocabulary))


if __name__ == '__main__':
    unittest.main()
