#!/usr/bin/env python3
import base64
import csv
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('classroom_metrics', Path(__file__).with_name('classroom-metrics.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ClassroomMetricsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Keep the small fixtures for the caller's recoverable cleanup.
        cls.fixtures = Path(tempfile.mkdtemp(prefix='LiveLingo-metrics-'))
        print('FIXTURE_DIRECTORY=' + str(cls.fixtures), flush=True)

    def test_distribution_keeps_slow_outlier_and_reports_both_centers(self):
        result = m.distribution([1, 1, 1, 1, 16])
        self.assertEqual(result['count'], 5)
        self.assertEqual(result['mean_seconds'], 4)
        self.assertEqual(result['median_seconds'], 1)
        self.assertEqual(result['p95_seconds'], 16)
        self.assertEqual(result['max_seconds'], 16)

    def test_empty_measurement_is_unknown_not_zero(self):
        self.assertIsNone(m.distribution([]))

    def test_bad_latencies_are_rejected_not_filtered(self):
        for value in [-1, float('nan'), float('inf'), True]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.distribution([1, value])

    def test_audio_end_is_required_and_partial_completion_visible(self):
        rows = [{'segment_id': 'one', 'clock': 'host_monotonic_seconds', 'audio_end_uptime': 100,
                 'first_translation_uptime': 101, 'final_translation_uptime': 104},
                {'segment_id': 'two', 'clock': 'host_monotonic_seconds', 'audio_end_uptime': 105}]
        result = m.latency_metrics(rows)
        self.assertEqual(result['first']['mean_seconds'], 1)
        self.assertEqual(result['final']['mean_seconds'], 4)
        self.assertEqual(result['final_unmeasured_count'], 1)
        with self.assertRaises(ValueError):
            m.latency_metrics([{'segment_id': 'one', 'elapsedSeconds': 2}])

    def test_latency_clock_and_identity_errors_rejected(self):
        row = {'segment_id': 'one', 'clock': 'host_monotonic_seconds', 'audio_end_uptime': 100,
               'first_translation_uptime': 101, 'final_translation_uptime': 102}
        for rows in [[row, row], [dict(row, clock='wall_time')],
                     [dict(row, final_translation_uptime=99)], [dict(row, first_translation_uptime=103)]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                m.latency_metrics(rows)

    def power_sample(self, duration_ns, cpu, gpu, ane):
        return {'is_delta': True, 'elapsed_ns': duration_ns, 'processor': {'cpu_power': cpu, 'gpu_power': gpu,
                'ane_power': ane, 'combined_power': 999999}, 'gpu': {'gpu_energy': 999999}}

    def test_power_uses_actual_intervals_and_does_not_double_count(self):
        blob = b'\0'.join(plistlib.dumps(row) for row in
            [self.power_sample(1_000_000_000, 1000, 1000, 0), self.power_sample(3_000_000_000, 2000, 0, 0)])
        result = m.power_metrics(blob)
        self.assertEqual(result['sampled_seconds'], 4)
        self.assertEqual(result['estimated_rail_joules'], 8)
        self.assertEqual(result['estimated_rail_joules_per_sampled_minute'], 120)
        self.assertIsNone(result['energy_j_per_classroom_minute'])

    def test_power_missing_or_invalid_components_do_not_become_zero(self):
        row = self.power_sample(1_000_000_000, 1000, 0, 0)
        missing = self.power_sample(1_000_000_000, 1000, 0, 0)
        del missing['processor']['ane_power']
        bad = self.power_sample(1_000_000_000, -1, 0, 0)
        for value in [missing, bad, dict(row, elapsed_ns=0), dict(row, invalid=True)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.power_metrics(plistlib.dumps(value))

    def test_power_cumulative_samples_cannot_be_added_to_intervals(self):
        row = self.power_sample(1_000_000_000, 1000, 0, 0)
        for value in [dict(row, is_delta=False), {k: v for k, v in row.items() if k != 'is_delta'}]:
            with self.subTest(value=value), self.assertRaises(ValueError): m.power_metrics(plistlib.dumps(value))

    def test_report_refuses_to_replace_a_measurement_input(self):
        path = self.fixtures / 'must-not-overwrite.plist'
        path.write_bytes(plistlib.dumps(self.power_sample(1_000_000_000, 1000, 0, 0)))
        original = path.read_bytes()
        result = subprocess.run([sys.executable, '-B', str(Path(__file__).with_name('classroom-metrics.py')),
            'report', '--powermetrics', str(path), '--output', str(path)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), original)

    def gold_fixture(self, suffix, reviewed=False):
        root = self.fixtures / suffix
        root.mkdir()
        audio = root / 'synthetic-input.dat'
        audio.write_bytes(b'synthetic fixture; not classroom audio')
        draft = root / 'draft.csv'
        with draft.open('w', encoding='utf-8-sig', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=['segment_id', 'machine_english_draft', 'machine_chinese_draft',
                'verified_english', 'verified_chinese', 'reviewer', 'human_verified'])
            writer.writeheader()
            writer.writerow({'segment_id': 'one', 'machine_english_draft': 'machine only',
                'machine_chinese_draft': '机器草稿', 'verified_english': 'reviewed example' if reviewed else '',
                'verified_chinese': '审校示例' if reviewed else '', 'reviewer': 'Synthetic fixture reviewer' if reviewed else '',
                'human_verified': 'true' if reviewed else 'false'})
        manifest = {'accuracy_comparison_allowed': True, 'clips': [{'id': 'synthetic', 'clip': audio.name,
                    'draft': draft.name, 'draft_segments': 1, 'clip_sha256': m.sha256(audio),
                    'source_directory': str(root / 'absent-original'), 'gold_status': 'human_verified'}]}
        path = root / 'manifest.json'
        path.write_text(json.dumps(manifest))
        return path, manifest

    def test_bom_csv_machine_drafts_never_qualify_as_gold(self):
        path, manifest = self.gold_fixture('machine')
        result = m.gold_metrics(path)
        self.assertFalse(result['ready_for_accuracy_comparison'])
        self.assertEqual(result['clips'][0]['reviewed_rows_declared'], 0)
        self.assertIsNone(result['accuracy_metrics'])

    def test_gold_requires_freeze_and_detects_changed_review(self):
        path, manifest = self.gold_fixture('reviewed', True)
        self.assertFalse(m.gold_metrics(path)['ready_for_accuracy_comparison'])
        draft = path.parent / 'draft.csv'
        manifest['clips'][0]['gold_sha256'] = m.sha256(draft)
        path.write_text(json.dumps(manifest))
        self.assertTrue(m.gold_metrics(path)['ready_for_accuracy_comparison'])
        draft.write_text(draft.read_text(encoding='utf-8-sig') + '\n', encoding='utf-8-sig')
        with self.assertRaises(ValueError): m.gold_metrics(path)

    def test_gold_audio_hash_mismatch_and_path_escape_rejected(self):
        for suffix, change in [('hash', {'clip_sha256': '0' * 64}), ('escape', {'draft': '../draft.csv'})]:
            path, manifest = self.gold_fixture(suffix)
            manifest['clips'][0].update(change)
            path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): m.gold_metrics(path)

    def test_source_coverage_deduplicates_batches_without_claiming_facts(self):
        one = self.source('one', 'same', '相同')
        two = self.source('two', 'other', '另外')
        snapshot = {'schemaVersion': 1, 'segments': [one, two], 'batches': [{'evidence': [one]}, {'evidence': [one]}]}
        payload = json.dumps(snapshot).encode()
        envelope = {'payload': base64.b64encode(payload).decode(), 'checksum': hashlib.sha256(payload).hexdigest()}
        result = m.snapshot_metrics(json.dumps(envelope))
        self.assertEqual(result['source_ids_covered'], 1)
        self.assertEqual(result['source_ids_total'], 2)
        self.assertIsNone(result['notes_facts_covered'])
        envelope['checksum'] = '0' * 64
        with self.assertRaises(ValueError): m.snapshot_metrics(json.dumps(envelope))

    def test_unknown_and_changed_evidence_cannot_count_as_coverage(self):
        snapshot = {'schemaVersion': 1, 'segments': [self.source('one', 'current')],
                    'batches': [{'evidence': [self.source('one', 'old'), self.source('absent')]}]}
        result = m.snapshot_metrics(json.dumps(snapshot))
        self.assertEqual(result['source_ids_covered'], 0)
        self.assertFalse(result['coverage_references_valid'])
        self.assertEqual(result['unknown_evidence_ids'], 1)
        self.assertEqual(result['stale_evidence_ids'], 1)

    def source(self, identity, english='synthetic', chinese='合成'):
        return {'id': identity, 'inputRevision': 0, 'startTime': 0, 'endTime': 1,
                'english': english, 'chinese': chinese}

    def test_missing_binding_fields_cannot_match_as_none_equals_none(self):
        source = self.source('one')
        for field in ['inputRevision', 'startTime', 'endTime', 'english', 'chinese']:
            incomplete = {key: value for key, value in source.items() if key != field}
            snapshot = {'schemaVersion': 1, 'segments': [incomplete], 'batches': [{'evidence': [incomplete]}]}
            with self.subTest(field=field), self.assertRaises(ValueError): m.snapshot_metrics(json.dumps(snapshot))

    def test_snapshot_invalid_binding_range_or_revision_rejected(self):
        for changes in [{'inputRevision': True}, {'inputRevision': -1}, {'endTime': -1},
                        {'startTime': 2}, {'chinese': None}]:
            source = dict(self.source('one'), **changes)
            snapshot = {'schemaVersion': 1, 'segments': [source], 'batches': [{'evidence': [source]}]}
            with self.subTest(changes=changes), self.assertRaises(ValueError): m.snapshot_metrics(json.dumps(snapshot))

    def row(self, pid, parent, started='Wed Sep 30 12:00:00 2026', uid=501):
        return {'pid': pid, 'ppid': parent, 'uid': uid, 'rss_bytes': 1024, 'started': started,
                'state': 'S', 'executable': '/synthetic/worker'}

    def test_rss_tracks_children_and_retains_identified_orphans(self):
        root = self.row(10, 1)
        known = {10: m.identity(root)}
        active = m.owned_processes({10: root, 11: self.row(11, 10), 12: self.row(12, 11),
                                   13: self.row(13, 10, uid=502), 14: self.row(14, 99)}, m.identity(root), known)
        self.assertEqual(set(active), {10, 11, 12})
        self.assertEqual(set(m.owned_processes({11: self.row(11, 1)}, m.identity(root), known)), {11})

    def test_rss_pid_reuse_cannot_adopt_a_new_process_or_its_children(self):
        root = self.row(10, 1)
        known = {10: m.identity(root)}
        reused = self.row(10, 1, started='Wed Sep 30 12:00:01 2026')
        self.assertEqual(m.owned_processes({10: reused, 11: self.row(11, 10)}, m.identity(root), known), {})

    def test_rss_reader_rejects_unowned_process_and_false_total(self):
        root = self.row(10, 1)
        header = {'event': 'rss_watch_start', 'root': m.identity(root), 'clock': 'host_monotonic_seconds'}
        end = {'event': 'rss_watch_end', 'reason': 'duration_limit', 'uptime': 2}
        for sample in [{'event': 'rss_sample', 'uptime': 1, 'processes': [self.row(11, 99)], 'owned_rss_bytes': 1024},
                       {'event': 'rss_sample', 'uptime': 1, 'processes': [root], 'owned_rss_bytes': 2048}]:
            with self.subTest(sample=sample), self.assertRaises(ValueError): m.rss_metrics([header, sample, end])

    def test_rss_end_label_cannot_override_live_final_sample(self):
        root = self.row(10, 1)
        header = {'event': 'rss_watch_start', 'root': m.identity(root), 'clock': 'host_monotonic_seconds'}
        live = {'event': 'rss_sample', 'uptime': 1, 'processes': [root], 'owned_rss_bytes': 1024}
        end = {'event': 'rss_watch_end', 'reason': 'all_observed_owned_exited', 'uptime': 2}
        with self.assertRaises(ValueError): m.rss_metrics([header, live, end])
        empty = dict(live, uptime=2, processes=[], owned_rss_bytes=0)
        self.assertTrue(m.rss_metrics([header, live, empty, end])['all_observed_owned_exited'])

    def test_rss_clock_and_event_order_must_be_consistent(self):
        root = self.row(10, 1)
        header = {'event': 'rss_watch_start', 'root': m.identity(root), 'clock': 'host_monotonic_seconds'}
        sample = {'event': 'rss_sample', 'uptime': 2, 'processes': [root], 'owned_rss_bytes': 1024}
        end = {'event': 'rss_watch_end', 'reason': 'duration_limit', 'uptime': 3}
        for rows in [[dict(header, clock='wall_time'), sample, end],
                     [header, sample, dict(end, reason='complete')],
                     [header, sample, dict(end, uptime=1)],
                     [header, sample, end, sample, end]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError): m.rss_metrics(rows)

    def test_mac_process_table_handles_spaces_in_executable(self):
        rows = m.process_table(' 10 1 501 100 S Wed Sep 30 12:00:00 2026 /synthetic/My Worker\n')
        self.assertEqual(rows[10]['executable'], '/synthetic/My Worker')
        self.assertEqual(rows[10]['rss_bytes'], 102400)

    def test_real_watcher_observes_only_its_synthetic_process(self):
        executable = str(Path(sys.executable).resolve())
        child = subprocess.Popen([executable, '-B', '-c', 'import time; time.sleep(0.8)'])
        path = self.fixtures / 'owned-rss.jsonl'
        observed = m.read_processes()[child.pid]
        self.assertEqual(observed['ppid'], os.getpid())
        # macOS's Python launcher execs Python.app; bind the actual process
        # path this test just spawned, rather than weakening exact matching.
        try:
            m.watch_rss(child.pid, observed['executable'], path, duration=3, interval=0.1)
        finally:
            self.assertEqual(child.wait(timeout=3), 0)
        rows = m.read_jsonl(path)
        self.assertTrue(all(p['pid'] == child.pid for row in rows if row.get('event') == 'rss_sample' for p in row['processes']))
        result = m.rss_metrics(rows)
        # ps can lose the executable identity before an exiting process is
        # reaped. The watcher must report that uncertainty rather than turn a
        # live final sample into a fabricated exit confirmation.
        self.assertIn(result['completion_reason'], ['all_observed_owned_exited', 'ownership_changed'])
        if result['completion_reason'] == 'ownership_changed':
            self.assertFalse(result['all_observed_owned_exited'])
            self.assertEqual(rows[-1]['uncertain_pids'], [child.pid])
            self.assertEqual(rows[-1]['observed_changed_processes'][0]['pid'], child.pid)
        else:
            self.assertTrue(result['all_observed_owned_exited'])
            self.assertEqual(rows[-2]['processes'], [])
        self.assertGreater(result['peak_owned_process_tree_rss_bytes'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
