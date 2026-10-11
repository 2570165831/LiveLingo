"""CPU-only synthetic JSONL integration tests; never load transcripts or audio.

Run with --build-dir DIR to compile into DIR/text-stats-test and DIR/ModuleCache,
or --binary FILE to test an existing CLI. Without either, use a temp directory.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest


BINARY: Path | None = None
BUILD_DIR: Path | None = None
FIELDS = {
    "pk_word_count", "pk_char_count", "english_gate_accepted", "quality_reason",
    "parakeet_accepted", "nl_language", "nl_probability", "nl_english_probability",
}
REASONS = {None, "emptyTranscript", "invalidText", "implausiblyShort", "repeatedLoop", "runawayText"}


def request(text: str, duration: float = 10) -> bytes:
    return json.dumps({"text": text, "duration": duration}, ensure_ascii=False, allow_nan=False).encode("utf-8")


class TextStatsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if BINARY is not None:
            cls.binary = BINARY.resolve()
            if not cls.binary.is_file():
                raise RuntimeError("The requested test binary is missing")
            return
        if BUILD_DIR is None:
            temporary = tempfile.TemporaryDirectory(prefix="text-stats-tests-")
            cls.addClassCleanup(temporary.cleanup)
            build = Path(temporary.name)
        else:
            build = BUILD_DIR.resolve()
            build.mkdir(parents=True, exist_ok=True)
        cache = build / "ModuleCache"
        cache.mkdir(exist_ok=True)
        cls.binary = build / "text-stats-test"
        environment = os.environ.copy()
        environment["TMPDIR"] = str(build)
        result = subprocess.run(
            ["xcrun", "swiftc", "-O", "-module-cache-path", str(cache),
             str(Path(__file__).with_name("text_stats.swift")), "-o", str(cls.binary)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError("CPU Swift compilation failed")

    def decode(self, line: bytes) -> dict:
        try:
            value = json.loads(line)
        except (ValueError, UnicodeError):
            self.fail("CLI response is not valid JSON")
        self.assertTrue(isinstance(value, dict), "CLI response is not an object")
        return value

    def check_stats(self, value: dict):
        self.assertTrue(set(value) == FIELDS, "Unexpected statistics fields")
        for key in ("pk_word_count", "pk_char_count"):
            self.assertTrue(type(value[key]) is int and value[key] >= 0, "Invalid count")
        for key in ("english_gate_accepted", "parakeet_accepted"):
            self.assertTrue(type(value[key]) is bool, "Invalid acceptance flag")
        self.assertTrue(value["quality_reason"] in REASONS, "Unsafe quality reason")
        language = value["nl_language"]
        self.assertTrue(language is None or isinstance(language, str), "Invalid NL language")
        for key in ("nl_probability", "nl_english_probability"):
            probability = value[key]
            self.assertTrue(probability is None or (
                type(probability) in (int, float) and math.isfinite(probability) and 0 <= probability <= 1
            ), "Invalid NL probability")

    def run_lines(self, lines: list[bytes], *, final_newline: bool = True) -> list[dict]:
        payload = b"\n".join(lines) + (b"\n" if final_newline else b"")
        result = subprocess.run([str(self.binary)], input=payload, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode, 0, "CLI exited unsuccessfully")
        self.assertTrue(result.stderr == b"", "CLI wrote diagnostics")
        replies = result.stdout.splitlines()
        self.assertEqual(len(replies), len(lines), "Expected exactly one response per input line")
        return [self.decode(line) for line in replies]

    def stats(self, text: str, duration: float = 10) -> dict:
        value = self.run_lines([request(text, duration)])[0]
        self.check_stats(value)
        return value

    def test_fixed_fields_and_no_content_in_output(self):
        marker = "SYNTHETIC_CONTENT_CANARY"
        result = subprocess.run([str(self.binary)], input=request(marker) + b"\n",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.encode() not in result.stdout + result.stderr, "Input content leaked")
        self.assertTrue(result.stderr == b"", "CLI wrote diagnostics")
        value = self.decode(result.stdout)
        self.check_stats(value)
        self.assertEqual(value["pk_word_count"], 3)
        self.assertIsNone(value["quality_reason"])
        self.assertTrue(value["parakeet_accepted"])

    def test_empty_and_whitespace_have_no_nl_guess(self):
        for text in ("", " \t\r\n", "\u00a0\u2003", "\u2028\u2029"):
            with self.subTest():
                value = self.stats(text)
                self.assertEqual(value["pk_word_count"], 0)
                self.assertEqual(value["pk_char_count"], 0)
                self.assertTrue(value["english_gate_accepted"])
                self.assertEqual(value["quality_reason"], "emptyTranscript")
                self.assertFalse(value["parakeet_accepted"])
                for key in ("nl_language", "nl_probability", "nl_english_probability"):
                    self.assertIsNone(value[key])

    def test_unicode_graphemes_and_quality_word_definition(self):
        value = self.stats(" \tCafé don't e\u0301lan 👩🏽‍💻 \r\n")
        self.assertEqual(value["pk_word_count"], 3)
        self.assertEqual(value["pk_char_count"], 17)
        self.assertIsNone(value["quality_reason"])
        self.assertTrue(value["parakeet_accepted"])
        value = self.stats("can't rock’n’roll ٢")
        self.assertEqual(value["pk_word_count"], 5)
        self.assertEqual(value["pk_char_count"], 19)
        self.assertTrue(value["parakeet_accepted"])

    def test_han_latin_threshold_and_original_scalar_ranges(self):
        cases = [
            ("abcde 中", False), ("abcdef 中", True),
            ("abcdef 中文", True), ("abcdefgh 中文字", False),
            ("abcdefghi 中文字", True), ("123456 中", False),
            ("éééééé 中", True), ("e\u0301" * 6 + " 中", True),
            ("中文", False), ("㐀", False), ("豈", False), ("𠀀", False),
            ("Ελληνικά", False), ("Русский", False), ("ＡＢＣ", False),
            # These broad source ranges count Latin-block symbols too.
            ("×" * 6 + " 中", True),
        ]
        replies = self.run_lines([request(text) for text, _ in cases])
        for value, (_, expected) in zip(replies, cases):
            with self.subTest():
                self.check_stats(value)
                self.assertEqual(value["english_gate_accepted"], expected)
                self.assertEqual(value["parakeet_accepted"], expected)

    def test_numbers_and_math_are_accepted(self):
        value = self.stats("3.14 + ٢ = ４")
        self.assertEqual(value["pk_word_count"], 4)
        self.assertTrue(value["english_gate_accepted"])
        self.assertIsNone(value["quality_reason"])
        self.assertTrue(value["parakeet_accepted"])
        value = self.stats("٢", 12)
        self.assertEqual(value["quality_reason"], "implausiblyShort")
        self.assertTrue(value["parakeet_accepted"])

    def test_short_acknowledgement_exception_at_duration_boundary(self):
        for duration, reason in ((0, None), (7.999, None), (8, "implausiblyShort"), (60, "implausiblyShort")):
            with self.subTest(duration=duration):
                value = self.stats("  Yes.  ", duration)
                self.assertEqual(value["pk_word_count"], 1)
                self.assertEqual(value["quality_reason"], reason)
                self.assertTrue(value["parakeet_accepted"])
        value = self.stats("中文", 8)
        self.assertEqual(value["quality_reason"], "implausiblyShort")
        self.assertFalse(value["parakeet_accepted"])

    def test_invalid_text_and_apostrophe_only_quality_tokens(self):
        for text in ("valid \ufffd word", "… 😊", "!!!"):
            with self.subTest():
                value = self.stats(text, 2)
                self.assertEqual(value["quality_reason"], "invalidText")
                self.assertFalse(value["parakeet_accepted"])
        value = self.stats("'", 2)
        self.assertEqual(value["pk_word_count"], 1)
        self.assertIsNone(value["quality_reason"])
        self.assertFalse(value["english_gate_accepted"])
        self.assertFalse(value["parakeet_accepted"])

    def test_local_emphasis_is_allowed(self):
        texts = [
            "write write write the next sentence explains why the measurement remains useful",
            "one two one two one two then we explain the result in detail",
        ]
        for text in texts:
            with self.subTest():
                value = self.stats(text)
                self.assertIsNone(value["quality_reason"])
                self.assertTrue(value["parakeet_accepted"])

    def test_short_repetitions_and_eight_word_boundary(self):
        for count, reason in ((3, None), (7, None), (8, "repeatedLoop")):
            with self.subTest(count=count):
                value = self.stats(" ".join(["repeat"] * count))
                self.assertEqual(value["quality_reason"], reason)
                self.assertEqual(value["parakeet_accepted"], reason is None)

    def test_dominant_word_share_boundary_and_noncontiguous_counts(self):
        cases = [
            (" ".join(["repeat"] * 6 + [f"tail{i}" for i in range(4)]), "repeatedLoop"),
            (" ".join(["repeat"] * 6 + [f"tail{i}" for i in range(5)]), None),
            ("repeat alpha repeat beta repeat gamma repeat delta repeat repeat", "repeatedLoop"),
            (" ".join(["repeat"] * 5 + ["alpha", "beta", "gamma"]), "repeatedLoop"),
        ]
        for text, reason in cases:
            with self.subTest():
                value = self.stats(text)
                self.assertEqual(value["quality_reason"], reason)
                self.assertEqual(value["parakeet_accepted"], reason is None)

    def test_phrase_loop_widths_and_share_boundary(self):
        for width in (2, 3, 4):
            phrase = [f"phrase{i}" for i in range(width)]
            for extra, reason in ((width * 2, "repeatedLoop"), (width * 2 + 1, None)):
                with self.subTest(width=width, extra=extra):
                    text = " ".join(phrase * 3 + [f"tail{i}" for i in range(extra)])
                    value = self.stats(text)
                    self.assertEqual(value["quality_reason"], reason)
                    self.assertEqual(value["parakeet_accepted"], reason is None)

    def test_runaway_floor_duration_rate_and_fractional_boundary(self):
        for duration, boundary in ((0, 40), (5, 40), (6.1, 42), (10, 70)):
            for count in (boundary, boundary + 1):
                with self.subTest(duration=duration, count=count):
                    value = self.stats(" ".join(f"word{i}" for i in range(count)), duration)
                    self.assertEqual(value["pk_word_count"], count)
                    self.assertEqual(value["quality_reason"], None if count == boundary else "runawayText")
                    self.assertEqual(value["parakeet_accepted"], count == boundary)

    def test_quality_reason_precedence(self):
        value = self.stats("\ufffd " + " ".join(["repeat"] * 50), 0)
        self.assertEqual(value["quality_reason"], "invalidText")
        value = self.stats(" ".join(["repeat"] * 50), 0)
        self.assertEqual(value["quality_reason"], "runawayText")

    def test_nl_language_probabilities_and_independent_requests(self):
        english = "The gardener waters the plants every morning and watches the flowers grow in the sunshine."
        french = "Le jardinier arrose les plantes chaque matin et regarde les fleurs pousser dans le jardin."
        replies = self.run_lines([request(english), request(french), request(""), request(english)])
        for value in replies:
            self.check_stats(value)
        self.assertEqual(replies[0]["nl_language"], "en")
        self.assertEqual(replies[1]["nl_language"], "fr")
        self.assertEqual(replies[3], replies[0])
        self.assertTrue(replies[1]["english_gate_accepted"])
        self.assertIsNone(replies[2]["nl_language"])
        self.assertIsNone(replies[2]["nl_probability"])
        self.assertIsNone(replies[2]["nl_english_probability"])
        self.assertGreater(replies[0]["nl_probability"], 0)
        self.assertGreater(replies[0]["nl_english_probability"], 0)

    def test_protocol_errors_are_fixed_and_do_not_leak(self):
        marker = "SYNTHETIC_ERROR_CONTENT_CANARY"
        lines = [
            b"", marker.encode(), b"null", b"[]", b"42", b"{}",
            json.dumps({"text": marker}).encode(),
            json.dumps({"duration": 1}).encode(),
            json.dumps({"text": marker, "duration": 1, "extra": marker}).encode(),
            json.dumps({"text": [marker], "duration": 1}).encode(),
            json.dumps({"text": None, "duration": 1}).encode(),
            json.dumps({"text": marker, "duration": True}).encode(),
            json.dumps({"text": marker, "duration": "1"}).encode(),
            json.dumps({"text": marker, "duration": None}).encode(),
            request(marker, -1), request(marker, 1e308),
            b'{"text":"' + marker.encode() + b'","duration":NaN}',
            b'{"text":"' + marker.encode() + b'","duration":Infinity}',
            b'{"text":"' + marker.encode() + b'","duration":1e999}',
            b'{"text":"' + marker.encode() + b'\xff","duration":1}',
            request(marker) + b" trailing", request(marker) + request(marker),
        ]
        values = self.run_lines(lines + [request("A valid final request")])
        for value in values[:-1]:
            self.assertTrue(value == {"error_code": "invalid_input"}, "Unsafe protocol error response")
            self.assertTrue(marker not in json.dumps(value), "Error content leaked")
        self.check_stats(values[-1])
        self.assertTrue(values[-1]["parakeet_accepted"])

    def test_crlf_escaped_newline_and_eof_without_newline(self):
        value = self.run_lines([request("one\ntwo\tthree") + b"\r"], final_newline=False)[0]
        self.check_stats(value)
        self.assertEqual(value["pk_word_count"], 3)
        self.assertEqual(value["pk_char_count"], 13)
        self.assertTrue(value["parakeet_accepted"])

    def test_large_line_crosses_read_buffer_without_extra_responses(self):
        value = self.stats("hello world" + " " * (70 * 1024), 1)
        self.assertEqual(value["pk_word_count"], 2)
        self.assertEqual(value["pk_char_count"], 11)
        self.assertTrue(value["parakeet_accepted"])

    def test_popen_request_response_before_eof_and_split_utf8(self):
        process = subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(process.stdin.close)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)
        try:
            encoded = request("Café grows here", 1)
            split_at = encoded.index("é".encode()) + 1
            process.stdin.write(encoded[:split_at])
            process.stdin.flush()
            self.assertFalse(select.select([process.stdout], [], [], 0.15)[0], "Replied to an incomplete line")
            process.stdin.write(encoded[split_at:] + b"\n")
            process.stdin.flush()
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "No response before EOF")
            value = self.decode(process.stdout.readline())
            self.check_stats(value)
            self.assertEqual(value["pk_word_count"], 3)
            for payload in (b"bad synthetic input", request("Yes", 8), request("")):
                process.stdin.write(payload + b"\n")
                process.stdin.flush()
                self.assertTrue(select.select([process.stdout], [], [], 10)[0], "No response before EOF")
                value = self.decode(process.stdout.readline())
                if payload.startswith(b"bad"):
                    self.assertTrue(value == {"error_code": "invalid_input"}, "Unsafe error response")
                else:
                    self.check_stats(value)
            process.stdin.close()
            self.assertEqual(process.wait(timeout=10), 0)
            self.assertTrue(process.stdout.read() == b"", "Extra response after EOF")
            self.assertTrue(process.stderr.read() == b"", "CLI wrote diagnostics")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--binary", type=Path)
    options.add_argument("--build-dir", type=Path)
    arguments, remaining = parser.parse_known_args()
    BINARY, BUILD_DIR = arguments.binary, arguments.build_dir
    unittest.main(argv=[sys.argv[0], *remaining])
