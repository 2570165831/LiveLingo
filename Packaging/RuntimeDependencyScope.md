# Offline runtime dependency scope

The preparation locks describe LiveLingo's offline inference entry points, not
the full optional environment advertised by each upstream Python distribution.
Selection reads the explicit input runtimes' metadata and RECORD files; it does
not install packages or use the build host's Python packages.

## Entry points

The language worker imports `engine`, which uses MLX-LM, Transformers tokenizers
and Outlines. Its review path imports `checks` and SymPy/Pint/ChemPy formula
helpers. The App supplies local model paths. Hugging Face Xet is a remote
download transport, imported lazily by its download session; neither offline
lock needs it.

The ASR service imports NumPy, SoundFile and SciPy's signal filters. Its model
loader imports `mlx_audio.stt.utils`, then `mlx_audio.utils`, and dynamically
selects Parakeet or Qwen3-ASR. Parakeet uses MLX feature extraction and its joint
vocabulary. Qwen3-ASR's post-load hook imports `AutoTokenizer` and
`WhisperFeatureExtractor`.

The pinned ASR Transformers version imports `audio_utils` when loading Whisper's
feature extractor. That module conditionally imports **both librosa and soxr at
module scope if librosa is installed**. They must be omitted together. STT audio
reading uses `mlx_audio.audio_io`, resampling uses SciPy, and Whisper feature
extraction has its own NumPy path. Neither ASR model needs librosa in this setup.

The packaged Qwen3-ASR tokenizer configuration selects `Qwen2Tokenizer`, with
local `vocab.json` and `merges.txt` and no `auto_map`. Native BPE consumes those
files. The optional TikToken converter is a SentencePiece/other-format fallback,
not this vocab/merges path. Parakeet does not use TikToken either.

`sounddevice` and PortAudio serve optional TTS/audio-player and speech-to-speech
APIs. The App's STT path uses SoundFile instead. `pip` installs packages and is
not imported by the App's runtime paths. ASR therefore omits pip, hf-xet,
sounddevice/PortAudio, librosa, soxr and tiktoken. The language lock omits hf-xet.
Scikit-learn remains because Numba's retained OpenMP extension resolves its
native dependency to scikit-learn's bundled libomp.

These choices require an offline smoke test against each newly prepared ASR
runtime: host CPython, no host site-packages fallback, native objects verified
first, and successful transcription of a generated sample with both Parakeet
and Qwen3-ASR. Editing a lock or importing the service is not inference evidence.

## Notices and gates

License-named and metadata-declared files are collected before pruning. Leading
copyright/license comments in other pruned files are retained verbatim, inside
a prose envelope, with source, excerpt and retained-file hashes in
`runtime-preparation.json`. A failed byte comparison stops preparation. The
existing source-notice parser recognizes C comment delimiters as syntax while
real machine paths still fail the privacy gate.

`MLXLicenses/embedded-source-notices` additionally records the installed inputs'
LIBSVM, HDBSCAN and mimalloc headers. Both preparation modes copy it even when
the containing distribution already has its own wheel license.

ASR copies available exact crate-version notice directories into
`Licenses/native-cargo-notices`. Every registry source path observed in retained
Rust extensions must have hash-verified notice texts for that exact version.
Missing versions fail preparation and appear in its report. Binary paths are a
lower bound; they do not replace the broader upstream Cargo.lock inventory or
establish exhaustive linked-dependency coverage.

Common corresponding-source archives remain under `LanguageRuntime/Licenses`
in the App, without duplicate archives at unreviewed ASR paths. An accidentally
reintroduced native soxr package fails without an exact registered, hash-bound
corresponding-source archive. Outputs with missing notices are not release
inputs.
