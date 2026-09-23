"""Response grammars for the owned MLX worker.

Review responses are versioned with the request. Review ``reviewVersion=2``
binds every addition to the short quote IDs the app's fragmenter emitted, so
the DFA (and therefore the sampling loop) never carries the transcript text
again: the fragment text stays in the model input and in the app's frozen
catalog. Input validation lives in ``review_diagnostics``.

Note responses (2026-09-22) additionally carry a **required** top-level
``followUps`` object keyed by the pending-point aliases (``q0``, ``q1`` ...)
the app froze for that exact request. Every provided alias must appear exactly
once with one of the four states, so a missing or renamed entry cannot retire
an earlier open question; ``后文补充`` binds its support with the same
response's ``sourceIDs`` (same-ID enum as the points, never transcript text).
"""
from review_diagnostics import review_input_problem

KINDS=['核心结论','概念关系','例子','易错点','补充理解','待确认']
FOLLOWUP_STATES=['缺信息','后文补充','前后冲突','关系不明']
STRING={'type':'string'}
REVIEW_VERSION=2
def obj(properties):return {'type':'object','properties':properties,'required':list(properties),'additionalProperties':False}
def array(items,minimum=0):return {'type':'array','items':items,'minItems':minimum}
def note_sources(ids):
 # Match the Swift provenance boundary while generating. An unbounded array
 # allowed otherwise correct notes to emit three or more IDs and lose linkage.
 return {**array({'enum':ids}),'maxItems':2} if ids else {'const':[]}
def followup_schema(aliases,sources):
 # 每个已提供的 q 编号都必须出现一次：漏写或改名不能让旧问题消失。
 if not aliases:return {'type':'object','properties':{},'required':[],'additionalProperties':False}
 entry=obj({'state':{'enum':FOLLOWUP_STATES},'sourceIDs':sources,'detail':STRING})
 return obj({alias:entry for alias in aliases})
def note_schema(data):
 ids=[u['id'] for u in data['evidence']]
 followups=[p['id'] for p in data.get('pendingPoints',[])]
 sources=note_sources(ids)
 entries=followup_schema(followups,sources)
 normal=obj({'sourceVersion':{'const':2},'topic':STRING,'noNewKnowledge':{'const':False},'points':array(obj({'kind':{'enum':KINDS},'text':STRING,'sourceIDs':sources,'needsContext':{'type':['string','null']}}),1),'followUps':entries})
 empty=obj({'sourceVersion':{'const':2},'topic':{'const':'无新增学习知识'},'points':{'const':[]},'noNewKnowledge':{'const':True},'followUps':entries})
 return {'oneOf':[normal,empty]}
def review_schema(data):
 # Refuse to constrain a payload the worker would not accept: a legacy or
 # malformed input must fail with a structured compatibility error instead of
 # silently producing a schema for the wrong shape.
 problem=review_input_problem(data)
 if problem is not None:
  raise ValueError(f'review input rejected: {problem[0]} at {problem[1]}')
 # Corrections keep their original interface: index and the exact note text.
 # Additions reference the app's short quote IDs instead of repeating the
 # transcript, and length/count limits stay in the caller's validator so the
 # grammar does not grow with the length of the sources.
 review_text=STRING
 corrections=[]
 for i,p in enumerate(data['note']['points']):
  corrections.append(obj({'index':{'const':p.get('index',i)},'original':{'const':p['text']},'kind':{'enum':KINDS},'text':review_text,'reason':review_text}))
 additions=[]
 for i,p in enumerate(data['evidence']):
  quote_ids=[q['id'] for q in p['quotes']]
  # enum 只收录该证据非空的短 ID；没有引文的证据不产生可引用的分支。
  if not quote_ids:continue
  additions.append(obj({'evidenceIndex':{'const':p.get('index',i)},'quoteID':{'enum':quote_ids},'kind':{'enum':KINDS},'text':review_text,'reason':review_text}))
 def bounded(items):
  if not items:return {'const':[]}
  return array({'oneOf':items})
 return obj({'reviewVersion':{'const':REVIEW_VERSION},'corrections':bounded(corrections),'additions':bounded(additions)})
