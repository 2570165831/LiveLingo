#!/usr/bin/env python3
"""Measure actual partial/completed checkpoint I/O on synthetic note requests.

Loads only a specified local model, never recordings. Measures synchronous save
and restore latency, verifies uninterrupted/resumed token equality, and keeps
one checkpoint per measured state for inspection. This is not an energy test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time

os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                  PYTHONDONTWRITEBYTECODE='1', TOKENIZERS_PARALLELISM='false')
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'Scripts/mlx_runtime'))


def finish(generation):
    while generation.step() != 'done':
        pass
    return list(generation.ids), generation.wire


def note_request(repeats=1):
    evidence = ('The net work on an object equals the change in its kinetic energy. '
                'If the net work is zero, its speed does not change. '
                'A force perpendicular to the instantaneous velocity does no work. '
                'These statements assume the classical mechanics model.')
    data = {'evidence': [{'id': 'e0', 'text': evidence}], 'pendingPoints': []}
    text = '\n'.join(f'Example {i + 1}: {evidence}' for i in range(repeats))
    prompt = ('<|im_start|>system\nReturn one concise Chinese study note as JSON. '
              'Use sourceVersion 2, noNewKnowledge false, topic and one point. '
              'The point kind is 核心结论, sourceIDs ["e0"], needsContext null. '
              'Set followUps to an empty object. Do not add facts.<|im_end|>\n'
              '<|im_start|>user\n' + text + '<|im_end|>\n'
              '<|im_start|>assistant\n<think>\n\n</think>\n\n')
    return prompt, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.model.is_dir():
        parser.error('An existing local model directory is required')
    args.output.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'Scripts/mlx_runtime/engine.py'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    from engine import Engine, Generation
    from schemas import note_schema
    import mlx.core as mx
    mx.set_cache_limit(1024 * 1024**2)
    engine = Engine(args.model)
    records = []
    for label, repeats in [('short-note', 1), ('long-input-note', 24)]:
        prompt, data = note_request(repeats)
        generation = Generation(engine, prompt, schema=note_schema(data),
                                seed=42, final_budget=768)
        while len(generation.ids) < 8:
            if generation.step() == 'done':
                raise RuntimeError('Synthetic note ended before the partial checkpoint')
        partial = args.output / (label + '-partial.safetensors')
        start = time.perf_counter()
        generation.save(partial)
        partial_save = time.perf_counter() - start
        uninterrupted = finish(generation)
        completed = args.output / (label + '-completed.safetensors')
        start = time.perf_counter()
        generation.save(completed)
        completed_save = time.perf_counter() - start
        start = time.perf_counter()
        restored = Generation.restore(engine, partial, generation.identity)
        partial_restore = time.perf_counter() - start
        resumed = finish(restored)
        if uninterrupted != resumed:
            raise RuntimeError('Partial checkpoint changed generated tokens or text')
        start = time.perf_counter()
        restored_done = Generation.restore(engine, completed, generation.identity)
        completed_restore = time.perf_counter() - start
        if not restored_done.done or finish(restored_done) != uninterrupted:
            raise RuntimeError('Completed checkpoint failed exact replay')
        row = dict(case=label, input_tokens=len(engine.tokenizer.encode(prompt,
                   add_special_tokens=False)), output_tokens=len(uninterrupted[0]),
                   token_ids=uninterrupted[0], wire=uninterrupted[1],
                   partial_bytes=partial.stat().st_size,
                   completed_bytes=completed.stat().st_size,
                   partial_save_seconds=partial_save,
                   completed_save_seconds=completed_save,
                   partial_restore_seconds=partial_restore,
                   completed_restore_seconds=completed_restore,
                   partial_exact=True, completed_exact=True,
                   completed_restored_tensor_bytes=sum(c.nbytes for c in restored_done.cache))
        records.append(row)
        print(json.dumps({k: v for k, v in row.items() if k not in ('token_ids', 'wire')}),
              flush=True)
        (args.output / 'requests.json').write_text(
            json.dumps(records, ensure_ascii=False, indent=2) + '\n')
    if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Engine source changed during measurement')
    summary = dict(model=args.model.name, engine_sha256=digest,
                   model_identity=engine.identity, cases=len(records),
                   all_tokens_equal=True,
                   scope='Synthetic notes; individual I/O samples, not energy measurements.')
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    main()
