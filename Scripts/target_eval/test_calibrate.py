"""Self-authored turns and canned transport replies only; never read real UN data."""
from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import unicodedata

from Scripts.target_eval import calibrate as a
from Scripts.target_eval import corpora as c
from Scripts.target_eval import metrics as m


def synthetic_unit(identity="synthetic:turn:1"):
    return c.ParallelUnit(identity, "un", {
        "ar": "هذا مثال صغير. هذا مثال آخر.", "zh": "这是小例子。这是另一个例子。",
        "en": "This is a small example. Here is another example.",
        "fr": "Voici un petit exemple. Voici un autre exemple.",
        "ru": "Это маленький пример. Вот другой пример.",
        "es": "Este es un pequeño ejemplo. Aquí hay otro ejemplo."})


def canned_verdict(case, *, accepted=None, rejection=None):
    """Decisions are canned by fixture kind, not computed from candidate text."""
    if accepted is None:
        accepted = case.kind == "good"
    if not accepted and rejection is None:
        rejection = "syntheticEcho" if case.kind == "echo" else "syntheticWrongLanguage"
    measured = m.length_ratio(unicodedata.normalize("NFC", case.request["source"]),
                              unicodedata.normalize("NFC", case.request["candidate"]), unit="letters")
    return {"id": case.request["id"], "targetLocale": case.request["targetLocale"],
            "accepted": accepted, "rejection": rejection,
            "reason": "accepted synthetic fixture" if accepted else rejection,
            "sourceLetters": measured["source_count"], "candidateLetters": measured["target_count"],
            "lengthRatio": measured["ratio"], "lengthAccepted": True,
            "maximumOutputLetters": max(24, measured["target_count"]),
            "stablePrefix": "", "sourceNumbers": [], "targetNumbers": [],
            "detectedLanguage": None,
            "candidateLanguages": sorted({case.request["sourceLanguage"], "en",
                                           case.request["targetLocale"]})}


class CaseAndMetricTests(unittest.TestCase):
    def test_all_five_sources_and_four_wrong_locales_per_target(self):
        unit = synthetic_unit()
        cases = a.make_cases([unit])
        self.assertEqual(len(cases), 90)
        self.assertEqual(len({case.request["id"] for case in cases}), 90)
        for target in a.TARGET_LOCALES:
            rows = [case for case in cases if case.request["targetLocale"] == target]
            self.assertEqual(Counter(case.kind for case in rows), {"good": 5, "echo": 5, "wrong": 20})
            self.assertEqual({case.request["sourceLanguage"] for case in rows},
                             set(c.UN_LOCALES) - {target})
            for source in set(c.UN_LOCALES) - {target}:
                group = [case for case in rows if case.request["sourceLanguage"] == source]
                wrong = {case.candidate_language for case in group if case.kind == "wrong"}
                self.assertEqual(wrong, set(c.UN_LOCALES) - {source, target})
                self.assertEqual(next(case for case in group if case.kind == "echo")
                                 .request["candidate"], unit.texts[source])
                self.assertEqual(next(case for case in group if case.kind == "good")
                                 .request["candidate"], unit.texts[target])

    def test_full_turns_diacritics_and_linebreaks_remain_unchanged(self):
        unit = synthetic_unit()
        unit.texts["fr"] = "Café inventé.\nUne e\u0301tape.\u2028Dernière phrase."
        cases = a.make_cases([unit], targets=("fr",))
        for case in cases:
            self.assertEqual(case.request["source"], unit.texts[case.request["sourceLanguage"]])
            self.assertEqual(case.request["candidate"], unit.texts[case.candidate_language])
            if case.kind == "good":
                self.assertEqual(case.request["candidate"], unit.texts["fr"])
        self.assertEqual(len(cases), 30)

    def test_en_pass_through_never_enters_echo_denominator(self):
        cases = a.make_cases([synthetic_unit()], targets=("en",))
        self.assertEqual(sum(case.kind == "echo" for case in cases), 5)
        self.assertTrue(all(case.request["sourceLanguage"] != "en" for case in cases))

    def test_ratio_override_is_explicit_and_defaults_are_not_tuned(self):
        default = a.make_cases([synthetic_unit()])
        self.assertTrue(all("maximumLengthRatio" not in case.request for case in default))
        override = a.make_cases([synthetic_unit()], maximum_length_ratio=1.75)
        self.assertTrue(all(case.request["maximumLengthRatio"] == 1.75 for case in override))

    def test_invalid_targets_ratio_mappings_and_empty_corpus_fail(self):
        for targets in ((), ("en", "en"), ("zh-Hans",)):
            with self.subTest(targets=targets), self.assertRaises(ValueError):
                a.make_cases([synthetic_unit()], targets=targets)
        for ratio in (0, -1, True, float("nan"), float("inf")):
            with self.subTest(ratio=ratio), self.assertRaises(ValueError):
                a.make_cases([synthetic_unit()], maximum_length_ratio=ratio)
        for texts in ({"en": "invented"}, dict(synthetic_unit().texts, fr=" ")):
            with self.subTest(texts=texts), self.assertRaises(ValueError):
                a.make_cases([c.ParallelUnit("made-up", "un", texts)])
        for units in ([], [synthetic_unit(), synthetic_unit()]):
            with self.subTest(units=units), self.assertRaises(ValueError):
                a.make_cases(units)

    def test_quantiles_match_hand_linear_interpolation_and_count_undefined(self):
        result = a.letter_ratio_quantiles([4, .5, None, 2, 1])
        self.assertEqual((result["sample_count"], result["defined_count"], result["undefined_count"]),
                         (5, 4, 1))
        for key, expected in (("p50", 1.5), ("p95", 3.7), ("p99", 3.94), ("p99.5", 3.97), ("max", 4)):
            self.assertAlmostEqual(result[key], expected)
        for values in ([], [None]):
            empty = a.letter_ratio_quantiles(values)
            self.assertTrue(all(empty[key] is None for key in ("p50", "p95", "p99", "p99.5", "max")))

    def test_summary_denominators_reasons_and_zh_split_are_exact(self):
        records = []
        for case in a.make_cases([synthetic_unit()]):
            target, source = case.request["targetLocale"], case.request["sourceLanguage"]
            row = canned_verdict(case)
            if (target, source, case.kind) == ("es", "zh", "good"):
                row = canned_verdict(case, accepted=False, rejection="syntheticFalseReject")
                row["maximumOutputLetters"] = row["candidateLetters"] - 1
                row["lengthAccepted"] = False
            if (target, source, case.kind) == ("es", "en", "echo"):
                row = canned_verdict(case, accepted=True)
            if (target, source, case.kind, case.candidate_language) == ("fr", "zh", "wrong", "es"):
                row = canned_verdict(case, accepted=True)
            records.append({**row, "turn_id": case.turn_id, "case_kind": case.kind,
                            "source_language": source, "candidate_language": case.candidate_language})
        result = a.summarize(records, a.TARGET_LOCALES)
        self.assertEqual(result["es"]["false_rejection"], {"numerator": 1, "denominator": 5, "rate": .2})
        self.assertEqual(result["es"]["echo_interception"], {"numerator": 4, "denominator": 5, "rate": .8})
        self.assertEqual(result["fr"]["wrong_language_interception"],
                         {"numerator": 19, "denominator": 20, "rate": .95})
        zh = result["es"]["by_source"]["zh"]
        self.assertEqual(zh["false_rejection"]["denominator"], 1)
        self.assertEqual(zh["wrong_language_interception"]["denominator"], 4)
        self.assertEqual(zh["rejection_counts"]["good"], {"syntheticFalseReject": 1})
        self.assertEqual(zh["length_rejected_counts"]["good"], 1)
        self.assertEqual(result["es"]["reference_letter_length_ratio"]["defined_count"], 5)
        self.assertNotIn("en", result["en"]["by_source"])
        self.assertEqual(result["es"]["wrong_language_by_candidate"]["zh"]["interception"]["denominator"], 4)

    def test_observed_guard_uses_source_floor_and_actual_cli_limit(self):
        case = a.CalibrationCase("synthetic-short", "good", "en", {
            "id": "short", "source": "abc", "candidate": "abcdef",
            "sourceLanguage": "zh", "targetLocale": "en"})
        row = {**canned_verdict(case), "maximumOutputLetters": 36,
               "turn_id": case.turn_id, "case_kind": case.kind,
               "source_language": "zh", "candidate_language": "en"}
        guard = a._summarize([row])["observed_letter_guard"]
        self.assertEqual(guard["documented_minimum_source_letters"], 24)
        self.assertEqual(guard["observed_effective_limit_ratio"], {"sample_count": 1, "min": 1.5, "max": 1.5})

    def test_configured_policy_is_distinct_from_effective_allowance_and_checked(self):
        case = a.CalibrationCase("synthetic-policy", "good", "en", {
            "id": "synthetic-policy", "source": "化学", "candidate": "DNA",
            "sourceLanguage": "zh", "targetLocale": "en"})
        row = {**canned_verdict(case), "configuredMaximumLengthRatio": 1.5,
               "minimumSourceLetters": 24, "absoluteLetterAllowance": 12,
               "maximumOutputLetters": 48}
        self.assertEqual(a._validate_verdict(row, case)["configuredMaximumLengthRatio"], 1.5)
        for change in ({"configuredMaximumLengthRatio": 0}, {"minimumSourceLetters": 0},
                       {"absoluteLetterAllowance": -1}, {"maximumOutputLetters": 47},
                       {"configuredMaximumLengthRatio": float("nan")}):
            with self.assertRaises(ValueError):
                a._validate_verdict({**row, **change}, case)
        incomplete = dict(row)
        incomplete.pop("absoluteLetterAllowance")
        with self.assertRaises(ValueError):
            a._validate_verdict(incomplete, case)


class ScratchTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="synthetic-calibration-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.enterContext(patch.dict(os.environ, {c.OUTPUT_ROOT_ENV: str(self.root)}))

    def transport_cli(self, cases, *, noisy=False, large_prefix=False):
        # This stand-in only transports precomputed synthetic rows by ID. It
        # contains no acceptance or language-identification implementation.
        rows = {}
        for case in cases:
            row = canned_verdict(case)
            if large_prefix:
                row["stablePrefix"] = case.request["candidate"]
            rows[case.request["id"]] = row
        data = self.root / "canned-replies.json"
        data.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
        executable = self.root / "synthetic judge transport"
        executable.write_text(
            "#!/opt/homebrew/bin/python3.13 -B\n"
            "import json\nfrom pathlib import Path\nimport sys\n"
            "assert sys.argv[1:] == ['judge']\n"
            "rows = json.loads(Path(__file__).with_name('canned-replies.json').read_text())\n"
            + ("sys.stderr.write('synthetic diagnostic\\n' * 10000)\n" if noisy else "")
            + "requests = [json.loads(line) for line in sys.stdin.read().split('\\n') if line]\n"
            "for request in reversed(requests):\n"
            "    print(json.dumps(rows[request['id']], ensure_ascii=False))\n", encoding="utf-8")
        executable.chmod(0o700)
        return executable

    def un_fixture(self, *, all_partial=False):
        units = [synthetic_unit(f"S/PV.synthetic:turn:{index}") for index in (1, 2)]
        data = {"schema_version": 1, "id": "S/PV.synthetic", "turn_count": 2,
                "mapped_turn_counts": dict.fromkeys(c.UN_LOCALES, 2),
                "country_header_checks_all_passed": True, "turns": [
                    {"index": index, "texts": unit.texts,
                     "text_status": dict.fromkeys(c.UN_LOCALES, "extracted"),
                     "original_language": "en", "original_languages": ["en"]}
                    for index, unit in enumerate(units, 1)]}
        data["turns"][1]["text_status"]["ru"] = "partial_missing_page"
        if all_partial:
            data["turns"][0]["text_status"]["fr"] = "partial_missing_page"
        path = self.root / "un" / "S_PV.synthetic" / "turns.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return path, units


class JudgeTransportTests(ScratchTests):
    def test_real_subprocess_drains_large_stdin_stdout_stderr_and_reorders_by_id(self):
        unit = synthetic_unit()
        unit.texts.update({locale: text * 1000 for locale, text in unit.texts.items()})
        cases = a.make_cases([unit], targets=("es",))
        executable = self.transport_cli(cases, noisy=True, large_prefix=True)
        rows, diagnostics = a.judge_cases(executable, cases, batch_size=11, timeout_seconds=10)
        self.assertEqual([row["id"] for row in rows], [case.request["id"] for case in cases])
        self.assertEqual(len(rows), 30)
        self.assertEqual(len(diagnostics), 3)
        self.assertTrue(all(row["stderr_bytes"] > 65536 and row["truncated"] for row in diagnostics))
        self.assertEqual(rows[0]["stablePrefix"], cases[0].request["candidate"])

    def test_nfc_counts_accents_jamo_and_ignores_marks_digits_punctuation(self):
        request = {"id": "made-up-normalization", "source": "\u1100\u1161 12!",
                   "candidate": "e\u0301 \u0301 3.14", "sourceLanguage": "zh", "targetLocale": "fr"}
        case = a.CalibrationCase("synthetic-normalization", "good", "fr", request)
        row = canned_verdict(case)
        self.assertEqual((row["sourceLetters"], row["candidateLetters"], row["lengthRatio"]), (1, 1, 1))
        self.assertIs(a._validate_verdict(row, case), row)

    def test_zero_letter_source_requires_null_ratio(self):
        case = a.CalibrationCase("synthetic-numeric", "good", "en", {
            "id": "numeric", "source": "3.14!", "candidate": "DNA", "sourceLanguage": "zh", "targetLocale": "en"})
        row = canned_verdict(case)
        self.assertIsNone(row["lengthRatio"])
        self.assertIs(a._validate_verdict(row, case), row)
        row["lengthRatio"] = 0
        with self.assertRaises(ValueError):
            a._validate_verdict(row, case)

    def test_jsonl_unicode_line_separator_is_not_a_record_boundary(self):
        case = a.make_cases([synthetic_unit()], targets=("fr",))[0]
        reply = canned_verdict(case)
        reply["stablePrefix"] = "Une phrase.\u2028Une autre phrase."
        process = subprocess.CompletedProcess([], 0, json.dumps(reply, ensure_ascii=False) + "\n", "")
        with patch.object(a.subprocess, "run", return_value=process):
            rows, _ = a.judge_cases(self.root / "not-run", [case])
        self.assertEqual(rows[0]["stablePrefix"], reply["stablePrefix"])

    def test_bad_identity_row_count_and_duplicate_json_fields_fail(self):
        cases = a.make_cases([synthetic_unit()], targets=("es",))[:2]
        first, second = [canned_verdict(case) for case in cases]
        variants = ["", json.dumps(first) + "\n",
                    json.dumps(first) + "\n" + json.dumps(first) + "\n",
                    json.dumps(dict(first, id="unknown")) + "\n" + json.dumps(second) + "\n",
                    json.dumps(first).replace('"accepted": true', '"accepted": true, "accepted": true')
                    + "\n" + json.dumps(second) + "\n"]
        for output in variants:
            with self.subTest(output=output), patch.object(a.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, output, "")), self.assertRaises(ValueError):
                a.judge_cases(self.root / "not-run", cases)

    def test_schema_type_count_ratio_and_length_inconsistencies_fail(self):
        case = a.make_cases([synthetic_unit()], targets=("es",))[0]
        valid = canned_verdict(case)
        changes = ({"targetLocale": "fr"}, {"accepted": 1}, {"rejection": "synthetic"},
                   {"reason": ""}, {"sourceLetters": True}, {"sourceLetters": -1},
                   {"candidateLetters": 999}, {"lengthRatio": None}, {"lengthRatio": float("nan")},
                   {"lengthRatio": 999}, {"lengthAccepted": False}, {"maximumOutputLetters": -1},
                   {"maximumOutputLetters": float("inf")}, {"sourceNumbers": "3"},
                   {"targetNumbers": [3]}, {"candidateLanguages": [None]},
                   {"detectedLanguage": 3}, {"stablePrefix": None})
        for change in changes:
            row = dict(valid, **change)
            with self.subTest(change=change), patch.object(a.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, json.dumps(row) + "\n", "")), self.assertRaises(ValueError):
                a.judge_cases(self.root / "not-run", [case])
        del valid["reason"]
        with self.assertRaises(ValueError):
            a._validate_verdict(valid, case)

    def test_nonzero_exit_timeout_and_invalid_batch_parameters_fail(self):
        case = a.make_cases([synthetic_unit()])[0]
        with patch.object(a.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 7, "", "synthetic error")), self.assertRaisesRegex(ValueError, "exited 7"):
            a.judge_cases(self.root / "not-run", [case])
        with patch.object(a.subprocess, "run", side_effect=subprocess.TimeoutExpired("judge", 1)), \
                self.assertRaisesRegex(ValueError, "TimeoutExpired"):
            a.judge_cases(self.root / "not-run", [case])
        for kwargs in ({"batch_size": 0}, {"batch_size": True}, {"timeout_seconds": 0},
                       {"timeout_seconds": float("nan")}):
            with self.subTest(kwargs=kwargs), patch.object(a.subprocess, "run") as runner, \
                    self.assertRaises(ValueError):
                a.judge_cases(self.root / "not-run", [case], **kwargs)
            runner.assert_not_called()


class CalibrationReportTests(ScratchTests):
    def test_invalid_environment_root_fails_before_read_or_launch(self):
        for configured in (None, "", "relative-root", str(self.root / "missing"), str(c.repository_root())):
            environment = dict(os.environ)
            environment.pop(c.OUTPUT_ROOT_ENV, None)
            if configured is not None:
                environment[c.OUTPUT_ROOT_ENV] = configured
            output = self.root / "not-created.json"
            with self.subTest(configured=configured), patch.dict(os.environ, environment, clear=True), \
                    patch.object(a, "load_un") as reader, patch.object(a.subprocess, "run") as runner, \
                    self.assertRaises(ValueError):
                a.calibrate(cli=self.root / "absent-cli", un_root=self.root / "absent-un", output=output)
            reader.assert_not_called()
            runner.assert_not_called()
            self.assertFalse(output.exists())

    def test_synthetic_roundtrip_provenance_exclusions_and_no_input_changes(self):
        path, units = self.un_fixture()
        original = path.read_bytes()
        cases = a.make_cases(units[:1])
        executable = self.transport_cli(cases)
        output = self.root / "report" / "new.json"
        report = a.calibrate(cli=executable, un_root=path.parent.parent, output=output, batch_size=31)
        self.assertEqual(json.loads(output.read_text()), report)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(report["corpus"]["files"][0]["sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(report["tools"]["swift_cli"]["sha256"], hashlib.sha256(executable.read_bytes()).hexdigest())
        self.assertEqual(report["tools"]["reused_from_commit"], a.REUSED_COMMIT)
        self.assertEqual(set(report["tools"]["python_file_sha256"]),
                         {"__init__.py", "calibrate.py", "corpora.py", "metrics.py"})
        self.assertEqual(report["corpus"]["total_turn_count"], 2)
        self.assertEqual(report["corpus"]["included_turn_count"], 1)
        self.assertEqual(report["corpus"]["excluded_turn_count"], 1)
        self.assertEqual(report["corpus"]["partial_text_counts_by_language"], {"ru": 1})
        self.assertEqual(report["execution"]["case_count"], 90)
        self.assertEqual(report["execution"]["judge_batch_count"], 3)
        self.assertEqual(len(report["verdicts"]), 90)
        self.assertFalse(report["methods"]["token_ratio"]["measured"])
        self.assertIn("NFC", report["methods"]["letters"])
        self.assertIn("not independent validation", report["methods"]["guard_defaults"]["sample_relationship"])
        for target in a.TARGET_LOCALES:
            result = report["targets"][target]
            self.assertEqual(result["false_rejection"]["denominator"], 5)
            self.assertEqual(result["echo_interception"]["denominator"], 5)
            self.assertEqual(result["wrong_language_interception"]["denominator"], 20)

    def test_partial_inclusion_requires_explicit_option_and_is_reported(self):
        path, units = self.un_fixture()
        executable = self.transport_cli(a.make_cases(units, targets=("en",)))
        report = a.calibrate(cli=executable, un_root=path.parent.parent, output=self.root / "partial.json",
                             targets=("en",), include_partial=True, maximum_length_ratio=2)
        self.assertTrue(report["corpus"]["include_partial"])
        self.assertEqual(report["corpus"]["excluded_turn_count"], 0)
        self.assertEqual(report["corpus"]["partial_turn_count"], 1)
        self.assertTrue(report["corpus"]["partial_turns"][0]["included_by_request"])
        self.assertEqual(report["targets"]["en"]["false_rejection"]["denominator"], 10)
        self.assertEqual(report["methods"]["maximum_length_ratio_override"], 2)

    def test_main_interface_exports_compact_summary_and_refuses_overwrite(self):
        path, units = self.un_fixture()
        executable = self.transport_cli(a.make_cases(units[:1], targets=("es",)))
        output = self.root / "cli-report.json"
        argv = ["--cli", str(executable), "--un-root", str(path.parent.parent), "--output", str(output),
                "--targets", "es", "--batch-size", "13"]
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(a.main(argv), 0)
        summary = json.loads(stdout.getvalue())
        self.assertEqual(summary["case_count"], 30)
        self.assertEqual(summary["targets"]["es"]["echo_interception"]["numerator"], 5)
        original = output.read_bytes()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error, \
                patch.object(a, "load_un") as reader, patch.object(a.subprocess, "run") as runner:
            a.main(argv)
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(output.read_bytes(), original)
        reader.assert_not_called()
        runner.assert_not_called()

    def test_forbidden_paths_and_symlink_escape_fail_before_read_or_launch(self):
        link = self.root / "repository-link"
        link.symlink_to(c.repository_root(), target_is_directory=True)
        outputs = (c.repository_root() / "forbidden-calibration.json", link / "out.json",
                   c.output_root().parent / "other-work" / "out.json", c.output_root())
        for output in outputs:
            with self.subTest(output=output), patch.object(a, "load_un") as reader, \
                    patch.object(a.subprocess, "run") as runner, self.assertRaises(ValueError):
                a.calibrate(cli=self.root / "absent-cli", un_root=self.root / "absent-un", output=output)
            reader.assert_not_called()
            runner.assert_not_called()

    def test_nonexecutable_cli_and_no_eligible_turns_produce_no_report(self):
        output = self.root / "not-created" / "out.json"
        with self.assertRaisesRegex(ValueError, "executable"), patch.object(a, "load_un") as reader:
            a.calibrate(cli=self.root / "absent-cli", un_root=self.root, output=output)
        reader.assert_not_called()
        path, units = self.un_fixture(all_partial=True)
        executable = self.transport_cli(a.make_cases(units))
        with self.assertRaisesRegex(ValueError, "no eligible"), patch.object(a.subprocess, "run") as runner:
            a.calibrate(cli=executable, un_root=path.parent.parent, output=output)
        runner.assert_not_called()
        self.assertFalse(output.parent.exists())

    def test_mutated_corpus_or_cli_is_detected_before_report_creation(self):
        path, units = self.un_fixture()
        reader = c.read_un

        def read_then_change(*args, **kwargs):
            result = reader(*args, **kwargs)
            path.write_text(path.read_text() + "\n")
            return result

        with patch.object(a.c, "read_un", side_effect=read_then_change), self.assertRaisesRegex(ValueError, "changed"):
            a.load_un(path.parent.parent)
        cases = a.make_cases(units[:1])
        executable = self.transport_cli(cases)
        output = self.root / "changed-cli.json"

        def changed_cli(*args, **kwargs):
            executable.write_text(executable.read_text() + "\n")
            rows = "".join(json.dumps(canned_verdict(case)) + "\n" for case in cases)
            return subprocess.CompletedProcess([], 0, rows, "")

        with patch.object(a.subprocess, "run", side_effect=changed_cli), self.assertRaisesRegex(ValueError, "changed"):
            a.calibrate(cli=executable, un_root=path.parent.parent, output=output, batch_size=100)
        self.assertFalse(output.exists())


class ReferenceLetterAuditTests(unittest.TestCase):
    def test_han_only_and_mixed_sources_use_all_production_letters(self):
        pure = synthetic_unit("synthetic-han")
        pure.texts.update(zh="汉字 123。", en="ABCDEF")
        mixed = synthetic_unit("synthetic-mixed")
        mixed.texts.update(zh="汉字 DNA e\u0301 123。", en="ABCDEF")
        report = a.reference_letter_audit([pure, mixed], target="en")
        first, second = report["rows"]
        self.assertEqual((first["source_letters"], first["source_han_letters"],
                          first["source_other_letters"], first["target_letters"]), (2, 2, 0, 6))
        self.assertEqual((second["source_letters"], second["source_han_letters"],
                          second["source_other_letters"], second["target_letters"]), (6, 2, 4, 6))
        self.assertEqual((first["production_letter_ratio"], second["production_letter_ratio"]), (3, 1))
        self.assertEqual((first["han_denominator_ratio"], second["han_denominator_ratio"]), (3, 3))
        cohorts = report["by_source_composition"]
        self.assertEqual(cohorts["han_only"]["sample_count"], 1)
        self.assertEqual(cohorts["mixed_han_and_other_letters"]["sample_count"], 1)
        self.assertEqual(cohorts["mixed_han_and_other_letters"]["source_other_letters"], 4)
        self.assertEqual(report["production_letter_ratio"]["p50"], 2)
        self.assertEqual(report["han_denominator_diagnostic"]["p50"], 3)
        self.assertAlmostEqual(report["provisional_p99_5_ceiling"], 2.99)
        self.assertTrue(report["provisional"])
        self.assertFalse(report["independent_validation"])
        self.assertTrue(report["requires_expanded_holdout"])

    def test_nfc_scalar_categories_and_production_han_ranges_are_preserved(self):
        unit = synthetic_unit()
        unit.texts.update(zh="汉Ａe\u0301𠮷 \u1100\u1161 123., \u0301", en="E\u0301 ﬁ 123! \u0301")
        row = a.reference_letter_audit([unit], target="en")["rows"][0]
        self.assertEqual((row["source_letters"], row["source_han_letters"],
                          row["source_other_letters"], row["target_letters"]), (5, 2, 3, 2))
        self.assertEqual(row["production_letter_ratio"], .4)
        unit.texts["zh"] = "汉々〇"
        row = a.reference_letter_audit([unit], target="en")["rows"][0]
        # 々 is a Unicode letter outside the production Han ranges; 〇 is
        # category Nl, so it is not a LatinTargetLengthGuard letter at all.
        self.assertEqual((row["source_letters"], row["source_han_letters"],
                          row["source_other_letters"]), (2, 1, 1))

    def test_zero_letter_sources_are_reported_without_inventing_a_ratio(self):
        unit = synthetic_unit()
        unit.texts.update(zh="123 !?", en="DNA")
        report = a.reference_letter_audit([unit], target="en")
        self.assertIsNone(report["rows"][0]["production_letter_ratio"])
        self.assertIsNone(report["rows"][0]["han_denominator_ratio"])
        self.assertIsNone(report["provisional_p99_5_ceiling"])
        self.assertEqual(report["production_letter_ratio"]["undefined_count"], 1)
        self.assertEqual(report["by_source_composition"]["no_han_letters"]["sample_count"], 1)


class ReferenceLetterReportTests(ScratchTests):
    def test_calibration_exports_same_unit_audit_without_changing_inputs(self):
        path, units = self.un_fixture()
        original = path.read_bytes()
        executable = self.transport_cli(a.make_cases(units[:1], targets=("en",)))
        report = a.calibrate(cli=executable, un_root=path.parent.parent,
                             output=self.root / "letters.json", targets=("en",))
        audit = report["reference_length_audits"]["en_from_zh"]
        self.assertEqual(audit["sample_count"], 1)
        self.assertEqual(audit["by_source_composition"]["han_only"]["sample_count"], 1)
        good = next(row for row in report["verdicts"]
                    if row["source_language"] == "zh" and row["case_kind"] == "good")
        row = audit["rows"][0]
        self.assertEqual((row["source_letters"], row["target_letters"], row["production_letter_ratio"]),
                         (good["sourceLetters"], good["candidateLetters"], good["lengthRatio"]))
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(audit["independent_validation"])
        self.assertIn("LatinTargetLengthGuard.letterCount", report["methods"]["letters"])


if __name__ == "__main__":
    unittest.main()
