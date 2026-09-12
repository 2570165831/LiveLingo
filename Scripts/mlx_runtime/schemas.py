KINDS=['核心结论','概念关系','例子','易错点','补充理解','待确认']
STRING={'type':'string'}
def obj(properties):return {'type':'object','properties':properties,'required':list(properties),'additionalProperties':False}
def array(items,minimum=0):return {'type':'array','items':items,'minItems':minimum}
def note_schema(data):
 ids=[u['id'] for u in data['evidence']]
 followups=[p['id'] for p in data.get('pendingPoints',[])]
 normal=obj({'sourceVersion':{'const':2},'topic':STRING,'noNewKnowledge':{'const':False},'points':array(obj({'kind':{'enum':KINDS},'text':STRING,'sourceIDs':array({'enum':ids}) if ids else {'const':[]},'needsContext':{'type':['string','null']},'clarifies':{'enum':[None,*followups]}}),1)})
 empty=obj({'sourceVersion':{'const':2},'topic':{'const':'无新增学习知识'},'points':{'const':[]},'noNewKnowledge':{'const':True}})
 return {'oneOf':[normal,empty]}
def review_schema(data):
 indices=[p.get('index',i) for i,p in enumerate(data['note']['points'])]
 evidence=[p.get('index',i) for i,p in enumerate(data['evidence'])]
 return obj({'corrections':array(obj({'index':{'enum':indices},'original':STRING,'kind':{'enum':KINDS},'text':STRING,'reason':STRING})) if indices else {'const':[]},'additions':array(obj({'evidenceIndex':{'enum':evidence},'quote':STRING,'kind':{'enum':KINDS},'text':STRING,'reason':STRING})) if evidence else {'const':[]}})
