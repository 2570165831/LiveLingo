# LiveLingo test CLI

This CLI compiles the production AppModel, SpeechPipeline, ASR/translation clients,
summary policies and exporter directly. CLI-only entry points are behind
`LIVELINGO_CLI`; the normal app does not include them. It neither launches nor
replaces `/Applications/LiveLingo.app`.

A CLI build runs outside the app bundle, so it has no bundled ASR service and no
bundled MLX runtime of its own. Point it at local resources explicitly instead
of relying on defaults:

- `LIVELINGO_ASR_ENDPOINT` (with `LIVELINGO_ASR_TOKEN` when the service requires
  a token) selects the loopback ASR service to reuse.
- `LIVELINGO_MLX_PYTHON`, `LIVELINGO_MLX_WORKER`, `LIVELINGO_MLX_MODELS` and
  `LIVELINGO_MLX_STATE` select the MLX language runtime.

The language runtime is MLX, one owned process per model; LM Studio is not used
and no LM Studio service is required. Those model resources are shared with other
clients, and the legacy `Scripts/run-qwen-service.sh` can serve the loopback ASR
service for local development. Do not run it alongside a real recording.

Build into a new directory:

```sh
bash Scripts/build-cli.sh /absolute/path/to/new-cli-build
```

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
JSON lines include elapsed time, caption/translation/summary coverage and
preview text. Logs contain the input's content; keep them with the test data.
`finished` means the existing export workflow finished: inspect coverage and
failure markers separately, because the production workflow can save an
incomplete summary. Capture duration accepts finite values from 0 (exclusive)
to 3600 seconds. Replay duration is the input file's duration.

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
