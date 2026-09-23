#!/usr/bin/env python3
"""Synthetic protocol regression. All writable evidence stays under an explicit test directory.

No model, real recording, AppModel or production queue is started. The original
quality-v1 corpus and its gold/manifest are read-only. Run with Python -B.
"""
from __future__ import annotations
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
CORPUS = HERE / 'Fixtures/learning-quality-v1'
spec = importlib.util.spec_from_file_location('learning_quality_scorer', HERE / 'evaluate-learning-quality.py')
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)
sha = lambda data: hashlib.sha256(data).hexdigest()


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def render(batches, latest=False):
    # Deliberately simple *synthetic* layout. Swift regression separately checks
    # actual notebook rendering rather than using this helper as that evidence.
    places = scorer.placements(batches, latest=latest)
    parts = {'body': [], 'replay': []}
    for batch in batches:
        for i, point in enumerate(batch['note']['points']):
            place = places[f"{batch['id']}:{i}"]
            if place != 'hidden': parts[place].append(scorer.point_line(point))
    return '\n\n'.join('## ' + ('课堂正文' if place == 'body' else '需要回听') + '\n' + '\n'.join(lines)
                       for place, lines in parts.items() if lines)


def make_probe(directory, case_id='constant-acceleration', custom_points=None, custom_topic=None,
               pending=None, representation='revisioned'):
    """Create clearly labelled synthetic output with complete independent artifacts."""
    directory.mkdir(parents=True, exist_ok=False)
    fixture_bytes = (CORPUS / (case_id + '.json')).read_bytes()
    case = json.loads(fixture_bytes)
    (directory / 'fixture.json').write_bytes(fixture_bytes)
    gold = next(c for c in json.loads((CORPUS/'gold.json').read_text())['cases'] if c['id'] == case_id)
    producer = {'executableSHA256': 'a'*64, 'promptSHA256': 'b'*64, 'sourceRepresentation': representation,
                'sourcePolicy': scorer.SOURCE_POLICY, 'displayContract': scorer.DISPLAY_CONTRACT,
                'batchCharacters': 4000, 'generationOrigin': 'synthetic-regression'}
    result = {'probeVersion': 2, 'fixtureID': case_id, 'fixtureSHA256': sha(fixture_bytes),
              'producer': producer, 'model': 'synthetic-regression-no-model', 'stages': [], 'requests': [],
              'requestedRequests': 0, 'successfulRequests': 0}
    batches, previous_count = [], 0
    for stage_index, source_rows in enumerate(case['stages']):
        full_sources = scorer.frozen_sources(case, stage_index + 1)
        new = full_sources[previous_count:]
        previous_count = len(full_sources)
        for group_start in range(0, len(new), 9):
            evidence = copy.deepcopy(new[group_start:group_start+9])
            for source in evidence:
                if representation == 'legacy': source.pop('inputRevision')
                else: source['translationState'] = 'completed'
            units = [{'id': f'{lang}{i}s0', 'index': i, 'language': lang, 'text': s[key]}
                     for i, s in enumerate(evidence) for lang, key in [('en','english'),('zh','chinese')]]
            unit_map = {u['id']: u for u in units}
            source_batch = str(uuid.uuid4()).upper()
            supplied = (custom_points or {}).get(stage_index)
            if supplied is None:
                supplied = [{'kind':'核心结论','text':s['chinese'],'sourceIDs':[f'zh{i}s0'],
                             'needsContext':None,'clarifies':None} for i,s in enumerate(evidence)]
            raw = {'sourceVersion':2, 'topic':(custom_topic or {}).get(stage_index,'课堂知识'),
                   'points':copy.deepcopy(supplied), 'noNewKnowledge':not supplied}
            normal = copy.deepcopy(raw)
            targets = [f"{batches[b]['id']}:{i}" for b,i in (pending or {}).get(stage_index,[])]
            followups = []
            for i, target in enumerate(targets):
                old_batch, old_index = target.rsplit(':',1)
                old = next(b for b in batches if b['id']==old_batch)['note']['points'][int(old_index)]
                followups.append({'id':f'q{i}','question':'当前原文是否补充了同一对象的关系？',
                                  'quotes':[s['quote'][:600] for s in old.get('sources',[])][:2],
                                  'candidateQuotes':[], 'referenceCheck':False})
            for point in normal['points']:
                if point.get('clarifies') is not None:
                    point['clarifies'] = targets[int(point['clarifies'][1:])]
            bound = copy.deepcopy(normal)
            for point in bound['points']:
                ids = point['sourceIDs']
                linked = [{'index':unit_map[x]['index'],'quote':unit_map[x]['text']} for x in ids]
                point['sources'] = linked
                question = (point.get('needsContext') or '')[:240].strip()
                owner_indices = sorted({s['index'] for s in linked})
                own_segments = [text for owner in owner_indices
                                for text in (evidence[owner]['english'], evidence[owner]['chinese'])]
                all_segments = [text for source in evidence
                                for text in (source['english'], source['chinese'])]
                difference,gap = scorer.numeric_report(point['text'],[s['quote'] for s in linked],
                                                       own_segments,all_segments)
                if not ids and point['kind']=='补充理解': state = None
                elif question: state = 'awaitingContext'
                elif difference:
                    state,question = 'numericDifference',scorer.NUMERIC_CONTEXT
                else: state = 'linked'
                if state is not None: point['referenceState']=state
                point['needsContext']=question or None
                point['sourceHasPronoun']=False
                if linked and state in ('linked','numericDifference') and gap:
                    point['numericGap']=gap
            batch = {'id':source_batch,'evidence':evidence,'note':bound}
            number = len(result['requests'])+1
            prepared = {'evidence':units,'pendingPoints':followups}
            input_file,response_file = f'input-{number}.json',f'response-{number}.txt'
            (directory/input_file).write_bytes(encode(prepared))
            (directory/response_file).write_bytes(encode(raw))
            result['requests'].append({'number':number,'stage':stage_index+1,'evidence':copy.deepcopy(evidence),
                'sourceUnits':units,'pendingTargets':targets,'inputFile':input_file,'inputSHA256':sha(encode(prepared)),
                'responseFile':response_file,'responseSHA256':sha(encode(raw)),'normalizedNote':normal,
                'batchID':source_batch,'outcome':'committed'})
            batches.append(batch)
        full, latest = render(batches),render(batches,latest=True)
        full_places,latest_places = scorer.placements(batches),scorer.placements(batches,latest=True)
        displays=[]
        for batch in batches:
            for i, point in enumerate(batch['note']['points']):
                ref=f"{batch['id']}:{i}"
                displays.append({'reference':ref,'hasOpenQuestion':scorer.open_question(point),
                                 'fullDisposition':full_places[ref],'latestDisposition':latest_places[ref],
                                 'renderedLine':scorer.point_line(point),'resolvedClarifies':point.get('clarifies')})
        count=len(result['requests'])
        result['stages'].append({'number':stage_index+1,'elapsedSeconds':float(stage_index+1),
             'batches':copy.deepcopy(batches),'markdown':full,'latestMarkdown':latest,
             'coveredSourceIDs':[s['id'] for s in full_sources],'displayPoints':displays,
             'requestedRequests':count,'successfulRequests':count})
        (directory/f'notes-stage-{stage_index+1}.md').write_text(full)
    result['requestedRequests']=result['successfulRequests']=len(result['requests'])
    (directory/'result.json').write_bytes(encode(result))
    return case,gold,result


class QualityScoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        location=os.environ.get('LIVELINGO_QUALITY_TEST_DIRECTORY')
        if not location: raise RuntimeError('Set LIVELINGO_QUALITY_TEST_DIRECTORY to an isolated evidence directory')
        cls.root=Path(location)
        if not cls.root.is_absolute(): raise RuntimeError('Test directory must be absolute')
        cls.root.mkdir(parents=True,exist_ok=True)
        cls.original={p.name:sha(p.read_bytes()) for p in CORPUS.iterdir() if p.is_file()}
    @classmethod
    def tearDownClass(cls):
        assert cls.original=={p.name:sha(p.read_bytes()) for p in CORPUS.iterdir() if p.is_file()},'Original corpus was changed'
    def setUp(self):
        self.directory=Path(tempfile.mkdtemp(prefix=self._testMethodName+'.',dir=self.root))/'probe'
        self.case,self.gold,self.result=make_probe(self.directory)
    def assess(self,result=None,**kwargs):
        return scorer.evaluate_case(self.gold,self.case,result or self.result,directory=self.directory,
                  fixture_sha=self.result['fixtureSHA256'],allow_synthetic=True,**kwargs)
    def reject(self,result=None,reason=None):
        report=self.assess(result)
        self.assertEqual(report['integrityStatus'],'failed',report)
        self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
        if reason: self.assertIn(reason,report['error'])
        return report
    def new_case(self,**kwargs):
        self.directory=self.directory.parent/str(uuid.uuid4())
        self.case,self.gold,self.result=make_probe(self.directory,**kwargs)
    def write_artifact(self,request_index,kind,value):
        request=self.result['requests'][request_index]
        data=encode(value)
        (self.directory/request[kind+'File']).write_bytes(data)
        request[kind+'SHA256']=sha(data)

    def test_nominal_complete_evidence_is_pending_not_semantic_pass(self):
        report=self.assess()
        self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertEqual(report['semanticCorrectness'],scorer.PENDING)
        self.assertTrue(any(f['coverageSignal'] for f in report['facts']))
        self.assertTrue(all(f['semanticStatus']==scorer.PENDING for f in report['facts']))
    def test_synthetic_is_rejected_without_explicit_test_mode(self):
        report=scorer.evaluate_case(self.gold,self.case,self.result,directory=self.directory,
                                    fixture_sha=self.result['fixtureSHA256'])
        self.assertIn('synthetic-or-unknown',report['error'])
    def test_legacy_representation_is_explicitly_supported(self):
        self.new_case(representation='legacy')
        self.assertEqual(self.assess()['integrityStatus'],'pass')
    def test_stage_duplicate_gap_order_and_boolean(self):
        for kind in ['duplicate','gap','order','boolean','missing','empty']:
            with self.subTest(kind=kind):
                result=copy.deepcopy(self.result)
                if kind=='duplicate': result['stages'].insert(0,copy.deepcopy(result['stages'][0]))
                if kind=='gap': result['stages'][0]['number']=2;result['stages'][1]['number']=3
                if kind=='order': result['stages'].reverse()
                if kind=='boolean': result['stages'][0]['number']=True
                if kind=='missing': result['stages']=result['stages'][1:]
                if kind=='empty': result['stages']=[]
                self.reject(result,'stages-must')
    def test_source_body_time_revision_and_session(self):
        for key,value in [('english','Unrelated text.'),('chinese','其他内容。'),('startTime',9999),
                          ('endTime',9999),('inputRevision',1),('inputRevision',True),
                          ('sessionID',str(uuid.uuid4()).upper()),('translationState','failed')]:
            with self.subTest(key=key,value=value):
                result=copy.deepcopy(self.result)
                for stage in result['stages']:stage['batches'][0]['evidence'][0][key]=value
                self.reject(result,'source-')
    def test_duplicate_covered_ID(self):
        self.result['stages'][0]['coveredSourceIDs'].append(self.result['stages'][0]['coveredSourceIDs'][0])
        self.reject(reason='covered-source-ID:duplicate')
    def test_wrong_and_repeated_evidence_ID(self):
        for duplicate in [False,True]:
            with self.subTest(duplicate=duplicate):
                result=copy.deepcopy(self.result);evidence=result['stages'][0]['batches'][0]['evidence']
                if duplicate:evidence.append(copy.deepcopy(evidence[0]))
                else:evidence[0]['id']=str(uuid.uuid4()).upper()
                self.reject(result)
    def test_historical_batch_cannot_change(self):
        self.result['stages'][1]['batches'][0]['note']['points'][0]['text']='历史被改写。'
        self.reject(reason='historical-batch-prefix')
    def test_requests_count_outcome_and_stage_must_match(self):
        changes=[('requestedRequests',0),('successfulRequests',0),('successfulRequests',True)]
        for key,value in changes:
            with self.subTest(key=key,value=value):
                r=copy.deepcopy(self.result);r[key]=value;self.reject(r)
        for key,value in [('number',True),('stage',2),('outcome','failed'),('batchID',str(uuid.uuid4()).upper())]:
            with self.subTest(key=key,value=value):
                r=copy.deepcopy(self.result);r['requests'][0][key]=value;self.reject(r)
    def test_extra_request_and_stage_count(self):
        r=copy.deepcopy(self.result);r['requests'].append(copy.deepcopy(r['requests'][0]));self.reject(r)
        self.result['stages'][0]['successfulRequests']=99;self.reject(reason='stage-request-count')
    def test_response_and_input_hashes_must_match(self):
        for kind in ['response','input']:
            with self.subTest(kind=kind):
                r=copy.deepcopy(self.result);r['requests'][0][kind+'SHA256']='0'*64;self.reject(r,'artifact-hash')
    def test_input_catalog_body_order_and_completeness(self):
        for mutation in ['body','order','drop','id']:
            with self.subTest(mutation=mutation):
                r=copy.deepcopy(self.result);units=r['requests'][0]['sourceUnits']
                if mutation=='body':units[0]['text']='Other lecture.'
                elif mutation=='order':units.reverse()
                elif mutation=='drop':units.pop()
                else:units[0]['id']='en99s0'
                self.reject(r,'missing-source-language' if mutation == 'drop' else 'source-unit')
    def test_point_invalid_source_index_and_quote(self):
        for key,value in [('sourceIDs',['missing']),('sources',[{'index':999,'quote':'unrelated'}])]:
            with self.subTest(key=key):
                r=copy.deepcopy(self.result)
                for stage in r['stages']:stage['batches'][0]['note']['points'][0][key]=value
                self.reject(r)
    def test_point_source_limit_and_duplicates(self):
        for values in [['zh0s0','zh0s0'],['en0s0','zh0s0','zh1s0']]:
            with self.subTest(values=values):
                r=copy.deepcopy(self.result)
                for stage in r['stages']:stage['batches'][0]['note']['points'][0]['sourceIDs']=values
                self.reject(r,'point-source-ID')
    def test_empty_body_is_invalid_even_with_full_title(self):
        self.new_case(custom_points={0:[{'kind':'核心结论','text':'','sourceIDs':['zh0s0'],'needsContext':None,'clarifies':None}]},
                      custom_topic={0:'初速度为3 m/s，加速度恒为2 m/s²；v = u + at。'})
        self.reject(reason='invalid-point')
    def test_title_facts_cannot_supply_body_coverage(self):
        pts={i:[{'kind':'核心结论','text':'这一项内容稍后说明。','sourceIDs':['zh0s0'],'needsContext':None,'clarifies':None}] for i in range(2)}
        self.new_case(custom_points=pts,custom_topic={0:'初速度为3 m/s，加速度恒为2 m/s²；v = u + at。',1:'4秒后速度11 m/s；要求恒定加速度。'})
        report=self.assess();self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
    def test_warning_preface_with_keywords_is_not_body_credit(self):
        pts={i:[{'kind':'核心结论','text':'待核实清单，以下内容均未确认：初速度3 m/s；加速度恒为2 m/s²；v = u + at；4秒后速度11 m/s。',
                 'sourceIDs':['zh0s0','zh1s0'],'needsContext':None,'clarifies':None}] for i in range(2)}
        self.new_case(custom_points=pts);report=self.assess()
        self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertTrue(any(f['lexicalSignal'] for f in report['facts']))
        self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
    def test_negated_known_claims_do_not_get_automatic_credit(self):
        pts={i:[{'kind':'核心结论','text':'初速度为3米；加速度恒为2米；公式 v = u + at 不成立。4秒后速度不等于11米；公式不要求恒定加速度。',
                 'sourceIDs':['zh0s0','zh1s0'],'needsContext':None,'clarifies':None}] for i in range(2)}
        self.new_case(custom_points=pts);report=self.assess()
        self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
    def test_unresolved_question_and_pending_kind_are_excluded(self):
        for kind,context in [('核心结论','加速度归属未明确。'),('待确认',None)]:
            with self.subTest(kind=kind):
                pts={i:[{'kind':kind,'text':'初速度为3 m/s，加速度恒为2 m/s²；v = u + at；4秒后速度11 m/s。',
                         'sourceIDs':['zh0s0','zh1s0'],'needsContext':context,'clarifies':None}] for i in range(2)}
                self.new_case(custom_points=pts);report=self.assess()
                self.assertEqual(report['integrityStatus'],'pass',report)
                self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
    def test_whitespace_and_numeric_advisory_match_production_property(self):
        self.assertFalse(scorer.open_question({'kind':'核心结论','needsContext':'   '}))
        self.assertFalse(scorer.open_question({'kind':'核心结论','needsContext':scorer.NUMERIC_CONTEXT}))
        self.assertTrue(scorer.open_question({'kind':'核心结论','needsContext':'这属于谁？','referenceState':'numericDifference'}))
    def test_fake_numeric_state_cannot_hide_question(self):
        for stage in self.result['stages']:
            point=stage['batches'][0]['note']['points'][0]
            point['needsContext']='真正的问题。';point['referenceState']='numericDifference'
        self.reject(reason='point-binding-question-or-state')
    def test_numeric_provenance_ignores_labels_and_separates_other_sentences(self):
        self.assertEqual(scorer.numeric_report('K7、样品M2为20摄氏度。',
                         ['K7、样品M2为20摄氏度。'],['K7、样品M2为20摄氏度。'],
                         ['K7、样品M2为20摄氏度。']), (False,None))
        difference,gap=scorer.numeric_report('温度为20摄氏度。',['这里介绍温度。'],
                         ['这里介绍温度。'],['这里介绍温度。','另一句说温度为20摄氏度。'])
        self.assertFalse(difference)
        self.assertIn('其他句子',gap)
        difference,gap=scorer.numeric_report('温度为20摄氏度。',['压强为20千帕。'],
                         ['压强为20千帕。'],['压强为20千帕。'])
        self.assertTrue(difference)
        self.assertIn('单位不同',gap)
    def test_committed_followup_retires_only_bound_old_question(self):
        first=[{'kind':'待确认','text':'温度为20摄氏度，所属样品不明。',
                'sourceIDs':['zh0s0'],'needsContext':'属于哪个样品？','clarifies':None}]
        second=[{'kind':'核心结论','text':'样品甲温度为20摄氏度。',
                 'sourceIDs':['zh0s0'],'needsContext':None,'clarifies':None}]
        self.new_case(custom_points={0:first,1:second},pending={1:[(0,0)]})
        request=self.result['requests'][1]
        target=request['pendingTargets'][0]
        raw=json.loads((self.directory/request['responseFile']).read_text())
        raw['followUps']={'q0':{'state':'后文补充','sourceIDs':['zh0s0'],'detail':'后文明确给出样品甲。'}}
        self.write_artifact(1,'response',raw)
        request['normalizedNote']['followUps']=[{'alias':'q0','target':target,'state':'后文补充',
            'sourceIDs':['zh0s0'],'detail':'后文明确给出样品甲。'}]
        stage=self.result['stages'][1]
        batch=stage['batches'][1]
        batch['followUps']=[{'alias':'q0','target':target,'state':'后文补充','sourceIDs':['zh0s0'],
            'pointIndex':0,'detail':'后文明确给出样品甲。',
            'evidenceIDs':[s['id'] for s in batch['evidence']],'notebookRevision':1}]
        stage['markdown']=render(stage['batches'])
        stage['latestMarkdown']=render(stage['batches'],latest=True)
        (self.directory/'notes-stage-2.md').write_text(stage['markdown'])
        full=scorer.placements(stage['batches'])
        latest=scorer.placements(stage['batches'],latest=True)
        for display in stage['displayPoints']:
            display['fullDisposition']=full[display['reference']]
            display['latestDisposition']=latest[display['reference']]
        report=self.assess()
        self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertEqual(stage['displayPoints'][0]['fullDisposition'],'body')
        self.assertEqual(stage['displayPoints'][0]['latestDisposition'],'hidden')
        forged=copy.deepcopy(self.result)
        forged['stages'][1]['batches'][1]['followUps'][0]['target']='unknown:0'
        self.reject(forged,'committed-followup-binding')
    def test_only_quotations_do_not_count(self):
        pts={i:[{'kind':'核心结论','text':'今天继续上课。','sourceIDs':['zh0s0','zh1s0'],'needsContext':None,'clarifies':None}] for i in range(2)}
        self.new_case(custom_points=pts);report=self.assess()
        self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertFalse(any(f['coverageSignal'] for f in report['facts']))
    def test_empty_markdown_or_latest_rejected(self):
        for key in ['markdown','latestMarkdown']:
            with self.subTest(key=key):
                r=copy.deepcopy(self.result);r['stages'][1][key]=''
                self.reject(r)
    def test_saved_markdown_must_equal_result(self):
        (self.directory/'notes-stage-1.md').write_text('replaced')
        self.reject(reason='saved-markdown-mismatch')
    def test_correct_followup_is_replay_until_explicit_semantic_readback(self):
        first=[{'kind':'待确认','text':'温度20摄氏度，样品归属待确认。','sourceIDs':['zh1s0'],
                'needsContext':'温度属于哪个样品？','clarifies':None}]
        second=[{'kind':'核心结论','text':'样品A加热前20摄氏度。','sourceIDs':['zh0s0'],'needsContext':None,'clarifies':'q0'},
                {'kind':'核心结论','text':'样品B加热前30摄氏度。','sourceIDs':['zh1s0'],'needsContext':None,'clarifies':None}]
        self.new_case(case_id='late-reference',custom_points={0:first,1:second},pending={1:[(0,0)]})
        report=self.assess();self.assertEqual(report['integrityStatus'],'pass',report)
        linked=[p for p in report['pointReadback']['2'] if p.get('resolvedClarifies')]
        self.assertEqual(linked[0]['fullDisposition'],'replay')
        self.assertEqual(linked[0]['latestDisposition'],'replay')
        self.assertFalse(linked[0]['eligibleBodySignal'])
        self.assertTrue(all(x['status']==scorer.PENDING for x in report['semanticRequirements']))
    def test_unknown_forward_self_followup_rejected(self):
        for target in ['NONEXISTENT-BATCH:999',f"{self.result['stages'][0]['batches'][0]['id']}:0"]:
            r=copy.deepcopy(self.result)
            for stage in r['stages']:stage['batches'][0]['note']['points'][0]['clarifies']=target
            self.reject(r,'clarifies-target-mismatch')
    def test_no_new_knowledge_can_be_structural_but_never_semantic_success(self):
        self.new_case(custom_points={0:[],1:[]})
        report=self.assess();self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertEqual(report['coverageStatus'],'no-valid-body-signals')
        self.assertEqual(report['semanticCorrectness'],scorer.PENDING)
    def test_chatter_retained_empty_then_new_knowledge(self):
        self.new_case(case_id='chatter-then-knowledge',custom_points={0:[]})
        report=self.assess();self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertEqual(report['pointReadback']['1'],[])
        self.assertTrue(report['semanticRequirements'][0]['structuralWitnessPresent'])
    def test_overflow_counts_real_distinct_committed_requests(self):
        self.new_case(case_id='overflow-ledger')
        report=self.assess();self.assertEqual(report['integrityStatus'],'pass',report)
        self.assertEqual(report['successfulRequests'],2)
        self.result['successfulRequests']=999;self.reject(reason='successful-count')
    def test_missing_artifacts_cannot_be_accepted(self):
        r=copy.deepcopy(self.result);r['requests'][0]['responseFile']='not-present.txt';self.reject(r)
    def test_legacy_probe_cannot_be_relabelled_v2_without_evidence(self):
        r=copy.deepcopy(self.result);r.pop('probeVersion');self.reject(r,'probe-v2-required')
        r['probeVersion']=2;r.pop('requests');self.reject(r,'requests:object-array-required')
    def test_injected_origin_without_required_manifest_is_rejected_as_real(self):
        self.result['producer']['generationOrigin']='production-model'
        self.reject(reason='artifact-missing:quality-build-manifest.json')
    def test_json_duplicate_keys_and_nan_are_rejected(self):
        for text in ['{"x":1,"x":2}','{"x":NaN}','{"x":Infinity}']:
            with self.subTest(text=text):
                with self.assertRaises(scorer.IntegrityError):scorer.decode(text)
    def test_symlink_escape_is_rejected(self):
        link=self.directory/'escaped.txt'
        link.symlink_to(self.directory/'response-1.txt')
        with self.assertRaises(scorer.IntegrityError):scorer.artifact(self.directory,'escaped.txt',self.result['requests'][0]['responseSHA256'])
    def test_stage_errors_and_nonfinite_elapsed_rejected(self):
        for key,value in [('error','failed'),('elapsedSeconds',float('nan')),('elapsedSeconds',-1)]:
            with self.subTest(key=key,value=value):
                r=copy.deepcopy(self.result);r['stages'][0][key]=value;self.reject(r)
    def test_structural_failure_cannot_reduce_fact_denominator(self):
        report=scorer.score(CORPUS,self.directory/'missing',allow_synthetic=True)
        self.assertEqual(report['totals']['expectedCases'],10)
        self.assertEqual(report['totals']['expectedFacts'],55)
        self.assertEqual(report['totals']['missingCases'],10)
        self.assertEqual(report['totals']['semanticallyAcceptedFacts'],0)
        self.assertEqual(report['bySplit']['development']['expectedFacts'],17)
        self.assertEqual(report['bySplit']['holdout']['expectedFacts'],38)
    def test_cli_returns_two_for_missing_results_and_preserves_report(self):
        output=self.directory/'missing-report.json'
        r=subprocess.run([sys.executable,'-B',str(HERE/'evaluate-learning-quality.py'),'--corpus',str(CORPUS),
                          '--results',str(self.directory/'missing'),'--output',str(output)],capture_output=True,text=True)
        self.assertEqual(r.returncode,2,r.stderr)
        self.assertEqual(json.loads(output.read_text())['totals']['expectedFacts'],55)
    def test_full_synthetic_set_has_exit_zero_for_structure_only(self):
        results=self.directory/'full'
        for item in json.loads((CORPUS/'gold.json').read_text())['cases']:
            make_probe(results/item['id'],case_id=item['id'])
        report=scorer.score(CORPUS,results,allow_synthetic=True)
        self.assertEqual(report['integrityStatus'],'pass',[(r['id'],r.get('error')) for r in report['cases']])
        self.assertEqual(report['totals']['semanticallyAcceptedFacts'],0)
        self.assertEqual(report['overallAcceptance'],'pending-semantic-readback-and-baseline-comparison')
    def test_unchanged_old_counterexamples_are_all_legacy_evidence(self):
        archive=self.root.parent/'counterexamples.json'
        if not archive.is_file():self.skipTest('Original audit archive is not in this checkout')
        items=json.loads(archive.read_text())['counterexamples']
        for item in items:
            with self.subTest(case=item['name']):
                case=json.loads((CORPUS/(item['fixture']+'.json')).read_text())
                gold=next(x for x in json.loads((CORPUS/'gold.json').read_text())['cases'] if x['id']==case['id'])
                report=scorer.evaluate_case(gold,case,item['input'],directory=self.directory,
                                           fixture_sha=sha((CORPUS/(case['id']+'.json')).read_bytes()),allow_synthetic=True)
                self.assertEqual(report['integrityStatus'],'failed')
                self.assertIn('probe-v2-required',report['error'])


if __name__=='__main__':
    unittest.main(verbosity=2)
