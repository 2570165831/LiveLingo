#!/usr/bin/env python3
"""Offline Parakeet chunk/overlap comparison; never changes an App or recording.

Run with the ASR runtime's Python dependencies on PYTHONPATH. Input must be a
16 kHz mono PCM16 WAV. Reference captions, if used for later scoring, require
independent review: this tool does not calculate an accuracy score.
"""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import time
import wave


def audio_info(source):
    with wave.open(source, 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(),
                audio.getcomptype()) != (1, 2, 16000, 'NONE'):
            raise ValueError('Input must be a 16 kHz mono PCM16 WAV')
        if not audio.getnframes():
            raise ValueError('Input audio is empty')
        return audio.getnframes(), audio.getframerate()


def frame_windows(frames, rate, start_seconds, duration_seconds, chunk_seconds, margin_seconds):
    values = (start_seconds, duration_seconds, chunk_seconds, margin_seconds)
    if not all(math.isfinite(x) for x in values):
        raise ValueError('Audio times must be finite')
    if start_seconds < 0 or duration_seconds <= 0 or not 1 <= chunk_seconds <= 30:
        raise ValueError('Start must be nonnegative, duration positive, and chunk length 1–30 seconds')
    if not 0 < margin_seconds <= min(2, chunk_seconds / 2):
        raise ValueError('Overlap margin must be positive and at most 2 seconds or half a chunk')
    start = round(start_seconds * rate)
    stop = min(frames, start + round(duration_seconds * rate))
    if start >= frames or stop <= start:
        raise ValueError('Requested range contains no audio')
    step, margin = round(chunk_seconds * rate), round(margin_seconds * rate)
    if not step or not margin:
        raise ValueError('Chunk and overlap must contain at least one sample')
    return [(a, min(a + step, stop), max(start, a - margin), min(stop, a + step + margin))
            for a in range(start, stop, step)]


def prefix_checks(previous, merged, boundary, margin):
    """Could a previously emitted token prefix survive this merge unchanged?"""
    result = []
    for lag in (margin, 2 * margin, 3 * margin, 4 * margin):
        cutoff = boundary + margin - lag
        count = 0
        # Only a contiguous prefix can have been committed. Never skip a token
        # whose end is late and then count a later one with an earlier end.
        for token in previous:
            if token.end > cutoff:
                break
            count += 1
        result.append({'lag_seconds':lag, 'prior_tokens':count,
                       'prefix_preserved':[t.id for t in previous[:count]] ==
                                          [t.id for t in merged[:count]]})
    return result


def run(args, windows, rate, report):
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      PYTHONDONTWRITEBYTECODE='1')
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.models.parakeet.alignment import (
        merge_longest_contiguous, merge_longest_common_subsequence)
    from mlx_audio.stt.models.parakeet import alignment

    report['runtime_versions'] = {name: importlib.metadata.version(name)
                                  for name in ('mlx', 'mlx-audio', 'numpy')}
    report['merge_implementation_sha256'] = hashlib.sha256(
        Path(alignment.__file__).read_bytes()).hexdigest()

    loaded = time.monotonic()
    model = load_model(str(args.model))
    if not type(model).__module__.startswith('mlx_audio.stt.models.parakeet.'):
        raise ValueError('This comparison requires a local Parakeet model')
    report['model_load_seconds'] = time.monotonic() - loaded
    merged = []
    with wave.open(str(args.audio), 'rb') as audio:
        def samples(start, end):
            audio.setpos(start)
            raw = audio.readframes(end - start)
            if len(raw) != (end - start) * 2:
                raise ValueError('Audio changed or ended while reading a window')
            return mx.array(np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32768)

        first = windows[0]
        model.generate(samples(first[0], first[1]), verbose=False)
        report['warmup_generations'] = 1
        for index, (start, end, left, right) in enumerate(windows):
            pair = {'chunk':index, 'start':start / rate, 'end':end / rate}
            order = ('exact', 'overlap') if index % 2 else ('overlap', 'exact')
            pair['order'] = order
            for mode in order:
                lo, hi = (start, end) if mode == 'exact' else (left, right)
                waveform = samples(lo, hi)
                mx.synchronize()
                began = time.monotonic()
                result = model.generate(waveform, verbose=False)
                mx.synchronize()
                record = {'raw':result.text.strip(), 'generation_seconds':time.monotonic() - began,
                          'window_start':lo / rate, 'window_end':hi / rate}
                if mode == 'overlap':
                    tokens = [token for sentence in result.sentences for token in sentence.tokens]
                    for token in tokens:
                        token.start += lo / rate
                        token.end = token.start + token.duration
                    before = list(merged)
                    record['merge_strategy'] = 'first'
                    began = time.monotonic()
                    if merged:
                        try:
                            merged = merge_longest_contiguous(merged, tokens,
                                overlap_duration=2 * args.overlap_seconds)
                            record['merge_strategy'] = 'contiguous'
                        except RuntimeError:
                            merged = merge_longest_common_subsequence(merged, tokens,
                                overlap_duration=2 * args.overlap_seconds)
                            record['merge_strategy'] = 'subsequence'
                    else:
                        merged = tokens
                    record['merge_seconds'] = time.monotonic() - began
                    record['prefix_checks'] = prefix_checks(before, merged, start / rate,
                                                            args.overlap_seconds)
                pair[mode] = record
            report['chunks'].append(pair)
            print(f'Compared {index + 1}/{len(windows)} chunks', flush=True)
    report['text'] = {'exact':' '.join(row['exact']['raw'] for row in report['chunks']),
                      'overlap':''.join(token.text for token in merged).strip()}
    report['formal_generations'] = 2 * len(report['chunks'])
    report['totals'] = {mode: {
        'generation_seconds':sum(row[mode]['generation_seconds'] for row in report['chunks']),
        'processed_audio_seconds':sum(row[mode]['window_end'] - row[mode]['window_start']
                                      for row in report['chunks'])}
        for mode in ('exact', 'overlap')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True, help='Existing local Parakeet directory; no downloads')
    parser.add_argument('--output', type=Path, required=True, help='New JSON result file; existing files are never overwritten')
    parser.add_argument('--start-seconds', type=float, default=0)
    parser.add_argument('--duration-seconds', type=float, default=600)
    parser.add_argument('--chunk-seconds', type=float, default=8)
    parser.add_argument('--overlap-seconds', type=float, default=0.5,
                        help='Audio context added on EACH side of a chunk')
    args = parser.parse_args()
    try:
        args.audio = args.audio.resolve(strict=True)
        args.model = args.model.resolve(strict=True)
        if not args.model.is_dir() or not (args.model / 'config.json').is_file():
            raise ValueError('Model must be an existing local directory with config.json')
        frames, rate = audio_info(str(args.audio))
        windows = frame_windows(frames, rate, args.start_seconds, args.duration_seconds,
                                args.chunk_seconds, args.overlap_seconds)
        # Exclusive creation also handles symlinks and a race with another run.
        output = args.output.open('x', encoding='utf-8')
    except (OSError, ValueError, wave.Error) as error:
        parser.error(str(error))
    report = {'schema':1, 'status':'running', 'audio_name':args.audio.name,
              'model_name':args.model.name, 'actual_sample_rate':rate,
              'actual_file_frames':frames, 'start_frame':windows[0][0], 'end_frame':windows[-1][1],
              'chunk_seconds':args.chunk_seconds, 'margin_seconds':args.overlap_seconds,
              'scope':'Offline ASR comparison, not live App scheduling or energy measurement. Prefix retractions are diagnostics, not a qualified streaming policy.',
              'accuracy_measured':False, 'chunks':[]}
    status = 0
    try:
        before = args.audio.stat()
        with args.audio.open('rb') as source:
            report['audio_sha256'] = hashlib.file_digest(source, 'sha256').hexdigest()
        report['model_config_sha256'] = hashlib.sha256((args.model / 'config.json').read_bytes()).hexdigest()
        report['benchmark_script_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        run(args, windows, rate, report)
        after = args.audio.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Input audio changed during the comparison')
        report['status'] = 'completed'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = {'type':type(error).__name__, 'message':str(error)}
        status = 1
    finally:
        with output:
            json.dump(report, output, ensure_ascii=False, indent=2)
            output.write('\n')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
