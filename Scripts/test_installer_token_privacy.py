"""Offline installer regressions: synthetic files and memory HTTP transports only."""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import installer_token_private as helper

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path(tempfile.gettempdir()).resolve() / "livelingo-installer-tests"
TOKEN = "synthetic_installer_token_for_offline_tests_0000000001"
BODY = plistlib.dumps({"Label": "synthetic.local.asr", "EnvironmentVariables": {
    "LIVELINGO_ASR_TOKEN": TOKEN}, "SyntheticBody": "Keep the original bytes."})
ALLOW = "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
DENY = "everyone deny writeextattr,file_inherit,directory_inherit"
EMBED_START = "<<'LIVELINGO_PRIVATE_INSTALL_HELPER'\n"
EMBED_END = "\nLIVELINGO_PRIVATE_INSTALL_HELPER\n"


def acl(path):
    listing = subprocess.run(["/bin/ls", "-lde", str(path)], check=True,
                             capture_output=True, text=True).stdout
    return tuple(line.strip() for line in listing.splitlines()
                 if re.match(r"\s*\d+:\s", line))


def add_acl(path, entry):
    subprocess.run(["/bin/chmod", "+a", entry, str(path)], check=True,
                   capture_output=True)


def fingerprint(path):
    info = path.lstat()
    return info.st_ino, stat.S_IMODE(info.st_mode), acl(path), path.read_bytes()


class InstallerTokenPrivacyTests(unittest.TestCase):
    def setUp(self):
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="synthetic-", dir=EVIDENCE))
        self.target = self.directory / "agent.plist"
        self.copies = self.directory / "copies"
        self.copies.mkdir()

    def tearDown(self):
        superseded = EVIDENCE / "superseded"
        superseded.mkdir(exist_ok=True)
        self.directory.rename(superseded / self.directory.name)

    def make_file(self, path=None, payload=BODY, mode=0o600):
        path = path or self.target
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        return path

    def assert_private(self, path):
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertFalse(any(" allow " in line for line in acl(path)),
                         "A token-bearing file retained an ALLOW ACL")

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_new_plist_removes_inherited_allow_before_writing_and_preserves_parent(self):
        add_acl(self.directory, ALLOW)
        parent_before = stat.S_IMODE(self.directory.stat().st_mode), acl(self.directory)
        helper.write_private_bytes(self.target, BODY)
        self.assert_private(self.target)
        self.assertTrue(self.target.read_bytes() == BODY, "Plist body changed")
        self.assertEqual((stat.S_IMODE(self.directory.stat().st_mode), acl(self.directory)), parent_before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_generated_copy_removes_allow_and_keeps_inherited_deny_and_body(self):
        add_acl(self.directory, ALLOW)
        add_acl(self.copies, DENY)
        add_acl(self.copies, ALLOW)
        before = stat.S_IMODE(self.copies.stat().st_mode), acl(self.copies)
        result = helper.write_private_bytes(self.target, BODY, retained_directory=self.copies)
        generated = result["generated"]
        self.assert_private(generated)
        self.assertTrue(any(" deny " in line and "writeextattr" in line for line in acl(generated)))
        self.assertTrue(generated.read_bytes() == BODY, "Retained body changed")
        self.assertEqual((stat.S_IMODE(self.copies.stat().st_mode), acl(self.copies)), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_private_copy_keeps_source_bytes_mode_acl_and_copies_body_privately(self):
        source = self.make_file(mode=0o644)
        add_acl(source, "everyone allow read,readattr,readextattr,readsecurity")
        add_acl(self.copies, ALLOW)
        before = fingerprint(source)
        copied = helper.retain_private_copy(source, self.copies, "old-agent")
        self.assert_private(copied)
        self.assertTrue(copied.read_bytes() == BODY, "Backup body changed")
        self.assertEqual(fingerprint(source), before)

    def test_read_only_existing_target_is_rejected_without_changes(self):
        self.make_file(mode=0o400)
        before = fingerprint(self.target)
        with self.assertRaises(OSError):
            helper.write_private_bytes(self.target, b"synthetic replacement",
                                       backup_directory=self.copies, retained_directory=self.copies)
        self.assertEqual(fingerprint(self.target), before)
        self.assertEqual(list(self.copies.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_acl_denied_existing_write_is_rejected_without_changes(self):
        self.make_file()
        add_acl(self.target, "everyone deny write")
        before = fingerprint(self.target)
        with self.assertRaises(OSError):
            helper.write_private_bytes(self.target, b"synthetic replacement")
        self.assertEqual(fingerprint(self.target), before)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended ACL regression")
    def test_atomic_replace_preserves_existing_deny_mode_and_private_backup(self):
        self.make_file()
        add_acl(self.target, "everyone deny writeextattr")
        old_inode = self.target.stat().st_ino
        payload = BODY + b"\n"
        result = helper.write_private_bytes(self.target, payload, backup_directory=self.copies)
        self.assertNotEqual(self.target.stat().st_ino, old_inode)
        self.assert_private(self.target)
        self.assertTrue(any(" deny " in line and "writeextattr" in line for line in acl(self.target)),
                        "Atomic replacement discarded the existing DENY ACL")
        self.assert_private(result["backup"])
        self.assertTrue(result["backup"].read_bytes() == BODY, "Previous body was not retained")
        self.assertTrue(self.target.read_bytes() == payload, "Replacement body changed")

    def test_public_existing_target_is_rejected_without_permission_migration(self):
        self.make_file(mode=0o644)
        before = fingerprint(self.target)
        with self.assertRaises(OSError):
            helper.write_private_bytes(self.target, BODY)
        self.assertEqual(fingerprint(self.target), before)

    def test_linked_existing_target_is_rejected_without_changing_either_file(self):
        source = self.make_file(self.directory / "neighbor.plist")
        self.target.symlink_to(source.name)
        before = fingerprint(source)
        with self.assertRaises(OSError):
            helper.write_private_bytes(self.target, b"synthetic replacement")
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(fingerprint(source), before)

    def test_hard_linked_existing_target_is_rejected_without_changing_either_file(self):
        source = self.make_file(self.directory / "neighbor.plist")
        os.link(source, self.target)
        before = fingerprint(source)
        with self.assertRaises(OSError):
            helper.write_private_bytes(self.target, b"synthetic replacement")
        self.assertEqual(fingerprint(source), before)
        self.assertEqual(self.target.stat().st_ino, source.stat().st_ino)

    def test_generated_copy_uses_exclusive_names_and_preserves_existing_copy(self):
        occupied = self.make_file(self.copies / "generated-asr-plist.xml", mode=0o400)
        before = fingerprint(occupied)
        result = helper.write_private_bytes(self.target, BODY, retained_directory=self.copies)
        self.assertNotEqual(result["generated"], occupied)
        self.assertEqual(fingerprint(occupied), before)
        self.assert_private(result["generated"])

    def test_acl_failure_happens_before_any_token_body_is_written(self):
        self.assertTrue(hasattr(helper, "make_new_file_private"), "Private ACL writer is missing")
        with patch.object(helper, "make_new_file_private", side_effect=OSError("synthetic ACL failure")):
            with self.assertRaises(OSError):
                helper.write_private_bytes(self.target, BODY)
        self.assertFalse(self.target.exists())
        for path in self.directory.iterdir():
            if path.is_file():
                self.assertEqual(path.stat().st_size, 0, "ACL failure left token bytes behind")

    def test_installers_keep_tokens_out_of_subprocess_arguments_and_use_token_file(self):
        for relative in ("Scripts/install-qwen-service.sh", "Packaging/install.command"):
            text = (ROOT / relative).read_text()
            with self.subTest(installer=relative):
                self.assertFalse(bool(re.search(r"(?m)^asr_token=", text)), "Installer captures a token in shell")
                self.assertFalse(bool(re.search(r"(?m)^/usr/bin/plutil .*LIVELINGO_ASR_TOKEN.*asr_token", text)),
                                 "Installer passes a token in plutil arguments")
                self.assertTrue("health --token-file" in text, "Installer lacks token-file health routing")
                self.assertTrue("check-target" in text, "Installer lacks private target preflight")

    def test_packaged_installer_contains_identical_helper_and_installs_usable_path(self):
        text = (ROOT / "Packaging/install.command").read_text()
        self.assertTrue(EMBED_START in text, "Packaged helper payload is missing")
        embedded = text.split(EMBED_START, 1)[1].split(EMBED_END, 1)[0] + "\n"
        canonical = (ROOT / "Scripts/installer_token_private.py").read_text()
        self.assertEqual(hashlib.sha256(embedded.encode()).hexdigest(),
                         hashlib.sha256(canonical.encode()).hexdigest())
        output = self.directory / "installed-helper.py"
        subprocess.run([sys.executable, "-B", "-", "export-helper", "--installer",
                        str(ROOT / "Packaging/install.command"), "--output", str(output)],
                       input=embedded, text=True, capture_output=True, check=True)
        self.assertTrue(output.read_bytes() == canonical.encode())
        help_result = subprocess.run([sys.executable, "-B", str(output), "health", "--help"],
                                     capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--token-file", help_result.stdout)

    def test_token_file_health_and_client_authenticate_memory_requests_only(self):
        self.assertTrue(hasattr(helper, "request_from_token_file"), "Token-file client is missing")
        self.make_file()
        calls = []

        class Connection:
            def __init__(self, host, port, timeout):
                calls.append((host, port, timeout))

            def request(self, method, path, body=None, headers=None):
                calls.append((method, path, body, headers))

            def getresponse(self):
                return type("Response", (), {"status": 200, "read": lambda self, size: b'{"ok":true,"auth":true}'})()

            def close(self):
                calls.append("closed")

        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            helper.request_from_token_file(self.target, connection_factory=Connection)
            helper.request_from_token_file(self.target, audio=b"synthetic wav bytes", connection_factory=Connection)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(calls[0][:2], ("127.0.0.1", 18765))
        requests = [row for row in calls if isinstance(row, tuple) and row[0] in ("GET", "POST")]
        self.assertEqual([row[0] for row in requests], ["GET", "POST"])
        for row in requests:
            self.assertTrue(row[3].get("X-LiveLingo-Token") == TOKEN, "Client omitted token header")
            self.assertFalse(TOKEN in row[1], "Client put the token into its request URL")

    def test_token_file_client_rejects_redirect_without_following_it(self):
        self.assertTrue(hasattr(helper, "request_from_token_file"), "Token-file client is missing")
        self.make_file()
        calls = []

        class Redirect:
            def __init__(self, *args, **kwargs):
                calls.append("connect")

            def request(self, *args, **kwargs):
                calls.append("request")

            def getresponse(self):
                return type("Response", (), {"status": 302, "read": lambda self, size: b""})()

            def close(self):
                calls.append("close")

        with self.assertRaises(OSError):
            helper.request_from_token_file(self.target, connection_factory=Redirect)
        self.assertEqual(calls, ["connect", "request", "close"])

    def test_client_rejects_public_or_missing_token_file_before_transport(self):
        self.assertTrue(hasattr(helper, "request_from_token_file"), "Token-file client is missing")
        self.make_file(mode=0o644)
        transport = unittest.mock.Mock()
        with self.assertRaises((OSError, ValueError)):
            helper.request_from_token_file(self.target, connection_factory=transport)
        transport.assert_not_called()
        with self.assertRaises((OSError, ValueError)):
            helper.request_from_token_file(self.directory / "missing.plist", connection_factory=transport)
        transport.assert_not_called()

    def test_generated_launchagent_uses_internal_token_and_preserves_program_body(self):
        self.assertTrue(hasattr(helper, "install_launchagent"), "Private LaunchAgent generator is missing")
        arguments = ["/synthetic/asr runner", "--host", "127.0.0.1", "--port", "18765"]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                patch.object(helper.secrets, "token_hex", return_value="a1" * 32):
            helper.install_launchagent(self.target, arguments, Path("/synthetic/logs"),
                                       models_directory=Path("/synthetic/models"),
                                       retained_directory=self.copies)
        self.assertEqual(output.getvalue(), "")
        self.assert_private(self.target)
        body = plistlib.loads(self.target.read_bytes())
        self.assertEqual(body["ProgramArguments"], arguments)
        self.assertEqual(body["EnvironmentVariables"]["LIVELINGO_ASR_MODELS"], "/synthetic/models")
        token = body["EnvironmentVariables"]["LIVELINGO_ASR_TOKEN"]
        self.assertTrue(bool(re.fullmatch(r"[a-f0-9]{64}", token)), "Generated token has the wrong format")
        copies = list(self.copies.iterdir())
        self.assertEqual(len(copies), 1)
        self.assertTrue(copies[0].read_bytes() == self.target.read_bytes(), "Generated copy body differs")

    def test_permission_change_during_target_open_is_rejected(self):
        self.make_file()
        original_open = os.open

        def change_mode(name, flags, *args, **kwargs):
            if name == self.target.name and kwargs.get("dir_fd") is not None:
                os.chmod(self.target, 0o644)
            return original_open(name, flags, *args, **kwargs)

        with patch.object(helper.os, "open", side_effect=change_mode):
            with self.assertRaises(OSError):
                helper.write_private_bytes(self.target, b"synthetic replacement")
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o644)
        self.assertTrue(self.target.read_bytes() == BODY, "Concurrent target body was overwritten")

    def test_late_target_appearance_is_rejected_without_overwriting_it(self):
        original_stat = os.stat
        visits = 0

        def appear_after_absence(name, *args, **kwargs):
            nonlocal visits
            if name == self.target.name and kwargs.get("dir_fd") is not None:
                visits += 1
                if visits == 2:
                    self.make_file(mode=0o400)
                    raise FileNotFoundError("Synthetic target appeared immediately after absence check")
            return original_stat(name, *args, **kwargs)

        with patch.object(helper.os, "stat", side_effect=appear_after_absence):
            with self.assertRaises(OSError):
                helper.write_private_bytes(self.target, b"synthetic replacement")
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o400)
        self.assertTrue(self.target.read_bytes() == BODY, "Late target body was overwritten")

    def test_client_never_prints_server_echoed_token_even_when_token_file_rotates(self):
        self.assertTrue(hasattr(helper, "request_from_token_file"), "Token-file client is missing")
        self.make_file()
        audio = self.make_file(self.directory / "synthetic-audio.wav", payload=b"synthetic audio")
        original_request = helper.request_from_token_file

        class Echo:
            def __init__(self, *args, **kwargs):
                pass

            def request(self, *args, **kwargs):
                pass

            def getresponse(self):
                payload = ('{"text":"' + TOKEN + '"}').encode()
                return type("Response", (), {"status": 200, "read": lambda self, size: payload})()

            def close(self):
                pass

        def memory_request(*args, **kwargs):
            return original_request(*args, **kwargs, connection_factory=Echo)

        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                patch.object(helper, "request_from_token_file", side_effect=memory_request), \
                patch.object(helper, "read_token_file", side_effect=[TOKEN, "b2" * 32]) as reader:
            helper.main(["client", "--token-file", str(self.target), "--audio-file", str(audio)])
        self.assertFalse(TOKEN in output.getvalue(), "Client printed the request's token")
        self.assertEqual(reader.call_count, 1, "Client reread a potentially different authentication token")


if __name__ == "__main__":
    unittest.main(verbosity=2)
