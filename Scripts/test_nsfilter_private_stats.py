#!/opt/homebrew/bin/python3.13
"""Synthetic-only tests; retained fixtures, no cleanup/deletion, no course reads."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
import wave

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("stats", Path(__file__).with_name("nsfilter-private-stats.py"))
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)
ROOT = None
TOOL = None
SENTINEL = "SECRET_TEXT_NAME_EXCEPTION_8de930"


def configure_paths(output=None, tool=None):
    global ROOT, TOOL
    repo = Path(__file__).resolve().parents[1]
    output = output or os.environ.get("LIVELINGO_CLI_TEST_OUTPUT_ROOT") or os.environ.get("TMPDIR") or repo.parent / "work/nsfilter"
    tool = tool or os.environ.get("LIVELINGO_NSFILTER_PROBE") or repo.parent / "work/nsfilter/nsfilter-probe"
    ROOT = Path(output) / ("nsfilter-synthetic-" + str(uuid.uuid4()))
    TOOL = Path(tool).absolute()
    ROOT.mkdir(parents=True, exist_ok=False)


def envelope(data, key="checksum"):
    encoded = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
    return {"payload": base64.b64encode(encoded).decode(), key: hashlib.sha256(encoded).hexdigest(), "schemaVersion": 1}


def silent_file(p, seconds=3):
    with wave.open(str(p), "wb") as w:
        w.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        w.writeframes(b"\0\0" * int(seconds * 16000))


def state_for(text, segments=None):
    return {"schemaVersion": 1, "sessionID": "00000000-0000-0000-0000-000000000001", "storageRevision": 1,
            "lastJournalSequence": 0, "lastJournalDigest": "0" * 64,
            "segments": segments if segments is not None else [{"id": "segment-one", "english": text, "startTime": 0, "endTime": 3}],
            "audioFiles": [{"relativePath": "recording.wav", "sampleRate": 16000}], "audioRanges": []}


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if ROOT is None:
            configure_paths()

    def require_probe(self):
        if not TOOL.is_file() or not os.access(TOOL, os.X_OK):
            self.skipTest("verified standalone nsfilter probe not supplied")

    def make_session(self, text=SENTINEL):
        p=ROOT/(SENTINEL+str(uuid.uuid4()));p.mkdir()
        silent_file(p/"recording.wav")
        (p/"session-snapshot.json").write_text(json.dumps(envelope(state_for(text))))
        return p

    def cli(self,p,tool=None):
        tool = TOOL if tool is None else tool
        r=subprocess.run(["/opt/homebrew/bin/python3.13","-I","-B",str(Path(__file__).with_name("nsfilter-private-stats.py")),str(p),"--tool",str(tool)],capture_output=True,text=True)
        self.assertNotIn(SENTINEL,r.stdout+r.stderr)
        self.assertNotIn(str(ROOT),r.stdout+r.stderr)
        self.assertEqual(r.stderr,"")
        return r,json.loads(r.stdout)

    def test_real_silent_audio_never_emits_body_or_path(self):
        self.require_probe()
        p=self.make_session();r,j=self.cli(p)
        self.assertEqual(r.returncode,0)
        self.assertEqual(j["spans"],1)
        self.assertEqual(j["thresholds"][1]["blocked_word_count"],1)
        self.assertEqual(j["thresholds"][1]["blocked_sentence_count"],1)
        self.assertEqual(j["window_reasons"]["scored"],1)
        # Strict allowlist: every output string is a fixed schema/method label.
        allowed={stats.SCHEMA,"whole-file-intersecting-window-max-v1","latin-digit-tokens-han-characters-v1","punctuation-separated-source-v1","numeric-statistics-v1","span-and-punctuation-sentence-v1"}
        def walk(v):
            if isinstance(v,str):self.assertIn(v,allowed)
            elif isinstance(v,dict):
                for x in v.values():walk(x)
            elif isinstance(v,list):
                for x in v:walk(x)
            else:self.assertIsInstance(v,(int,float))
        walk(j)

    def test_invalid_arguments_and_paths_are_numeric_only(self):
        p=ROOT/SENTINEL;r,j=self.cli(p)
        self.assertEqual(r.returncode,1);self.assertEqual(j["errors"],1)
        r=subprocess.run(["/opt/homebrew/bin/python3.13","-I","-B",str(Path(__file__).with_name("nsfilter-private-stats.py")),SENTINEL],capture_output=True,text=True)
        self.assertNotIn(SENTINEL,r.stdout+r.stderr);self.assertEqual(r.stderr,"")

    def test_corrupt_envelope_does_not_leak_exception(self):
        self.require_probe()
        p=self.make_session();(p/"session-snapshot.json").write_text(SENTINEL)
        _,j=self.cli(p);self.assertEqual(j["counters"]["sessions_rejected"],1)

    def test_unverified_tool_never_executes(self):
        p=self.make_session();folder=ROOT/(SENTINEL+"-tool");folder.mkdir();tool=folder/"nsfilter-probe"
        tool.write_text("#!/bin/sh\nprintf '"+SENTINEL+"'\n");tool.chmod(0o700)
        r,j=self.cli(p,tool);self.assertEqual(r.returncode,1);self.assertEqual(j["errors"],1)

    def test_window_overlap_tail_and_failopen(self):
        r={"completed":1,"windows":[{"start":0,"duration":1.5,"speech":0.03},{"start":0.75,"duration":1.5,"speech":0.8}]}
        c,covered,reason=stats.score_span(r,0,3)
        self.assertIsNone(c);self.assertEqual(covered,2.25);self.assertEqual(reason,"insufficient_coverage")
        self.assertEqual(stats.score_span(r,0,2.25)[0],0.8)
        self.assertIsNone(stats.score_span(r,2.5,4.5)[0])
        self.assertEqual(stats.score_span(r,0,1.499)[2],"short")
        for invalid in ({**r,"error":1},{**r,"completed":0},{**r,"nonfinite":1},
                        {"completed":1,"windows":[{"start":0,"duration":1.5,"speech":float("nan")}]},
                        {"completed":1,"windows":[{"start":0,"duration":1.5}]}):
            self.assertIsNone(stats.score_span(invalid,0,3)[0])

    def test_threshold_equality_and_word_distribution(self):
        p=ROOT/"unused.wav";spans=[(p,0,3,1,1,[1]),(p,3,6,12,2,[1,11])]
        result={p:{"completed":1,"cpu_seconds":0,"windows":[{"start":0,"duration":3,"speech":0.1},{"start":3,"duration":3,"speech":0.09}]}}
        j=stats.aggregate(spans,result,{})
        self.assertEqual(j["thresholds"][1]["blocked_spans"],1)
        self.assertEqual(j["thresholds"][1]["blocked_word_count"],12)
        self.assertEqual(j["thresholds"][1]["blocked_span_word_distribution"]["eleven_thirty"],1)

    def test_multisentence_distribution_is_per_sentence_and_private(self):
        self.require_probe()
        p=self.make_session("One. Two three four.")
        r,j=self.cli(p)
        self.assertNotIn("One.",r.stdout+r.stderr)
        self.assertNotIn("Two three four.",r.stdout+r.stderr)
        t=j["thresholds"][1]
        self.assertEqual(t["blocked_sentence_count"],2)
        self.assertEqual(t["blocked_word_count"],4)
        self.assertEqual(t["blocked_spans"],1)
        self.assertEqual(t["blocked_span_word_distribution"]["four_ten"],1)
        self.assertEqual(t["blocked_sentence_word_distribution"]["one"],1)
        self.assertEqual(t["blocked_sentence_word_distribution"]["two_three"],1)
        self.assertEqual(sum(t["blocked_sentence_word_distribution"].values()),t["blocked_sentence_count"])
        self.assertEqual(sum(j["sentence_word_distribution"].values()),j["sentence_count"])

    def test_session_journal_replays_upsert_with_checksum(self):
        self.require_probe()
        p=self.make_session();s=state_for(SENTINEL);segment={"id":"two","english":SENTINEL,"startTime":0,"endTime":2}
        payload=json.dumps({"upsertSegment":{"_0":segment}}).encode()
        prefix=f"LiveLingo-journal-1\n1\n{s['sessionID']}\n1\n{'0'*64}\n".encode()
        row={"schemaVersion":1,"sequence":1,"sessionID":s["sessionID"],"baseStorageRevision":1,"previousDigest":"0"*64,
             "payload":base64.b64encode(payload).decode(),"checksum":hashlib.sha256(prefix+payload).hexdigest()}
        (p/"session-journal.jsonl").write_text(json.dumps(row)+"\n")
        _,j=self.cli(p);self.assertEqual(j["spans"],2);self.assertEqual(j["counters"]["journal_sessions"],1)

    def test_durable_snapshot_log_and_audio_range(self):
        self.require_probe()
        p=self.make_session();(p/"session-snapshot.json").write_text(json.dumps(envelope(state_for("",[]))))
        d=p/"durable-transcription";d.mkdir()
        record={"id":"one","audioFile":"missing.wav","recordingFile":"recording.wav","startFrame":0,"endFrame":48000,"sampleRate":16000,"text":SENTINEL}
        state={"version":1,"sessionID":"test","sequence":1,"records":[record]}
        (d/"snapshot.json").write_text(json.dumps(envelope(state,"sha256")))
        (d/"work.jsonl").write_text(json.dumps(envelope({"version":1,"sessionID":"test","sequence":1,"record":record},"sha256"))+"\n")
        _,j=self.cli(p);self.assertEqual(j["spans"],1);self.assertEqual(j["counters"]["durable_sessions"],1)

    def test_symlink_and_parent_escape_rejected(self):
        p=self.make_session();outside=ROOT/"outside.wav";silent_file(outside)
        (p/"linked.wav").symlink_to(outside)
        for relative in ("linked.wav","../outside.wav",str(outside)):
            with self.assertRaises(ValueError):stats.safe_file(p,relative)

    def test_short_synthetic_audio_product_passes(self):
        self.require_probe()
        p=ROOT/"short.wav";silent_file(p,0.3)
        stats.verified_probe(TOOL)
        r=subprocess.run([str(TOOL)],input=json.dumps({"path":str(p)})+"\n",text=True,capture_output=True)
        self.assertNotIn(str(p),r.stdout+r.stderr)
        j=json.loads(r.stdout);self.assertEqual(j["short"],1);self.assertIsNone(j["production_maximum"])

    def test_runtime_component_or_wrong_tool_name_rejected(self):
        self.require_probe()
        for part in ("candidate", "ASRRuntime", "LanguageRuntime", "python3.13", "a.app"):
            directory=ROOT/part;directory.mkdir();p=directory/"nsfilter-probe"
            p.write_bytes(TOOL.read_bytes());p.chmod(0o700)
            with self.assertRaises(ValueError):stats.verified_probe(p)
        with self.assertRaises(ValueError):stats.verified_probe(TOOL.with_name("python3.13"))

    def test_audio_range_frames_are_used(self):
        self.require_probe()
        p=self.make_session();s=state_for(SENTINEL)
        s["segments"][0]["startTime"]=100;s["segments"][0]["endTime"]=103
        s["audioRanges"]=[{"segmentID":"segment-one","filePath":"recording.wav","startFrame":0,"frameCount":48000}]
        (p/"session-snapshot.json").write_text(json.dumps(envelope(s)))
        _,j=self.cli(p);self.assertEqual(j["summed_span_seconds"],3)
        self.assertEqual(j["window_reasons"]["scored"],1)

    def test_legacy_export_pointer_without_filename_leak(self):
        self.require_probe()
        p=ROOT/(SENTINEL+str(uuid.uuid4()));p.mkdir();silent_file(p/"recording.wav")
        generation=str(uuid.uuid4());g=p/".exports/versions"/generation;g.mkdir(parents=True)
        raw=(json.dumps({"id":"one","english":SENTINEL,"startTime":0,"endTime":3})+"\n").encode()
        (g/"bilingual.jsonl").write_bytes(raw)
        (g/"export-index.json").write_text(json.dumps({"version":1,"members":{"bilingual.jsonl":hashlib.sha256(raw).hexdigest()}}))
        (p/".exports/current.json").write_text(json.dumps({"version":1,"generation":generation}))
        _,j=self.cli(p);self.assertEqual(j["spans"],1);self.assertEqual(j["counters"]["legacy_sessions"],1)

    def test_incomplete_tail_is_counted_without_repair(self):
        self.require_probe()
        p=self.make_session();payload=SENTINEL.encode();journal=p/"session-journal.jsonl";journal.write_bytes(payload)
        _,j=self.cli(p);self.assertEqual(j["counters"]["incomplete_tails"],1)
        self.assertEqual(journal.read_bytes(),payload)


if __name__=="__main__":
    if len(sys.argv) == 3:
        configure_paths(sys.argv[1], sys.argv[2])
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result=unittest.TextTestRunner(verbosity=1).run(suite)
    receipt={"schema":"nsfilter-synthetic-test-receipt-v1","tests":result.testsRun,"failures":len(result.failures),"errors":len(result.errors),
             "success":int(result.wasSuccessful()),"skipped":len(result.skipped),"private_course_reads":0,"fixtures":"retained-synthetic-v1"}
    (ROOT.parent/"tests-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(receipt));sys.exit(not result.wasSuccessful())
