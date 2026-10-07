"""Synthetic integration with the App-source CLI; no model or public corpus."""
from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.target_eval import corpora as c

SOURCE = Path(__file__).resolve().parents[1]
LAB = SOURCE.parent
DERIVED = LAB / "work" / "dd-latin" / "target-acceptance-cli"


class TargetAcceptanceCLIIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = c.output_root()
        default_cli = cls.output / "latin-cli-delivery" / "target-acceptance-cli"
        cls.cli = Path(os.environ.get("LIVELINGO_TARGET_ACCEPTANCE_CLI", str(default_cli)))
        if not cls.cli.is_file():
            raise unittest.SkipTest("Build the offline target-acceptance CLI first")

    def row(self, *, id="synthetic", target="es", language="en", source=None, candidate=None, **extra):
        return {"id": id, "targetLocale": target, "sourceLanguage": language,
                "source": "The solution contains water and the temperature increases." if source is None else source,
                "candidate": "La solución contiene agua y la temperatura aumenta." if candidate is None else candidate, **extra}

    def run_cli(self, args, input="", *, env=None):
        return subprocess.run([str(self.cli), *args], input=input, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, env=env)

    def judge(self, rows):
        reply = self.run_cli(["judge"], "".join(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n" for row in rows))
        self.assertEqual(reply.returncode, 0, reply.stderr)
        return [json.loads(line) for line in reply.stdout.split("\n") if line]

    def test_multitarget_jsonl_verdicts_have_reasons_and_preserve_identity(self):
        source = "The solution contains water and the temperature increases."
        rows = [self.row(id="good-es"), self.row(id="echo-es", candidate=source),
                self.row(id="good-fr", target="fr", candidate="La solution contient de l’eau et la température augmente."),
                self.row(id="good-en", target="en", language="es", source="La solución contiene agua y la temperatura aumenta.", candidate=source)]
        replies = self.judge(rows)
        self.assertEqual([reply["id"] for reply in replies], [row["id"] for row in rows])
        self.assertEqual([reply["accepted"] for reply in replies], [True, False, True, True])
        self.assertEqual(replies[1]["rejection"], "sourceEcho")
        self.assertTrue(all(reply["reason"] for reply in replies))
        self.assertIsNone(replies[0]["rejection"])
        self.assertEqual(replies[2]["candidateLanguages"], ["en", "fr"])

    def test_term_numeric_and_stable_prefix_diagnostics(self):
        rows = [self.row(source="pH 7.4", candidate="pH 7,4"),
                self.row(id="prefix", source="The value is 3.14. It increases.",
                         candidate="La valeur est 3,14. Elle augmente.", target="fr")]
        replies = self.judge(rows)
        self.assertEqual(replies[0]["sourceNumbers"], ["74e-1"])
        self.assertEqual(replies[0]["targetNumbers"], ["74e-1"])
        self.assertEqual(replies[1]["stablePrefix"], "La valeur est 3,14.")
        self.assertTrue(all(reply["accepted"] for reply in replies))

    def test_unicode_letter_counts_and_zero_source_ratio(self):
        replies = self.judge([self.row(source="DNA", candidate="DNA"),
                              self.row(source="1234", candidate="1234", target="fr")])
        self.assertEqual(replies[0]["sourceLetters"], 3)
        self.assertEqual(replies[0]["candidateLetters"], 3)
        self.assertEqual(replies[0]["lengthRatio"], 1)
        self.assertIsNone(replies[1]["lengthRatio"])
        for row in replies:
            self.assertAlmostEqual(row["maximumOutputLetters"], max(row["sourceLetters"], row["minimumSourceLetters"])
                                   * row["configuredMaximumLengthRatio"] + row["absoluteLetterAllowance"])

    def test_zh_hans_uses_original_gate_and_original_stable_prefix(self):
        rows = [self.row(id="han", target="zh-Hans", source="The temperature increases.", candidate="温度升高。"),
                self.row(id="echo", target="zh-Hans", candidate="The solution contains water and the temperature increases."),
                self.row(id="prefix", target="zh-Hans", source="The temperature increases. The pressure decreases.", candidate="温度升高。压力降低。")]
        replies = self.judge(rows)
        self.assertEqual([reply["accepted"] for reply in replies], [True, False, True])
        self.assertEqual(replies[1]["rejection"], "sourceEcho")
        self.assertEqual(replies[2]["stablePrefix"], "温度升高。")

    def test_zh_english_trimmed_character_limit_and_han_counts(self):
        source = "The temperature increases now."
        limit = len(source) * 1.3
        boundary = int(limit)
        rows = [self.row(id="boundary", target="zh-Hans", source=source, candidate="温" * boundary),
                self.row(id="too-long", target="zh-Hans", source=source, candidate="温" * (boundary + 1)),
                self.row(id="trim-notices", target="zh-Hans", source=" \t" + source + " \r\n",
                         candidate=" \t【公式待核对】\n【公式待核对】\t" + "温" * boundary + "。 \n"),
                self.row(id="technical", target="zh-Hans", source=source,
                         candidate="温" * boundary + " pH 7.4"),
                self.row(id="combining", target="zh-Hans", source="a\u0301" * len(source), candidate="温" * boundary)]
        replies = self.judge(rows)
        self.assertEqual([r["accepted"] for r in replies], [True, False, True, True, True])
        self.assertEqual(replies[1]["rejection"], "disproportionateLength")
        for request, reply in zip(rows, replies):
            with self.subTest(id=request["id"]):
                self.assertEqual(reply["sourceLetters"], len(source))
                self.assertEqual(reply["candidateLetters"], boundary + (request["id"] == "too-long"))
                self.assertAlmostEqual(reply["maximumOutputLetters"], limit)
                self.assertEqual(reply["lengthAccepted"], reply["accepted"])
                self.assertEqual(reply["configuredMaximumLengthRatio"], 1.3)
                self.assertEqual(reply["minimumSourceLetters"], 24)
                self.assertAlmostEqual(reply["lengthRatio"], reply["candidateLetters"] / len(source))

    def test_zh_english_short_floor_and_notice_only_rejection(self):
        rows = [self.row(id="short-boundary", target="zh-Hans", source="DNA", candidate="温" * 31),
                self.row(id="short-too-long", target="zh-Hans", source="DNA", candidate="温" * 32),
                self.row(id="notice-only", target="zh-Hans", source="DNA", candidate="【公式待核对】\n【公式待核对】"),
                self.row(id="embedded-notice", target="zh-Hans", source="DNA", candidate="温【公式待核对】温"),
                self.row(id="empty", target="zh-Hans", source="", candidate="")]
        replies = self.judge(rows)
        self.assertEqual([r["accepted"] for r in replies], [True, False, False, True, False])
        self.assertEqual(replies[1]["rejection"], "disproportionateLength")
        self.assertEqual(replies[2]["rejection"], "empty")
        self.assertEqual(replies[2]["candidateLetters"], 0)
        self.assertEqual(replies[3]["candidateLetters"], len("温公式待核对温"))
        self.assertIsNone(replies[4]["lengthRatio"])
        for reply in replies:
            self.assertAlmostEqual(reply["maximumOutputLetters"], 24 * 1.3)

    def test_zh_nonenglish_uses_each_app_writing_system_limit(self):
        # Expected bounds are the original App's runaway heuristics, not corpus
        # measurements. Exercise both sides so a second English guard cannot pass.
        cases = [("ja", "あ", 2, 12), ("zh", "源", 2, 12), ("yue", "源", 2, 12),
                 ("th", "ก", 2, 12), ("ko", "가", 2.5, 12), ("ar", "س", 2, 24),
                 ("hi", "क", 2, 24), ("ru", "я", 1.5, 24), ("el", "λ", 1.5, 24),
                 ("es", "ñ", 1.3, 24)]
        for language, character, ratio, floor in cases:
            for source_count in (1, 30):
                with self.subTest(language=language, source_count=source_count):
                    limit = max(source_count, floor) * ratio
                    boundary = int(limit)
                    rows = [self.row(id=str(count), target="zh-Hans", language=language,
                                     source=" \t" + character * source_count + "! \n", candidate="温" * count)
                            for count in (boundary, boundary + 1)]
                    replies = self.judge(rows)
                    self.assertEqual([r["accepted"] for r in replies], [True, False])
                    self.assertEqual(replies[1]["rejection"], "disproportionateLength")
                    for count, reply in zip((boundary, boundary + 1), replies):
                        self.assertEqual(reply["sourceLetters"], source_count)
                        self.assertEqual(reply["candidateLetters"], count)
                        self.assertAlmostEqual(reply["maximumOutputLetters"], limit)
                        self.assertEqual(reply["configuredMaximumLengthRatio"], ratio)
                        self.assertEqual(reply["minimumSourceLetters"], floor)
                        self.assertEqual(reply["lengthAccepted"], reply["accepted"])

    def test_zh_nonenglish_counts_alphanumerics_without_leading_notices(self):
        # Japanese: 15 kana + 3 digits => 36 output alphanumerics. Punctuation
        # cannot increase the allowance; Latin letters and digits consume it.
        source = "あ" * 15 + " 123 " + "。" * 100
        rows = [self.row(id=str(count), target="zh-Hans", language="ja", source=" \t" + source + "\n",
                         candidate=" \n【公式待核对】\t【公式待核对】\n" + "温" * count + " pH 7.4")
                for count in (32, 33)]
        replies = self.judge(rows)
        self.assertEqual([r["accepted"] for r in replies], [True, False])
        for count, reply in zip((36, 37), replies):
            self.assertEqual(reply["sourceLetters"], 18)
            self.assertEqual(reply["candidateLetters"], count)
            self.assertEqual(reply["maximumOutputLetters"], 36)
            self.assertAlmostEqual(reply["lengthRatio"], count / 18)

    def test_zh_content_rejection_keeps_priority_over_length(self):
        rows = [self.row(id=language, target="zh-Hans", language=language,
                         source="The temperature increases." if language == "en" else "あ",
                         candidate="<think>" + "温" * 100)
                for language in ("en", "ja")]
        for reply in self.judge(rows):
            self.assertFalse(reply["accepted"])
            self.assertFalse(reply["lengthAccepted"])
            self.assertEqual(reply["rejection"], "controlMarker")

    def test_zh_combining_marks_keep_original_branch_rejection(self):
        for candidate in ("\u0301", " \t【公式待核对】\n\u0301 \n"):
            with self.subTest(candidate=candidate):
                replies = self.judge([
                    self.row(target="zh-Hans", language="en", candidate=candidate),
                    self.row(target="zh-Hans", language="ja", source="あ", candidate=candidate)])
                self.assertEqual([r["accepted"] for r in replies], [False, False])
                self.assertEqual([r["rejection"] for r in replies], ["incompleteProse", "nonChineseText"])

    def test_zh_unsupported_source_does_not_invent_length_metadata(self):
        reply = self.judge([self.row(target="zh-Hans", language="en-US", candidate="温度升高。")])[0]
        self.assertFalse(reply["accepted"])
        self.assertEqual(reply["rejection"], "nonChineseText")
        for key in ("maximumOutputLetters", "configuredMaximumLengthRatio", "minimumSourceLetters"):
            self.assertIn(key, reply)
            self.assertIsNone(reply[key])

    def test_cli_and_owned_sources_have_no_machine_path_literals(self):
        machine_prefix = b"/" + b"Users" + b"/"
        self.assertFalse(machine_prefix in self.cli.read_bytes(), "CLI contains a machine path")
        scripts = Path(__file__).resolve().parent
        for name in ("target-acceptance-cli.swift", "build-target-eval-cli.sh", "test_target_acceptance_cli.py"):
            with self.subTest(name=name):
                self.assertNotIn(machine_prefix, (scripts / name).read_bytes())
        self.assertNotIn("#filePath", (scripts / "target-acceptance-cli.swift").read_text())

    def test_bad_target_ratio_and_json_fail_without_fabricated_verdict(self):
        for row in [self.row(target="de"), self.row(maximumLengthRatio=0), self.row(maximumLengthRatio=-1)]:
            reply = self.run_cli(["judge"], json.dumps(row) + "\n")
            self.assertNotEqual(reply.returncode, 0)
            self.assertEqual(reply.stdout, "")
        reply = self.run_cli(["judge"], "not json\n")
        self.assertNotEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, "")

    def test_prompt_export_reads_back_exact_bytes_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-", dir=self.output) as scratch:
            destination = Path(scratch) / "prompts"
            reply = self.run_cli(["prompts", "--output-dir", str(destination)])
            self.assertEqual(reply.returncode, 0, reply.stderr)
            manifest = json.loads((destination / "manifest.json").read_text())
            self.assertNotIn(b"/" + b"Users" + b"/", (destination / "manifest.json").read_bytes())
            self.assertEqual(manifest["targetsWithPrompts"], ["zh-Hans"])
            self.assertEqual(manifest["targetsWithoutPrompts"], ["en", "es", "fr"])
            self.assertFalse(manifest["addedTrailingNewline"])
            self.assertEqual(len(manifest["prompts"]), 14)
            for entry in manifest["prompts"]:
                data = (destination / entry["file"]).read_bytes()
                self.assertEqual(entry["byteCount"], len(data))
                self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
                data.decode("utf-8")
            original = (destination / "manifest.json").read_bytes()
            again = self.run_cli(["prompts", "--output-dir", str(destination)])
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual((destination / "manifest.json").read_bytes(), original)

    def test_prompt_export_rejects_checkout_and_symlink_destinations(self):
        reply = self.run_cli(["prompts", "--output-dir", str(SOURCE / "forbidden-prompt-output")])
        self.assertNotEqual(reply.returncode, 0)
        self.assertFalse((SOURCE / "forbidden-prompt-output").exists())
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-path-", dir=self.output) as scratch:
            root = Path(scratch)
            (root / "link").symlink_to(root, target_is_directory=True)
            reply = self.run_cli(["prompts", "--output-dir", str(root / "link" / "escape")])
            self.assertNotEqual(reply.returncode, 0)
            self.assertFalse((root / "escape").exists())

    def test_prompt_output_root_comes_from_environment_not_cwd(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-runtime-", dir=self.output) as scratch:
            destination = Path(scratch) / "prompts"
            reply = subprocess.run([str(self.cli), "prompts", "--output-dir", str(destination)],
                                   cwd=LAB / "work" / "dd-latin", capture_output=True, text=True, timeout=60)
            self.assertEqual(reply.returncode, 0, reply.stderr)
            self.assertTrue((destination / "manifest.json").is_file())

    def test_prompt_export_uses_configured_root_after_binary_relocation(self):
        DERIVED.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="synthetic-relocated-", dir=DERIVED) as scratch:
            relocated = Path(scratch) / "target-acceptance-cli"
            relocated.write_bytes(self.cli.read_bytes())
            relocated.chmod(0o700)
            with tempfile.TemporaryDirectory(prefix="synthetic-cli-root-", dir=self.output) as output:
                destination = Path(output) / "prompts"
                reply = subprocess.run([str(relocated), "prompts", "--output-dir", str(destination)],
                                       capture_output=True, text=True, timeout=60)
                self.assertEqual(reply.returncode, 0, reply.stderr)
                self.assertTrue((destination / "manifest.json").is_file())

    def test_prompt_export_requires_existing_external_environment_root(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-config-", dir=self.output) as scratch:
            root = Path(scratch)
            link = root / "root-link"
            link.symlink_to(root, target_is_directory=True)
            file = root / "root-file"
            file.write_text("synthetic", encoding="utf-8")
            invalid = (None, "", "relative-root", str(root / "missing"), str(link),
                       str(file), str(root / ".." / root.name), str(SOURCE))
            for configured in invalid:
                destination = (SOURCE if configured == str(SOURCE) else root) / "not-created"
                environment = dict(os.environ)
                environment.pop(c.OUTPUT_ROOT_ENV, None)
                if configured is not None:
                    environment[c.OUTPUT_ROOT_ENV] = configured
                with self.subTest(configured=configured):
                    reply = self.run_cli(["prompts", "--output-dir", str(destination)], env=environment)
                    self.assertNotEqual(reply.returncode, 0)
                    self.assertFalse(destination.exists())

    def test_prompt_export_follows_environment_changes_and_rejects_previous_root(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-new-root-", dir=self.output) as scratch:
            configured = Path(scratch) / "external-output"
            configured.mkdir()
            environment = dict(os.environ, **{c.OUTPUT_ROOT_ENV: str(configured)})
            destination = configured / "prompts"
            reply = self.run_cli(["prompts", "--output-dir", str(destination)], env=environment)
            self.assertEqual(reply.returncode, 0, reply.stderr)
            self.assertTrue((destination / "manifest.json").is_file())
            outside = Path(scratch) / "outside-root"
            reply = self.run_cli(["prompts", "--output-dir", str(outside)], env=environment)
            self.assertNotEqual(reply.returncode, 0)
            self.assertFalse(outside.exists())

    def test_prompt_directory_creation_is_exclusive(self):
        with tempfile.TemporaryDirectory(prefix="synthetic-cli-exclusive-", dir=self.output) as scratch:
            path = str(Path(scratch) / "prompts")
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(lambda _: self.run_cli(["prompts", "--output-dir", path]), range(2)))
            self.assertEqual(sum(row.returncode == 0 for row in replies), 1)
            self.assertEqual(len(json.loads((Path(path) / "manifest.json").read_text())["prompts"]), 14)

    def test_build_directory_creation_is_exclusive_and_rejects_checkout(self):
        script = Path(__file__).resolve().parent / "build-target-eval-cli.sh"
        with tempfile.TemporaryDirectory(prefix="synthetic-build-exclusive-", dir=self.output) as scratch:
            root = Path(scratch)
            tools = root / "bin"
            tools.mkdir()
            # Synthetic compiler only verifies directory reservation. It writes
            # exactly the -o path supplied by the real build script, no models.
            compiler = tools / "xcrun"
            compiler.write_text('#!/usr/bin/python3\nimport json, os, sys\nfrom pathlib import Path\n'
                                'args = sys.argv[1:]\nout = Path(args[args.index("-o") + 1])\n'
                                'out.write_text("synthetic-binary")\n'
                                'out.with_name("synthetic-build-arguments.json").write_text('
                                'json.dumps({"args": args, "tmp": os.environ["TMPDIR"]}))\n')
            compiler.chmod(0o700)
            environment = dict(os.environ, PATH=str(tools) + ":" + os.environ.get("PATH", ""))
            destination = root / "build"
            def build(_):
                return subprocess.run(["/bin/bash", str(script), str(destination)], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(build, range(2)))
            self.assertEqual(sum(reply.returncode == 0 for reply in replies), 1)
            self.assertEqual((destination / "target-acceptance-cli").read_text(), "synthetic-binary")
            invocation = json.loads((destination / "synthetic-build-arguments.json").read_text())
            args = invocation["args"]
            self.assertEqual(args[args.index("-file-prefix-map") + 1], str(script.parent.parent) + "=.")
            self.assertEqual(Path(args[args.index("-module-cache-path") + 1]), DERIVED / destination.name / "ModuleCache.noindex")
            self.assertEqual(Path(invocation["tmp"]), DERIVED / destination.name / "tmp")
            environment.pop(c.OUTPUT_ROOT_ENV)
            rejected = subprocess.run(["/bin/bash", str(script), str(root / "unset-root")],
                                      env=environment, capture_output=True, timeout=20)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(c.OUTPUT_ROOT_ENV.encode(), rejected.stderr)
            self.assertFalse((root / "unset-root").exists())
            environment[c.OUTPUT_ROOT_ENV] = str(self.output)
            rejected = subprocess.run(["/bin/bash", str(script), str(SOURCE / "forbidden-build-output")],
                                      env=environment, capture_output=True, timeout=20)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertFalse((SOURCE / "forbidden-build-output").exists())


if __name__ == "__main__":
    unittest.main()
