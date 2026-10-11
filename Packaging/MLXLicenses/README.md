# Bundled dependency notices and source

`runtime-manifest.json` in the enclosing LanguageRuntime records pinned Python packages and their direct license files. `AUDIT.json` records the verified collection scope.

- `native-source-notices`: exact Python source release notices; MLX uses its identified upstream Git revision.
- `native-cargo-notices`: exact Cargo.lock union and notice hashes. Optional, build and platform entries are included for coverage; this does not assert every crate is linked. MPL/CDDL source archives are under CorrespondingSource.
- `mlx-0.32.2-native`: MLX, Metal C++, fmt, JSON, nanobind and robin-map notices and source provenance.
- `CPython-3.13.7-20250902`: portable Python and upstream bundled dependency notices.
- `GCC-runtime-13.4.0`: source archive and runtime license/exception texts for SciPy's GNU runtime dependencies; see its provenance limitation.
- `ASR-audio`: publisher notices, exact binary provenance and LGPL library sources. The build script and darwin.cmake are inside the libsndfile archive. Four optional BSD-only codec archives are omitted; all their notices remain. Original and prepared archive hashes are separate in inventory.json.

Sources are included for inspection and rebuilding the corresponding third-party components. The original upstream build recipes are retained; a byte-identical rebuild is not asserted. Dynamically loaded library files are present in the portable Python directories. A modified local App will require a fresh local code signature before macOS can run it. No additional restriction on rights granted by the respective third-party licenses is intended.

Packaging/SourceArchiveAudit.json records source subset preparation, preserved license hashes, removed tests/docs/unbundled compiler components and comment example edits. Packaging/PrivacyResources.json binds each reviewed resource to its complete App-relative path and SHA-256. Source archives are recursively inspected without extraction or execution; unknown binaries and private metadata remain rejected. These are static checks, not evidence of a matching rebuilt binary. Cargo attribution declarations retain package/license/author provenance, with dependency and feature build tables omitted. Filenames accidentally matched by the old notice collector (such as LicenseProtection implementation modules) are listed separately in the collection inventory. Pillow notices originally below Tests are preserved byte-for-byte under test-notices with their upstream paths recorded.
