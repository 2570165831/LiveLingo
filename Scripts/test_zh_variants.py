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


class ChineseVariantsRenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.converter = Converter()

    def render(self, text, mode="s2tw"):
        # The baseline has only convert(); exercise its actual output for the
        # red phase rather than failing solely because the render API is absent.
        renderer = getattr(self.converter, "render", self.converter.convert)
        return renderer(text, mode, project_tables=True)

    def assert_rendered(self, source, taiwan, hong_kong=None):
        for mode, expected in (("s2tw", taiwan), ("s2hk", hong_kong or taiwan)):
            with self.subTest(mode=mode):
                self.assertEqual(self.render(source, mode).encode(), expected.encode())

    def test_raw_opencc_conversion_remains_independent(self):
        source = r'`record["头发"]` \label{eq:头发}'
        for mode in ("s2tw", "s2hk", "s2twp"):
            self.assertEqual(self.converter.convert(source, mode), r'`record["頭髮"]` \label{eq:頭髮}')

    def test_inline_code_with_different_backtick_lengths(self):
        code = '`record["头发"]`，``record["头发"] + `头发` ``，```record["头发"] + ``头发`` ```'
        self.assert_rendered("头发在这里。" + code + "头发在这里。",
                             "頭髮在這裡。" + code + "頭髮在這裡。",
                             "頭髮在這裏。" + code + "頭髮在這裏。")

    def test_fenced_backtick_and_tilde_code_preserve_crlf_and_utf8(self):
        code = '````python\r\nrecord = {"头发": 3}\r\nrecord["头发"] # e\u0301 😀\r\n```\r\n这里仍然是代码\r\n```` \t\r\n~~~json\r\n{"头发": "这里"}\r\n~~~\r\n'
        self.assert_rendered("头发在这里。\r\n" + code + "头发在这里。\r\n",
                             "頭髮在這裡。\r\n" + code + "頭髮在這裡。\r\n",
                             "頭髮在這裏。\r\n" + code + "頭髮在這裏。\r\n")

    def test_unclosed_and_mismatched_fences(self):
        code = '~~~python\nrecord["头发"]\n```\n这里仍然是代码\n~~\n后面仍然是代码\n'
        self.assert_rendered("头发在这里。\n" + code,
                             "頭髮在這裡。\n" + code, "頭髮在這裏。\n" + code)

    def test_indented_code_and_ordinary_prose(self):
        source = '头发在这里。\n\n    record["头发"]\n\tprint(record["头发"])\n\n- 头发在这里。\n  头发在这里。\n    - 头发在这里。\n'
        taiwan = '頭髮在這裡。\n\n    record["头发"]\n\tprint(record["头发"])\n\n- 頭髮在這裡。\n  頭髮在這裡。\n    - 頭髮在這裡。\n'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_json_keys_and_natural_language_values(self):
        source = r'{"头发":"头发在这里。","对象":{"后面":"头发"},"数组":[{"这里":"后面"}],"头\"发":"这里","头\u53d1":"这里"}'
        taiwan = r'{"头发":"頭髮在這裡。","对象":{"后面":"頭髮"},"数组":[{"这里":"後面"}],"头\"发":"這裡","头\u53d1":"這裡"}'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))
        for mode in ("s2tw", "s2hk"):
            rendered = json.loads(self.render(source, mode))
            self.assertIn("头发", rendered)
            self.assertNotIn("頭髮", rendered)

    def test_math_and_latex_chinese_identifiers(self):
        technical = r'\(x_{\mathrm{头发}}=1\) \[\text{这里}\label{eq:头发}\] $x_{头发}$ $$\label{eq:头发}$$ \label{eq:头发} \ref{eq:头发} \eqref{eq:头发} \cite[这里]{头发} \newcommand{\头发}[1]{#1}'
        self.assert_rendered("头发在这里。" + technical + "头发在这里。",
                             "頭髮在這裡。" + technical + "頭髮在這裡。",
                             "頭髮在這裏。" + technical + "頭髮在這裏。")

    def test_multiline_inline_code_and_display_math(self):
        source = '头发在这里。``record[\r\n"头发"]``\r\n$$\r\nx_{头发}=1\r\n\\label{eq:头发}\r\n$$\r\n头发在这里。'
        taiwan = '頭髮在這裡。``record[\r\n"头发"]``\r\n$$\r\nx_{头发}=1\r\n\\label{eq:头发}\r\n$$\r\n頭髮在這裡。'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_ordinary_quotes_currency_and_unmatched_backticks(self):
        source = r'"头发"在这里。头发价格 $5，后面是 $6。\$头发在这里。\$ `头发在这里。'
        taiwan = r'"頭髮"在這裡。頭髮價格 $5，後面是 $6。\$頭髮在這裡。\$ `頭髮在這裡。'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_dollar_math_beginning_with_digits_or_whitespace(self):
        self.assert_rendered("$3+x_{头发}$", "$3+x_{头发}$")
        self.assert_rendered("$ x_{头发} $", "$ x_{头发} $")
        self.assert_rendered("头发价格 $5，后面是 $6；公式 $3+x_{头发}$ 和 $ x_{头发} $，后面是头发。",
                             "頭髮價格 $5，後面是 $6；公式 $3+x_{头发}$ 和 $ x_{头发} $，後面是頭髮。")

    def test_ordered_list_fence_preserves_keys_and_following_prose(self):
        code = '1. ```python\n   record["头发"]\n   ```\n\n'
        self.assert_rendered(code + "头发在这里。", code + "頭髮在這裡。", code + "頭髮在這裏。")
        for mode in ("s2tw", "s2hk"):
            expression = self.render(code, mode).splitlines()[1].strip()
            self.assertEqual(eval(expression, {"__builtins__": {}}, {"record": {"头发": 3}}), 3)

    def test_list_paragraph_indentation_is_relative_to_container(self):
        source = '- 课程内容：\n\n    头发在这里。\n\n- 后面是结论。'
        taiwan = '- 課程內容：\n\n    頭髮在這裡。\n\n- 後面是結論。'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_inline_backticks_cannot_pair_across_blank_paragraphs(self):
        source = '这里有一个未闭合标记 `record[\n\n头发在这里。\n\n` 后面是正文。'
        taiwan = '這裡有一個未閉合標記 `record[\n\n頭髮在這裡。\n\n` 後面是正文。'
        self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_blockquote_fence_ends_with_container(self):
        self.assert_rendered('这里。\n> ```python\n> record["头发"]\n\n头发在这里。',
                             '這裡。\n> ```python\n> record["头发"]\n\n頭髮在這裡。',
                             '這裏。\n> ```python\n> record["头发"]\n\n頭髮在這裏。')

    def test_nested_container_fences_and_relative_indented_code(self):
        for code in ('12) ~~~python\n    record["头发"]\n    ~~~\n\n',
                     '> 1. ```python\n>    record["头发"]\n>    ```\n\n',
                     '- 内容：\n\n      record["头发"]\n\n'):
            expected_code = code.replace("内容", "內容")
            self.assert_rendered(code + "头发在这里。", expected_code + "頭髮在這裡。",
                                 expected_code + "頭髮在這裏。")

    def test_inline_code_block_boundaries_and_soft_line_breaks(self):
        self.assert_rendered('> 这里 `record[\r\n> "头发"]` 后面。',
                             '> 這裡 `record[\r\n> "头发"]` 後面。',
                             '> 這裏 `record[\r\n> "头发"]` 後面。')
        for source in ('这里 `头发\n# 头发` 后面。', '这里 `头发\n- 头发` 后面。',
                       '> 这里 `头发\n- 头发` 后面。'):
            taiwan = source.replace("这里", "這裡").replace("头发", "頭髮").replace("后面", "後面")
            self.assert_rendered(source, taiwan, taiwan.replace("這裡", "這裏"))

    def test_swift_python_markdown_container_parity(self):
        executable = os.environ.get("LIVELINGO_ZH_VARIANTS_RENDER_CLI")
        if not executable:
            self.skipTest("Build the Foundation-only protected-rendering probe first")
        cases = ('1. ```python\n   record["头发"]\n   ```\n\n头发在这里。',
                 '- 课程内容：\n\n    头发在这里。\n\n- 后面是结论。',
                 '这里有一个未闭合标记 `record[\n\n头发在这里。\n\n` 后面是正文。',
                 '这里。\n> ```python\n> record["头发"]\n\n头发在这里。')
        for source in cases:
            for mode in ("s2tw", "s2hk"):
                with self.subTest(source=source, mode=mode):
                    reply = subprocess.run([executable, mode], input=source.encode(), capture_output=True, timeout=30)
                    self.assertEqual(reply.returncode, 0, reply.stderr.decode())
                    self.assertEqual(reply.stdout, self.render(source, mode).encode())

    def test_swift_python_rendering_parity(self):
        executable = os.environ.get("LIVELINGO_ZH_VARIANTS_RENDER_CLI")
        if not executable:
            self.skipTest("Build the Foundation-only protected-rendering probe first")
        source = '头发在这里。\r\n```python\r\nrecord["头发"]\r\n```\r\n' + r'{"头发":"这里"} `record["头发"]` \label{eq:头发}'
        for mode in ("s2tw", "s2hk"):
            reply = subprocess.run([executable, mode], input=source.encode(), capture_output=True, timeout=30)
            self.assertEqual(reply.returncode, 0, reply.stderr.decode())
            self.assertEqual(reply.stdout, self.render(source, mode).encode())


if __name__ == "__main__":
    unittest.main()
