"""F3/F8 regressions through hash-bound app resource approvals.

Synthetic inputs live under the task's work directory; teardown moves them to
the authorized superseded directory instead of deleting them.
"""
import gzip
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_literals as literals
from Scripts import privacy_package as privacy
from Scripts import prepare_source_archive as prepare
from Scripts import reviewed_resources as reviewed


TASK = Path(os.environ.get("LIVELINGO_RELPIPE_TEST_OUTPUT",
                          Path(__file__).resolve().parent.parent / "work/relpipe"))
HOST = "/" + "Users/synthetic/build"
RESOURCE = "Contents/Resources/LanguageRuntime/Licenses/fixture/source.tar.gz"


class SourceReview2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        output = TASK / "source-review2"
        output.mkdir(parents=True, exist_ok=True)
        cls.scratch = Path(tempfile.mkdtemp(prefix="fixtures-", dir=output))

    @classmethod
    def tearDownClass(cls):
        superseded = TASK / "superseded"
        superseded.mkdir(exist_ok=True)
        destination = superseded / ("source-review2-" + cls.scratch.name)
        if destination.exists():
            raise AssertionError("fixture recovery destination already exists")
        shutil.move(str(cls.scratch), str(destination))

    def setUp(self):
        self.root = self.scratch / self._testMethodName
        self.root.mkdir()
        self.app = self.root / "Fixture.app"
        self.app.mkdir()
        self.manifest = self.root / "manifest.json"
        self.resources = []
        self.write_manifest()
        self.approval_patch = patch.object(reviewed, "MANIFEST", self.manifest)
        self.approval_patch.start()

    def tearDown(self):
        self.approval_patch.stop()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({"version": 1, "resources": self.resources}))

    def approve(self, data, *, examples=None, fixtures=None, package="fixture", version="1.0"):
        path = self.app / RESOURCE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.resources = [{"path": RESOURCE, "sha256": hashlib.sha256(data).hexdigest(),
                           "format": "source-tar", "package": package, "version": version,
                           "reason": "Synthetic reviewed source regression."}]
        if examples is not None:
            self.resources[0]["publicSourceHostPathExamples"] = examples
        if fixtures is not None:
            self.resources[0]["opaqueSourceFixtures"] = fixtures
        self.write_manifest()
        return path

    def check(self):
        return privacy.inspect_tree(self.app)

    def test_vendor_digest_is_typed_and_decoded_bytes_are_still_path_scanned(self):
        payload = json.dumps({"package": [{"checksumSHA1": base64.b64encode(b'\xff' * 20).decode()}]}).encode()
        self.approve(self.archive("vendor.vjson", payload))
        self.check()
        private_digest_bytes = ("/" + "Users/private/fileX").encode()
        self.assertEqual(len(private_digest_bytes), 20)
        for value in (base64.b64encode(private_digest_bytes).decode(), "not-a-digest"):
            payload = json.dumps({"package": [{"checksumSHA1": value}]}).encode()
            self.approve(self.archive("vendor.vjson", payload))
            with self.assertRaises(privacy.PrivacyError):
                self.check()

    def test_go_escaped_literals_raw_strings_and_literal_sums_are_checked(self):
        for code in (r'package p; var location = "\u002fUsers/private"',
                     r'package p; var location = "\057Users/private"',
                     'package p; var location = "/" + "Users/private"',
                     'package p; var location = `/' + 'Users/private`'):
            with self.subTest(code=code[:10]):
                self.approve(self.archive("main.go", code.encode()))
                with self.assertRaises(privacy.PrivacyError):
                    self.check()

    def test_json_event_sequences_scan_every_event_and_reject_duplicates(self):
        for data in (b'{"Action":"run"}\n{"Action":"pass"}\n',):
            self.approve(self.archive("events.json", data))
            self.check()
        for data in (b'{"Action":"run"}\n{"path":"' + HOST.encode() + b'"}\n',
                     b'{"Action":"run"}\n{"Action":"pass","Action":"output"}\n',
                     b'{"Action":"run"}\nnot-json', b'{"Action":"run"}{"Action":"pass"}'):
            self.approve(self.archive("events.json", data))
            with self.assertRaises(privacy.PrivacyError):
                self.check()

    def test_c_attributes_are_source_syntax_and_literals_remain_scanned(self):
        self.approve(self.archive("input.c", b'[[gnu::nonnull]]\nint f(void) { return 0; }'))
        self.check()
        self.approve(self.archive("input.c", b'[[gnu::nonnull]]\nchar *p="' + HOST.encode() + b'";'))
        with self.assertRaises(privacy.PrivacyError):
            self.check()

    def test_rooted_package_fixture_requires_exact_member_hash(self):
        data = b'{"path":"/xdr2"}'
        examples = {"fixture-1.0/vendor.vmanifest": {
            "sha256": hashlib.sha256(data).hexdigest(),
            "examples": [{"style": "rooted-package", "path": "xdr2"}]}}
        self.approve(self.archive("vendor.vmanifest", data), examples=examples)
        self.check()
        self.approve(self.archive("vendor.vmanifest", b'{"path":"/xdr2","other":"' + HOST.encode() + b'"}'), examples=examples)
        with self.assertRaises(privacy.PrivacyError):
            self.check()
        with self.assertRaises(privacy.PrivacyError):
            reviewed.public_example_spellings([{"style": "rooted-package", "path": "Users/private"}], source_only=True)
        with self.assertRaises(privacy.PrivacyError):
            reviewed.public_example_spellings([{"style": "rooted-package", "path": "xdr2"}])

    def test_public_root_token_does_not_mask_other_decoded_paths(self):
        data = b'char *root = "/";'
        examples = {"fixture-1.0/input.c": {
            "sha256": hashlib.sha256(data).hexdigest(),
            "examples": [{"style": "source-literal-hex", "path": b'/'.hex()}]}}
        self.approve(self.archive("input.c", data), examples=examples)
        self.check()
        data += b'char *private = "\\u002fUsers\\u002fprivate";'
        examples["fixture-1.0/input.c"]["sha256"] = hashlib.sha256(data).hexdigest()
        self.approve(self.archive("input.c", data), examples=examples)
        with self.assertRaises(privacy.PrivacyError):
            self.check()
        with self.assertRaises(privacy.PrivacyError):
            reviewed.public_example_spellings([{"style": "source-literal-hex", "path": HOST.encode().hex()}], source_only=True)

    def test_xml_build_variables_keep_literal_private_values_checked(self):
        self.approve(self.archive("build.xml", b'<build path="${prefix}/include/g++-v3"/>'))
        self.check()
        self.approve(self.archive("build.xml", b'<build path="${prefix}/include/g++-v3" other="' + HOST.encode() + b'"/>'))
        with self.assertRaises(privacy.PrivacyError):
            self.check()

    def test_bom_xml_build_file_keeps_structural_and_path_checks(self):
        prefix = b'\xef\xbb\xbf<?xml version="1.0" encoding="utf-8"?>'
        self.approve(self.archive("input.build", prefix + b'<build path="${build.root}/debug/"/>'))
        self.check()
        for body in (b'<build transcript="synthetic"/>', b'<build other="' + HOST.encode() + b'"/>'):
            self.approve(self.archive("input.build", prefix + body))
            with self.assertRaises(privacy.PrivacyError):
                self.check()

    @staticmethod
    def archive(name, data, package="fixture", version="1.0"):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
            member = tarfile.TarInfo(package + "-" + version + "/" + name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        return stream.getvalue()

    @staticmethod
    def change_header(data, start, length, value):
        raw = bytearray(gzip.decompress(data))
        if len(value) > length:
            raise AssertionError("synthetic header field overflow")
        raw[start:start + length] = value.ljust(length, b"\0")
        raw[148:156] = b" " * 8
        checksum = sum(raw[:512])
        raw[148:156] = ("%06o" % checksum).encode() + b"\0 "
        return gzip.compress(raw, mtime=0)

    def test_hash_bound_nul_hidden_string_fields_are_rejected(self):
        original = self.archive("main.c", b"int public_value = 1;\n")
        for start, length in ((0, 100), (157, 100), (265, 32), (297, 32), (345, 155)):
            with self.subTest(field=start):
                visible = b"fixture-1.0/main.c" if start == 0 else b""
                changed = self.change_header(original, start, length, visible + b"\0" + HOST.encode())
                # The original parser ignores the exact bytes the new hook checks.
                with tarfile.open(fileobj=io.BytesIO(changed)) as archive:
                    member = archive.next()
                    self.assertEqual(member.name, "fixture-1.0/main.c")
                    self.assertEqual(member.uname, "")
                    self.assertEqual(member.gname, "")
                self.approve(changed)  # Bind the altered archive's correct SHA-256.
                with self.assertRaisesRegex(privacy.PrivacyError, "nonpublic-source-archive-header"):
                    self.check()

    def test_nul_hidden_numeric_field_and_reserved_padding_are_rejected(self):
        original = self.archive("main.c", b"int value;\n")
        for start, length, value in ((108, 8, b"0\0X"), (500, 12, b"hidden")):
            self.approve(self.change_header(original, start, length, value))
            with self.assertRaisesRegex(privacy.PrivacyError, "nonpublic-source-archive-header"):
                self.check()

    def test_raw_pax_extension_header_is_checked_before_it_is_discarded(self):
        original = self.archive("a" * 110 + ".c", b"int value;\n")
        self.assertEqual(gzip.decompress(original)[156:157], tarfile.XHDTYPE)
        changed = self.change_header(original, 265, 32, b"\0" + HOST.encode())
        self.approve(changed)
        with self.assertRaisesRegex(privacy.PrivacyError, "nonpublic-source-archive-header"):
            self.check()

    def test_base256_numeric_field_is_not_exempt_from_raw_path_inspection(self):
        original = self.archive("main.c", b"int value;\n")
        hidden = b"\x80/" + b"Users/"
        for start in (100, 329, 337):
            self.approve(self.change_header(original, start, 8, hidden))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_hash_gate_still_precedes_raw_header_and_literal_checks(self):
        original = self.archive("main.c", b"int value;\n")
        path = self.approve(original)
        path.write_bytes(self.change_header(original, 265, 32, b"\0" + HOST.encode()))
        with self.assertRaisesRegex(privacy.PrivacyError, "reviewed-resource-hash-mismatch"):
            self.check()

    def test_canonical_header_and_long_pax_names_still_pass(self):
        for name in ("main.c", "a" * 110 + ".c"):
            self.approve(self.archive(name, b"int value;\n"))
            self.assertEqual(self.check()["source_archive_members"], 1)

    def test_hash_bound_python_unicode_octal_bytes_and_fstrings_are_rejected(self):
        unicode_path = "".join("\\u%04x" % ord(c) for c in HOST)
        octal_path = "".join("\\%03o" % ord(c) for c in HOST)
        sources = [f'BUILD = "{unicode_path}"\n', f'BUILD = "{octal_path}"\n',
                   f'BUILD = b"{octal_path}"\n', f'BUILD = f"{unicode_path}{{value}}"\n',
                   f'print "legacy statement"\nBUILD = "{unicode_path}"\n']
        for text in sources:
            self.approve(self.archive("build.py", text.encode()))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_python_pure_literal_concatenation_cannot_hide_encoded_paths(self):
        for prefix in ("", "b"):
            text = 'BUILD = ' + prefix + '"\\057Use" + (' + prefix + '"rs\\057" + ' + prefix + '"synthetic\\057build")'
            for ending in ("\n", " + missing\n"):
                self.approve(self.archive("build.py", (text + ending).encode()))
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    self.check()

    def test_python_names_and_calls_in_sums_are_not_evaluated(self):
        seen = []
        text = 'VALUE = "public" + missing + dangerous_call()\n'
        literals.inspect_python_literals(text, seen.append)
        self.assertEqual(seen, ["public"])

    def test_hash_bound_c_rust_shell_and_html_decoded_paths_are_rejected(self):
        unicode_path = "".join("\\u%04x" % ord(c) for c in HOST)
        octal_path = "".join("\\%03o" % ord(c) for c in HOST)
        rust_path = "".join("\\u{%x}" % ord(c) for c in HOST)
        entity_path = "".join("&#%d;" % ord(c) for c in HOST)
        examples = [("build.c", f'const char *BUILD = "{unicode_path}";\n'),
                    ("build.c", f'const char *BUILD = "{octal_path}";\n'),
                    ("build.c", 'const char *BUILD = "\\057Use" /* join */ "rs\\057synthetic\\057build";\n'),
                    ("build.rs", f'const BUILD: &str = "{rust_path}";\n'),
                    ("build.sh", f"BUILD=$'{octal_path}'\n"),
                    ("doc/build.html", f'<p>{entity_path}</p>\n'),
                    ("doc/build.html", f'<a href="{entity_path}">build</a>\n')]
        for name, text in examples:
            with self.subTest(name=name, text=text):
                self.approve(self.archive(name, text.encode()))
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    self.check()

    def test_raw_and_double_escaped_literals_are_not_recursively_decoded(self):
        encoded = "".join("\\u%04x" % ord(c) for c in HOST)
        examples = [("build.py", f'BUILD = r"{encoded}"\n'),
                    ("build.py", 'BUILD = "' + encoded.replace("\\", "\\\\") + '"\n'),
                    ("build.cpp", f'const char *BUILD = R"tag({encoded})tag";\n'),
                    ("build.rs", f'const BUILD: &str = r##"{encoded}"##;\n')]
        for name, text in examples:
            self.approve(self.archive(name, text.encode()))
            self.assertEqual(self.check()["reviewed_resource_files"], 1)

    def test_known_binary_source_member_retains_raw_path_checks(self):
        for name, signature in (("doc/example.png", b"\x89PNG\r\n\x1a\n\0"),
                                ("doc/example.jpg", b"\xff\xd8\xff")):
            payload = signature + HOST.encode() + b' BUILD="\\u002f"'
            self.approve(self.archive(name, payload))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()
            self.approve(self.archive(name, signature + b' public BUILD="\\u002f"'))
            self.assertEqual(self.check()["opaque_binary_files"], 1)

    def test_c_line_splicing_cannot_hide_an_adjacent_literal_path(self):
        payload = b'const char *BUILD = "\\057Use" \\\n "rs\\057synthetic\\057build";\n'
        self.approve(self.archive("build.c", payload))
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            self.check()

    def test_character_quotes_and_nested_rust_comments_preserve_public_source(self):
        self.approve(self.archive("build.rs", b'''/* outer /* nested */ comment */
fn quote<'a>() { let quote = '\\"'; let public = "safe"; }
'''))
        self.check()

    def test_javascript_regex_quotes_are_lexed_without_executing_regexes(self):
        source = b'''const quoted = /["']+\\/\\*/g;
const publicString = "safe";
'''
        self.approve(self.archive("doc/example.js", source))
        self.check()
        escaped = "".join("\\u%04x" % ord(c) for c in HOST)
        for value in ('"' + escaped + '"', '`' + escaped + '`', '/' + escaped + '/'):
            self.approve(self.archive("doc/example.js", ('const path = ' + value + ';\n').encode()))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_c_raw_adjacent_literals_and_javascript_literal_sum_are_scanned(self):
        examples = [("build.cpp", b'const char *BUILD = R"tag(/Use)tag" "rs/synthetic/build";\n'),
                    ("build.js", b'const BUILD = "\\u002fUse" + "rs/synthetic/build";\n')]
        for name, data in examples:
            self.approve(self.archive(name, data))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_python_utf16_byte_literal_is_decoded_before_scanning(self):
        self.approve(self.archive("build.py", ('BUILD = ' + repr(HOST.encode("utf-16-le")) + '\n').encode()))
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            self.check()

    def test_patch_source_literals_are_scanned_without_applying_the_patch(self):
        encoded = "".join("\\u%04x" % ord(c) for c in HOST)
        for removed, added in ((f'const char *p="{encoded}";', 'const char *p="safe";'),
                               ('const char *p="safe";', f'const char *p="{encoded}";')):
            patch_data = ('--- a/build.c\n+++ b/build.c\n@@ -1 +1 @@\n-' + removed + '\n+' + added + '\n').encode()
            self.approve(self.archive("release-build/target.patch", patch_data))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_renamed_unidentified_binary_remains_rejected(self):
        payload = b"\0\x01\x02" + HOST.encode()
        self.approve(self.archive("build.py", payload))
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata|unreviewed-source-archive-binary"):
            self.check()

    def test_python_source_is_parsed_without_running_calls(self):
        marker = self.root / "must-not-exist"
        source = 'from pathlib import Path\nPath("' + str(marker) + '").write_text("executed")\nVALUE="public"\n'
        seen = []
        literals.inspect_python_literals(source, seen.append)
        self.assertIn("public", seen)
        self.assertFalse(marker.exists())

    def test_caller_callback_receives_decoded_literals_without_file_exemption(self):
        allowed = "/home/public/example"
        seen = []
        def callback(value):
            seen.append(value)
            if value != allowed:
                reviewed.scan_host_paths(value.encode(), source_code=True)
        public = 'VALUE="' + "".join("\\u%04x" % ord(c) for c in allowed) + '"\n'
        literals.inspect_source_literals(public.encode(), "fixture.py", scan=callback)
        self.assertIn(allowed, seen)
        private = public + 'PRIVATE="' + "".join("\\u%04x" % ord(c) for c in HOST) + '"\n'
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            literals.inspect_source_literals(private, "fixture.py", scan=callback)

    @staticmethod
    def member_example(name, payload):
        return {"fixture-1.0/" + name: {"sha256": hashlib.sha256(payload).hexdigest(),
                "examples": [{"style": "posix", "path": "home/public/example"}],
                "sourceURL": "https://example.invalid/upstream/source", "reason": "Synthetic public example."}}

    def test_opaque_source_fixture_only_approves_exact_member_and_bytes(self):
        payload = b"\0\x01\x02binary regression canary"
        fixtures = {"fixture-1.0/test/canary.bin": hashlib.sha256(payload).hexdigest()}
        self.approve(self.archive("test/canary.bin", payload), fixtures=fixtures)
        counts = self.check()
        self.assertEqual(counts["opaque_source_fixtures"], 1)
        self.assertEqual(counts["opaque_binary_files"], 1)
        self.approve(self.archive("test/canary.bin", payload + b"changed"), fixtures=fixtures)
        with self.assertRaisesRegex(privacy.PrivacyError, "opaque-source-fixture-hash-mismatch"):
            self.check()
        self.approve(self.archive("test/other.bin", payload), fixtures=fixtures)
        with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-source-archive-binary"):
            self.check()

    def test_opaque_source_fixture_does_not_waive_text_or_metadata(self):
        for name, payload, code in [("build.py", ('BUILD="' + HOST + '"\n').encode(), "local-path-metadata"),
                                    ("meta.json", b'{"rawText":"classroom canary"}', "classroom-content-metadata")]:
            fixtures = {"fixture-1.0/" + name: hashlib.sha256(payload).hexdigest()}
            self.approve(self.archive(name, payload), fixtures=fixtures)
            with self.assertRaisesRegex(privacy.PrivacyError, code):
                self.check()

    def test_opaque_source_fixture_does_not_waive_invalid_catalog_or_raw_header(self):
        for payload in (b"\0" * 32, b"\0" * 8):
            fixtures = {"fixture-1.0/test/canary.mo": hashlib.sha256(payload).hexdigest()}
            self.approve(self.archive("test/canary.mo", payload), fixtures=fixtures)
            with self.assertRaisesRegex(privacy.PrivacyError, "invalid-source-catalog"):
                self.check()
        fixtures = {"fixture-1.0/test/canary.bin": hashlib.sha256(payload).hexdigest()}
        changed = self.change_header(self.archive("test/canary.bin", payload), 265, 32, b"\0" + HOST.encode())
        self.approve(changed, fixtures=fixtures)
        with self.assertRaisesRegex(privacy.PrivacyError, "nonpublic-source-archive-header"):
            self.check()

    def test_opaque_source_fixture_tampering_is_rejected_even_when_bytes_become_text(self):
        payload = b"\0\x01\x02binary regression canary"
        fixtures = {"fixture-1.0/test/canary.bin": hashlib.sha256(payload).hexdigest()}
        self.approve(self.archive("test/canary.bin", b"public text"), fixtures=fixtures)
        with self.assertRaisesRegex(privacy.PrivacyError, "opaque-source-fixture-hash-mismatch"):
            self.check()

    def test_member_public_example_is_bound_to_exact_path_and_member_hash(self):
        payload = b'VALUE="\\057home/public/example"\n'
        examples = self.member_example("build.py", payload)
        self.approve(self.archive("build.py", payload), examples=examples)
        self.check()
        changed = payload + b'OTHER="private metadata"\n'
        self.approve(self.archive("build.py", changed), examples=examples)
        with self.assertRaisesRegex(privacy.PrivacyError, "source-member-example-hash-mismatch"):
            self.check()
        self.approve(self.archive("other.py", payload), examples=examples)
        with self.assertRaises(privacy.PrivacyError):
            self.check()

    def test_member_public_example_never_waives_other_paths_or_raw_tar_header(self):
        payload = ('VALUE="/home/public/example"\nOTHER="' + HOST + '"\n').encode()
        self.approve(self.archive("build.py", payload), examples=self.member_example("build.py", payload))
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            self.check()
        safe = b'VALUE="/home/public/example"\n'
        changed = self.change_header(self.archive("build.py", safe), 265, 32, b"\0" + HOST.encode())
        self.approve(changed, examples=self.member_example("build.py", safe))
        with self.assertRaisesRegex(privacy.PrivacyError, "nonpublic-source-archive-header"):
            self.check()

    def test_member_public_example_keeps_xml_and_classroom_metadata_checks(self):
        safe = b'<project filename="/home/public/example"/>\n'
        self.approve(self.archive("build.xml", safe), examples=self.member_example("build.xml", safe))
        self.check()
        private = b'<project filename="/home/public/example" rawText="classroom canary"/>\n'
        self.approve(self.archive("build.xml", private), examples=self.member_example("build.xml", private))
        with self.assertRaisesRegex(privacy.PrivacyError, "classroom-content-metadata"):
            self.check()

    def test_compiler_negative_syntax_fixtures_still_scan_decodable_fragments(self):
        public = [("negative.c", b'#error "unterminated\n'),
                  ("negative.rs", b'fn broken() { /* intentionally unterminated\n'),
                  ("negative.c", b'const char *p="\\xffffffff";\n'),
                  ("negative.py", b'if True:\n\t x=1\n        y=2\nVALUE="public"\n')]
        for name, payload in public:
            self.approve(self.archive(name, payload))
            self.check()
        for name, payload in [("negative.c", b'#error "\\057Users/synthetic/build\n'),
                              ("negative.py", b'if True:\n\t x=1\n        y=2\nVALUE="\\057Users/synthetic/build"\n')]:
            self.approve(self.archive(name, payload))
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                self.check()

    def test_inferno_preparation_neutralizes_both_slash_and_escaped_test_examples(self):
        slash = b"C:/" + b"Users/User/AppData/Local/Programs/Python/Python39/lib/thread.py"
        escaped = b"C:\\\\" + b"Users\\\\User\\\\AppData\\\\Local\\\\Programs\\\\Python\\\\Python39\\\\lib\\\\thread.py"
        payload = b'pub fn production() {}\n#[cfg(test)]\nmod tests { const A: &str="' + slash + b'"; const B: &str="' + escaped + b'"; }\n'
        source = self.root / "original.tar.gz"
        original = self.archive("src/flamegraph/color/palettes.rs", payload, "inferno", "0.11.21")
        source.write_bytes(original)
        output = self.root / "prepared.tar.gz"
        report = prepare.prepare(source, output, "inferno", "0.11.21")
        self.approve(output.read_bytes(), package="inferno", version="0.11.21")
        self.check()
        with tarfile.open(output) as archive:
            clean = archive.extractfile("inferno-0.11.21/src/flamegraph/color/palettes.rs").read()
        self.assertIn(b"#[cfg(test)]\nmod tests", clean)
        self.assertIn(b'C:/Public/Programs/', clean)
        self.assertIn(b'C:\\\\Public\\\\Programs\\\\', clean)
        self.assertEqual(report["redactedComments"][0]["commentExamples"], 2)
        self.assertEqual(source.read_bytes(), original)

    def prepare_member(self, name, payload):
        original = self.root / "original.tar.gz"
        original.write_bytes(self.archive(name, payload))
        output = self.root / "prepared.tar.gz"
        report = prepare.prepare(original, output, "fixture", "1.0")
        with tarfile.open(output) as archive:
            data = archive.extractfile("fixture-1.0/" + name).read()
            notice = json.loads(archive.extractfile("fixture-1.0/MODIFICATIONS.json").read())
        self.approve(output.read_bytes())
        self.check()  # Prepared source uses the same app-facing gate.
        self.assertEqual(report["preparedSHA256"], hashlib.sha256(output.read_bytes()).hexdigest())
        self.assertEqual(notice["modified"][0]["preparedSHA256"], hashlib.sha256(data).hexdigest())
        return data

    def test_preparation_preserves_html_escaped_closing_tag_and_entities(self):
        payload = b'<p>&lt;filename&gt;/home/public/build&lt;/filename&gt; &amp; next</p>\n'
        clean = self.prepare_member("doc/documentation_hacking.html", payload)
        self.assertIn(b'&lt;filename&gt;UPSTREAM_HOME/example&lt;/filename&gt; &amp; next', clean)
        self.assertTrue(clean.startswith(b"<!-- Modified by Li"))

    def test_preparation_roff_notice_is_a_comment_and_does_not_render(self):
        payload = b'.TH FIXTURE 1 "2026-10-11" "Fixture"\n.SH NAME\nfixture \\- public tool\n.SH EXAMPLES\n/home/public/build\n'
        clean = self.prepare_member("doc/gcov.1", payload)
        self.assertTrue(clean.startswith(b'.\\" Modified by Li'))
        command = shutil.which("mandoc")
        if command is None:
            self.skipTest("mandoc unavailable; syntax and app gate already checked")
        rendered = subprocess.run([command, "-T", "utf8"], input=clean, capture_output=True, check=True).stdout
        self.assertNotIn(b"Modified by Li", rendered)
        self.assertIn(b"UPSTREAM_HOME/example", rendered)


if __name__ == "__main__":
    unittest.main()
