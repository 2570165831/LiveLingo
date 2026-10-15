"""F2 file-URL regressions, using host stdlib and in-memory source archives.

No fixture is executed, loaded, extracted, written or removed. The archive IO
adapter preserves the production hash gate, member checks and envelope pass.
"""
from collections import Counter
import hashlib
import io
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
import tarfile
import unittest
from unittest.mock import patch
from urllib.parse import unquote_to_bytes, urlparse

from Scripts import privacy_package as privacy
from Scripts import privacy_text as text_scan
from Scripts import reviewed_resources as reviewed
from Scripts import source_archive as source


HOST_PATH = "/" + "Users/reviewprobe/build"
REVIEW_URL = "file://build-host" + HOST_PATH
RESOURCE = "Contents/Resources/LanguageRuntime/Licenses/fixture/source.tar"
MEMBER = "fixture-1.0/probe.py"


class MemoryFile(PurePosixPath):
    def __init__(self, name, data):
        super().__init__(name)
        self.data = data

    def with_segments(self, *segments):
        return PurePosixPath(*segments)

    def is_symlink(self):
        return False

    def stat(self):
        return SimpleNamespace(st_size=len(self.data))

    def open(self, mode):
        assert mode == "rb"
        return io.BytesIO(self.data)

    def read_bytes(self):
        return self.data


def python_source(value):
    return ("BUILD=" + repr(value) + "\n").encode()


def source_tar(payload, name=MEMBER):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        member = tarfile.TarInfo(name)
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    return output.getvalue()


def inspect_archive(payload, *, examples=None, archive_digest=None, name=MEMBER):
    data = source_tar(payload, name)
    fixture = MemoryFile("source.tar", data)
    item = {"path": RESOURCE, "sha256": archive_digest or hashlib.sha256(data).hexdigest(),
            "format": "source-tar", "package": "fixture", "version": "1.0",
            "reason": "Synthetic static F2 review fixture; never executed."}
    if examples is not None:
        item["publicSourceHostPathExamples"] = examples
    real_tar_open = tarfile.open

    def memory_tar_open(path, *args, **kwargs):
        if path is fixture:
            return real_tar_open(None, *args, fileobj=io.BytesIO(data), **kwargs)
        return real_tar_open(path, *args, **kwargs)

    def memory_path(path):
        return fixture if path is fixture else Path(path)

    counts = Counter()
    with patch.object(source.tarfile, "open", memory_tar_open), \
         patch.object(source, "Path", memory_path):
        assert reviewed.inspect(fixture, RESOURCE, {RESOURCE: item}, counts)
    return counts


def public_examples(payload, *spellings):
    return {MEMBER: {"sha256": hashlib.sha256(payload).hexdigest(),
                     "reason": "Exact synthetic public upstream URL example.",
                     "examples": [{"style": "source-literal-hex", "path": value.encode().hex()}
                                  for value in spellings]}}


class Relpipe6TextTests(unittest.TestCase):
    def check_routes(self, value, reason=None):
        payload = python_source(value)

        def metadata():
            counts = Counter()
            privacy.inspect_metadata_file(MemoryFile("probe.py", payload), counts, False)
            self.assertEqual(counts["path_scanned_text_files"], 1)

        def archive():
            counts = inspect_archive(payload)
            self.assertEqual(counts["source_archive_members"], 1)
            self.assertEqual(counts["reviewed_resource_files"], 1)

        routes = (("path-operands", lambda: text_scan.scan_path_operands(value)),
                  ("ordinary-python-text", lambda: text_scan.inspect_text(payload, "probe.py")),
                  ("metadata-entry", metadata), ("reviewed-source-tar", archive))
        for name, check in routes:
            with self.subTest(route=name, value=value):
                if reason:
                    with self.assertRaisesRegex(privacy.PrivacyError, "^" + reason + "$"):
                        check()
                else:
                    check()

    def test_review_probe_and_raw_source_code_boundary(self):
        # F2 deliberately leaves the generic raw-source scanner unchanged.
        reviewed.scan_host_paths(python_source(REVIEW_URL), source_code=True)
        self.check_routes(REVIEW_URL, "local-path-metadata")

    def test_arbitrary_authorities_cannot_hide_private_roots(self):
        for authority in ("build-host", "BUILD-HOST", "build-host.example.invalid", "127.0.0.1",
                          "[::1]", "[2001:db8::1]", "user@build-host", "build-host:445", "b%75ild-host"):
            self.check_routes("file://" + authority + HOST_PATH, "local-path-metadata")

    def test_percent_encoded_private_paths(self):
        for authority in ("build-host", "localhost", "", "%6cocalhost"):
            for path in ("/%55sers/reviewprobe/build", "/%55%73%65%72%73/reviewprobe/build",
                         "/%2fUsers%2freviewprobe%2fbuild", "/private%2ftmp/build",
                         "/C:%5cUsers%5creviewprobe%5cbuild"):
                self.check_routes("file://" + authority + path, "local-path-metadata")

    def test_empty_and_localhost_authorities_keep_private_path_checks(self):
        for authority in ("", "localhost", "LOCALHOST", "%6cocalhost"):
            for path in (HOST_PATH, "//" + HOST_PATH, "/Volumes/disk/build", "/home/reviewprobe/build"):
                self.check_routes("file://" + authority + path, "local-path-metadata")

    def test_remote_authorities_require_exact_source_review_even_for_system_paths(self):
        for authority in ("build-host", "server.example.invalid", "localhost.", "127.0.0.1",
                          "[::1]", "user@localhost", "localhost:445", "b%75ild-host"):
            for path in ("/usr/include/stdio.h", "/share/project.c", ""):
                self.check_routes("file://" + authority + path, "unreviewed-file-url-authority")

    def test_remote_url_in_a_list_is_not_hidden_by_a_local_first_url(self):
        for value in ("file:///usr/share/public,file://build-host/share/project.c",
                      "file://$WORK/proxy,file://build-host/share/project.c"):
            self.check_routes(value, "unreviewed-file-url-authority")

    def test_approved_local_uri_path_does_not_invent_an_authority(self):
        path = "/home/upstream/public.c"
        for authority in ("", "localhost", "build-host"):
            payload = python_source("file://" + authority + path)
            examples = {MEMBER: {"sha256": hashlib.sha256(payload).hexdigest(),
                        "reason": "Exact public upstream path", "examples": [{"style": "posix", "path": path[1:]}]}}
            if authority == "build-host":
                with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-file-url-authority"):
                    inspect_archive(payload, examples=examples)
            else:
                self.assertEqual(inspect_archive(payload, examples=examples)["source_archive_members"], 1)

    def test_ordinary_reviewed_uri_requires_full_hash_and_complete_spelling(self):
        relative = "Contents/Resources/LanguageRuntime/python/lib/probe.py"
        public = "file://public.example.invalid/share/example.c"
        payload = python_source(public)
        item = {"path": relative, "sha256": hashlib.sha256(payload).hexdigest(),
                "format": "python-public-examples", "package": "fixture", "version": "1.0",
                "reason": "Exact public source URI example", "publicHostPathExamples": [
                    {"style": "file-url-hex", "path": public.encode().hex()}]}
        self.assertTrue(reviewed.inspect(MemoryFile("probe.py", payload), relative, {relative: item}, Counter()))
        for changed in (public + "/private.c", "file://public.example.invalid-extra/share/example.c"):
            data = python_source(changed)
            with self.assertRaisesRegex(privacy.PrivacyError, "reviewed-resource-hash-mismatch"):
                reviewed.inspect(MemoryFile("probe.py", data), relative, {relative: item}, Counter())
            changed_item = {**item, "sha256": hashlib.sha256(data).hexdigest()}
            with self.assertRaisesRegex(privacy.PrivacyError, "unreviewed-file-url-authority"):
                reviewed.inspect(MemoryFile("probe.py", data), relative, {relative: changed_item}, Counter())

    def test_unc_remote_shares_require_host_review(self):
        for value in ("file://fileserver/share/project.c", "file:////fileserver/share/project.c",
                      "file://///fileserver/share/project.c", "file://localhost//fileserver/share/project.c",
                      "file:///%2Ffileserver/share/project.c", "file:///%5C%5Cfileserver%5Cshare%5Cproject.c"):
            self.check_routes(value, "unreviewed-file-url-authority")
        # A local file URI must not hide a remote share in an encoded suffix.
        self.check_routes("file:///usr/share/%5C%5Cfileserver%5Cshare%5Cproject.c", "local-path-metadata")

    def test_public_https_urls_are_preserved(self):
        for value in ("https://public.example.invalid" + HOST_PATH,
                      "https://public.example.invalid/docs?example=" + REVIEW_URL,
                      "https://public.example.invalid/file://fileserver/share/project.c",
                      "http://public.example.invalid/%55sers/reviewprobe/build"):
            self.check_routes(value)

    def test_local_system_file_urls_are_preserved(self):
        for authority in ("", "localhost", "LOCALHOST", "%6cocalhost"):
            for path in ("/usr/include/stdio.h", "/usr/share/project/home/example.c", "/boot/home/config/lib", "/"):
                self.check_routes("file://" + authority + path)

    def test_file_url_syntax_implementation_is_preserved(self):
        for name, payload in (("probe.py", b'PREFIX="file://"\ndef is_file(value):\n    return value.startswith(PREFIX)\n'),
                              ("probe.c", b'const char *prefix="file://";\n'),
                              ("probe.sh", b'case "$value" in file://*) echo file;; esac\n')):
            with self.subTest(name=name):
                text_scan.inspect_text(payload, name)
                counts = inspect_archive(payload, name="fixture-1.0/" + name)
                self.assertEqual(counts["source_archive_members"], 1)

    def test_percent_decoding_is_once_per_url_component(self):
        self.check_routes("file://localhost/%2555sers/reviewprobe/build")
        self.check_routes("file://localhost/usr/share/%252Fhome/example.c")

    def test_pure_authority_templates_name_no_concrete_host(self):
        for template in ("%s", "%(host)s", "{host}", "{}", "{0}", "${host}", "{%s}", "$WORK"):
            self.check_routes("file://" + template + "/usr/include/stdio.h")
            self.check_routes("file://" + template + "/%55sers/reviewprobe/build", "local-path-metadata")
        for authority in ("{host}.internal", "$WORK.internal", "%25s", "%7Bhost%7D", "{%s}.internal", "build-{%s}"):
            self.check_routes("file://" + authority + "/share/project.c", "unreviewed-file-url-authority")
        payload = b'BUILD=f"file://{host}/{path}"\n'
        text_scan.inspect_text(payload, "probe.py")
        self.assertEqual(inspect_archive(payload)["source_archive_members"], 1)

    def test_malformed_ip_authorities_fail_as_privacy_errors(self):
        for value in ("file://[::1/usr/include", "file://[not-an-ip]/usr/include"):
            self.check_routes(value, "invalid-file-url")

    def test_decoded_source_literals_use_the_same_url_policy(self):
        for value in (REVIEW_URL, "file://fileserver/share/project.c"):
            octal = "".join("\\%03o" % ord(char) for char in value)
            reason = "local-path-metadata" if value == REVIEW_URL else "unreviewed-file-url-authority"
            for name, payload in (("probe.c", ('const char *p="' + octal + '";\n').encode()),
                                  ("probe.sh", ("BUILD=$'" + octal + "'\n").encode()),
                                  ("probe.py", ("BUILD=" + repr(value[:5]) + "+" + repr(value[5:]) + "\n").encode())):
                with self.subTest(name=name, value=value):
                    with self.assertRaisesRegex(privacy.PrivacyError, "^" + reason + "$"):
                        text_scan.inspect_text(payload, name)
                    with self.assertRaisesRegex(privacy.PrivacyError, "^" + reason + "$"):
                        inspect_archive(payload, name="fixture-1.0/" + name)

    def test_hash_bound_exact_upstream_file_url_examples_are_preserved(self):
        for value in (REVIEW_URL, "file://fileserver/share/project.c", "file:////fileserver/share/project.c"):
            payload = python_source(value)
            with self.subTest(value=value):
                counts = inspect_archive(payload, examples=public_examples(payload, value))
                self.assertEqual(counts["reviewed_resource_files"], 1)
                self.assertEqual(counts["source_archive_members"], 1)

    def test_upstream_approval_does_not_cover_another_url(self):
        public = "file://public.example.invalid/share/example.c"
        payload = python_source(public) + python_source(REVIEW_URL)
        with self.assertRaisesRegex(privacy.PrivacyError, "^local-path-metadata$"):
            inspect_archive(payload, examples=public_examples(payload, public))

    def test_stale_whole_archive_hash_still_rejects_first(self):
        original = python_source("file://public.example.invalid/share/example.c")
        digest = hashlib.sha256(source_tar(original)).hexdigest()
        changed = python_source(REVIEW_URL)
        with self.assertRaisesRegex(privacy.PrivacyError, "^reviewed-resource-hash-mismatch$"):
            inspect_archive(changed, archive_digest=digest, examples=public_examples(changed, REVIEW_URL))

    def test_stale_member_hash_still_rejects_exact_upstream_allowance(self):
        original = python_source(REVIEW_URL)
        changed = original + b'PUBLIC="changed"\n'
        with self.assertRaisesRegex(privacy.PrivacyError, "^source-member-example-hash-mismatch$"):
            inspect_archive(changed, examples=public_examples(original, REVIEW_URL))

    def test_independent_urllib_parser_positive_and_negative_controls(self):
        # urlparse + unquote_to_bytes deliberately avoid production extraction,
        # urlsplit, unquote and root regexes. Expected components are explicit.
        cases = ((REVIEW_URL, "build-host", HOST_PATH, "local-path-metadata"),
                 ("file://b%75ild-host/%55sers/reviewprobe/build", "build-host", HOST_PATH, "local-path-metadata"),
                 ("file://fileserver/share/project.c", "fileserver", "/share/project.c", "unreviewed-file-url-authority"),
                 ("file:////fileserver/share/project.c", "", "//fileserver/share/project.c", "unreviewed-file-url-authority"),
                 ("file://localhost/%55sers/reviewprobe/build", "localhost", HOST_PATH, "local-path-metadata"),
                 ("file://localhost/usr/include/stdio.h", "localhost", "/usr/include/stdio.h", None),
                 ("file:///usr/include/stdio.h", "", "/usr/include/stdio.h", None),
                 ("https://public.example.invalid" + HOST_PATH, "public.example.invalid", HOST_PATH, None))
        for value, authority, path, reason in cases:
            with self.subTest(value=value):
                parsed = urlparse(value)
                self.assertEqual(unquote_to_bytes(parsed.netloc).decode(), authority)
                self.assertEqual(unquote_to_bytes(parsed.path).decode(), path)
                self.assertEqual(parsed.scheme, "https" if value.startswith("https:") else "file")
                self.check_routes(value, reason)


if __name__ == "__main__":
    unittest.main()
