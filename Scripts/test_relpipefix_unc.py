"""Review5 UNC regressions. Synthetic bytes remain in memory; nothing executes."""
from collections import Counter
import hashlib
import unittest

from Scripts import macho_paths as macho, privacy_text as text_scan, reviewed_resources as reviewed
from Scripts.privacy_package import PrivacyError
from Scripts.test_relpipe6_binary import thin, ENCODINGS
from Scripts.test_relpipe6_text import MemoryFile, inspect_archive, MEMBER


UNC = r"\\review-host\private-share\source.c"


class UNCPrivacyTests(unittest.TestCase):
    def reject_source(self, name, data):
        with self.assertRaises(PrivacyError):
            text_scan.inspect_text(data, name)
        with self.assertRaises(PrivacyError):
            inspect_archive(data, name="fixture-1.0/" + name)

    def test_plain_python_c_and_shell_unc_sources_and_archives_rejected(self):
        sources = [("probe.py", ('BUILD = r"' + UNC + '"\n').encode()),
                   ("probe.py", ("BUILD = " + repr(UNC) + "\n").encode()),
                   ("probe.c", ('const char *p="' + UNC.replace("\\", "\\\\") + '";\n').encode()),
                   ("probe.sh", ("BUILD='" + UNC + "'\n").encode())]
        for name, data in sources:
            with self.subTest(name=name, data=data):
                self.reject_source(name, data)

    def test_decoded_octal_and_literal_sums_use_unc_policy(self):
        octal = "".join("\\%03o" % ord(char) for char in UNC)
        for name, data in (("probe.c", ('const char *p="' + octal + '";\n').encode()),
                           ("probe.sh", ("BUILD=$'" + octal + "'\n").encode()),
                           ("probe.py", ("BUILD=" + repr(UNC[:8]) + "+" + repr(UNC[8:]) + "\n").encode())):
            with self.subTest(name=name):
                self.reject_source(name, data)

    def test_private_unc_after_large_escaped_source_literal_is_not_skipped(self):
        prefix = r"\x41" * 25000
        body = prefix + UNC.replace("\\", "\\\\")
        for name, declaration in (("probe.go", 'package probe\nvar build="'),
                                  ("probe.c", 'const char *build="')):
            with self.subTest(name=name):
                self.reject_source(name, (declaration + body + '";\n').encode())

    def test_private_unc_across_many_adjacent_literals_is_not_skipped(self):
        pieces = ['"A"'] * 10000 + ['"' + char.replace("\\", "\\\\") + '"' for char in UNC]
        for name, declaration, separator in (("probe.c", 'const char *build=', ' '),
                                             ("probe.go", 'package probe\nvar build=', '+'),
                                             ("probe.js", 'const build=', '+')):
            with self.subTest(name=name):
                self.reject_source(name, (declaration + separator.join(pieces) + ';\n').encode())

    def test_unc_syntax_and_public_https_controls(self):
        for data in (b'PREFIX="\\\\\\\\"\n', b'VALUE="https://public.example.invalid/source.c"\n',
                     b'PATTERN=r"\\\\[A-Za-z]+"\n'):
            text_scan.inspect_text(data, "probe.py")
            self.assertEqual(inspect_archive(data)["source_archive_members"], 1)

    def test_control_escape_documentation_is_decoded_before_unc_decision(self):
        data = b'def probe():\n    """Use "\\\\r\\\\n" as a line ending."""\n    return None\n'
        text_scan.inspect_text(data, "probe.py")
        self.assertEqual(inspect_archive(data)["source_archive_members"], 1)
        # Raw literals preserve the actual doubled separators and still reject.
        self.reject_source("probe.py", b'BUILD=r"\\\\r\\\\n"\n')

    def test_public_unc_example_requires_exact_resource_hash_and_spelling(self):
        public = r"\\upstream-host\public-share\example.c"
        data = ('BUILD=r"' + public + '"\n').encode()
        relative = "Contents/Resources/LanguageRuntime/python/lib/probe.py"
        item = {"path": relative, "sha256": hashlib.sha256(data).hexdigest(),
                "format": "python-public-examples", "package": "fixture", "version": "1",
                "reason": "Exact public upstream UNC example", "publicHostPathExamples": [
                    {"style": "unc-hex", "path": public.encode().hex()}]}
        for form in ("python-public-examples", "text-public-examples", "source-build-text"):
            approved = {**item, "format": form}
            self.assertTrue(reviewed.inspect(MemoryFile("probe.py", data), relative, {relative: approved}, Counter()))
            for value in (public + "-private", public + "\\other.c", public + " private",
                          public + ",private", public + ";private", public + "'private", public + "`private",
                          public.replace("public-share", "private-share")):
                with self.subTest(form=form, value=value):
                    changed = ('BUILD=r"' + value + '"\n').encode()
                    with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
                        reviewed.inspect(MemoryFile("probe.py", changed), relative, {relative: approved}, Counter())
                    with self.assertRaises(PrivacyError):
                        reviewed.inspect(MemoryFile("probe.py", changed), relative,
                                         {relative: {**approved, "sha256": hashlib.sha256(changed).hexdigest()}}, Counter())

    def test_public_unc_archive_example_requires_exact_member_hash(self):
        public = r"\\upstream-host\public-share\example.c"
        data = ('BUILD=r"' + public + '"\n').encode()
        examples = {MEMBER: {"sha256": hashlib.sha256(data).hexdigest(),
                            "examples": [{"style": "unc-hex", "path": public.encode().hex()}],
                            "reason": "Exact public upstream member example"}}
        self.assertEqual(inspect_archive(data, examples=examples)["source_archive_members"], 1)
        with self.assertRaises(PrivacyError):
            inspect_archive(data + b"# altered\n", examples=examples)
        for suffix in ("-private", "\\other.c", " private", ",private", ";private", "'private", "`private"):
            changed = ('BUILD=r"' + public + suffix + '"\n').encode()
            current = {MEMBER: {**examples[MEMBER], "sha256": hashlib.sha256(changed).hexdigest()}}
            with self.subTest(suffix=suffix), self.assertRaises(PrivacyError):
                inspect_archive(changed, examples=current)

    def test_binary_unc_symbol_and_format_prefixes_all_encodings(self):
        for prefix in ("__symbol_", "%s", "debug-prefix-", "-I"):
            for encoding in ENCODINGS:
                with self.subTest(prefix=prefix, encoding=encoding):
                    blob = thin() + b"\0\0" + (prefix + UNC).encode(encoding) + b"\0\0"
                    matches = macho.scan_binary_paths_bytes(blob)["matches"]
                    self.assertTrue(any(item["path"] == UNC and item["encoding"] == encoding for item in matches))
                    expected = len(thin()) + 2 + len(prefix.encode(encoding))
                    self.assertTrue(any(item["offset"] == expected and item["path"] == UNC for item in matches))

    def test_unbounded_instruction_like_unc_with_symbol_prefix_is_not_a_string(self):
        # Stop both byte orders and alignments without inserting a NUL edge.
        fence = b"\x01\x01\x00\x01\x01\x00\x01\x01"
        for encoding in ENCODINGS:
            blob = fence + ("__symbol_" + UNC).encode(encoding) + fence
            self.assertEqual(macho.scan_binary_paths_bytes(blob)["matches"], [])

    def test_repeated_escape_table_requires_exact_public_approval(self):
        data = b"\0lf\\`" + b"\\" * 28 + b"rnh\\\\b\\pdjt" + b"\\" * 30 + b"v\\^\0"
        matches = macho.scan_binary_paths_bytes(data)["matches"]
        self.assertEqual(len(matches), 1)
        self.assertTrue(matches[0]["path"].startswith("\\\\rnh\\\\b\\pdjt"))
        # An accidental byte-table token gets no new prefix exemption. Its
        # complete spelling and complete resource hash must be reviewed.
        self.assertEqual(macho._exact_build_path_approvals([matches[0]["path"].encode()]),
                         frozenset({matches[0]["path"]}))

    def test_source_syntax_approval_does_not_hide_an_added_unc_literal(self):
        statement = r"# Sed substitution: s/\([\"`\\]\)/\\\1/g"
        data = (statement + "\n").encode()
        relative = "Contents/Resources/LanguageRuntime/python/lib/probe.py"
        item = {"path": relative, "sha256": hashlib.sha256(data).hexdigest(),
                "format": "python-public-examples", "package": "fixture", "version": "1",
                "reason": "Exact public upstream sed statement", "publicHostPathExamples": [
                    {"style": "source-syntax-hex", "path": statement.encode().hex()}]}
        self.assertTrue(reviewed.inspect(MemoryFile("probe.py", data), relative, {relative: item}, Counter()))
        changed = data + ('BUILD=r"' + UNC + '"\n').encode()
        with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
            reviewed.inspect(MemoryFile("probe.py", changed), relative, {relative: item}, Counter())
        with self.assertRaises(PrivacyError):
            reviewed.inspect(MemoryFile("probe.py", changed), relative,
                             {relative: {**item, "sha256": hashlib.sha256(changed).hexdigest()}}, Counter())
        for changed in ((statement + " private\n").encode(), ("prefix" + statement + "\n").encode()):
            with self.subTest(changed=changed), self.assertRaises(PrivacyError):
                reviewed.inspect(MemoryFile("probe.py", changed), relative,
                                 {relative: {**item, "sha256": hashlib.sha256(changed).hexdigest()}}, Counter())

    def test_utf16_unicode_prefix_and_suffix_use_real_string_edges(self):
        for prefix in ("é", "__symbol_é", "%sé", "😀"):
            for encoding in ("utf-16-le", "utf-16-be"):
                with self.subTest(prefix=prefix, encoding=encoding):
                    path = UNC.replace("source.c", "source-é-😀.c")
                    blob = thin() + b"\0\0" + (prefix + path).encode(encoding) + b"\0\0"
                    expected = len(thin()) + 2 + len(prefix.encode(encoding))
                    self.assertTrue(any(item["path"] == path and item["offset"] == expected
                                        and item["encoding"] == encoding
                                        for item in macho.scan_binary_paths_bytes(blob)["matches"]))
                    fence = b"\x01\x01\x00\x01\x01\x00\x01\x01"
                    # DE00 in the positive emoji exposes a genuine 0000 edge
                    # in the opposite byte alignment. Use DE01 here so the
                    # negative control contains no such alternative string.
                    control = fence + (prefix + path).replace("😀", "😁").encode(encoding) + fence
                    self.assertEqual(macho.scan_binary_paths_bytes(control)["matches"], [])

    def test_existing_hash_bound_re2_tokens_remain_distinct_from_unc_paths(self):
        name = "fixture-1.0/table.txt"
        for anchor in ("B", "b"):
            for middle in ("", "foo", "x"):
                public = "\\\\" + anchor + middle + "\\\\" + anchor
                data = (public + "\t0\tinput\n").encode()
                examples = {name: {"sha256": hashlib.sha256(data).hexdigest(),
                                   "examples": [{"style": "binary-readable-hex", "path": public.encode().hex()}],
                                   "reason": "Exact public word-boundary regression token"}}
                self.assertEqual(inspect_archive(data, examples=examples, name=name)["source_archive_members"], 1)
                changed = (public + "-private\t0\tinput\n").encode()
                current = {name: {**examples[name], "sha256": hashlib.sha256(changed).hexdigest()}}
                with self.assertRaises(PrivacyError):
                    inspect_archive(changed, examples=current, name=name)
                literal = ('BUILD=r"' + public + ' private"\n').encode()
                private_example = {MEMBER: {"sha256": hashlib.sha256(literal).hexdigest(),
                                           "examples": [{"style": "unc-hex", "path": public.encode().hex()}],
                                           "reason": "Complete path, not a regex token"}}
                with self.assertRaises(PrivacyError):
                    inspect_archive(literal, examples=private_example)

    def test_re2_byte_class_example_requires_the_complete_hash_bound_line(self):
        name = "fixture-1.0/re2-search.txt"
        line = '"^' + r'\\C\\C\\C' + '$"'
        data = (line + "\n").encode()
        example = {"style": "source-syntax-hex", "path": line.encode().hex()}
        def approval(blob):
            return {name: {"sha256": hashlib.sha256(blob).hexdigest(),
                           "examples": [example], "reason": "Exact upstream RE2 byte-class line"}}
        self.assertEqual(inspect_archive(data, name=name, examples=approval(data))["source_archive_members"], 1)
        for changed in ((line + " private\n").encode(), data + (UNC + "\n").encode()):
            with self.subTest(changed=changed), self.assertRaises(PrivacyError):
                inspect_archive(changed, name=name, examples=approval(changed))


if __name__ == "__main__":
    unittest.main(verbosity=2)
