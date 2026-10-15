"""In-memory source-pruning regressions; never launch a bundled runtime."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import unittest
from unittest.mock import Mock

from Scripts.embedded_notices import MAX_HEADER_BYTES, collect_notices, extract_notice


class ExtractNoticeTests(unittest.TestCase):
    def test_pruned_h_stops_before_preprocessor_and_source_body(self):
        header = (b"/* Copyright (c) A unique header contributor\n"
                  b" * Licensed under the MIT license; see LICENSE.\n */\n")
        data = header + b"#pragma once\n#define X 1\nint copyright_value;\n"
        self.assertEqual(extract_notice(data), header)

    def test_pruned_cpp_preserves_credits_in_consecutive_blocks(self):
        header = (b"/* Copyright Original contributor\nAll rights reserved.\n*/\n\n"
                  b"/* Modified by Another contributor: dense support. */\n")
        self.assertEqual(extract_notice(header + b'#include "svm.h"\n'), header)

    def test_pruned_pxd_keeps_separate_hash_paragraphs_and_full_disclaimer(self):
        header = (b"# Copyright (c) 2015, A distinct contributor\n"
                  b"# All rights reserved.\n\n"
                  b"# Redistribution and use in source and binary forms,\n"
                  b"# with or without modification, are permitted.\n\n"
                  b"# 1. Retain this copyright notice.\n\n"
                  b"# THIS SOFTWARE IS PROVIDED AS IS.\n"
                  b"# NO LIABILITY FOR CONSEQUENTIAL DAMAGES.\n")
        source = (b"\nfrom sklearn.utils cimport helper\n"
                  b"# Copyright found only inside implementation\n"
                  b"cdef struct NODE:\n    int value\n")
        self.assertEqual(extract_notice(header + source), header)

    def test_unique_copyright_is_kept_without_a_license_keyword(self):
        header = b"// Copyright 2026 Unique human contributor\n"
        self.assertEqual(extract_notice(header + b"int run();\n"), header)

    def test_spdx_only_comment_is_a_notice(self):
        header = b"// SPDX-License-Identifier: BSD-3-Clause\n"
        self.assertEqual(extract_notice(header + b"void run();\n"), header)
        self.assertEqual(extract_notice(b"# SPDX-FileCopyrightText: 2026 Human\n"),
                         b"# SPDX-FileCopyrightText: 2026 Human\n")

    def test_permission_and_public_domain_without_copyright(self):
        for header in (b"/* Permission is hereby granted to copy. */\n",
                       b"! Dedicated to the public domain.\n"):
            with self.subTest(header=header):
                self.assertEqual(extract_notice(header + b"      END\n"), header)

    def test_raw_bytes_bom_crlf_tabs_and_non_ascii_survive(self):
        for name in ("François".encode(), b"Fran\xe7ois"):
            header = b"\xef\xbb\xbf\t/* Copyright " + name + b"\r\n * License: BSD\r\n */ \r\n"
            self.assertEqual(extract_notice(header + b"int value;\r\n"), header)

    def test_shebang_encoding_and_python_header_are_preserved(self):
        header = (b"#!/usr/bin/env python3\n# coding: latin-1\n\n"
                  b"# Copyright Fran\xe7ois\n# See LICENSE for terms.\n")
        self.assertEqual(extract_notice(header + b"import os\n"), header)

    def test_fortran_free_and_fixed_form(self):
        for marker in (b"!", b"C", b"c", b"*"):
            header = marker + b" Copyright Fortran contributor\n\n" + marker + b" All rights reserved.\n"
            self.assertEqual(extract_notice(header + b"      SUBROUTINE RUN()\n"), header)

    def test_template_comment_delimiters(self):
        for opening, closing in ((b"<!--", b"-->"), (b"{#", b"#}"),
                                 (b"<%--", b"--%>"), (b"<%doc>", b"</%doc>"),
                                 (b"{% comment %}", b"{% endcomment %}")):
            header = opening + b" Copyright Template contributor " + closing + b"\n"
            self.assertEqual(extract_notice(header + b"<div>{{ value }}</div>\n"), header)

    def test_source_on_same_line_is_never_part_of_excerpt(self):
        header = b"/* Copyright Header contributor */"
        self.assertEqual(extract_notice(header + b" int copyright_body;\n"), header)

    def test_source_preceding_notice_is_not_scanned(self):
        for source in (b"import os\n", b"int value;\n", b"#include <stdio.h>\n",
                       b"# define NAME Copyright\n", b"#pragma once\n",
                       b"C = 'Copyright in an assignment'\n", b"class Copyright:\n",
                       b'"""Copyright in a Python docstring."""\n'):
            with self.subTest(source=source):
                self.assertIsNone(extract_notice(source + b"# Copyright Too late\n"))

    def test_c_preprocessor_after_slash_comment_stops_the_region(self):
        for directive in (b"#include <x.h>\n", b"# define X 1\n", b"#if 1\n"):
            header = b"// Copyright Header owner\n"
            self.assertEqual(extract_notice(header + directive + b"// implementation\n"), header)

    def test_other_languages_comment_markers_do_not_swallow_source(self):
        header = b"/* Copyright C contributor */\n"
        for source in (b"!value;\n", b"* value = 1;\n", b"C value;\n"):
            self.assertEqual(extract_notice(header + source), header)
        header = b"# Copyright Python contributor\n"
        for source in (b"c = 1\n", b"!command\n", b"* values, = sequence\n"):
            self.assertEqual(extract_notice(header + source), header)

    def test_c_block_and_slash_comments_may_mix(self):
        header = b"/* Copyright C contributor */\n// Modified by Human contributor\n"
        self.assertEqual(extract_notice(header + b"void run();\n"), header)

    def test_ordinary_or_empty_comments_do_not_qualify(self):
        for data in (b"", b" \n", b"# Helpers and implementation notes\nvalue=1\n",
                     b"/* An ordinary comment. */\nint value;\n"):
            self.assertIsNone(extract_notice(data))

    def test_binary_and_control_characters_are_rejected(self):
        for data in (b"\x7fELF\0Copyright contributor", b"# Copyright contributor\0\n",
                     b"/* Copyright contributor */\n\x00\x01",
                     b"# Copyright contributor\x7f\n", b"# Copyright contributor\x85\n",
                     "# Copyright contributor\n".encode("utf-16")):
            self.assertIsNone(extract_notice(data))

    def test_unclosed_or_overlong_comments_are_not_truncated(self):
        self.assertIsNone(extract_notice(b"/* Copyright contributor\n"))
        self.assertIsNone(extract_notice(b"/* Copyright A */\n/* unfinished"))
        self.assertIsNone(extract_notice(b"# Copyright " + b"x" * MAX_HEADER_BYTES + b"\n"))
        self.assertIsNone(extract_notice(b"/* Copyright " + b"x" * MAX_HEADER_BYTES + b"*/"))

    def test_short_header_on_large_source_is_eligible(self):
        header = b"/* Copyright Large source contributor */\n"
        self.assertEqual(extract_notice(header + b"int value;\n" * MAX_HEADER_BYTES), header)

    def test_complete_notice_at_header_limit_and_without_newline(self):
        header = b"/* Copyright " + b"x" * (MAX_HEADER_BYTES - len(b"/* Copyright */")) + b"*/"
        self.assertEqual(len(header), MAX_HEADER_BYTES)
        self.assertEqual(extract_notice(header + b"int value;"), header)
        self.assertEqual(extract_notice(b"# Copyright Last line"), b"# Copyright Last line")


class CollectNoticeTests(unittest.TestCase):
    library = PurePosixPath("lib/python3.13")
    site = library / "site-packages"

    def collect(self, files, selected=()):
        reader = Mock(side_effect=files.__getitem__)
        result = collect_notices(files, reader, stdlib=self.library, selected_files=selected)
        return result, reader

    def test_removed_locked_pxd_h_and_src_keep_distinct_copyrights(self):
        names = ("sklearn/cluster/_hdbscan/_tree.pxd", "sklearn/svm/src/libsvm/svm.cpp",
                 "numpy/include/numpy/unique.h")
        files = {str(self.site / name): f"# Copyright Unique owner {i}\n".encode() + b"int value;\n"
                 for i, name in enumerate(names)}
        notices, reader = self.collect(files, selected=names)
        self.assertEqual(len(notices), len(names))
        self.assertEqual(reader.call_count, len(names))
        for row in notices:
            source = files[row.source]
            self.assertEqual(row.data, source.splitlines(keepends=True)[0])
            self.assertEqual(row.source_sha256, hashlib.sha256(source).hexdigest())
            self.assertEqual(row.notice_sha256, hashlib.sha256(row.data).hexdigest())

    def test_tests_examples_and_arbitrary_text_suffixes_are_covered(self):
        names = ("extra/dev.pxd", "locked/tests/a.h", "locked/Test/a.h", "locked/examples/a.pyx",
                 "locked/test_single.py", "locked/benchmarks/a.f90", "locked/demo/a.in",
                 "locked/tests/fixture.data", "locked/examples/extensionless")
        files = {str(self.site / name): b"# Copyright excluded\n" for name in names}
        notices, reader = self.collect(files, selected=names[1:])
        self.assertEqual([row.source for row in notices], sorted(str(self.site / name) for name in names[1:]))
        self.assertEqual(reader.call_count, len(names) - 1)
        self.assertNotIn(str(self.site / names[0]), [call.args[0] for call in reader.call_args_list])

    def test_entirely_unlocked_packages_not_read(self):
        files = {str(self.site / "extra/dev.pxd"): b"# Copyright excluded\n"}
        notices, reader = self.collect(files)
        self.assertEqual(notices, [])
        reader.assert_not_called()

    def test_exact_record_membership_does_not_allow_package_neighbors(self):
        files = {str(self.site / "locked/missing.pxd"): b"# Copyright neighbor\n"}
        notices, reader = self.collect(files, selected=["locked/retained.py"])
        self.assertEqual(notices, [])
        reader.assert_not_called()

    def test_all_removed_paths_outside_site_packages_are_eligible(self):
        files = {name: b"/* Copyright Standard library contributor */\nint value;\n" for name in (
            "include/python3.13/internal/mimalloc/mimalloc.h", "lib/python3.13/unused.py",
            "lib/python3.13/config-3.13/config.c", "bin/build.py", "share/example.h",
            "lib/python3.13/tests/test_data.h", "lib/python3.13/opaque.so")}
        notices, reader = self.collect(files)
        self.assertEqual([row.source for row in notices], sorted(files))
        self.assertEqual(reader.call_count, len(files))

    def test_output_is_sorted_deduplicated_and_keeps_per_source_provenance(self):
        data = b"# Copyright Shared header contributor\nvalue=1\n"
        paths = [self.library / "z.py", self.library / "a.py", self.library / "z.py"]
        reader = Mock(return_value=data)
        notices = collect_notices(paths, reader, stdlib=self.library, selected_files=[])
        self.assertEqual([row.source for row in notices], [str(self.library / "a.py"), str(self.library / "z.py")])
        self.assertEqual(reader.call_count, 2)
        self.assertEqual(notices[0].notice_sha256, notices[1].notice_sha256)

    def test_non_notices_return_no_rows(self):
        notices, reader = self.collect({str(self.library / "ordinary.py"): b"value=1\n"})
        self.assertEqual(notices, [])
        reader.assert_called_once()

    def test_unsafe_paths_rejected_before_any_read(self):
        for path in ("/private/source.py", "../source.py", "lib/../../source.py", "lib//source.py",
                     "lib/./source.py", "lib\\source.py", "C:/source.py", "lib/source\n.py", ""):
            reader = Mock()
            with self.subTest(path=path), self.assertRaises(ValueError):
                collect_notices([path], reader, stdlib=self.library, selected_files=[])
            reader.assert_not_called()

    def test_callback_failure_is_not_silently_skipped(self):
        with self.assertRaises(FileNotFoundError):
            collect_notices([self.library / "removed.py"], Mock(side_effect=FileNotFoundError),
                            stdlib=self.library, selected_files=[])


class SupplementTests(unittest.TestCase):
    root = Path(__file__).resolve().parent.parent / "Packaging/MLXLicenses/embedded-source-notices"

    def test_supplement_excerpts_and_provenance_are_portable_and_hash_bound(self):
        manifest = json.loads((self.root / "PROVENANCE.json").read_bytes())
        excerpts = manifest["notices"]
        self.assertEqual({row["source"] for row in excerpts}, {
            "Contents/Resources/ASRRuntime/python/include/python3.13/internal/mimalloc/mimalloc.h",
            "Contents/Resources/LanguageRuntime/python/include/python3.13/internal/mimalloc/mimalloc.h",
            "Contents/Resources/ASRRuntime/python/lib/python3.13/site-packages/sklearn/svm/src/libsvm/svm.cpp",
            "Contents/Resources/ASRRuntime/python/lib/python3.13/site-packages/sklearn/cluster/_hdbscan/_tree.pxd",
        })
        self.assertEqual(len(excerpts), 4)
        for row in excerpts:
            self.assertFalse(PurePosixPath(row["source"]).is_absolute())
            self.assertNotIn("..", PurePosixPath(row["source"]).parts)
            self.assertRegex(row["source_sha256"], r"^[0-9a-f]{64}$")
            data = (self.root / row["copy"]).read_bytes()
            self.assertTrue(data.startswith(b"Verbatim source header notice:\n\n"))
            self.assertEqual(hashlib.sha256(data).hexdigest(), row["file_sha256"])
            self.assertEqual(len(data), row["file_bytes"])
            self.assertEqual(row["excerpt_offset"], len(b"Verbatim source header notice:\n\n"))
            raw = data[row["excerpt_offset"]:]
            self.assertEqual(hashlib.sha256(raw).hexdigest(), row["excerpt_sha256"])
            self.assertEqual(len(raw), row["excerpt_bytes"])
            self.assertEqual(extract_notice(raw), raw)
        all_text = b"\n".join(path.read_bytes() for path in self.root.rglob("*") if path.is_file())
        for token in (b"/Users/", b"/Applications/", b"/private/", b"Generated by", b"Co-Authored-By"):
            self.assertNotIn(token, all_text)

    def test_hdbscan_full_disclaimer_and_libsvm_human_credits_survive(self):
        hdbscan = (self.root / "hdbscan-tree.pxd.notice.txt").read_bytes()
        self.assertIn(b"Leland McInnes", hdbscan)
        self.assertIn(b"# POSSIBILITY OF SUCH DAMAGE.\n", hdbscan)
        self.assertNotIn(b"cimport", hdbscan)
        libsvm = (self.root / "libsvm-svm.cpp.notice.txt").read_bytes()
        self.assertIn(b"Chih-Chung Chang and Chih-Jen Lin", libsvm)
        self.assertIn("Juan Martín Loyola".encode(), libsvm)
        self.assertNotIn(b"#include", libsvm)

    def test_shared_mit_terms_are_complete_verbatim_and_hash_bound_to_local_source(self):
        repo = Path(__file__).resolve().parent.parent
        manifest = json.loads((self.root / "PROVENANCE.json").read_bytes())
        self.assertEqual(len(manifest["shared_license_terms"]), 1)
        row = manifest["shared_license_terms"][0]
        self.assertEqual(row["source_root"], "repository")
        self.assertEqual(row["source"],
                         "Packaging/MLXLicenses/native-cargo-notices/libc-0.2.189/LICENSE-MIT")
        self.assertEqual(row["copy"], "MIT-TERMS.txt")
        source = (repo / row["source"]).read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), row["source_sha256"])
        self.assertEqual(len(source), row["source_bytes"])
        inventory = json.loads((repo / "Packaging/MLXLicenses/native-cargo-notices/inventory.json").read_bytes())
        component = next(item for item in inventory["components"]
                         if item["name"] == "libc" and item["version"] == "0.2.189")
        original = next(item for item in component["texts"] if item["path"] == "libc-0.2.189/LICENSE-MIT")
        self.assertEqual(row["source_sha256"], original["sha256"])
        self.assertIn(b"Copyright (c) The Rust Project Developers", source)
        self.assertEqual(row["source_excerpt_offset"], source.index(b"Permission is hereby granted"))
        raw = source[row["source_excerpt_offset"]:]
        data = (self.root / row["copy"]).read_bytes()
        self.assertEqual(data[row["excerpt_offset"]:], raw)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), row["excerpt_sha256"])
        self.assertEqual(len(raw), row["excerpt_bytes"])
        self.assertEqual(hashlib.sha256(data).hexdigest(), row["file_sha256"])
        self.assertEqual(len(data), row["file_bytes"])
        self.assertTrue(raw.startswith(b"Permission is hereby granted"))
        self.assertIn(b"The above copyright notice and this permission notice", raw)
        self.assertIn(b'THE SOFTWARE IS PROVIDED "AS IS"', raw)
        self.assertTrue(raw.endswith(b"DEALINGS IN THE SOFTWARE.\n"))

    def test_shared_terms_reference_does_not_replace_or_misattribute_mimalloc_copyright(self):
        manifest = json.loads((self.root / "PROVENANCE.json").read_bytes())
        row = manifest["shared_license_terms"][0]
        data = (self.root / row["copy"]).read_bytes()
        description = data[:row["excerpt_offset"]]
        self.assertIn(b"local reference", description)
        self.assertIn(b"libc-0.2.189/LICENSE-MIT", description)
        self.assertIn(b"not a copy of mimalloc's original LICENSE", description)
        reference = manifest["external_license_references"][0]
        self.assertEqual(reference["local_terms_reference"], "MIT-TERMS.txt")
        self.assertIs(reference["original_license_copy"], False)
        mimalloc = (self.root / "mimalloc.h.notice.txt").read_bytes()
        self.assertEqual(hashlib.sha256(mimalloc).hexdigest(),
                         "b015fde7dab5af50931049c26f2ce56ff01d358193d5bbd21430227cd4760285")
        self.assertIn(b"Copyright (c) 2018-2023, Microsoft Research, Daan Leijen", mimalloc)


if __name__ == "__main__":
    unittest.main()
