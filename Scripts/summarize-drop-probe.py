"""Read-only aggregation of drop-probe event/resource logs and common references."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import re
import statistics


def words(text):
    return re.findall(r"[a-z0-9]+(?:['’][a-z0-9]+)?", text.casefold())


def ordered_coverage(reference, hypothesis):
    # Exact ordered token recall (LCS), not bag-of-words, WER or human accuracy.
    row = [0] * (len(hypothesis) + 1)
    for token in reference:
        previous = 0
        for index, candidate in enumerate(hypothesis, 1):
            old = row[index]
            row[index] = previous + 1 if token == candidate else max(row[index], row[index - 1])
            previous = old
    return {'matched': row[-1], 'reference_words': len(reference),
            'hypothesis_words': len(hypothesis),
            'percent': 100 * row[-1] / len(reference) if reference else None}


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return {'count': len(values), 'median': statistics.median(values),
            'p95': ordered[math.ceil(len(values) * .95) - 1],
            'maximum': max(values), 'minimum': min(values)}


def transport(rows):
    outstanding = []
    generated_end = consumed_end = 0.0
    offsets = []
    peak_pending = 0
    unmatched = 0
    for row in rows:
        event = row['event']
        if event == 'convert':
            for value in row['inputs']:
                start = value['start'] if value['start'] is not None else generated_end
                outstanding.append((value, start))
                generated_end = start + value['duration']
            peak_pending = max(peak_pending, len(outstanding))
        elif event in ['consumed', 'dropped', 'terminated']:
            signature = {k: row[k] for k in ['start', 'duration', 'rate', 'frames']}
            index = next((i for i, (value, _) in enumerate(outstanding) if value == signature), None)
            if index is None:
                unmatched += 1
                continue
            value, expected_start = outstanding.pop(index)
            if event == 'consumed':
                actual_start = value['start'] if value['start'] is not None else consumed_end
                offsets.append(actual_start - expected_start)
                consumed_end = actual_start + value['duration']
    return {'estimated_max_abs_transport_offset_s': max(map(abs, offsets), default=0),
            'estimated_last_transport_offset_s': offsets[-1] if offsets else None,
            'produced_not_delivered_peak_packets': peak_pending,
            'pending_packets_at_finish': len(outstanding), 'unmatched_packets': unmatched}


def reference_words_with_times(reference):
    text = ''
    ranges = []
    for sentence in reference.get('sentences', []):
        for token in sentence['tokens']:
            start = len(text)
            text += token['text']
            ranges.append((start, len(text), token['start'], token['end']))
    result = []
    for match in re.finditer(r"[a-z0-9]+(?:['’][a-z0-9]+)?", text.casefold()):
        overlapping = [row for row in ranges if row[0] < match.end() and row[1] > match.start()]
        if overlapping:
            result.append((match.group(), min(row[2] for row in overlapping), max(row[3] for row in overlapping)))
    return result


def latest_results(rows):
    results = []
    for row in rows:
        if row['event'] != 'apple_result' or not row['final']:
            continue
        previous = next((i for i, value in enumerate(results) if abs(value['start'] - row['start']) < .05), None)
        if previous is None:
            results.append(row)
        else:
            results[previous] = row
    return sorted(results, key=lambda row: (row['start'], row['end']))


def summarize(path, reference, resources, timing):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    converts = [row for row in rows if row['event'] == 'convert']
    dropped = [row for row in rows if row['event'] == 'dropped']
    if not converts:
        return {'invalid': True, 'reason': 'No modern preview input; excluded from queue comparisons'}
    source_seconds = sum(row['sourceFrames'] / row['sourceRate'] for row in converts)
    previews = latest_results(rows)
    finals = [row for row in rows if row['event'] == 'final' and not row['repair']]
    all_generated = [value for row in converts for value in row['inputs']]
    times = reference_words_with_times(reference)
    reference_tokens = words(reference.get('text', ''))
    # Match unique 3-word tails to a common full-audio Parakeet decode.
    anchors = []
    tokens = [row[0] for row in times]
    for preview in previews:
        tail = words(preview['text'])[-3:]
        if len(tail) != 3:
            continue
        matches = [i for i in range(len(tokens) - 2) if tokens[i:i + 3] == tail]
        if len(matches) == 1:
            anchors.append(preview['end'] - times[matches[0] + 2][2])
    rss = []
    replay_rss = []
    cpu = re.search(r'([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys', timing)
    finished = next(row for row in rows if row['event'] == 'finished')
    startup_offset = float(cpu[1]) - finished['wall'] if cpu else 0
    for sample in resources:
        total = sum(row['rss_kib'] for row in sample['processes']) / 1024
        rss.append(total)
        # Sampling starts before Python/model initialization. This filter is
        # deliberately relative to first PCM conversion, with a 10 s warmup.
        if converts and startup_offset + converts[0]['wall'] + 10 <= sample['wall'] <= startup_offset + converts[-1]['wall']:
            replay_rss.append((sample['wall'], total))
    growth = None
    if len(replay_rss) >= 20:
        growth = statistics.median(row[1] for row in replay_rss[-10:]) - statistics.median(row[1] for row in replay_rss[:10])
    cpu_seconds = float(cpu[2]) + float(cpu[3]) if cpu else None
    return {'seconds': source_seconds, 'drop_packets': len(dropped),
            'drop_frames': sum(row['frames'] for row in dropped),
            'drop_seconds': sum(row['duration'] for row in dropped),
            'drop_packets_per_hour': len(dropped) * 3600 / source_seconds,
            'drop_audio_percent': 100 * sum(row['duration'] for row in dropped) / source_seconds,
            'drop_implicit_packets': sum(row['start'] is None for row in dropped),
            'drop_explicit_packets': sum(row['start'] is not None for row in dropped),
            'convert_output_counts': dict(Counter(len(row['inputs']) for row in converts)),
            'generated_packets': len(all_generated), 'generated_seconds': sum(row['duration'] for row in all_generated),
            'explicit_generated_packets': sum(row['start'] is not None for row in all_generated),
            'boundary_reasons': dict(Counter(row['reason'] for row in rows if row['event'] == 'boundary')),
            'apple_final_results': len(previews), 'parakeet_initial_finals': len(finals),
            'preview_word_coverage': ordered_coverage(reference_tokens, words(' '.join(row['text'] for row in previews))) if reference_tokens else None,
            'formal_word_coverage': ordered_coverage(reference_tokens, words(' '.join(row['text'] for row in finals))) if reference_tokens else None,
            'apple_minus_parakeet_tail_end_s': distribution(anchors),
            'formal_chunk_end_to_result_s': distribution([row['wallFromReplay'] - row['end'] for row in finals]),
            'asr_inference_wall_s': sum(row['seconds'] for row in rows if row['event'] == 'asr'),
            'cpu_user_system_s': cpu_seconds, 'cpu_percent_one_core_per_audio_second': 100 * cpu_seconds / source_seconds if cpu_seconds is not None else None,
            'rss_process_tree_peak_mib': max(rss) if rss else None,
            'rss_process_tree_warm_delta_mib': growth,
            'mlx_peak_allocated_mib': max((row['gpu_peak_bytes'] / 1048576 for row in rows if row['event'] == 'asr'), default=None),
            'errors': dict(Counter(row['event'] for row in rows if row['event'] in ['failure', 'issue', 'converter_error', 'analyzer_error'])),
            'apple_capture_lag_s': distribution([row['sourceEnd'] - row['end'] for row in rows if row['event'] == 'preview']),
            **transport(rows)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    summaries = {}
    for path in sorted(args.root.glob('runs*/*/events.jsonl')):
        name = path.parent.name
        speaker = name.split('-')[0]
        reference_path = args.root / (speaker + '-reference.json')
        reference = json.loads(reference_path.read_text()) if reference_path.exists() else {}
        resource_path = args.root / (name + '.resources.json')
        resources = json.loads(resource_path.read_text()) if resource_path.exists() else []
        timing = (args.root / (name + '.stderr')).read_text()
        summaries[name] = summarize(path, reference, resources, timing)
    args.output.write_text(json.dumps(summaries, indent=2, ensure_ascii=False))
    print('summarized_runs=' + str(len(summaries)))


if __name__ == '__main__':
    main()
