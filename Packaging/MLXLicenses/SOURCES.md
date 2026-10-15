Pinned supplements, retrieved 2026-09-10:
- sentencepiece 0.2.2: https://raw.githubusercontent.com/google/sentencepiece/v0.2.2/LICENSE
- tokenizers 0.23.2: https://raw.githubusercontent.com/huggingface/tokenizers/v0.23.2/LICENSE

These supplement license files absent from the installed wheels. They do not by themselves constitute a complete native transitive dependency audit.

2026-09-10 additions:
- CPython-3.13.7-20250902: official full archive, verified GitHub release digest; executable/libpython file-backed Mach-O sections and UUIDs match the portable base. PROVENANCE.json contains details.
- outlines-core-0.2.14-cargo: exact local Cargo.lock registry sources and available license/notice texts. inventory.json distinguishes absent texts and includes optional/platform crates; this is not a linked-only inventory.

2026-10-11 GCC review:
- GCC-runtime-13.4.0: the complete GNU release file set in gcc-13.4.0-full.tar.xz plus the pinned Homebrew Darwin patch corresponds to the three GNU runtime libraries in the inspected SciPy 1.18.1 macOS arm64 wheel. Every file-backed Mach-O section matches the official arm64_sonoma Homebrew bottle. The former upstream subset is superseded. PROVENANCE.json records source and toolchain evidence; SOURCE-COMPLETENESS.json records all retained files, original license hashes and per-file modifications. Native arm64 compiler/libgcc/libquadmath/libgfortran configuration and real bounded builds passed offline. A separate, dated macOS host mapping patch supports the current SDK 27 check; it is not the wheel's source patch. Neither the Darwin r0 tag alone nor a byte-identical historical wheel rebuild is claimed.
