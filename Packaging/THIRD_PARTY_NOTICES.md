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

The separate project phrase/subject tables contain no active mappings. Their
commented examples await Taiwan and Hong Kong/Macau native-speaker review.
