"""Corresponding-source build coverage, including real offline configure runs."""
from collections import Counter
from datetime import datetime, timedelta, timezone
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
    def test_complete_darwin_gcc_inputs_are_hash_bound(self):
        directory = build.REPO / "Packaging/MLXLicenses/GCC-runtime-13.4.0"
        inputs = build.gcc_source_inputs(directory)
        self.assertEqual(set(inputs), {build.GCC_FULL, build.GCC_PATCH, build.GCC_MAPPING})
        self.assertNotIn("gcc-13.4.0.tar.xz", inputs)

    def test_gcc_input_tampering_is_rejected(self):
        directory = build.REPO / "work/relpipe/gcc-review2" / ("input-fixture-" + str(time.time_ns()))
        directory.mkdir(parents=True)
        inputs = {}
        for name in (build.GCC_FULL, build.GCC_PATCH, build.GCC_MAPPING):
            (directory / name).write_bytes(b"pinned input\n")
            inputs[name] = {"sha256": hashlib.sha256(b"pinned input\n").hexdigest()}
        (directory / "PROVENANCE.json").write_text(json.dumps({"darwinCorrespondingSource": {"inputs": inputs}}))
        (directory / build.GCC_PATCH).write_bytes(b"changed input\n")
        with self.assertRaisesRegex(PrivacyError, "gcc-darwin-source-hash-mismatch"):
            build.gcc_source_inputs(directory)
        directory.rename(build.REPO / "work/relpipe/superseded" / directory.name)

    def test_native_gcc_does_not_pass_when_only_compiler_configuration_succeeds(self):
        root = build.REPO / "work/relpipe/gcc-review2" / ("native-fixture-" + str(time.time_ns()))
        root.mkdir(parents=True)
        source = root / "gcc-13.4.0"
        source.mkdir()
        for name in ["gcc/config/aarch64/darwin.h", "gcc/config/aarch64/t-aarch64-darwin",
                     "libgcc/config/aarch64/t-darwin", "libgfortran/configure", "libquadmath/configure"]:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")
        commands = []
        def run(command, directory, log, **kwargs):
            commands.append(command)
            return {"exit": 2 if "all-gcc" in command else 0, "log": log.name}
        sdk = type("Result", (), {"stdout": "/public-sdk\n"})()
        with patch.object(build, "gcc_source_inputs", return_value={}), \
             patch.object(build, "unpack", return_value=source), \
             patch.object(build.platform, "system", return_value="Darwin"), \
             patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build.platform, "release", return_value="27.2.0"), \
             patch.object(build, "run_gcc_offline", side_effect=run), \
             patch.object(build.subprocess, "run", return_value=sdk):
            result = build.check_gcc_native(root, root / "output")
        self.assertFalse(result["passed"])
        self.assertEqual(result["runtimeLibraries"], {})
        configure = next(c for c in commands if any("--build=" in str(x) for x in c))
        for option in ("--build=", "--host=", "--target="):
            self.assertIn(option + "aarch64-apple-darwin27", configure)
        self.assertFalse(any("x86_64" in str(c) for c in commands))
        root.rename(build.REPO / "work/relpipe/superseded" / root.name)

    def test_gcc_timeout_kills_descendants_after_make_parent_exits(self):
        root = build.REPO / "work/relpipe/gcc-review2"
        process = type("Process", (), {"pid": 12345})()
        process.wait = unittest.mock.Mock(side_effect=[subprocess.TimeoutExpired("make", 1), -15])
        with patch.object(build.subprocess, "Popen", return_value=process), patch.object(build.os, "killpg") as kill:
            result = build.run_gcc_offline(["make"], root, root / "timeout-fixture.log", timeout=1,
                                         stop_at=datetime.now(timezone.utc) + timedelta(seconds=60))
        self.assertTrue(result["timedOut"])
        self.assertEqual([call.args[1] for call in kill.call_args_list], [build.signal.SIGTERM, build.signal.SIGKILL])

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
                    notice_data = archive.extractfile(change.get("noticePath", change["path"])).read()
                    self.assertIn(b"Modified by Li on 2026-10-11", notice_data)
                    if root == "gcc-13.4.0":
                        # Text notices are in-file; changed binary fixtures have
                        # separate, exact per-file notices to retain their format.
                        self.assertEqual(notice["omittedCount"], 0)
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
