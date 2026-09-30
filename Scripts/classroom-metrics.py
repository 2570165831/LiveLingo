#!/usr/bin/env python3
"""Local classroom measurement reader. Missing evidence is never a zero result."""
import argparse
import base64
import csv
import hashlib
import json
import math
import os
import plistlib
import statistics
import subprocess
import time
from pathlib import Path


def number(value, label, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'{label}: expected a number')
    if not math.isfinite(value) or value < 0 or (positive and value == 0):
        raise ValueError(f'{label}: invalid measurement')
    return value


def load_json(path):
    def invalid(value):
        raise ValueError(f'Non-finite JSON value: {value}')
    return json.loads(Path(path).read_text(encoding='utf-8-sig'), parse_constant=invalid)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def distribution(values):
    samples = sorted(number(v, 'latency') for v in values)
    if not samples:
        return None
    return {'count': len(samples), 'mean_seconds': statistics.mean(samples),
            'median_seconds': statistics.median(samples),
            'p95_seconds': samples[math.ceil(0.95 * len(samples)) - 1],
            'max_seconds': samples[-1], 'p95_method': 'nearest rank; no outliers removed'}


def latency_metrics(rows):
    """Explicit audio-end timestamps are required; CLI polling cannot supply them."""
    seen, first, final = set(), [], []
    for row in rows:
        identity = row.get('segment_id')
        if not isinstance(identity, str) or not identity or identity in seen:
            raise ValueError('Missing or duplicate latency segment ID')
        seen.add(identity)
        if row.get('clock') != 'host_monotonic_seconds':
            raise ValueError('Latency clocks cannot be mixed')
        start = number(row.get('audio_end_uptime'), 'audio end')
        observed = {}
        for key, target in [('first_translation_uptime', first), ('final_translation_uptime', final)]:
            value = row.get(key)
            if value is not None:
                value = number(value, key)
                if value < start:
                    raise ValueError('Translation predates its audio end')
                observed[key] = value
                target.append(value - start)
        if len(observed) == 2 and observed['first_translation_uptime'] > observed['final_translation_uptime']:
            raise ValueError('First translation is later than final translation')
    return {'segments_observed': len(seen), 'first': distribution(first), 'final': distribution(final),
            'first_unmeasured_count': len(seen) - len(first), 'final_unmeasured_count': len(seen) - len(final),
            'definition': 'Observed audio segment end to translation observation on the same host monotonic clock',
            'scope': 'Pipeline timing only; does not prove visible GUI paint time or exact spoken-word end'}


def power_metrics(blob):
    samples = [plistlib.loads(part) for part in blob.split(b'\0') if part.strip()]
    if not samples:
        raise ValueError('No powermetrics samples')
    fields = ('cpu_power', 'gpu_power', 'ane_power')
    joules = dict.fromkeys(fields, 0.0)
    seconds = 0.0
    for sample in samples:
        if sample.get('is_delta') is not True:
            raise ValueError('Cumulative or unmarked power sample; interval integration not allowed')
        processor = sample.get('processor', {})
        if sample.get('invalid') or processor.get('invalid'):
            raise ValueError('Invalid powermetrics sample')
        duration = number(sample.get('elapsed_ns'), 'sample elapsed_ns', positive=True) / 1e9
        seconds += duration
        for field in fields:
            # processor powers are mW. combined_power and gpu.gpu_energy
            # overlap this scope and must not be added a second time.
            power = number(processor.get(field), field)
            joules[field] += power / 1000 * duration
    total = sum(joules.values())
    return {'sample_count': len(samples), 'sampled_seconds': seconds,
            'estimated_rail_joules': total, 'component_joules': joules,
            'estimated_rail_joules_per_sampled_minute': total / (seconds / 60),
            'energy_j_per_classroom_minute': None,
            'scope': 'Estimated CPU/GPU/ANE rails for every host workload; excludes display and other components',
            'limitations': 'No classroom-window binding or idle baseline; not process energy, battery drain or whole-Mac energy'}


def gold_metrics(manifest_path):
    manifest_path = Path(manifest_path).resolve()
    manifest = load_json(manifest_path)
    ids, clips = set(), []
    for clip in manifest['clips']:
        identity = clip['id']
        if identity in ids:
            raise ValueError('Duplicate clip ID')
        ids.add(identity)
        paths = []
        for key in ('clip', 'draft'):
            path = manifest_path.parent / clip[key]
            if Path(clip[key]).is_absolute() or path.resolve().parent != manifest_path.parent or path.is_symlink():
                raise ValueError('Benchmark input outside manifest directory')
            paths.append(path)
        audio, draft = paths
        if sha256(audio) != clip['clip_sha256']:
            raise ValueError(f'{identity}: clip checksum mismatch')
        with draft.open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.DictReader(stream)
            required = {'segment_id', 'human_verified', 'verified_english', 'verified_chinese', 'reviewer'}
            if not required.issubset(reader.fieldnames or []):
                raise ValueError(f'{identity}: human-review columns missing')
            rows = list(reader)
        if not rows or len(rows) != clip['draft_segments']:
            raise ValueError(f'{identity}: draft row count changed')
        row_ids = [row['segment_id'] for row in rows]
        if any(not value for value in row_ids) or len(set(row_ids)) != len(row_ids):
            raise ValueError(f'{identity}: missing or duplicate gold segment ID')
        draft_hash = sha256(draft)
        frozen = clip.get('gold_sha256') == draft_hash
        if clip.get('gold_sha256') is not None and not frozen:
            raise ValueError(f'{identity}: frozen gold checksum mismatch')
        complete = sum(row.get('human_verified', '').strip().lower() == 'true'
                       and all(row.get(key, '').strip() for key in ('verified_english', 'verified_chinese', 'reviewer'))
                       for row in rows)
        clips.append({'clip_id': identity, 'clip_hash_verified': True, 'draft_sha256': draft_hash,
                      'frozen_gold_hash_verified': frozen,
                      'draft_rows': len(rows), 'reviewed_rows_declared': complete,
                      'ready_for_accuracy_comparison': frozen and complete == len(rows)
                          and manifest.get('accuracy_comparison_allowed') is True
                          and clip.get('gold_status') == 'human_verified',
                      'original_directory_currently_exists': Path(clip['source_directory']).is_dir()})
    return {'clips': clips, 'ready_for_accuracy_comparison': bool(clips)
            and all(c['ready_for_accuracy_comparison'] for c in clips),
            'scope': 'Checks declared human review and frozen inputs; never promotes machine draft columns to gold',
            'accuracy_metrics': None}


def snapshot_metrics(raw):
    data = json.loads(raw)
    if 'payload' in data:
        payload = base64.b64decode(data['payload'], validate=True)
        if hashlib.sha256(payload).hexdigest() != data.get('checksum'):
            raise ValueError('Snapshot checksum mismatch')
        data = json.loads(payload)
    if data.get('schemaVersion') != 1:
        raise ValueError('Unsupported snapshot schema')
    def binding(unit):
        fields = ('id', 'inputRevision', 'startTime', 'endTime', 'english', 'chinese')
        if any(key not in unit for key in fields):
            raise ValueError('Snapshot source binding fields missing')
        if not isinstance(unit['id'], str) or not unit['id']:
            raise ValueError('Snapshot source ID missing')
        revision = unit['inputRevision']
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
            raise ValueError('Snapshot source revision invalid')
        start = number(unit['startTime'], 'snapshot start')
        end = number(unit['endTime'], 'snapshot end')
        if end < start or any(not isinstance(unit[key], str) for key in ('english', 'chinese')):
            raise ValueError('Snapshot source range or text invalid')
        return tuple(unit[key] for key in fields)
    segments = data['segments']
    for segment in segments:
        binding(segment)
    by_id = {segment['id']: segment for segment in segments}
    if len(by_id) != len(segments):
        raise ValueError('Duplicate snapshot segment ID')
    covered, unknown, stale = set(), set(), set()
    for batch in data['batches']:
        for evidence in batch['evidence']:
            observed_binding = binding(evidence)
            identity = evidence['id']
            live = by_id.get(identity)
            if live is None:
                unknown.add(identity)
            elif observed_binding != binding(live):
                stale.add(identity)
            else:
                covered.add(identity)
    covered -= stale
    return {'source_ids_covered': len(covered), 'source_ids_total': len(segments),
            'unknown_evidence_ids': len(unknown), 'stale_evidence_ids': len(stale),
            'coverage_references_valid': not unknown and not stale,
            'notes_facts_covered': None, 'gold_facts_total': None,
            'scope': 'Snapshot checkpoint only; journal tail not replayed. Source coverage does not prove fact correctness.'}


def process_table(text):
    rows = {}
    for line in text.splitlines():
        fields = line.strip().split(None, 10)
        if len(fields) != 11:
            raise ValueError('Unrecognized process identity fields')
        pid, ppid, uid, rss_kib = map(int, fields[:4])
        rows[pid] = {'pid': pid, 'ppid': ppid, 'uid': uid, 'rss_bytes': rss_kib * 1024,
                     'state': fields[4], 'started': ' '.join(fields[5:10]), 'executable': fields[10]}
    return rows


def identity(row):
    return {key: row[key] for key in ('pid', 'uid', 'started', 'executable')}


def owned_processes(rows, root, known):
    rows = {pid: row for pid, row in rows.items() if not row['state'].startswith('Z')}
    active = {pid: row for pid, row in rows.items() if pid in known and identity(row) == known[pid]}
    live_root = rows.get(root['pid'])
    if live_root is not None and identity(live_root) == root:
        active[root['pid']] = live_root
    # Only adopt new descendants while their previously identified parent is
    # alive. Retain orphaned children by identity; never follow a reused PID.
    changed = True
    while changed:
        changed = False
        for pid, row in rows.items():
            if pid not in active and pid not in known and row['uid'] == root['uid'] and row['ppid'] in active:
                active[pid] = row
                changed = True
    known.update({pid: identity(row) for pid, row in active.items()})
    return active


def read_processes():
    return process_table(subprocess.check_output(
        ['/bin/ps', '-ww', '-axo', 'pid=,ppid=,uid=,rss=,stat=,lstart=,comm='], text=True))


def watch_rss(pid, expected_executable, output, duration, interval):
    number(duration, 'watch duration', positive=True)
    number(interval, 'sample interval', positive=True)
    if duration > 7200 or interval < 0.05:
        raise ValueError('RSS watch bounds exceeded')
    rows = read_processes()
    row = rows.get(pid)
    if row is None or row['state'].startswith('Z') or row['executable'] != str(Path(expected_executable).resolve()) or row['uid'] != os.getuid():
        raise ValueError('RSS root does not match current PID, user and exact executable')
    root, known = identity(row), {pid: identity(row)}
    start = time.monotonic()
    with Path(output).open('x', encoding='utf-8') as stream:
        def emit(record):
            stream.write(json.dumps(record, sort_keys=True) + '\n')
            stream.flush()
        emit({'event': 'rss_watch_start', 'root': root, 'clock': 'host_monotonic_seconds',
              'scope': 'Sum of owned process RSS; shared pages may be counted more than once'})
        while True:
            rows = read_processes()
            changed = [pid for pid, item in rows.items() if pid in known and not item['state'].startswith('Z')
                       and item['started'] == known[pid]['started'] and identity(item) != known[pid]]
            if changed:
                emit({'event': 'rss_watch_end', 'reason': 'ownership_changed', 'uncertain_pids': changed,
                      'observed_changed_processes': [rows[pid] for pid in changed],
                      'uptime': time.monotonic()})
                return
            active = owned_processes(rows, root, known)
            now = time.monotonic()
            emit({'event': 'rss_sample', 'uptime': now, 'processes': list(active.values()),
                  'owned_rss_bytes': sum(r['rss_bytes'] for r in active.values())})
            if not active or now - start >= duration:
                emit({'event': 'rss_watch_end', 'reason': 'all_observed_owned_exited' if not active else 'duration_limit',
                      'uptime': now})
                return
            time.sleep(min(interval, max(0, duration - (now - start))))


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding='utf-8').splitlines() if line.strip()]


def rss_metrics(rows):
    if not rows or rows[0].get('event') != 'rss_watch_start':
        raise ValueError('RSS ownership header missing')
    if rows[0].get('clock') != 'host_monotonic_seconds':
        raise ValueError('RSS clock missing or unsupported')
    root, known = rows[0]['root'], {rows[0]['root']['pid']: rows[0]['root']}
    if len(rows) < 3 or rows[-1].get('event') != 'rss_watch_end':
        raise ValueError('RSS measurement did not finish')
    reason = rows[-1].get('reason')
    if reason not in ('all_observed_owned_exited', 'duration_limit', 'ownership_changed'):
        raise ValueError('Unrecognized RSS completion reason')
    previous, samples = None, []
    last_processes = None
    for record in rows[1:-1]:
        if record.get('event') != 'rss_sample':
            raise ValueError('Unexpected event inside RSS samples')
        stamp = number(record['uptime'], 'RSS uptime')
        if previous is not None and stamp < previous:
            raise ValueError('RSS sample clock moved backward')
        previous = stamp
        processes = {p['pid']: p for p in record['processes']}
        if len(processes) != len(record['processes']):
            raise ValueError('Duplicate RSS process')
        active = owned_processes(processes, root, known)
        if set(active) != set(processes):
            raise ValueError('Unowned or reused process in RSS measurement')
        total = sum(number(p['rss_bytes'], 'RSS bytes') for p in active.values())
        if total != record['owned_rss_bytes']:
            raise ValueError('RSS total differs from owned process samples')
        samples.append(total)
        last_processes = processes
    if not samples:
        raise ValueError('RSS measurement did not finish')
    ended = number(rows[-1]['uptime'], 'RSS end uptime')
    if ended < previous:
        raise ValueError('RSS end clock moved backward')
    if reason == 'all_observed_owned_exited' and last_processes:
        raise ValueError('RSS claims exit while its final sample still has processes')
    return {'peak_owned_process_tree_rss_bytes': max(samples), 'sample_count': len(samples),
            'all_observed_owned_exited': reason == 'all_observed_owned_exited',
            'completion_reason': reason,
            'scope': 'Sampled RSS sum of identified root and descendants; not unique physical memory or unsampled peak'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    report = sub.add_parser('report', help='Read measurements; create a new JSON report without changing inputs')
    for name in ('gold-manifest', 'powermetrics', 'snapshot', 'latency-jsonl', 'rss-jsonl'):
        report.add_argument('--' + name, type=Path)
    report.add_argument('--output', type=Path, required=True)
    watch = sub.add_parser('watch-rss', help='Read only this owned process tree; never signal a process')
    watch.add_argument('--pid', type=int, required=True)
    watch.add_argument('--executable', required=True)
    watch.add_argument('--output', type=Path, required=True)
    watch.add_argument('--duration', type=float, default=1800)
    watch.add_argument('--interval', type=float, default=1)
    args = parser.parse_args()
    if args.command == 'watch-rss':
        watch_rss(args.pid, args.executable, args.output, args.duration, args.interval)
        return
    result = {'schema_version': 1, 'gold': None, 'power': None, 'latency': None, 'rss': None, 'notes': None,
              'run_success_verified': False,
              'limitations': 'Metrics do not prove CLI exit status, run_verified, runtime cleanup or a complete classroom run.'}
    inputs = {}
    for name in ('gold_manifest', 'powermetrics', 'snapshot', 'latency_jsonl', 'rss_jsonl'):
        path = getattr(args, name)
        if path is not None:
            if not path.is_file() or path.is_symlink():
                raise ValueError('Measurement input is not a regular file')
            inputs[name] = {'path': str(path.resolve()), 'sha256': sha256(path)}
    if not inputs:
        raise ValueError('No measurement inputs')
    if args.gold_manifest: result['gold'] = gold_metrics(args.gold_manifest)
    if args.powermetrics: result['power'] = power_metrics(args.powermetrics.read_bytes())
    if args.snapshot: result['notes'] = snapshot_metrics(args.snapshot.read_bytes())
    if args.latency_jsonl: result['latency'] = latency_metrics(read_jsonl(args.latency_jsonl))
    if args.rss_jsonl: result['rss'] = rss_metrics(read_jsonl(args.rss_jsonl))
    result['inputs'] = inputs
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps({'report': str(args.output), 'sections_measured': [k for k in
                     ('gold', 'power', 'latency', 'rss', 'notes') if result[k] is not None]}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f'Measurement rejected: {error}')
