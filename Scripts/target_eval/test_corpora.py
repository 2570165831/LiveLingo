"""Handwritten public-format stand-ins with isolated temporary output roots."""
from copy import deepcopy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts.target_eval import corpora as c


class CorporaTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="synthetic-corpora-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.enterContext(patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(self.root)}))

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def meeting(self):
        # Invented sentences, not excerpts from any lecture or UN record.
        texts = {"ar": "هذا مثال.", "zh": "这是例子。", "en": "This is an example.",
                 "fr": "Voici un exemple.", "ru": "Это пример.", "es": "Este es un ejemplo."}
        return {"schema_version": 1, "id": "S/PV.synthetic", "turn_count": 2,
                "mapped_turn_counts": dict.fromkeys(c.UN_LOCALES, 2),
                "record_counts_equal": False, "country_header_checks_all_passed": True,
                "turns": [{"index": i, "texts": dict(texts),
                           "text_status": dict.fromkeys(c.UN_LOCALES, "extracted"),
                           "original_language": "en", "original_languages": ["en"],
                           "start_s": None, "end_s": None, "time_alignment": "unavailable"}
                          for i in (1, 2)]}

    def un_file(self, data=None, name="S_PV.synthetic/turns.json"):
        return self.write(name, json.dumps(data if data is not None else self.meeting(), ensure_ascii=False))

    def test_un_uses_curated_six_language_turns_and_no_invented_timing(self):
        path = self.un_file()
        before = path.read_bytes()
        result = c.read_un(self.root)
        self.assertEqual(len(result.units), 2)
        self.assertEqual(result.units[1].id, "S/PV.synthetic:turn:2")
        self.assertEqual(set(result.units[0].texts), set(c.UN_LOCALES))
        self.assertEqual(result.units[0].texts["zh"], "这是例子。")
        self.assertEqual(result.units[0].metadata["alignment"], "curated-turn-index")
        self.assertNotIn("start_ms", result.units[0].metadata)
        self.assertEqual(path.read_bytes(), before)

    def test_un_partial_translation_excluded_and_reported_or_explicitly_included(self):
        data = self.meeting()
        data["turns"][1]["text_status"]["ru"] = "partial_missing_page"
        path = self.un_file(data)
        result = c.read_un_meeting(path)
        self.assertEqual(len(result.units), 1)
        self.assertEqual(result.excluded[0]["text_status"], {"ru": "partial_missing_page"})
        self.assertFalse(result.excluded[0]["included_by_request"])
        included = c.read_un_meeting(path, include_partial=True)
        self.assertEqual(len(included.units), 2)
        self.assertTrue(included.excluded[0]["included_by_request"])
        self.assertEqual(included.units[1].metadata["text_status"]["ru"], "partial_missing_page")

    def test_un_rejects_missing_text_status_mapping_duplicates_and_count_mismatches(self):
        variants = []
        data = self.meeting(); del data["turns"][0]["texts"]["ar"]; variants.append(data)
        data = self.meeting(); del data["turns"][0]["text_status"]["fr"]; variants.append(data)
        data = self.meeting(); data["turns"][1]["index"] = 1; variants.append(data)
        data = self.meeting(); data["turn_count"] = 3; variants.append(data)
        data = self.meeting(); data["mapped_turn_counts"]["ru"] = 1; variants.append(data)
        data = self.meeting(); data["country_header_checks_all_passed"] = False; variants.append(data)
        data = self.meeting(); data["schema_version"] = 2; variants.append(data)
        data = self.meeting(); data["schema_version"] = True; variants.append(data)
        data = self.meeting(); data["turn_count"] = 2.0; variants.append(data)
        data = self.meeting(); data["mapped_turn_counts"]["fr"] = 2.0; variants.append(data)
        data = self.meeting(); data["turns"][0]["index"] = True; variants.append(data)
        for i, data in enumerate(variants):
            with self.subTest(i=i), self.assertRaises(ValueError):
                c.read_un_meeting(self.un_file(data, f"bad-{i}.json"))

    def test_un_does_not_open_quarantine_or_audio_and_rejects_duplicate_ids(self):
        self.un_file()
        self.write("_incomplete/turns.json", "must not be read")
        self.write("S_PV.synthetic/audio.flac", "must not be read")
        self.assertEqual(len(c.read_un(self.root).units), 2)
        self.un_file(name="S_PV.other/turns.json")
        with self.assertRaises(ValueError):
            c.read_un(self.root)
        with self.assertRaises(ValueError):
            c.read_un(self.root / "missing")

    def test_srt_bom_crlf_multiline_and_milliseconds(self):
        path = self.write("lesson.srt", "\ufeff1\r\n01:02:03,004 --> 01:02:04.005\r\nOne invented\r\nline.\r\n\r\n"
                          "2\r\n01:02:04,005 --> 01:02:06,000\r\n<i>Another.</i>\r\n")
        cues = c.read_srt(path)
        self.assertEqual(cues[0], c.Cue("1", 3723004, 3724005, "One invented\nline."))
        self.assertEqual(cues[1].text, "<i>Another.</i>")

    def test_srt_rejects_bad_timestamp_zero_duration_duplicate_and_out_of_order(self):
        variants = ["1\n00:61:00,000 --> 00:62:00,000\nText.",
                    "1\n00:00:01,000 --> 00:00:01,000\nText.",
                    "1\n00:00:02,000 --> 00:00:01,000\nText.",
                    "1\n00:00:00,00 --> 00:00:01,000\nText.",
                    "1\n00:00:00,000 --> 00:00:01,000\n   ",
                    "1\n00:00:00,000 --> 00:00:01,000\nA\n\n1\n00:00:01,000 --> 00:00:02,000\nB",
                    "1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:00,000 --> 00:00:01,000\nB"]
        for i, text in enumerate(variants):
            with self.subTest(i=i), self.assertRaises(ValueError):
                c.read_srt(self.write(f"bad-{i}.srt", text))

    def test_overlap_groups_one_to_many_many_to_one_without_reusing_cues(self):
        result = c.align_subtitles({
            "en": [c.Cue("1", 0, 2000, "One two."), c.Cue("2", 2000, 3000, "Three."),
                   c.Cue("3", 3000, 4000, "Four.")],
            "es": [c.Cue("1", 0, 1000, "Uno."), c.Cue("2", 1000, 2000, "Dos."),
                   c.Cue("3", 2000, 4000, "Tres cuatro.")]}, document_id="synthetic")
        self.assertEqual(len(result.units), 2)
        self.assertEqual(result.units[0].texts, {"en": "One two.", "es": "Uno.\nDos."})
        self.assertEqual(result.units[1].metadata["cue_ids"], {"en": ["2", "3"], "es": ["3"]})
        self.assertEqual(result.units[1].metadata["start_ms"], 2000)
        self.assertEqual(result.units[1].metadata["end_ms"], 4000)
        self.assertEqual(result.unmatched, {"en": (), "es": ()})

    def test_touching_times_do_not_align_and_unmatched_cues_are_reported(self):
        result = c.align_subtitles({"en": [c.Cue("1", 0, 1000, "One.")],
                                    "fr": [c.Cue("1", 1000, 2000, "Un.")]})
        self.assertEqual(result.units, ())
        self.assertEqual(result.unmatched, {"en": ("1",), "fr": ("1",)})

    def test_three_way_alignment_requires_every_requested_locale(self):
        result = c.align_subtitles({"en": [c.Cue("1", 0, 100, "One.")],
                                    "es": [c.Cue("1", 10, 90, "Uno.")], "fr": []})
        self.assertEqual(result.units, ())
        self.assertEqual(result.unmatched["en"], ("1",))
        with self.assertRaises(ValueError):
            c.align_subtitles({"en": []})

    def test_cs50_and_ted_read_only_explicit_local_srt_files(self):
        paths = {"en": self.write("en.srt", "1\n00:00:00,000 --> 00:00:01,000\nOne.\n"),
                 "fr": self.write("fr.srt", "1\n00:00:00,000 --> 00:00:01,000\nUn.\n")}
        original = {key: path.read_bytes() for key, path in paths.items()}
        self.assertEqual(c.read_cs50_srts(paths, document_id="made-up-lesson").units[0].corpus, "cs50")
        self.assertEqual(c.read_ted_srts(paths, document_id="made-up-talk").units[0].corpus, "ted")
        self.assertEqual(original, {key: path.read_bytes() for key, path in paths.items()})

    def test_flores_local_lines_keep_locale_and_index(self):
        paths = {"en": self.write("eng_Latn.devtest", "\ufeffOne.\nTwo.\n"),
                 "zh-Hant": self.write("zho_Hant.devtest", "一。\n二。\n")}
        units = c.read_flores_plus(paths)
        self.assertEqual(units[1].id, "flores-plus:devtest:2")
        self.assertEqual(units[1].texts, {"en": "Two.", "zh-Hant": "二。"})

    def test_flores_rejects_unequal_and_blank_lines_without_shifting(self):
        en = self.write("en.txt", "One.\nTwo.\n")
        for i, text in enumerate(("Un.\n", "Un.\n\n", "Un.\n \n", "")):
            with self.subTest(i=i), self.assertRaises(ValueError):
                c.read_flores_plus({"en": en, "fr": self.write(f"fr-{i}.txt", text)})

    def test_output_rejects_repository_other_work_roots_and_traversal_before_mkdir(self):
        paths = [c.repository_root() / "target-eval-forbidden.jsonl",
                 c.output_root().parent / "target-eval-other" / "out.jsonl",
                 c.output_root() / ".." / "outside" / "out.jsonl", c.output_root()]
        for path in paths:
            with self.subTest(path=path), self.assertRaises(ValueError), patch.object(Path, "mkdir") as mkdir:
                c.write_jsonl([], path)
            mkdir.assert_not_called()

    def test_symlinked_parent_and_leaf_are_rejected(self):
        outside = self.root / "repository-link"
        outside.symlink_to(c.repository_root(), target_is_directory=True)
        inside = self.root / "internal-link"
        inside.symlink_to(self.root, target_is_directory=True)
        leaf = self.root / "leaf.json"
        leaf.symlink_to(self.root / "missing.json")
        for path in (outside / "out.json", inside / "out.json", leaf):
            with self.subTest(path=path), self.assertRaises(ValueError):
                c.write_json({}, path)
        self.assertTrue(leaf.is_symlink())

    def test_symlinked_output_root_cannot_redirect_writes(self):
        root_link = self.root / "root-link"
        root_link.symlink_to(c.repository_root(), target_is_directory=True)
        with patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(root_link)}), \
                self.assertRaises(ValueError), patch.object(Path, "mkdir") as mkdir:
            c.write_json({}, root_link / "forbidden.json")
        mkdir.assert_not_called()

    def test_writer_utf8_roundtrip_never_replaces_existing_files(self):
        unit = c.ParallelUnit("synthetic:1", "synthetic", {"en": "One.", "zh": "一。"})
        path = self.root / "outputs" / "corpus.jsonl"
        c.write_jsonl([unit], path)
        before = path.read_bytes()
        self.assertIn("一。".encode(), before)
        self.assertEqual(json.loads(before)["texts"], unit.texts)
        with self.assertRaises(FileExistsError):
            c.write_jsonl([], path)
        self.assertEqual(path.read_bytes(), before)

    @staticmethod
    def acl(path):
        result = subprocess.run(["/bin/ls", "-lde", str(path)], check=True,
                                capture_output=True, text=True)
        return result.stdout.splitlines()[1:]

    @unittest.skipUnless(sys.platform == "darwin", "macOS inherited ACL")
    def test_writers_clear_inherited_acl_on_new_ancestors_and_body_files(self):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,file_inherit,directory_inherit",
                        str(self.root)], check=True, capture_output=True)
        canary = self.write("acl-canary", "synthetic")
        self.assertTrue(any("everyone inherited allow" in row for row in self.acl(canary)))
        out = self.root / "nested" / "private"
        unit = c.ParallelUnit("synthetic:1", "synthetic", {"en": "Synthetic body."})
        c.write_jsonl([unit], out / "corpus.jsonl")
        c.write_json({"text": "Synthetic body."}, out / "report.json")
        c._write_text(out / "summary.md", "Synthetic body.\n")
        for path in (out.parent, out):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
            self.assertEqual(self.acl(path), [])
        for name in ("corpus.jsonl", "report.json", "summary.md"):
            self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o600)
            self.assertEqual(self.acl(out / name), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS existing ACL")
    def test_writer_preserves_existing_parent_and_clears_new_file_acl(self):
        parent = self.root / "existing"
        parent.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,file_inherit,directory_inherit",
                        str(parent)], check=True, capture_output=True)
        before = parent.stat().st_mode, self.acl(parent)
        c.write_json({"text": "synthetic"}, parent / "body.json")
        self.assertEqual((parent.stat().st_mode, self.acl(parent)), before)
        self.assertEqual(self.acl(parent / "body.json"), [])
        self.assertEqual(stat.S_IMODE((parent / "body.json").stat().st_mode), 0o600)

    def test_writer_refuses_existing_readonly_objects_without_permission_upgrade(self):
        parent = self.root / "readonly"
        parent.mkdir(mode=0o500)
        before = parent.stat().st_mode
        with self.assertRaises((OSError, ValueError)):
            c.write_json({}, parent / "body.json")
        self.assertEqual(parent.stat().st_mode, before)
        self.assertFalse((parent / "body.json").exists())
        destination = self.write("readonly.json", "synthetic retained body")
        destination.chmod(0o400)
        before = destination.stat().st_mode, destination.read_bytes()
        with self.assertRaises((OSError, ValueError)):
            c.write_json({}, destination)
        self.assertEqual((destination.stat().st_mode, destination.read_bytes()), before)

    def test_parser_errors_use_fixed_prog_and_omit_private_arguments(self):
        sentinel = "SYNTHETIC_PRIVATE_ARGUMENT"
        with patch.object(sys, "argv", ["synthetic-program-" + sentinel]), \
                redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
            c.main([sentinel, "--output", str(self.root / "out.jsonl")])
        self.assertNotIn(sentinel, error.getvalue())
        self.assertIn("target-eval-corpora", error.getvalue())

    def test_cli_io_error_does_not_print_private_input_path(self):
        sentinel = "SYNTHETIC_PRIVATE_INPUT"
        with redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
            c.main(["cs50", "--locale-file", "en=" + str(self.root / sentinel),
                    "--locale-file", "fr=" + str(self.root / "missing"),
                    "--document-id", "synthetic", "--output", str(self.root / "out.jsonl")])
        self.assertNotIn(sentinel, error.getvalue())
        self.assertIn("target-eval-corpora", error.getvalue())

    @unittest.skipUnless(sys.platform == "darwin", "macOS deny ACL")
    def test_writer_preserves_private_parent_deny_acl(self):
        parent = self.root / "deny-acl"
        parent.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone deny delete", str(parent)],
                       check=True, capture_output=True)
        self.addCleanup(subprocess.run, ["/bin/chmod", "-a", "everyone deny delete", str(parent)],
                        check=True, capture_output=True)
        before = parent.stat().st_mode, self.acl(parent)
        c.write_json({"text": "synthetic body"}, parent / "body.json")
        self.assertEqual((parent.stat().st_mode, self.acl(parent)), before)
        self.assertEqual(stat.S_IMODE((parent / "body.json").stat().st_mode), 0o600)
        self.assertEqual(self.acl(parent / "body.json"), [])

    def test_cli_entrypoints_direct_scripts_and_alias_preserve_private_parser(self):
        scripts = Path(c.__file__).resolve().parents[1]
        environment = {"PYTHONPATH": str(scripts), "PYTHONDONTWRITEBYTECODE": "1",
                       "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
        sentinel = "SYNTHETIC_PRIVATE_ARGUMENT"
        prefixes = ([sys.executable, "-B", str(scripts / "target_eval/corpora.py")],
                    [sys.executable, "-B", "-m", "Scripts.target_eval.corpora"],
                    [sys.executable, "-B", "-m", "target_eval.corpora"])
        for prefix in prefixes:
            with self.subTest(entry=prefix[-1]):
                help_result = subprocess.run([*prefix, "--help"], cwd=scripts.parent, env=environment,
                                             capture_output=True, text=True, timeout=10)
                self.assertEqual(help_result.returncode, 0)
                self.assertIn("target-eval-corpora", help_result.stdout)
                result = subprocess.run([*prefix, "--unknown-" + sentinel], cwd=scripts.parent, env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(sentinel, result.stdout + result.stderr)
                self.assertNotIn(str(scripts), result.stdout + result.stderr)
                self.assertIn("invalid_arguments", result.stderr)

    def test_cli_synthetic_export_retains_incomplete_diagnostics(self):
        data = deepcopy(self.meeting())
        data["turns"][1]["text_status"]["ru"] = "partial_missing_page"
        self.un_file(data)
        path = self.root / "cli.jsonl"
        with redirect_stdout(io.StringIO()) as stdout:
            result = c.main(["un", "--input", str(self.root), "--output", str(path)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["unit_count"], 1)
        row = json.loads(path.read_text())
        self.assertEqual(row["metadata"]["corpus_diagnostics"]["incomplete_turns"][0]["id"],
                         "S/PV.synthetic:turn:2")

    def test_cli_rejects_output_before_opening_input(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit_code, \
                patch.object(c, "read_un") as reader:
            c.main(["un", "--input", "nonexistent-input", "--output",
                    str(c.repository_root() / "forbidden.jsonl")])
        self.assertEqual(exit_code.exception.code, 2)
        reader.assert_not_called()


if __name__ == "__main__":
    unittest.main()
