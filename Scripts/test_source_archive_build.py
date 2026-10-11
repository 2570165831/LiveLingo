"""Corresponding-source build coverage, including real offline configure runs."""
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import tarfile
import re
import subprocess
import time
import unittest
from unittest.mock import patch

from Scripts import prepare_source_archive as prepare
from Scripts import source_archive as source
from Scripts import source_build_check as build
from Scripts.privacy_package import PrivacyError


class SourceBuildPolicyTests(unittest.TestCase):
    def test_doc_manual_and_automake_include_inputs_are_retained(self):
        for package, name in [("lame", "doc/html/Makefile.in"), ("lame", "ACM/ddk/Makefile.in"),
                              ("mpg123", "man1/mpg123.1"), ("mpg123", "src/tests/Makemodule.am"),
                              ("mpg123", "doc/Makemodule.am"), ("gcc", "gcc/doc/gcov.texi"),
                              ("gcc", "gcc/doc/gcov.1"), ("gcc", "gcc/doc/gcc.info"),
                              ("gcc", "libquadmath/Makefile.in")]:
            self.assertIsNone(prepare.omission(package + "-1.0/" + name, package), name)

    def test_gate_rejects_nonpublic_tar_header_fields_even_with_approved_hash(self):
        for field, value in [("uname", "synthetic-owner"), ("gname", "staff"), ("uid", 501),
                             ("gid", 20), ("mtime", 123456)]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w:gz") as archive:
                member = tarfile.TarInfo("fixture-1.0/main.c")
                member.size = 1
                setattr(member, field, value)
                archive.addfile(member, io.BytesIO(b"\n"))
            with tarfile.open(fileobj=io.BytesIO(data.getvalue())) as archive:
                with patch.object(source.tarfile, "open", return_value=archive):
                    with self.assertRaisesRegex(PrivacyError, "nonpublic-source-archive-header"):
                        source.inspect_source_archive(Path("fixture"), {"package": "fixture", "version": "1.0"}, Counter())

    def test_configure_commands_are_always_network_isolated(self):
        root = build.REPO / "work/relpipe"
        root.mkdir(parents=True, exist_ok=True)
        log = root / "sandbox-command-test.txt"
        def launch(command, **kwargs):
            self.assertEqual(command[:3], [build.SANDBOX, "-p", build.PROFILE])
            kwargs["stdout"].write(b"synthetic configure completed\n")
            return type("Result", (), {"returncode": 0})()
        with patch.object(build.subprocess, "run", side_effect=launch):
            self.assertEqual(build.run_offline(["true"], root, log)["exit"], 0)

    def test_xml_build_macros_and_public_dtd_are_checked_without_fetching(self):
        source.inspect_source_xml(b'<?xml version="1.0"?><!DOCTYPE project PUBLIC "-//W3C//DTD SVG 1.0//EN" "https://example.invalid/source.dtd"><project OutputFile="$(OutDir)/library.a">FLAC++/decoder.h</project>')
        for data in [b'<project rawText="synthetic canary"/>', b'<project><rawText>canary</rawText></project>',
                     b'<project path="/synthetic/private"/>', b'<project><!-- {"rawText":"canary"} --></project>',
                     b'<!DOCTYPE project [<!ENTITY private "/synthetic/private">]><project>&private;</project>']:
            with self.assertRaises(PrivacyError):
                source.inspect_source_xml(data)


class BundledSourceBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archives = build.REPO / "Packaging/MLXLicenses"
        cls.output = build.REPO / "work/relpipe" / ("source-build-tests-" + str(time.time_ns()))
        cls.results = build.check(cls.archives, cls.output)

    def test_every_bundled_autotools_archive_configures_and_dry_runs_offline(self):
        results = [r for r in self.results if "configure" in r]
        self.assertEqual(len(results), 8)
        for result in results:
            with self.subTest(archive=result["archive"]):
                self.assertTrue(result["passed"], json.dumps(result))

    def test_crate_build_entry_points_and_in_archive_modification_notices(self):
        crates = [r for r in self.results if "cargoInputs" in r]
        self.assertEqual(len(crates), 3)
        self.assertTrue(all(r["cargoInputs"]["libraryPresent"] for r in crates))
        for result in self.results:
            with tarfile.open(self.archives / result["archive"]) as archive:
                root = archive.getnames()[0].split("/")[0]
                notice = json.loads(archive.extractfile(root + "/MODIFICATIONS.json").read())
                for change in notice["modified"]:
                    self.assertEqual(change["contributor"], "Li")
                    self.assertEqual(change["date"], "2026-10-11")
                    data = archive.extractfile(change["path"]).read()
                    self.assertIn(b"Modified by Li on 2026-10-11", data)
                    self.assertEqual(hashlib.sha256(data).hexdigest(), change["preparedSHA256"])
                if root == "inferno-0.11.21":
                    modules = [m.name for m in archive if m.isfile() and m.name.endswith(".rs")
                               and b"#[cfg(test)]\nmod tests {" in archive.extractfile(m).read()]
                    self.assertEqual(len(modules), 10)
                    self.assertEqual(len(notice["modified"]), 1)

    def test_all_static_audio_codecs_rebuild_libsndfile_without_network(self):
        recipe = self.archives / "ASR-audio/offline-rebuild.sh"
        output = self.output / "audio-rebuild"
        result = build.run_offline(["/bin/sh", recipe, output], self.output,
                                   self.output / "audio-rebuild.log", timeout=600)
        self.assertEqual(result["exit"], 0, str(self.output / result["log"]))
        libraries = [p for p in (output / "sndfile-build").glob("libsndfile*.dylib")
                     if p.is_file() and not p.is_symlink()]
        self.assertEqual(len(libraries), 1)
        symbols = subprocess.run(["/usr/bin/nm", str(libraries[0])], capture_output=True, text=True, check=True).stdout
        counts = {prefix: len(re.findall(r"\b_" + re.escape(prefix) + r"\w*", symbols))
                  for prefix in ("FLAC__", "ogg_", "vorbis_", "opus_", "lame_", "mpg123_")}
        (self.output / "audio-codec-symbol-counts.json").write_text(json.dumps(counts, indent=2) + "\n")
        self.assertTrue(all(counts.values()), counts)


if __name__ == "__main__":
    unittest.main()
