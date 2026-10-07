#!/usr/bin/env python3
"""Offline A/B of original Generation and prefix reuse on one real loaded model.

Uses synthetic classroom captions, never user recordings. Model load is excluded;
request timing includes construction, prefill, and decoding. Alternating order
reduces drift. Saved token equality is a regression check, not an accuracy score
or a measurement of whole-device electricity use.
"""
import gc
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import statistics
import sys
import textwrap
import time

try:
    from Scripts.privacy_cli import PrivateArgumentParser
    from Scripts.private_files import make_private_directory
except ModuleNotFoundError as error:
    if error.name != 'Scripts':
        raise
    from privacy_cli import PrivateArgumentParser
    from private_files import make_private_directory

os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                  PYTHONDONTWRITEBYTECODE='1', TOKENIZERS_PARALLELISM='false')
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'Scripts/mlx_runtime'))

CAPTIONS = [
    'At constant temperature, doubling the pressure halves the volume of a fixed amount of gas.',
    'The acceleration is zero, but this does not mean that the velocity is zero.',
    'The density is 2.7 grams per cubic centimetre. Convert it to kilograms per cubic metre.',
    'The equilibrium shifts to the left when the product concentration increases.',
    'The ion is Fe3+ and the complex is [FeSCN]2+. Keep the charges with the correct species.',
    'The eigenvectors are linearly independent, but their eigenvalues need not be different.',
    'Dijkstra\'s algorithm does not support negative edge weights. Use Bellman-Ford instead.',
    'The work done by the net force is equal to the change in kinetic energy.',
    'The heater operates at 220 volts and draws 5 amperes. The power is 1100 watts.',
    'The rate doubles only if the concentration doubles and the other conditions stay fixed.',
    'Proper time is measured in the rest frame of the clock, not the observer moving relative to it.',
    'A nucleophile donates an electron pair during an SN2 reaction.',
    'We have not established that the two events are independent.',
    'The binary search takes O(log n) comparisons in a sorted array.',
    'The temperature rises from 20 degrees Celsius to 35 degrees Celsius.',
    '[Formula transcription uncertain] The lecturer has not confirmed this expression.',
]


def load_original(path):
    spec = importlib.util.spec_from_file_location('prefix_benchmark_original', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Generation


def system_prompt():
    source = (ROOT / 'LiveLingo/Sources/QwenRuntime.swift').read_text()
    match = re.search(r'static let systemPrompt = """\n(.*?)\n    """', source, re.S)
    if match is None:
        raise RuntimeError('Production translation system prompt was not found')
    return textwrap.dedent(match[1])


def prompt(system, caption):
    return ('<|im_start|>system\n' + system + '<|im_end|>\n'
            + '<|im_start|>user\n' + caption + '<|im_end|>\n'
            + '<|im_start|>assistant\n<think>\n\n</think>\n\n')


def run(generation_type, engine, text):
    import mlx.core as mx
    gc.collect()
    mx.clear_cache()
    before_cpu = resource.getrusage(resource.RUSAGE_SELF)
    start = time.perf_counter()
    generation = generation_type(engine, text, seed=42, final_budget=160)
    first = None
    prefill_steps = 0
    while True:
        state = generation.step()
        if state == 'prefill':
            prefill_steps += 1
        elif first is None:
            first = time.perf_counter() - start
        if state == 'done':
            break
    elapsed = time.perf_counter() - start
    after_cpu = resource.getrusage(resource.RUSAGE_SELF)
    return dict(first_token_seconds=first, total_seconds=elapsed,
                cpu_seconds=(after_cpu.ru_utime + after_cpu.ru_stime
                             - before_cpu.ru_utime - before_cpu.ru_stime),
                prefill_steps=prefill_steps,
                reused_prefix_tokens=getattr(generation, 'reused_prefix_tokens', 0),
                token_ids=generation.ids, text=generation.text)


def main():
    parser = PrivateArgumentParser(prog='benchmark-prefix-cache.py', description=__doc__)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--baseline-engine', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--limit', type=int, default=len(CAPTIONS))
    args = parser.parse_args()
    if not args.model.is_dir() or not args.baseline_engine.is_file():
        parser.error('Local model and original engine file are required')
    if not 1 <= args.limit <= len(CAPTIONS):
        parser.error('limit must be within the synthetic caption corpus')
    make_private_directory(args.output, exclusive=True)
    candidate_path = ROOT / 'Scripts/mlx_runtime/engine.py'
    candidate_sha = hashlib.sha256(candidate_path.read_bytes()).hexdigest()
    original_sha = hashlib.sha256(args.baseline_engine.read_bytes()).hexdigest()
    from engine import Engine, Generation
    import mlx.core as mx
    mx.set_cache_limit(2048 * 1024**2)
    original = load_original(args.baseline_engine)
    start = time.perf_counter()
    engine = Engine(args.model)
    if hashlib.sha256(candidate_path.read_bytes()).hexdigest() != candidate_sha:
        raise RuntimeError('Candidate source changed while loading the model')
    load_seconds = time.perf_counter() - start
    system = system_prompt()
    # Both paths warm up before measured requests; cache construction is recorded.
    warmup_text = prompt(system, 'The measured mass is 2 kilograms.')
    warmup = {name: run(kind, engine, warmup_text)
              for name, kind in [('baseline', original), ('candidate', Generation)]}
    rows = []
    with (args.output / 'requests.jsonl').open('x') as stream:
        for index, caption in enumerate(CAPTIONS[:args.limit]):
            row = dict(index=index, source=caption)
            order = [('baseline', original), ('candidate', Generation)]
            if index % 2:
                order.reverse()
            for name, kind in order:
                row[name] = run(kind, engine, prompt(system, caption))
            row['tokens_equal'] = row['baseline']['token_ids'] == row['candidate']['token_ids']
            row['text_equal'] = row['baseline']['text'] == row['candidate']['text']
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
            stream.flush()
            rows.append(row)
            print(json.dumps({key:row[key] for key in ['index','tokens_equal','text_equal']}) , flush=True)
            if not row['tokens_equal'] or not row['text_equal']:
                raise RuntimeError('Prefix reuse changed output; inspect saved request and do not ship')
    metrics = {}
    for key in ('first_token_seconds', 'total_seconds', 'cpu_seconds', 'prefill_steps'):
        metrics[key] = {name:statistics.median(row[name][key] for row in rows)
                        for name in ('baseline', 'candidate')}
        base = metrics[key]['baseline']
        metrics[key]['reduction_percent'] = (100 * (base - metrics[key]['candidate']) / base
                                             if base else None)
    if (hashlib.sha256(candidate_path.read_bytes()).hexdigest() != candidate_sha
            or hashlib.sha256(args.baseline_engine.read_bytes()).hexdigest() != original_sha):
        raise RuntimeError('Benchmark source changed during the run; results are not accepted')
    summary = dict(model=args.model.name, model_identity=engine.identity,
                   original_engine_sha256=original_sha,
                   candidate_engine_sha256=candidate_sha,
                   requests=len(rows), all_tokens_equal=all(row['tokens_equal'] for row in rows),
                   model_load_seconds=load_seconds, warmup=warmup,
                   retained_prefix_tokens=len(engine.prefix_cache.tokens),
                   retained_prefix_bytes=engine.prefix_cache.nbytes, median=metrics,
                   scope='Steady-state synthetic translation; no whole-device energy measurement.')
    (args.output/'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k != 'warmup'}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
