"""R2 static text regressions through the production metadata entry point.

All fixtures remain in memory. No input program, candidate interpreter, native
extension, external command or network service is executed by this suite.
"""
import ast
import io
from pathlib import PurePosixPath
import posixpath
import shlex
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from Scripts import privacy_literals as literals
from Scripts import privacy_package as privacy
from Scripts import privacy_text as text_scan


HOST = "/" + "Users/synthetic/build"
OCTAL = "".join("\\%03o" % ord(c) for c in HOST)
UNICODE = "".join("\\u%04x" % ord(c) for c in HOST)


class MemoryFile(PurePosixPath):
    def __init__(self, name, data):
        super().__init__(name)
        self.data = data

    def with_segments(self, *segments):
        return PurePosixPath(*segments)

    def stat(self):
        return SimpleNamespace(st_size=len(self.data))

    def open(self, mode):
        assert mode == "rb"
        return io.BytesIO(self.data)

    def read_bytes(self):
        return self.data


class Relpipe5TextTests(unittest.TestCase):
    def inspect(self, name, source):
        data = source.encode() if isinstance(source, str) else source
        counts = {"metadata_files": 0, "opaque_binary_files": 0,
                  "unreviewed_text_files": 0, "opaque_metadata_fields": 0}
        privacy.inspect_metadata_file(MemoryFile(name, data), counts, False)
        self.assertEqual(counts.get("path_scanned_text_files"), 1)
        self.assertEqual(counts["unreviewed_text_files"], 1)
        return counts

    def reject(self, name, source, reason="local-path-metadata"):
        with self.assertRaisesRegex(privacy.PrivacyError, "^" + reason + "$"):
            self.inspect(name, source)

    def test_review_c_octal_through_metadata(self):
        self.reject("probe.c", f'const char *p="{OCTAL}";\n')

    def test_review_shell_ansi_through_metadata(self):
        self.reject("probe.sh", f"BUILD=$'{OCTAL}'\n")

    def test_review_uppercase_python_through_metadata(self):
        self.reject("probe.PY", f'BUILD="{UNICODE}"\n')

    def test_review_repeated_slashes_through_metadata(self):
        self.reject("probe.py", f'BUILD="//{HOST}"\n')

    def test_review_localhost_url_through_metadata(self):
        self.reject("probe.py", f'BUILD="file://localhost{HOST}"\n')

    def test_review_isystem_through_metadata(self):
        self.reject("probe.py", f'BUILD="-isystem{HOST}"\n')

    def test_python_case_variants_keep_strict_source_validation(self):
        for name in ("probe.py", "probe.PY", "probe.Py", "probe.PYI"):
            with self.subTest(name=name):
                self.reject(name, f'BUILD="{UNICODE}"\n')
                self.reject(name, "def missing(:\n", "invalid-package-python-source")
                self.inspect(name, 'BUILD="public"\n')

    def test_python_encoding_cookie_is_used(self):
        source = b'# coding: latin-1\nVALUE="caf\xe9"\n'
        text_scan.inspect_text(source, "probe.PY")
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            text_scan.inspect_text(source + b'BUILD="' + UNICODE.encode() + b'"\n', "probe.PY")
        # The outer owner currently requires metadata-decodable bytes before
        # reaching inspect_text; this pre-existing admission boundary stays.
        self.reject("probe.PY", source, "unreviewed-binary-package-entry")

    def test_python_literal_sums_and_fstrings_remain_checked(self):
        sources = ['BUILD="\\057Use" + "rs\\057synthetic\\057build"\n',
                   f'BUILD=f"{UNICODE}{{missing}}"\n',
                   f'BUILD=b"{OCTAL}"\n']
        for source in sources:
            with self.subTest(source=source):
                self.reject("probe.PY", source)

    def test_safe_python_shebang_forms(self):
        for declaration in ("/usr/bin/python3", "/usr/bin/python3.13 -I", "/usr/bin/env python3",
                            "/usr/bin/env -S python3 -I -B"):
            with self.subTest(declaration=declaration):
                self.reject("bin/tool", f'#!{declaration}\nBUILD="{UNICODE}"\n')
                self.inspect("bin/tool", f'#!{declaration}\nBUILD="public"\n')

    def test_safe_shell_shebang_forms(self):
        for declaration in ("/bin/sh", "/bin/bash -eu", "/usr/bin/env bash",
                            "/usr/bin/env -S zsh -eu"):
            with self.subTest(declaration=declaration):
                self.reject("bin/tool", f"#!{declaration}\nBUILD=$'{OCTAL}'\n")
                self.inspect("bin/tool", f'#!{declaration}\nBUILD="public"\n')

    def test_shebang_recognition_does_not_infer_arbitrary_commands(self):
        for declaration in ("/custom/python3", "/usr/bin/env X=1 python3", "/usr/bin/env -S python3 -c code",
                            "/usr/bin/env $(python3)", "/usr/bin/env wrapper python3",
                            "/usr/bin/env -S python3 --check-hash-based-pycs always", "/bin/bash --rcfile custom"):
            with self.subTest(declaration=declaration):
                self.assertEqual(literals.source_format("#!" + declaration, "tool"), "")
        self.assertEqual(literals.source_format("#!" + " " * 512 + "/bin/sh", "tool"), "")
        self.assertEqual(literals.source_format("#!/bin/sh\n", "probe.py"), ".py")

    def test_c_cpp_and_objective_c_suffixes_share_literal_decoder(self):
        # The main task owns extension admission in privacy_package. Exercise
        # its admitted suffixes end to end and the shared decoder for the rest.
        for suffix in sorted(literals.C_SOURCE_SUFFIXES):
            for spelling in (suffix, suffix.upper()):
                with self.subTest(spelling=spelling):
                    source = f'const char *p="{OCTAL}";\n'
                    if suffix in privacy.TEXT_SUFFIXES:
                        self.reject("probe" + spelling, source)
                    else:
                        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                            text_scan.inspect_text(source.encode(), "probe" + spelling)

    def test_c_adjacency_and_line_splicing_are_checked(self):
        for source in ('const char *p="\\057Use" /* public */ "rs\\057synthetic\\057build";\n',
                       'const char *p="\\057Use" \\\n "rs\\057synthetic\\057build";\n'):
            with self.subTest(source=source):
                self.reject("probe.CPP", source)

    def test_c_raw_and_double_escaped_strings_are_not_redecoded(self):
        self.inspect("probe.cpp", f'const char *p=R"tag({OCTAL})tag";\n')
        self.inspect("probe.c", 'const char *p="' + OCTAL.replace("\\", "\\\\") + '";\n')

    def test_c_comments_and_public_source_paths_are_preserved(self):
        source = f'/* const char *p="{OCTAL}"; */\n#include </usr/include/stdio.h>\n'
        source += 'const char *p="/boot/home/config/lib";\nconst char *h="/usr/include/stdio.h";\n'
        self.inspect("probe.c", source)

    def test_shell_case_variants_and_unicode_ansi_literals(self):
        for suffix in (".SH", ".BASH", ".ZSH"):
            with self.subTest(suffix=suffix):
                self.reject("probe" + suffix, f"BUILD=$'{UNICODE}'\n")

    def test_shell_constant_word_adjacency_is_checked(self):
        for source in ("BUILD=$'\\057Use'$'rs\\057synthetic\\057build'\n",
                       'BUILD=\'/Use\'"rs/synthetic/build"\n'):
            with self.subTest(source=source):
                self.reject("probe.sh", source)

    def test_shell_ordinary_quotes_and_comments_do_not_decode_ansi_text(self):
        for source in (f"BUILD='{OCTAL}'\n", f'BUILD="{OCTAL}"\n',
                       f'BUILD="$\'{OCTAL}\'"\n', f"# BUILD=$'{OCTAL}'\n",
                       "BUILD=$'" + OCTAL.replace("\\", "\\\\") + "'\n"):
            with self.subTest(source=source):
                self.inspect("probe.sh", source)

    def test_shell_variables_break_literal_concatenation(self):
        seen = []
        literals.inspect_source_literals('BUILD="/Use"${missing}"rs/synthetic/build"\n', "probe.sh", seen.append)
        self.assertNotIn(HOST, seen)
        self.assertIn("/Use", seen)
        self.assertIn("rs/synthetic/build", seen)

    def test_shell_hash_inside_assignment_does_not_start_a_comment(self):
        self.reject("probe.sh", f"BUILD=#$'{OCTAL}'\n")

    def test_python_raw_and_double_escaped_strings_are_not_redecoded(self):
        self.inspect("probe.PY", f'BUILD=r"{UNICODE}"\n')
        self.inspect("probe.PY", 'BUILD="' + UNICODE.replace("\\", "\\\\") + '"\n')

    def test_format_controls_cannot_split_a_host_root(self):
        value = "/" + "Use\u200brs/synthetic/build"
        self.reject("probe.txt", "BUILD=" + value + "\n", "unreviewed-binary-package-entry")
        self.reject("probe.py", 'BUILD="\\057Use\\u200brs\\057synthetic\\057build"\n')

    def test_repeated_root_and_component_slashes(self):
        for value in ("//" + HOST, "/" + "Users//synthetic///build", "///private//tmp///build",
                      "//opt///homebrew//build", "///usr//local///opt//build", "//Volumes//disk/build"):
            with self.subTest(parts=value.split("/")):
                self.reject("probe.txt", "BUILD=" + value + "\n")

    def test_local_file_url_variants(self):
        for value in ("file://LOCALHOST" + HOST, "file://localhost//" + HOST,
                      "file://localhost/%55sers/synthetic/build", "file://localhost/private//tmp/build",
                      "file://" + HOST):
            with self.subTest(value=value.split("/")):
                self.reject("probe.py", "BUILD=" + repr(value) + "\n")

    def test_public_urls_and_system_file_urls_are_preserved(self):
        for value in ("https://example.invalid" + HOST, "http://example.invalid//" + HOST,
                      "file://localhost/usr/include/stdio.h", "/boot//home/config/lib",
                      "share/" + "Users/public/source.c", "/usr/share/project/home/example.c"):
            with self.subTest(parts=value.split("/")):
                self.inspect("probe.py", "BUILD=" + repr(value) + "\n")

    def test_compiler_absolute_operands_are_checked(self):
        for option in ("-isystem", "-iquote", "-idirafter", "-iframework", "-isysroot", "-I", "-L", "-F"):
            for separator in ("", " ", "="):
                with self.subTest(option=option, separator=separator):
                    self.reject("probe.py", "BUILD=" + repr(option + separator + "/" + HOST) + "\n")

    def test_compiler_public_operands_and_unrelated_words_are_preserved(self):
        for value in ("-isystem/usr/include", "-isystem /usr/include", "-isystem/boot/home/config/lib",
                      "-I/include/project", "prefix-isystem" + HOST):
            with self.subTest(parts=value.split("/")):
                self.inspect("probe.py", "BUILD=" + repr(value) + "\n")

    def test_decoded_literals_use_the_same_path_operand_policy(self):
        values = ["file://localhost" + HOST, "-isystem" + HOST, "/" + HOST]
        for value in values:
            encoded = "".join("\\%03o" % ord(c) for c in value)
            with self.subTest(parts=value.split("/")):
                self.reject("probe.c", f'const char *p="{encoded}";\n')
                self.reject("probe.sh", f"BUILD=$'{encoded}'\n")

    def test_source_templates_and_upstream_shell_names(self):
        for name in ("probe.CXX.in", "probe.PY.IN"):
            with self.subTest(name=name):
                source = f'BUILD="{UNICODE}"\n' if ".PY" in name else f'const char *p="{OCTAL}";\n'
                with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                    text_scan.inspect_text(source.encode(), name)
        for name in ("configure", "test-driver"):
            with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
                text_scan.inspect_text(f"BUILD=$'{OCTAL}'\n".encode(), name)

    def test_explicit_public_allowance_does_not_mask_other_private_literals(self):
        public = "/home/public/example"
        text_scan.inspect_text(b'BUILD="/home/public/example"\n', "probe.py", allowed=(public,))
        source = f'PUBLIC="{public}"\nPRIVATE="{UNICODE}"\n'
        with self.assertRaisesRegex(privacy.PrivacyError, "local-path-metadata"):
            text_scan.inspect_text(source.encode(), "probe.py", allowed=(public,))

    def test_input_calls_and_substitutions_are_never_executed(self):
        python = 'raise AssertionError("do not execute")\nVALUE="public"\n'
        shell = 'VALUE="$(touch synthetic-marker)"\n'
        with patch("builtins.exec", side_effect=AssertionError("exec forbidden")), \
             patch("builtins.eval", side_effect=AssertionError("eval forbidden")):
            self.inspect("probe.PY", python)
            self.inspect("bin/tool", "#!/usr/bin/env -S python3 -I\n" + python)
            self.inspect("probe.SH", shell)

    def test_independent_format_parsers_recover_review_path_values(self):
        # Fixed-width octal fixture parser, AST values, URL parser and compiler
        # token splitting do not call the production decoding or path regexes.
        octal_value = "".join(chr(int(OCTAL[i + 1:i + 4], 8)) for i in range(0, len(OCTAL), 4))
        self.assertEqual(octal_value, HOST)
        python = ast.parse(f'BUILD="{UNICODE}"\n')
        self.assertEqual(python.body[0].value.value, HOST)
        url = urlsplit("file://localhost" + HOST)
        self.assertEqual((url.scheme, url.hostname, url.path), ("file", "localhost", HOST))
        operand = shlex.split("-isystem " + HOST)[1]
        self.assertEqual(operand, HOST)
        repeated = "///" + HOST.lstrip("/")
        self.assertEqual(posixpath.normpath(repeated), HOST)
        for name, source in (("probe.c", f'const char *p="{OCTAL}";\n'),
                             ("probe.sh", f"BUILD=$'{OCTAL}'\n"),
                             ("probe.PY", f'BUILD="{UNICODE}"\n'),
                             ("probe.py", "BUILD=" + repr("file://localhost" + HOST) + "\n"),
                             ("probe.py", "BUILD=" + repr("-isystem " + operand) + "\n"),
                             ("probe.py", "BUILD=" + repr(repeated) + "\n")):
            self.reject(name, source)


if __name__ == "__main__":
    unittest.main()
