"""Public upstream gold and synthetic converter parity; no class data or models."""
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

from Scripts.zh_variants import Converter, RESOURCE_ROOT

FIXTURES = Path(__file__).parent / "Fixtures/zh-variants-v1"


class ChineseVariantsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.converter = Converter()

    def test_upstream_answers_are_byte_identical(self):
        for mode in ("s2tw", "s2hk", "s2twp"):
            with self.subTest(mode=mode):
                raw = (FIXTURES / "upstream" / (mode + ".in")).read_text()
                self.assertEqual(self.converter.convert(raw, mode).encode(),
                                 (FIXTURES / "upstream" / (mode + ".ans")).read_bytes())

    def test_source_hashes(self):
        source = json.loads((RESOURCE_ROOT / "SOURCE.json").read_text())
        for file in source["files"]:
            self.assertEqual(hashlib.sha256((RESOURCE_ROOT / file["path"]).read_bytes()).hexdigest(), file["sha256"])
        for file in source["testFiles"]:
            self.assertEqual(hashlib.sha256((RESOURCE_ROOT.parents[2] / file["path"]).read_bytes()).hexdigest(), file["sha256"])

    def test_non_han_byte_preservation(self):
        raw = "DNA pH 7.4 CaCO₃ H₂O \\(x^2\\) $a+b$ e\u0301 かな カナ 한글 😀\n\t"
        for mode in ("s2tw", "s2hk", "s2twp"):
            self.assertEqual(self.converter.convert(raw, mode).encode(), raw.encode())

    def test_missing_data_fails(self):
        with self.assertRaises(FileNotFoundError):
            Converter(FIXTURES / "missing")

    def test_project_tables_pending_review_are_empty(self):
        for name in ("TW-reviewed-phrases", "LiveLingo-TW-overlay", "LiveLingo-HK-overlay"):
            lines = (RESOURCE_ROOT / (name + ".txt")).read_text().splitlines()
            self.assertFalse([line for line in lines if line.strip() and not line.startswith("#")])

    def test_swift_python_parity(self):
        executable = os.environ.get("LIVELINGO_ZH_VARIANTS_CLI")
        if not executable:
            self.skipTest("Build the Foundation-only Chinese variant probe first")
        with (FIXTURES / "cases.tsv").open() as handle:
            cases = list(csv.DictReader(handle, delimiter="\t"))
        for mode in ("s2tw", "s2hk", "s2twp"):
            raw = "\n".join(row["source"] for row in cases) + "\n"
            reply = subprocess.run([executable, mode], input=raw.encode(), capture_output=True, timeout=30)
            self.assertEqual(reply.returncode, 0, reply.stderr.decode())
            self.assertEqual(reply.stdout, self.converter.convert(raw, mode).encode())


if __name__ == "__main__":
    unittest.main()
