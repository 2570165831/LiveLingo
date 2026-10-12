# LiveLingo offline package — third-party notices

This personal-use transfer image bundles third-party software and model weights.
The following projects retain their own copyrights and licenses.

Layout note: earlier packages used a `Payload/` transfer layout with
`Payload/ASRService/...` and `Payload/Models/...`. The current pipeline does not
create a `Payload` directory; the same content is placed inside the app as
`Contents/Resources/ASRRuntime/...` and `Contents/Resources/Models/...`. The
legacy `Packaging/install.command` and `Packaging/verify.command` scripts still
describe that older layout and are kept only for reference. No license text or
corresponding source is removed by this note.

| Component | Source | License |
|---|---|---|
| Parakeet TDT 0.6B v2, MLX conversion | `mlx-community/parakeet-tdt-0.6b-v2`, converted from `nvidia/parakeet-tdt-0.6b-v2` | CC BY 4.0 |
| Qwen3-ASR 1.7B 4-bit, MLX conversion | `mlx-community/Qwen3-ASR-1.7B-4bit`, converted from `Qwen/Qwen3-ASR-1.7B` | Apache-2.0 |
| Qwen3.5 4B MLX 8-bit | `mlx-community/Qwen3.5-4B-MLX-8bit`, converted from `Qwen/Qwen3.5-4B` | Apache-2.0 |
| Qwen3.5 9B MLX 4-bit | `lmstudio-community/Qwen3.5-9B-MLX-4bit`, converted from `Qwen/Qwen3.5-9B` | Apache-2.0 |
| MLX, mlx-audio and bundled Python packages | Package metadata inside the portable Python runtime | Their respective package licenses |
| Python standalone runtime | `astral-sh/python-build-standalone`, CPython and bundled dependencies | License files under `Contents/Resources/ASRRuntime/python/lib/python3.13/`, the collected `Contents/Resources/ASRRuntime/Licenses/`, and package metadata |
ASR MLX 0.32.2 was built unmodified from upstream commit
`1f8e74e3f12f31365464a6867c6579f0e9b29d85` with macOS 14 deployment target.

Model cards are retained inside model directories when supplied by the downloaded
artifact. Source pages:

- https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2
- https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit
- https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-8bit
- https://huggingface.co/lmstudio-community/Qwen3.5-9B-MLX-4bit
- https://github.com/astral-sh/python-build-standalone/releases

The Apache License 2.0 text is available at
https://www.apache.org/licenses/LICENSE-2.0 and the CC BY 4.0 legal code at
https://creativecommons.org/licenses/by/4.0/legalcode.

## Managed language runtime

This package replaces the LM Studio installation and language inference dependency with MLX 0.32.2, MLX-LM 0.31.3 and Outlines 1.3.3 / Outlines Core 0.2.14. It uses Pint 0.25.3, SymPy 1.14.0 and the formula/composition portion of ChemPy 0.10.1. Notebook, plotting and ODE solver APIs are not exposed or bundled as a general ChemPy environment. Runtime versions and collected license files are recorded in `LanguageRuntime/runtime-manifest.json` and `LanguageRuntime/Licenses`.

Outlines Core 0.2.14 is rebuilt from the original source with macOS deployment target 14.0 and release stripping disabled; MLX uses the separately audited macOS 14 build. The application implements its own request scheduler, checkpoint format, bounded calculation input parser and advice display. Anarlog's community diff presentation informed the UI concept; no Anarlog enterprise implementation is included.

No LM Studio installer or runtime is included. The `lmstudio-community` model-directory name identifies the model publisher, not a dependency on the LM Studio application.

The App carries offline direct and transitive notices at `Contents/Resources/LanguageRuntime/Licenses`, with `AUDIT.json`, per-component provenance and source archive checksums. Cargo.lock coverage includes optional/build/platform dependencies and is not a claim that every listed crate is linked. Source archives for selected reciprocal-license components are included there. See the local README and respective license texts for details.

Compatibility, signing, notarization and runtime acceptance are recorded separately; this notice is not a release test certificate.

## Prepared third-party copies (Li, 2026-10-11)

The project modifies distribution copies only. File names, changes, dates,
reasons and before/after hashes are bundled in the following relative notices:

During assembly, Li's packaging step on 2026-10-11 also changes
`ASRRuntime/python/lib/python3.13/site-packages/numba/np/ufunc/omppool.cpython-313-darwin.so`:
its `@rpath/libomp.dylib` dependency becomes
`@loader_path/../../../sklearn/.dylibs/libomp.dylib`, resolving the OpenMP library
already shipped in the app. The upstream library implementation is unchanged;
this is a native load-command change, without signing.

- `LanguageRuntime/Licenses/source-preparation/SourceArchiveAudit.json` and each source archive's `MODIFICATIONS.json`: home-directory examples are neutralized in GCC/libstdc++ headers and upstream documentation. Inferno's complete inline test modules are restored; one Windows home-directory fixture is neutralized. The complete GNU GCC 13.4.0 release, including all original source files, frontends, regression data, configure inputs and generated manuals, is retained with the exact Homebrew Darwin patch and its production bottle formula. The source definition is the GNU release plus that patch; the Darwin fork tag alone is not an exact substitute. Other source archives' omissions are recorded individually. Original copyright/license bytes are preserved.
- `LanguageRuntime/MODIFICATIONS.json` and `ASRRuntime/python/MODIFICATIONS.json`: Python source encoding is normalized with the AST unchanged; modified Python files carry a dated comment. Optional package descriptions, installation records and certificate labels are prepared for distribution; certificate blocks are unchanged. Native library IDs/dependencies use portable load paths. This does not change their upstream copyright or license.
- Each `Models/<publisher>/<model>/MODIFICATIONS.json`: unused Qwen3.5 translation chat-template metadata is removed because LiveLingo supplies its prompts; Parakeet's unused training tokenizer directory metadata and unused training tokenizer model and vocabulary are omitted because the loader uses its retained joint vocabulary. Weights and retained inference vocabularies are unchanged; publisher attribution and the Apache-2.0 / CC BY 4.0 license notices remain applicable. Each model's scope is derived from its own recorded changes; an empty change list records no model-file modifications.

Additional native preparation by Li on 2026-10-12 strips debug symbols and
remaps diagnosed Rust/Cython source-location strings. MLX's build-only last
metallib fallback is disabled; its preceding packaged-resource lookups remain.
All instructions and file-backed sections outside the recorded cstring changes
are unchanged. The runtime modification records bind the actual before/after
hashes, including ad-hoc signatures applied before host import checks.
`LanguageRuntime/Licenses/native-build-paths/README.md` describes these changes
and their static validation limits. This does not assert runtime acceptance.

The original publisher libsndfile build recipe is retained, and an additional
`LanguageRuntime/Licenses/ASR-audio/offline-rebuild.sh` uses all bundled static
codec sources. Its path is resolved independently of the caller's directory.

A static comparison of the retained fixed publisher libsndfile arm64 asset
(SHA-256 `e9fd4d76bc457dcfb956617e8d467df85087ce069747fccd78e1e702d8629c14`)
and the reviewed runtime input
(SHA-256 `6ef1f1c0a4ccbc72210ff55e3df6addc682f873e68aff3e7218e92ccc294da93`)
confirmed equality of all 11 file-backed sections, including code and data.
Of 15 load commands, 13 are byte-identical; only the `__LINKEDIT` file size and
`LC_CODE_SIGNATURE` data size differ, reflecting the changed signature allocation.
All other bytes before the signature are identical. The publisher asset carries
an ad-hoc linker signature; the reviewed input carries different CodeDirectory
metadata, a requirements blob and a CMS blob. All code-page hashes in both
CodeDirectories match their respective file bytes. Whole-file exactMatch remains false.
This explains the static byte differences for these two fixed hashes; it does
not verify signer trust, signing history, platform acceptance or a byte-identical
source rebuild. A different input hash requires a new comparison. The repository
provenance JSON remains a pending reference. Assembly binds the real input and
final hashes in the copied package notice. Later native signing must rebind that
notice before the outer App resource seal; the final gate requires this binding.

## OpenCC Chinese variant dictionaries

Unmodified data/configuration and conversion test fixtures from
[BYVoid/OpenCC](https://github.com/BYVoid/OpenCC/tree/ver.1.1.9), tag `ver.1.1.9`,
commit `556ed22496d650bd0b13b6c163be9814637970ae`, are redistributed under Apache-2.0.
The full license and project-written attribution are bundled at
`Contents/Resources/ZhVariants/LICENSE` and `NOTICE`. Upstream has no root NOTICE
in this tag. `SOURCE.json` records all source URLs and SHA-256 values.
The Apache-2.0 copyright and patent grants are retained; these files are
combined with this GPL-3.0 application without relicensing the upstream data.

| Bundled upstream file | SHA-256 |
|---|---|
| `LICENSE` | `b534e465949558eec2597b04f5092b5e161236a68dfbfd04d547592ac3964308` |
| `STPhrases.txt` | `17fece21a28f3db2dc32397abd73d21ae73261c3f295fa6a3fe64b5e8d8b554b` |
| `STCharacters.txt` | `ed1d268e0ad028511dcf5b0089faed0a980ad332449ec11d481ceefde6879f41` |
| `TWVariants.txt` | `30e6f8395edbfdd74e293fd8b9c62105d787c849fbb208d2a7832eac696734d7` |
| `HKVariants.txt` | `c3c93c35885902ba2b12a3235a7761b00fb2b027f36aa8314db2f6b6ad51d374` |
| `TWPhrasesIT.txt` | `3a4a2ad207f3a9442eb8f399630cf982c2ffc561df9c58b2ee352cfa023915c1` |
| `TWPhrasesName.txt` | `76e643569a30ea54e7ab6e52621fd4c396e01ee6dc2d15b7d25bf23addf4438a` |
| `TWPhrasesOther.txt` | `6d0365fd180283f3e14b44f63d19d1aca045d60b0e000765902ad889a90d7a33` |
| `s2tw.json` | `67ce1f5aa3d6b21ebb523084b40e66f80bec27bb2dc6b540d44dac2e27f7194e` |
| `s2hk.json` | `3708e756ea01783e9cf6b3cce527580810b3d539b8c7fcc3594dd1517aa05bff` |
| `s2twp.json` | `72d187574510542be608c862d5359d29480ee61f137082df8a06d74f7bcfc79c` |

The four separate LiveLingo-authored phrase/subject tables contain 75 entries
(including 24 identity/protection entries). Each entry cites a public Ministry
of Education, National Academy for Educational Research, or Hong Kong Education
Bureau terminology source. Only short factual terms are recorded; definitions
and complete source glossaries are not redistributed. Project tables are part
of this GPL-3.0 application; upstream OpenCC files remain Apache-2.0.

用语经大模型审阅，非母语者人工审校。 Review used 356 synthetic sentences;
this is LLM review, not native-speaker certification. SOURCE.json records each
project table's SHA-256, size and count. Converter version livelingo-v2 identifies
the new project tables independently of the unchanged upstream ver.1.1.9.
