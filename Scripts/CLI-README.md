# LiveLingo test CLI

This CLI compiles the production AppModel, SpeechPipeline, ASR/translation clients,
summary policies and exporter directly. CLI-only entry points are behind
`LIVELINGO_CLI`; the normal app does not include them. It neither launches nor
replaces `/Applications/LiveLingo.app`.

A CLI build runs outside the app bundle, so it has no bundled ASR service and no
bundled MLX runtime of its own. Point it at local resources explicitly instead
of relying on defaults:

- Place `ASRRuntime/` and `Models/` beside the executable, or inside its isolated
  bundle. The CLI starts and verifies its own loopback ASR child process.
  External ASR endpoint/token overrides and resources inside `/Applications`
  are rejected; do not use the installed app as a test runtime.
- `LIVELINGO_MLX_PYTHON`, `LIVELINGO_MLX_WORKER` and `LIVELINGO_MLX_MODELS`
  select local MLX language resources outside `/Applications`. Preferences,
  data and MLX checkpoint state are isolated under each new output directory.

The language runtime is MLX, one owned process per model; LM Studio is not used
and no LM Studio service is required. Read-only model files may be reused, but
test processes and their writable state belong to this run. Do not run a replay
alongside a real recording or use the legacy service script for this CLI.

Build into a new directory:

```sh
bash Scripts/build-cli.sh /absolute/path/to/new-cli-build
```

To reuse an existing compatible Swift module cache, pass
`--module-cache /absolute/path/to/existing-cache`. The output directory must
still be new. `--lifecycle-tests` can be combined with this option. Headless
commands cancel any UI-only file chooser path without presenting a window.

Silent real-time replay (no audio output device is opened):

```sh
/absolute/path/to/new-cli-build/livelingo-cli \
  --replay /absolute/path/to/lesson.wav \
  --output /absolute/path/to/new-test-session \
  --high-quality > events.ndjson 2> errors.log
```

Real system-audio capture:

```sh
/absolute/path/to/new-cli-build/livelingo-cli \
  --system-audio 30 \
  --output /absolute/path/to/new-capture-session \
  --high-quality > capture-events.ndjson 2> capture-errors.log
```

The CLI itself never plays sound in either mode. System-audio mode captures
currently playing system audio and needs macOS recording permission; refusal is
an error, not a passing test. Silent replay bypasses ScreenCaptureKit capture
and injects PCM into the same post-capture writer, segmentation, preview,
transcription, translation, summary and stop/export pipeline. Replay cannot
prove physical/system-audio routing or GUI layout.

`--high-quality` selects the production 9B profile; omission selects 4B.
Apple preview uses an installed English-to-Simplified-Chinese translation
session on macOS 26+, without a SwiftUI translation task. Availability errors
remain distinct from formal Qwen translation. Neither this mechanism nor the
CLI claims macOS 14 preview support.

The output directory must not already exist. A run saves recording.wav,
transcripts, bilingual JSONL/SRT, manifest and available cumulative summary.
JSON lines include elapsed time and caption/translation/summary counts. Routine
events omit classroom text; exported transcripts and model diagnostic artifacts
remain private classroom material. Keep them with the test data.
`processing_finished` means the existing export workflow finished: inspect coverage and
failure markers separately, because the production workflow can save an
incomplete summary. Capture duration accepts finite values from 0 (exclusive)
to 3600 seconds. Replay duration is the input file's duration.

Only a zero exit status together with `run_verified` and confirmed runtime
cleanup is a successful complete run. `--verify-saved` checks export integrity;
it does not prove complete processing and accepts valid audio with zero captions.

Multilingual exports reuse the existing files. `transcript-en.txt` contains the
original source text without language labels. The target transcript (currently
`transcript-zh-Hans.txt`, selected by `CaptionTranslationTarget`) contains Chinese
speech verbatim and translated text for other languages, including Cantonese.
SRT cues contain Chinese speech once; English and other languages retain source
and target lines. JSONL keeps the legacy `english` key for source text and the
optional `sourceLanguage` code from the existing segment encoder. Inferred legacy
Chinese keeps its absent marker for 0.2.0 revision replay. Manifest
`sourceLanguages` is an optional sorted list of unique non-English codes and is
omitted for English-only courses; `sourceLocale` retains its legacy value.

`run_verified` adds integer counts: `chineseCaptions` counts zh captions,
`otherLanguageCaptions` counts all other non-English captions (including yue), and
`languageProbes` counts auto requests submitted during this run. Failed responses
count; cached results and historical requests do not. These three event fields
accept only nonnegative Swift integers, never text, booleans or floating-point
coercions. The counter is in memory and adds no persisted fields.

For cleanup, first ensure the CLI has exited, keep the result/required logs,
and move only its explicit test output/build paths to Trash. Never remove
real session directories or the installed app as part of a CLI test.

## Silent virtual output for a real capture test

The build also produces `livelingo-virtual-player`. It explicitly selects the
existing `Microsoft Teams Audio` virtual device by name, refuses to fall back
if that device is absent, and stops if its output route changes. Running it
without an argument only checks device availability. Passing an audio file
plays that file to this virtual device; it does not change the system default
output. Verify your virtual device does not monitor to physical speakers.
Start the CLI capture first and wait for its `capture_ready` JSON event before
starting the virtual player. Stop the player when capture ends; otherwise it
continues through the input file. No device driver is installed by these tools.

### 跨段回归

正式翻译使用前文上下文。硬切或明显未完的边界会顺序校对前段尾句，因此该边界最多使用两次翻译请求；普通断句只使用一次。前段中文改变时，包含该段的旧摘要批次撤回并重新生成。CLI 状态和结束事件包含 `summaryStatus`；验收时必须同时检查 `translated`、`summarized` 与 `segments`，不能仅凭 `phase=已保存` 判定完整通过。回放不播放声音，也不验证 ScreenCaptureKit 输入或悬浮窗口布局。

## Classroom measurement reader

`classroom-metrics.py` reads local artifacts and writes a **new** JSON report.
It uses only Python's standard library, never starts models, never changes
classroom files, and never promotes old machine captions to human ground truth.

```sh
python3 -B Scripts/classroom-metrics.py report \
  --gold-manifest /absolute/path/to/benchmark/manifest.json \
  --powermetrics /absolute/path/to/power-samples.plist \
  --rss-jsonl /absolute/path/to/owned-rss.jsonl \
  --output /absolute/path/to/new-metrics.json
```

Every input is optional; absent measurements are `null`. The report itself
does not establish CLI success, which still requires exit status, `run_verified`
and runtime cleanup. Existing output files are never replaced.

Use normal NUL-separated **delta** plist samples from `powermetrics`, with
`cpu_power,gpu_power,ane_power`. Powers are mW and each sample's `elapsed_ns`
sets its integration interval. Cumulative/unmarked samples, missing rails,
negative values and invalid samples are rejected. CPU/GPU/ANE components are
added once; `combined_power` and duplicate GPU sections are not added again.
This estimates those rails across **all host workloads**, excluding the display
and other components. It is neither per-process energy nor battery discharge.
The reader reports joules per **sampled** minute; classroom energy remains
unknown until the measurement window and idle baseline are bound to a real run.

For RSS, start the CLI first and bind its actual PID and executable:

```sh
python3 -B Scripts/classroom-metrics.py watch-rss \
  --pid 12345 --executable /absolute/path/to/livelingo-cli \
  --duration 1800 --interval 1 --output /absolute/path/to/new-owned-rss.jsonl
```

The watcher matches PID, user, start time and executable before adopting child
processes. It retains observed orphaned children by identity, rejects PID reuse,
and stops with an incomplete status if ownership changes or the duration limit
is reached. It never signals or restarts a process. The peak is a sampled RSS
sum. The reader also requires a consistent monotonic clock, ordered samples,
and an empty final process sample before accepting the observed-exit status.
It does not infer exit from a completion label alone. RSS includes possible
shared-page duplication; unobserved child processes
and between-sample peaks are not proven absent. It cannot replace CLI cleanup
confirmation. On macOS, Python launchers may exec a framework binary: use the
observed executable of the process you started, not a different guessed path.
The report preserves the completion reason, including an identity change that
can also occur during process exit; it does not turn that uncertainty into a
confirmed release.

`--latency-jsonl` accepts one row per segment with `segment_id`,
`clock="host_monotonic_seconds"`, `audio_end_uptime`, and optional
`first_translation_uptime` / `final_translation_uptime`. It reports mean,
median, nearest-rank P95 and maximum, retaining slow outliers and the number
of unmeasured segments. Existing CLI polling timestamps and model execution
times **cannot** supply audio-end-to-caption latency; no conversion is assumed.
These events measure pipeline observations, not the GUI's paint completion.

`--snapshot` checks an encoded snapshot's payload checksum and counts distinct
matching source IDs in completed batches. Missing or changed references are
reported; knowledge-point coverage and factual correctness remain unknown.
This reads only the snapshot checkpoint, without replaying its journal tail.

Gold eligibility requires every row's declared human review, both verified
texts, reviewer, a matching frozen `gold_sha256`, `gold_status="human_verified"`
and the manifest's explicit `accuracy_comparison_allowed=true`. The tool checks
those declarations, not who actually performed the review. The unreviewed CSVs
prepared from real classrooms intentionally do not qualify.
