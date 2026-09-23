#!/usr/bin/env python3
"""Assemble an offline runtime from an explicitly selected, tested environment.
Run with that environment's Python. Refuses an existing destination; no downloads.
ChemPy's formula/composition feature uses an explicit dependency subset. Notebook,
ODE solvers and plotting APIs are not exposed by LiveLingo and are not packaged.
"""
import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import shutil

RUNTIME_MODULES=('worker.py','engine.py','schemas.py','checks.py','review_diagnostics.py','grammar_vocabulary.py')
# 先确认运行时模块都在，再谈环境：否则从克隆构建时只会看到裸的 FileNotFoundError，
# 不会知道"某个模块没有被纳入版本控制"。这段只用 stdlib，因此任何 python 都能先给出结论。
_source_dir=Path(__file__).parent/'mlx_runtime'
_missing=[name for name in RUNTIME_MODULES if not (_source_dir/name).is_file()]
if _missing:
 raise SystemExit(
  '缺少运行时模块：' + ', '.join(_missing) + '\n'
  '查找路径：' + str(_source_dir) + '\n'
  '提示：这些是运行时必需件；若从 git 克隆后缺失，说明它们没有被提交，先补齐再构建。')
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

parser=argparse.ArgumentParser()
parser.add_argument('--base-python',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
if args.output.exists():raise SystemExit('Refusing an existing runtime destination')
base=args.base_python.resolve()
if not (base/'bin/python3').is_file():raise SystemExit('Missing portable base Python')
root=args.output.resolve()
root.mkdir(parents=True)
shutil.copytree(base,root/'python',symlinks=True,ignore=shutil.ignore_patterns('__pycache__'))
site=root/'python/lib/python3.13/site-packages'
roots=['mlx','mlx-lm','outlines','Pint','sympy','chempy','numpy','scipy','quantities','pyparsing','setuptools']
selected={}
queue=roots[:]
while queue:
 name=canonicalize_name(queue.pop())
 if name in selected:continue
 dist=metadata.distribution(name);selected[name]=dist
 if name=='chempy':continue
 for raw in dist.requires or []:
  requirement=Requirement(raw)
  if requirement.marker is None or requirement.marker.evaluate({'extra':''}):
   installed=metadata.distribution(requirement.name)
   if installed.version not in requirement.specifier:raise RuntimeError(f'Version mismatch: {raw}')
   queue.append(requirement.name)
manifest=[]
missing=[]
lock_path=Path(__file__).parent.parent/'Packaging/MLXRuntime.lock.json'
lock=json.loads(lock_path.read_text())
actual={name:dist.version for name,dist in selected.items()}
if actual != lock:raise SystemExit('Runtime does not match the reviewed version lock')
for name,dist in sorted(selected.items()):
 license_dir=root/'Licenses'/name
 license_dir.mkdir(parents=True)
 (license_dir/'METADATA.txt').write_text(dist.read_text('METADATA') or '')
 licenses=[]
 for relative in dist.files or []:
  source=Path(dist.locate_file(relative)).resolve()
  # Never copy environment console scripts or paths outside site-packages.
  if '..' in relative.parts or '__pycache__' in relative.parts or source.suffix=='.pyc' or not source.is_file():continue
  target=site/relative
  target.parent.mkdir(parents=True,exist_ok=True)
  shutil.copy2(source,target)
  if any(word in source.name.lower() for word in ('license','licence','notice','copying')):
   dest=license_dir/str(relative).replace('/','__')
   shutil.copy2(source,dest);licenses.append(dest.name)
 if not licenses:
  supplement=Path(__file__).parent.parent/'Packaging/MLXLicenses'/f'{name}-{dist.version}-LICENSE'
  if supplement.is_file():
   shutil.copy2(supplement,license_dir/'LICENSE');licenses.append('LICENSE')
  else:missing.append(name)
 manifest.append(dict(name=dist.metadata['Name'],version=dist.version,licenses=licenses))
for name in ['worker.py','engine.py','schemas.py','checks.py','review_diagnostics.py','grammar_vocabulary.py']:
 shutil.copy2(Path(__file__).parent/'mlx_runtime'/name,root/name)
for source in base.rglob('*'):
 if source.is_file() and source.name.lower() in ('license','license.txt','license.rst','notice','copying'):
  relative=source.relative_to(base)
  target=root/'Licenses/CPython'/str(relative).replace('/','__')
  target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
receipt=dict(components=manifest,missingLicenseFiles=missing,
 chempyScope='Only Substance.from_formula and composition; solver, plotting and notebook dependencies intentionally omitted. This is not a general-purpose ChemPy installation.',
 python=str(base),workerHashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*.py')})
supplements=Path(__file__).parent.parent/'Packaging/MLXLicenses'
for source in supplements.iterdir():
 if source.is_dir():shutil.copytree(source,root/'Licenses'/source.name)
 elif source.name in ('AUDIT.json','README.md'):shutil.copy2(source,root/'Licenses'/source.name)
audit_path=supplements/'AUDIT.json'
receipt['nativeTransitiveNoticeAudit']=json.loads(audit_path.read_text()) if audit_path.is_file() else {'status':'pending'}
(root/'runtime-manifest.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2))
print(json.dumps(dict(runtime=str(root),components=len(manifest),missingLicenseFiles=missing)))
