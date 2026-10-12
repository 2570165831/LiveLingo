# Release pipeline static validation, 2026-10-12

The release branch incorporates lab commit `1c33933` through merge `a4180a1`.
The eight review findings are addressed by the following bounded changes.

| Finding | Change and verification |
| --- | --- |
| R1 | Scan the whole Mach-O for readable build paths. Strip debug symbols and remap only diagnosed Rust/Cython cstrings; disable MLX's build-only last metallib fallback. Independent comparisons cover 103 repaired objects and 1075 file-backed sections, plus all 74 sections of the fresh universal Release main. Instructions and all bytes outside registered cstring edits remain unchanged. |
| R2 | Decode identified Python, C-family and shell literal syntax statically, with case-insensitive suffixes and limited shebang recognition. Check repeated separators, local file URLs and compiler path operands without evaluating input. |
| R3 | Inspect raw PAX records, fixed tar fields, member padding and all bytes after the end blocks. Check opaque member bytes, gettext tables and Mach-O commands. Public GNU test fixtures require exact member hashes and documented exact examples. |
| R4 | Capture the real ASR input hash before assembly, finalize after all copies and native edits, and require final binding in the default App gate. Missing, pending and schema-1 notices fail. The signing tool rebinds after native signing and before the outer resource seal; that order is tested with mocks, without signing. |
| R5 | Compare the retained fixed publisher libsndfile asset with the actual input. All 11 file-backed sections match. Differences outside the signature are only two signature allocation fields. Keep whole-file equality false and bind the historical comparison to its exact input hash. |
| R6 | Separate framework/client/library names from path-valued Mach-O commands and inspect full raw command payloads, including bytes before string offsets and after NUL terminators. |
| R7 | Share C-family suffix definitions with metadata fallback. Valid C++ attributes remain source while complete structured metadata retains strict duplicate-key checks. |
| R8 | Derive each model notice from its own recorded changes. Describe complete GNU base source plus exact Darwin patches, and distinguish omitted Parakeet training data from retained inference vocabularies and weights. |

The privacy resource index binds 46 specific native files and 5009 exact public
upstream build strings. It contains no directory-wide, suffix-wide or path-prefix
approval. Load commands remain strict. Twenty-one GNU binary test members and
one additional spelling of an already reviewed Windows URI are approved only
under their full member hashes. The matching packaged index must be identical
to the repository index.

Task-confined tests may explicitly select a dedicated directory below ignored
`work`. Source directories, the checkout/work roots, traversal, symlink escapes
and existing output files remain protected. The review index uses held directory
descriptors so it does not probe ancestors above a caller's filesystem grant.

This is static release preparation. Candidate programs are not run. Host Python
may import prepared extensions only after strict signature verification; modified
extensions are ad-hoc signed first. No Developer ID signing, notarization,
installation, VM acceptance or publication is included. After future signing,
the complete native approval hashes must be reviewed and updated for the signed
bytes, then the final package gate must run again.

The offline GNU source check builds a current native arm64 compiler and three
runtime libraries. It does not reproduce the historical publisher toolchain
byte for byte. Static wheel/bottle comparisons establish equality of all 50
file-backed sections in the six packaged GNU runtime libraries, not whole-file
or historical build equality. All task logs and cleanup proposals remain under
ignored `work/relpipe/relpipe5`; no cleanup is performed by this task.
