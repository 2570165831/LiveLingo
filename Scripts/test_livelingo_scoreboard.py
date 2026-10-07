#!/usr/bin/env python3
"""Small synthetic orchestration tests. No model, server or real audio replay."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import struct
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("livelingo_scoreboard", Path(__file__).with_name("livelingo-scoreboard.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

SENTINEL = "PRIVATE_CLASSROOM_SENTINEL_do_not_export"
SEGMENT = "00000000-0000-0000-0000-000000000001"

FAKE = r'''
import base64, hashlib, json, os, pathlib, sys, time
args = sys.argv[1:]
root = pathlib.Path(args[args.index('--output') + 1]); root.mkdir()
sentinel = 'PRIVATE_CLASSROOM_SENTINEL_do_not_export'
segment = '00000000-0000-0000-0000-000000000001'
if '--translate-text' in args:
    print('model=synthetic')
    print('OUTPUT[0]=合成译文')
    time.sleep(.1)
    sys.exit(0)
row = dict(id=segment,startTime=0.,endTime=.1,english=sentinel,
           chinese=sentinel,translationState='failed')
(root/'bilingual.jsonl').write_text(json.dumps(row)+'\n')
journal = root/'durable-transcription'; journal.mkdir()
record = dict(id=segment,sessionID=segment,start=0.,end=.1,status='completed',
              candidateText=sentinel,appleEvidence=sentinel,automaticRetryCount=1)
payload = json.dumps(dict(version=1,sequence=0,sessionID=segment,records=[record])).encode()
(journal/'snapshot.json').write_text(json.dumps(dict(payload=base64.b64encode(payload).decode(),
                                                 sha256=hashlib.sha256(payload).hexdigest())))
(journal/'work.jsonl').write_text('')
for row in [dict(event='capture',kind='silent-pcm-replay',text=sentinel),
            dict(event='state',pendingTranscription=0,segments=1,unresolvedTranscription=1),
            dict(event='processing_finished',segments=1,translated=0,unresolvedTranscription=1,
                 otherLanguageTranscription=0,stopSeconds=.02,summaryStatus=sentinel),
            dict(event='saved_verified',segments=1,missingTranslations=1),
            dict(event='runtime_cleanup',confirmed=True)]:
    print(json.dumps(row),flush=True)
print(json.dumps(dict(event='cli_failed',reason='processingIncomplete',detail=sentinel)),file=sys.stderr,flush=True)
print(sentinel,file=sys.stderr,flush=True)
with pathlib.Path(os.environ['LIVELINGO_SCOREBOARD_TIMINGS']).open('a') as f:
    f.write(json.dumps(dict(stage='asr_inference',wall_seconds=.01,process_cpu_seconds=.005,
                           start_mono=0.,end_mono=.01,completed=True))+'\n')
time.sleep(.22)
sys.exit(1)
'''


class ScoreboardOrchestrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = m.WORK / "orchestration-tests"
        parent.mkdir(parents=True, exist_ok=True)
        cls.root = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        cls.build = cls.root / "fake-build"
        cls.build.mkdir()
        cls.cli = cls.build / "livelingo-cli"
        cls.cli.write_text("#!" + sys.executable + "\n" + FAKE)
        cls.cli.chmod(0o700)
        cls.fixtures = cls.root / "fixtures"
        cls.fixtures.mkdir()
        (cls.fixtures / "rules").mkdir()
        files = {}
        for name in ("ruler.json", "normalizer-v1.json", "cs50-glossary-v1.json", "translation-authored-80.json"):
            path = cls.fixtures / "rules" / name
            path.write_bytes((m.RULES / name).read_bytes())
            files["rules/" + name] = m.sha256(path)
        # One tenth of a second of silence. No audio device is ever opened.
        data = bytes(3200 * 2)
        fmt = struct.pack("<HHIIHH", 1, 1, 32000, 64000, 2, 16)
        blob = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data
        audio = cls.fixtures / "private.wav"
        audio.write_bytes(blob)
        files[audio.name] = m.sha256(audio)
        cls.clip = dict(id="private-0928-30m", privacy="private", tiers=["smoke"],
                        audio="private.wav", audio_seconds=.1, frames=3200)
        manifest = dict(schema="livelingo-fixtures/1", id="ruler-1", files=files, clips=[cls.clip])
        (cls.fixtures / "fixtures-manifest.json").write_text(json.dumps(manifest))

    def path(self, suffix):
        return self.root / (self.id().split(".")[-1] + "-" + suffix)

    def args(self, out):
        return m.parser().parse_args(["run", "--fixtures", str(self.fixtures), "--build", str(self.build),
                                      "--tier", "smoke", "--no-energy", "--out", str(out)])

    @staticmethod
    def provider():
        # Unit tests inject only Python identities. An unrelated real CLI/GPU
        # regression is excluded from this synthetic provider, never altered.
        return {pid: row for pid, row in m.read_processes().items()
                if Path(row["executable"]).name in {Path(sys.executable).name, "Python", "python3", "python3.11"}}

    @staticmethod
    def oslog(execution, directory):
        m.write_jsonl(directory / "oslog-numeric.jsonl", [
            dict(timestamp=execution["spawn_wall"] + .001, category="ReplayClock", kind="replay", event="start"),
            dict(timestamp=execution["spawn_wall"] + .151, category="TranslationLatency", kind="caption",
                 event="request", id=SEGMENT, elapsed_ms=0.)])
        return "synthetic"

    def test_private_failed_run_still_scores_and_offline_score_agrees(self):
        out = self.path("online")
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = m.run(self.args(out), provider=self.provider, log_collector=self.oslog)
        self.assertEqual(code, 0)
        report = m.read_json(out / "scoreboard.json")
        run = report["clips"][self.clip["id"]]["runs"][0]
        self.assertEqual(run["validity"]["outcome"], "completed_with_unresolved")
        self.assertFalse(run["validity"]["success"])
        self.assertEqual(run["transcription"]["completed_with_unresolved"], 1)
        self.assertEqual(run["model_times"]["stages"]["asr_inference"]["wall_seconds"], .01)
        self.assertEqual(report["headline"]["runs_verified"], 0)
        self.assertNotIn(SENTINEL, stdout.getvalue() + stderr.getvalue())
        self.assertNotIn(SENTINEL, (out / "scoreboard.json").read_text() + (out / "scoreboard.md").read_text())
        for path in (out / "clips").rglob("*"):
            if path.is_file() and "session" not in path.parts:
                self.assertNotIn(SENTINEL, path.read_text())
        rescored = self.path("offline")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.score(m.parser().parse_args(["score", "--run-dir", str(out), "--out", str(rescored)])), 0)
        self.assertEqual(report, m.read_json(rescored / "scoreboard.json"))

    def test_existing_output_is_refused_without_overwriting(self):
        out = self.path("existing")
        out.mkdir()
        canary = out / "canary"
        canary.write_text("keep")
        with self.assertRaises(m.Rejected):
            m.run(self.args(out), provider=lambda: {})
        self.assertEqual(canary.read_text(), "keep")

    def test_busy_process_refused_before_creating_output(self):
        out = self.path("busy")
        provider = lambda: {123: dict(pid=123, executable="/synthetic/livelingo-cli", state="S")}
        with self.assertRaises(m.Rejected) as failure:
            m.run(self.args(out), provider=provider)
        self.assertEqual(failure.exception.reason, "another_livelingo_run_active")
        self.assertFalse(out.exists())

    def test_lock_blocks_a_second_writer_and_is_reusable(self):
        path = self.path("lock")
        with m.session_lock(path):
            with self.assertRaises(m.Rejected):
                with m.session_lock(path):
                    pass
        with m.session_lock(path):
            pass
        self.assertTrue((path / ".lock").is_file())

    def test_json_and_md_creation_are_exclusive(self):
        out = m.new_directory(self.path("exclusive"))
        m.write_json(out / "scoreboard.json", {"number": 1})
        with self.assertRaises(m.Rejected):
            m.write_json(out / "scoreboard.json", {"number": 2})
        with m.exclusive(out / "scoreboard.md") as stream:
            stream.write("1\n")
        with self.assertRaises(m.Rejected):
            m.exclusive(out / "scoreboard.md")
        self.assertEqual(m.read_json(out / "scoreboard.json"), {"number": 1})

    def test_output_symlink_and_escape_rejected(self):
        target = self.path("target")
        target.mkdir()
        link = self.path("link")
        link.symlink_to(target, target_is_directory=True)
        for path in (link / "new", m.ROOT / "Scripts/new-output", Path("/tmp/scoreboard-escape")):
            with self.subTest(path=path), self.assertRaises(m.Rejected):
                m.new_directory(path)

    def test_manifest_requires_member_hashes_and_safe_paths(self):
        manifest = m.verify_fixtures(self.fixtures)
        self.assertEqual(len(manifest["clips"]), 1)
        with self.assertRaises(m.Rejected):
            m.fixture_path(self.fixtures, "../outside")
        with self.assertRaises(m.Rejected):
            m.fixture_path(self.fixtures, "/outside")

    def test_abba_sequence_and_invalid_counts(self):
        self.assertEqual(m.run_order(2, 2), list("ABBA"))
        self.assertEqual(m.run_order(2, 3), list("ABBAAB"))
        self.assertEqual(m.run_order(1, 3), list("AAA"))
        for builds, repeats, order in ((2, 2, "AB"), (1, 1, "A"), (3, 1, None), (2, 2, "ABBC")):
            with self.assertRaises(m.Rejected):
                m.run_order(builds, repeats, order)

    def test_abba_substitute_runs_keep_builds_separate(self):
        out = self.path("abba")
        args = self.args(out)
        args.builds = str(self.build) + "," + str(self.build)
        args.repeats, args.order = 2, "ABBA"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.run(args, provider=self.provider, log_collector=self.oslog), 0)
        local = m.read_json(out / "run-manifest.json")
        self.assertEqual([item["build"] for item in local["records"]], list("ABBA"))
        self.assertEqual([item["repeat"] for item in local["records"]], [1,1,2,2])
        report = m.read_json(out / "scoreboard.json")
        self.assertEqual(set(report["groups"]), {"A/9b","B/9b"})
        self.assertEqual(report["groups"]["A/9b"]["summary"]["private_unresolved"]["n"], 2)
        self.assertNotIn("asr_norm_rate_cs50_pooled", report["headline"])
        self.assertIn("9b", report["ab_comparison"])

    def test_build_dependency_changes_are_refused_without_starting_a_model(self):
        root = self.path("dependency-build")
        root.mkdir()
        paths = {}
        for relative in ("livelingo-cli", "ASRRuntime/qwen_asr_service.py", "ASRRuntime/python/bin/python3",
                         "ASRRuntime/scoreboard_timing.py", "language-python-host", "mlx_runtime/worker.py",
                         "Models/weights.bin", "asr-packages/module.py", "language-packages/module.py", "python-host"):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic dependency\n")
            paths[relative] = path
        paths["livelingo-cli"].chmod(0o700)
        provenance = dict(commit="1" * 40, dirty=False, cli_sha256=m.sha256(paths["livelingo-cli"]),
            asr_service_sha256=m.sha256(paths["ASRRuntime/qwen_asr_service.py"]),
            asr_host_sha256=m.sha256(paths["ASRRuntime/python/bin/python3"]),
            language_host_sha256=m.sha256(paths["language-python-host"]),
            asr_timing_sha256=m.sha256(paths["ASRRuntime/scoreboard_timing.py"]),
            external_python_sha256=m.sha256(paths["python-host"]),
            mlx_runtime_tree=m.tree_manifest(root/"mlx_runtime"), models_manifest=m.tree_manifest(root/"Models"),
            asr_packages_manifest=m.tree_manifest(root/"asr-packages"), language_packages_manifest=m.tree_manifest(root/"language-packages"),
            runtime_sources=dict(python=str(paths["python-host"]), asr_site_packages=str(root/"asr-packages"),
                                 language_site_packages=str(root/"language-packages"), models=str(root/"Models")))
        m.write_json(root/"build-provenance.json",provenance)
        cli, safe = m.build_info(root)
        self.assertEqual(cli,paths["livelingo-cli"])
        self.assertTrue(safe["runtime_hashes_verified"])
        self.assertTrue(safe["external_dependency_hashes_verified"])
        self.assertNotIn(str(root),json.dumps(safe))
        for relative, path in paths.items():
            before = path.read_bytes()
            try:
                with self.subTest(dependency=relative):
                    path.write_bytes(before+b"changed\n")
                    with self.assertRaises(m.Rejected) as rejected:
                        m.build_info(root)
                    self.assertEqual(rejected.exception.code,3)
            finally:
                path.write_bytes(before)

    def test_build_without_provenance_keeps_runtime_verification_unknown(self):
        _, provenance = m.build_info(self.build)
        self.assertFalse(provenance["runtime_hashes_verified"])
        self.assertFalse(provenance["external_dependency_hashes_verified"])
        self.assertIsNone(provenance["commit"])

    def test_build_provenance_allowlist_drops_private_text_and_dependency_paths(self):
        provenance = dict(commit=SENTINEL, dirty=SENTINEL, cli_sha256="a"*64, detail=SENTINEL,
                          runtime_sources=dict(models="/private/"+SENTINEL),
                          models_manifest=dict(sha256="b"*64,files=2,text=SENTINEL))
        safe = m.safe_build_provenance(provenance)
        self.assertNotIn(SENTINEL,json.dumps(safe))
        self.assertNotIn("runtime_sources",safe)
        self.assertEqual(safe["models_manifest"],dict(sha256="b"*64,files=2))
        self.assertIsNone(safe["commit"])
        self.assertIsNone(safe["dirty"])

    def test_timeout_signals_the_actual_owned_substitute_and_retains_numeric_evidence(self):
        out = m.new_directory(self.path("timeout"))
        execution, _ = m.execute_cli(self.cli,["--replay",str(self.fixtures/"private.wav"),"--output",str(out/"session")],
                                      out,.1,provider=self.provider)
        self.assertTrue(execution["timeout"])
        self.assertTrue(execution["identity_verified"])
        self.assertFalse(execution["ownership_uncertain"])
        self.assertNotEqual(execution["exit_code"],0)
        self.assertEqual(execution["residual_owned_processes"],0)
        self.assertNotIn(SENTINEL,(out/"events.ndjson").read_text()+(out/"stderr-numeric.jsonl").read_text())

    def test_signalling_only_spawned_unchanged_identity(self):
        process = Mock(pid=42)
        process.poll.return_value = None
        row = dict(pid=42, uid=os.getuid(), started="current", executable="/synthetic/livelingo-cli")
        identity = m.classroom.identity(row)
        self.assertTrue(m.signal_owned(process, identity, lambda: {42: row}, signal.SIGINT))
        process.send_signal.assert_called_once_with(signal.SIGINT)
        process.send_signal.reset_mock()
        reused = dict(row, started="different")
        self.assertFalse(m.signal_owned(process, identity, lambda: {42: reused}, signal.SIGTERM))
        self.assertFalse(m.signal_owned(process, None, lambda: {42: row}, signal.SIGTERM))
        process.send_signal.assert_not_called()

    def test_event_white_list_drops_text_and_unknown_reason(self):
        row = m.safe_event(dict(event="cli_failed", reason=SENTINEL, code=1, text=SENTINEL, path=SENTINEL))
        self.assertEqual(row, {"event": "cli_failed", "code": 1})
        self.assertIsNone(m.safe_event(dict(event=SENTINEL, segments=1)))
        self.assertNotIn("segments", m.safe_event(dict(event="state", segments=True)))

    def test_srt_and_wave_parser_small_sample(self):
        cues = m.parse_srt("1\n00:00:00,000 --> 00:00:00,100\n<i>Synthetic example</i>\n")
        self.assertEqual(cues[0]["end_rel"], .1)
        self.assertEqual(cues[0]["text"], "Synthetic example")
        self.assertEqual(m.wav_info(self.fixtures / "private.wav")["frames"], 3200)
        with self.assertRaises(m.Rejected):
            m.parse_srt("1\ninvalid\n" + SENTINEL)

    def test_translation_output_markers_multiline_and_failure_prefix(self):
        result = m.translation_outputs("model=synthetic\nOUTPUT[0]=第一行\n第二行\nOUTPUT[1]=下一句\n")
        self.assertEqual(result, {0: "第一行\n第二行", 1: "下一句"})
        self.assertEqual(m.translation_outputs("model=synthetic\n"), {})

    def test_compare_uses_paired_ci_noise_and_accuracy_guardrail(self):
        def group(errors, energy, censored=False):
            values = [dict(asr_critical_cs50_pooled=e, net_j_per_audio_min_pooled=j) for e, j in zip(errors, energy)]
            head = dict(asr_critical_cs50_pooled=sum(errors)/len(errors), energy_comparable=True,
                        latency_full_population_quantiles=not censored)
            return dict(profile="9b", headline=head, preview_backends={"cs50-w3-search": ["modern"]},
                        repeat_headlines=[dict(headline=v) for v in values])
        floors = {"asr_critical_cs50_pooled": {"threshold": .5}, "net_j_per_audio_min_pooled": {"threshold": 5}}
        result = m.compare_groups(group([0, 0, 0], [100, 100, 100]), group([2, 2, 2], [80, 80, 80]), noise=floors)
        self.assertEqual(result["metrics"]["asr_critical_cs50_pooled"]["conclusion"], "worse")
        self.assertEqual(result["metrics"]["net_j_per_audio_min_pooled"]["conclusion"], "better")
        self.assertEqual(result["outcome"], "tradeoff")
        self.assertEqual(result["metrics"]["asr_critical_cs50_pooled"]["paired"]["ci95"], [2, 2])

    def test_compare_rejects_unknown_backend_and_unmeasured_joules(self):
        group = dict(profile="9b", headline=dict(energy_comparable=False, latency_full_population_quantiles=False),
                     preview_backends={"private-0928-30m": ["unknown"]},
                     repeat_headlines=[dict(headline=dict(private_unresolved=1, net_j_per_audio_min_pooled=None))])
        result = m.compare_groups(group, group)
        self.assertEqual(result["metrics"]["private_unresolved"]["conclusion"], "not_comparable")
        self.assertIsNone(result["metrics"]["net_j_per_audio_min_pooled"]["delta"])

    def test_phase_energy_uses_clock_boundaries_and_adjacent_idle_power(self):
        samples = [dict(start_mono=0., end_mono=10., is_delta=True, rails_j=dict(cpu=10.,gpu=20.,ane=5.),
                        source="ioreport",mode="energy_counters",busy_seconds=dict(cpu=0.,gpu=0.,ane=None))]
        execution = dict(spawn_mono=2.,exit_mono=6.,clock_offset_start=100.)
        events = [dict(recv_mono=5.,line=dict(event="processing_finished"))]
        measured = dict(rails_idle_w={key:{"used":value} for key,value in dict(cpu=.1,gpu=.2,ane=.05).items()})
        result = m.phase_energy(measured,samples,execution,events,dict(monotonic_export_valid=True,t0=103.),1.)
        self.assertTrue(result["phase_boundaries_valid"])
        for value in result["phases_net_j"].values():
            self.assertAlmostEqual(value, 3.15)
        self.assertAlmostEqual(sum(result["phases_net_j"].values()),12.6)

    def test_missing_private_census_does_not_become_zero(self):
        run = dict(transcription=dict(other_language=None,failed=None,unresolved=None),
                   validity=dict(outcome="failed",success=False),energy=dict(comparable=False),
                   translation=dict(untranslated_segments=0),
                   latency=dict(latency_valid=False,censored={key:0 for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]},
                                unmeasured={key:1 for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]},
                                **{key:{"steady":dict(censored=0,unmeasured=1)} for key in ["en_commit","zh_first","zh_final","zh_final_from_start"]}))
        result = m.headline({"private-0928-30m":dict(privacy="private",audio_seconds=1.,runs=[run])})
        self.assertIsNone(result["private_unresolved"])
        self.assertIsNone(result["private_failed"])
        self.assertIsNone(result["asr_edits_cs50"])
        self.assertFalse(result["latency_full_population_quantiles"])


if __name__ == "__main__":
    unittest.main()
