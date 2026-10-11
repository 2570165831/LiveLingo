"""Synthetic exact-path approvals and fail-closed resource representations."""
import hashlib
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package as privacy
from Scripts import reviewed_resources as reviewed
from Scripts import prepare_source_archive as prepare_source


BASE = "Contents/Resources/LanguageRuntime/"


class ReviewedResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="reviewed-resources-")
        self.root = Path(self.temp.name)
        self.app = self.root / "app"
        self.app.mkdir()
        self.manifest = self.root / "manifest.json"
        self.resources = []
        self.manifest.write_text('{"version":1,"resources":[]}')
        self.patch = patch.object(reviewed, "MANIFEST", self.manifest)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def write(self, relative, data):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def approve(self, relative, data, form, package="fixture", version="1.0"):
        path = self.write(relative, data)
        self.resources.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(),
                               "format": form, "package": package, "version": version,
                               "reason": "Synthetic required dependency fixture."})
        self.manifest.write_text(json.dumps({"version": 1, "resources": self.resources}))
        return path

    def check(self):
        return privacy.inspect_tree(self.app)

    def tar(self, files, special=None):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            if special is not None:
                archive.addfile(special)
        return stream.getvalue()

    def test_exact_path_and_sha256_approve_resource(self):
        self.approve(BASE + "fixture/grammar.lark", b'start: "value"\n', "lark-grammar")
        self.assertEqual(self.check()["reviewed_resource_files"], 1)

    def test_hash_mismatch_rejects_changed_resource(self):
        path = self.approve(BASE + "fixture/grammar.lark", b'start: "value"\n', "lark-grammar")
        path.write_bytes(b'start: "changed"\n')
        with self.assertRaisesRegex(privacy.PrivacyError, "hash-mismatch"):
            self.check()

    def test_same_bytes_at_a_different_path_are_rejected(self):
        data = b'start: "value"\n'
        path = self.approve(BASE + "fixture/grammar.lark", data, "lark-grammar")
        path.rename(path.with_name("other.lark"))
        with self.assertRaisesRegex(privacy.PrivacyError, "unsupported-package-file-format"):
            self.check()

    def test_unlisted_same_format_is_rejected(self):
        self.write(BASE + "fixture/grammar.lark", b'start: "value"\n')
        with self.assertRaises(privacy.PrivacyError):
            self.check()

    def test_approved_symlink_is_not_a_content_attestation(self):
        data = b'start: "value"\n'
        path = self.approve(BASE + "fixture/grammar.lark", data, "lark-grammar")
        target = self.write(BASE + "fixture/source.txt", data)
        path.unlink()
        path.symlink_to(target.name)
        with self.assertRaisesRegex(privacy.PrivacyError, "reviewed-resource-symlink"):
            self.check()

    def test_schema_references_are_not_host_paths(self):
        data = json.dumps({"$defs": {"value": {"type": "string"}}, "$ref": "#/$defs/value"}).encode()
        self.approve(BASE + "fixture/schema.json", data, "json-schema")
        self.assertEqual(self.check()["reviewed_resource_files"], 1)

    def test_schema_approval_does_not_waive_private_fields_or_paths(self):
        for value in ({"rawText": "synthetic private content"}, {"build": "/synthetic/private"}):
            with self.subTest(value=value):
                self.resources = []
                self.approve(BASE + "fixture/schema.json", json.dumps(value).encode(), "json-schema")
                with self.assertRaises(privacy.PrivacyError):
                    self.check()

    def test_nonallowlisted_schema_reference_stays_rejected(self):
        self.write(BASE + "fixture/schema.json", b'{"$ref":"#/$defs/value"}')
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            self.check()

    def test_grammar_regex_and_comment_delimiters_are_inspected_as_syntax(self):
        self.approve(BASE + "fixture/grammar.lark", b'// public comment\nstart: /[a-z]+/ "/*" "*/"\n', "lark-grammar")
        self.check()

    def test_approved_grammar_literal_still_rejects_a_host_path(self):
        self.approve(BASE + "fixture/grammar.lark", b'start: "/synthetic/private"\n', "lark-grammar")
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            self.check()

    def test_resource_comments_cannot_hide_private_metadata(self):
        for form, data in (("css", b'/* {"rawText":"synthetic private content"} */ a {color: blue}'),
                           ("lark-grammar", b'// {"rawText":"synthetic private content"}\nstart: "a"\n')):
            with self.subTest(form=form):
                self.resources = []
                self.approve(BASE + "fixture/resource.txt", data, form)
                with self.assertRaisesRegex(privacy.PrivacyError, "classroom-content-metadata"):
                    self.check()

    def test_source_archive_xml_metadata_and_unknown_yaml_stay_guarded(self):
        for name, data in (("fixture-1.0/build.xml", b'<build rawText="synthetic private content"/>'),
                           ("fixture-1.0/config.yml", b'rawText: synthetic private content\n')):
            with self.subTest(name=name):
                self.resources = []
                archive = self.tar({name: data})
                self.approve(BASE + "Licenses/fixture/source.tar.gz", archive, "source-tar")
                with self.assertRaises(privacy.PrivacyError):
                    self.check()

    def test_model_vocabulary_approval_keeps_other_metadata_guarded(self):
        relative = "Contents/Resources/Models/fixture/config.json"
        value = {"joint": {"vocabulary": ["a", "/"]}, "labels": ["a", "/"]}
        self.approve(relative, json.dumps(value).encode(), "parakeet-config")
        self.check()
        for extra in ({"rawText": "synthetic private content"}, {"path": "/synthetic/private"},
                      {"labels": ["different"]}):
            self.resources = []
            self.approve(relative, json.dumps({**value, **extra}).encode(), "parakeet-config")
            with self.assertRaises(privacy.PrivacyError):
                self.check()

    def test_model_directory_staging_uses_same_exact_path_and_hash(self):
        relative = "Contents/Resources/Models/mlx-community/parakeet-tdt-0.6b-v2/config.json"
        data = b'{"joint":{"vocabulary":["/"]},"labels":["/"]}'
        path = self.approve(relative, data, "parakeet-config")
        self.assertEqual(privacy.inspect_tree(path.parent)["reviewed_resource_files"], 1)
        path.write_bytes(data + b"\n")
        with self.assertRaisesRegex(privacy.PrivacyError, "hash-mismatch"):
            privacy.inspect_tree(path.parent)

    def test_approved_numeric_msgpack_is_decoded_without_unpickling(self):
        data = b'\x81\xcb' + struct.pack('>d', 1.5) + b'\x81\x02\xff'
        self.approve(BASE + "fixture/intervals.msgpack", data, "numeric-msgpack")
        self.check()

    def test_msgpack_rejects_strings_extensions_nonfinite_and_trailing_bytes(self):
        for data in (b'\x81\x01\xa4text', b'\x81\x01\xd4\x01\x01', b'\x81\xcb' + struct.pack('>d', float('nan')) + b'\x01', b'\x80\x00'):
            with self.subTest(data=data):
                with self.assertRaises(privacy.PrivacyError):
                    reviewed.inspect_numeric_msgpack(data)

    def test_reviewed_notice_still_rejects_renamed_private_metadata(self):
        self.approve(BASE + "Licenses/fixture/LICENSE.txt", b'{"rawText":"synthetic private content"}', "notice-text")
        with self.assertRaisesRegex(privacy.PrivacyError, "classroom-content-metadata"):
            self.check()

    def test_reviewed_notice_parses_comment_markup_without_rewriting_bytes(self):
        data = b'/* Copyright fixture. Permission is hereby granted. */\n'
        path = self.approve(BASE + "Licenses/fixture/LICENSE.txt", data, "notice-text")
        self.check()
        self.assertEqual(path.read_bytes(), data)

    def test_unknown_binary_remains_rejected(self):
        self.write(BASE + "fixture/data.bin", b'\x00\x01\x02\xff')
        with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-binary"):
            self.check()

    def test_reviewed_source_archive_scans_each_member(self):
        data = self.tar({"fixture-1.0/src/lib.c": b'/* public source */\nint value = 1;\n'})
        self.approve(BASE + "Licenses/fixture/source.tar.gz", data, "source-tar")
        self.assertEqual(self.check()["source_archive_members"], 1)

    def test_archive_rejects_private_metadata_unknown_binary_and_classroom_names(self):
        files = {"meta.json": b'{"translatedText":"synthetic"}', "private.json": b'{"path":"/synthetic/private"}',
                 "unknown.bin": b'\x00\x01\x02\xff', "recording.wav": b'not real audio'}
        for name, payload in files.items():
            with self.subTest(name=name):
                self.resources = []
                self.approve(BASE + "Licenses/fixture/source.tar.gz", self.tar({"fixture-1.0/" + name: payload}), "source-tar")
                with self.assertRaises(privacy.PrivacyError):
                    self.check()

    def test_source_system_directory_is_not_a_user_home_root(self):
        reviewed.scan_host_paths(b"system_dir='/boot/home/config/lib'", source_code=True)
        with self.assertRaises(privacy.PrivacyError):
            reviewed.scan_host_paths(b"user_dir='/home/synthetic/private'", source_code=True)
        with self.assertRaises(privacy.PrivacyError):
            reviewed.scan_host_paths(b"user_dir='file:///home/synthetic/private'", source_code=True)
        with self.assertRaises(privacy.PrivacyError):
            privacy.validate_metadata({"path": "/boot/home/config/lib"})

    def test_source_archive_rejects_traversal_and_links(self):
        symlink = tarfile.TarInfo("fixture-1.0/link")
        symlink.type = tarfile.SYMTYPE
        symlink.linkname = "../../outside"
        for data in (self.tar({"fixture-1.0/../outside": b'public'}), self.tar({}, special=symlink)):
            self.resources = []
            self.approve(BASE + "Licenses/fixture/source.tar.gz", data, "source-tar")
            with self.assertRaises(privacy.PrivacyError):
                self.check()

    def test_manifest_rejects_duplicate_paths_and_invalid_hashes(self):
        self.approve(BASE + "fixture/grammar.lark", b'start: "v"\n', "lark-grammar")
        self.manifest.write_text(json.dumps({"version": 1, "resources": self.resources * 2}))
        with self.assertRaises(privacy.PrivacyError):
            self.check()
        self.resources[0]["sha256"] = "unknown"
        self.manifest.write_text(json.dumps({"version": 1, "resources": self.resources}))
        with self.assertRaises(privacy.PrivacyError):
            self.check()

    def test_source_preparation_keeps_legal_bytes_and_library_source(self):
        data = self.tar({"fixture-1.0/src/lib.c": b'int value = 1;\n', "fixture-1.0/tests/data.bin": b'\x00',
                         "fixture-1.0/LICENSE": b'Copyright fixture. Permission granted.\n'})
        original = self.root / "original.tar.gz"
        original.write_bytes(data)
        output = self.root / "prepared.tar.gz"
        report = prepare_source.prepare(original, output, "fixture", "1.0")
        self.assertEqual(original.read_bytes(), data)
        self.assertEqual(report["retainedFiles"], 4)  # Includes the in-archive notice.
        self.assertEqual(len(report["omitted"]), 0)

    def test_rust_test_module_trimming_never_removes_later_production_code(self):
        module = b'pub fn value() {}\n#[cfg(test)]\nmod tests { fn check() { let s = "}"; } }\n'
        clean, changed = prepare_source.omit_trailing_rust_tests(module, "src/lib.rs")
        self.assertTrue(changed)
        self.assertEqual(clean, b'pub fn value() {}\n')
        later = module + b'pub fn later() {}\n'
        self.assertEqual(prepare_source.omit_trailing_rust_tests(later, "src/lib.rs"), (later, False))

    def test_c_comment_redaction_never_edits_quoted_or_raw_string_code(self):
        data = b'/* example /home/synthetic/private */\nconst char *a="/home/synthetic/private";\nconst char *b=R"tag(/* /home/synthetic/private */)tag";\n'
        clean, count = prepare_source.redact_c_block_examples(data)
        self.assertEqual(count, 1)
        self.assertIn(b'const char *a="/home/synthetic/private";', clean)
        self.assertIn(b'R"tag(/* /home/synthetic/private */)tag"', clean)

    def test_malformed_plist_date_is_a_fixed_privacy_error(self):
        data = b'<?xml version="1.0"?><plist version="1.0"><date>not-a-date</date></plist>'
        with self.assertRaisesRegex(privacy.PrivacyError, "invalid-package-plist"):
            privacy.parse_metadata(data, "plist")


if __name__ == "__main__":
    unittest.main()
