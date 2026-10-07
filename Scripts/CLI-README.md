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
bash Scripts/build-cli.sh work/new-cli-build
```

To reuse an existing compatible Swift module cache, pass
`--module-cache /absolute/path/to/existing-cache`. The output directory must
still be new. `--lifecycle-tests`, `--multilingual-tests` and
`--translation-failure-tests` all accept this option, but the test options use
separate entry points and cannot be combined. Headless
commands cancel any UI-only file chooser path without presenting a window.

Run the multilingual regression from the repository root. For this worktree,
keep the build, module cache, temporary files and evidence under
`../work/dd-trad/`. The following commands use authored fixtures only.

```sh
mkdir -p ../work/dd-trad/tmp ../work/dd-trad/cli-module-cache
CLI_TEST_TMP="$(cd ../work/dd-trad/tmp && pwd)"
CLI_TEST_CACHE="$(cd ../work/dd-trad/cli-module-cache && pwd)"
TMPDIR="$CLI_TEST_TMP" bash Scripts/build-cli.sh ../work/dd-trad/cli-step11-build \
  --multilingual-tests --module-cache "$CLI_TEST_CACHE"
TMPDIR="$CLI_TEST_TMP" LIVELINGO_CLI_TEST_OUTPUT_ROOT="$(cd ../work/dd-trad && pwd)" \
  ../work/dd-trad/cli-step11-build/livelingo-cli-multilingual-tests \
  ../work/dd-trad/cli-step11-build/livelingo-cli ../work/dd-trad/cli-step11-evidence
TMPDIR="$CLI_TEST_TMP" LIVELINGO_CLI_TEST_OUTPUT_ROOT="$(cd ../work/dd-trad && pwd)" \
  ../work/dd-trad/cli-step11-build/livelingo-cli-target-review-tests \
  ../work/dd-trad/cli-step11-target-review-evidence
```

The test executable requires the `livelingo-cli` beside it from that same build.
The optional second argument selects its evidence directory; alternatively set
`LIVELINGO_CLI_MULTILINGUAL_WORK`. If neither is supplied, it creates a new
`work/cli-multilingual-<UUID>` directory under the source root, or under
`LIVELINGO_CLI_TEST_OUTPUT_ROOT` when set. Existing directories and symlink
escapes are refused. The synthetic fixtures
are retained for inspection. It starts only the CLI's read-only `--verify-saved`
mode, with no model, HTTP service or audio device. Captured CLI output is checked
in memory; test events contain check names and counts, never subtitle text.
The additional target-review entry point checks snapshot/manifest mismatches,
snapshot error reporting, fixture-only English layouts, target retention and
parsed target forwarding. It uses synthetic audio files and an injected CLI
runner; it never loads a model or starts capture.

The regional regression covers both `zh-Hant-TW` and `zh-Hant-HK`:

- Export synthetic English, Chinese, Japanese and Cantonese captions, including
  pending/failed translations. Check hand-authored transcript, SRT and summary
  bytes; keep JSONL and original transcripts identical to the Hans reference.
  Summary source quotations and schedule source fields keep their original bytes.
  Run the actual normal CLI's `--verify-saved` and check its receipt and read-only result.
- Copy only the normal `livelingo-cli` to a new evidence subdirectory without
  `ZhVariants`. Its regional verification must exit nonzero, emit
  `cli_failed` with `reason=converterUnavailable`, and emit no `saved_verified`.
  The same binary must still verify the synthetic Hans reference. The original
  build's dictionary is retained.
- Verify hand-authored legacy regional exports with no snapshot,
  `sourceLanguages` or `converterVersion`, retaining their two-line SRT layout.
  Reject a substituted one-line layout and preserve files on every rejection.
- Reject a changed `converterVersion` through both the direct verifier and the
  actual binary. Missing dictionaries must still report `converterUnavailable`
  before renderer/version validation. Existing frozen Hans/Latin bytes remain exact.
- Check rendered `學習筆記` headings and MD/TXT fingerprints, rejecting an
  unrendered heading or missing converter. Bind each synthetic regional course
  into its authenticated run marker, verify raw generation-text digests, reject
  a changed regional target and a target edit without a matching checksum, and
  keep the marker and snapshot unchanged during binary verification.

The required pass receipt is exit zero plus `multilingual_cli_tests_passed` from
the test executable. Syntax parsing alone does not establish these results.
This synthetic verification does not establish GUI release readiness, real
classroom quality, model execution or PDF/DOCX content acceptance.

The existing lifecycle entry point remains separate:

```sh
bash Scripts/build-cli.sh work/cli-lifecycle-build --lifecycle-tests
work/cli-lifecycle-build/livelingo-cli-lifecycle-tests work/cli-lifecycle-evidence
```

Build and run the translation-failure regression independently from the
repository root. In this lab, keep its build, module cache and isolated test
directory under the shared `../work/dd/`:

```sh
bash Scripts/build-cli.sh ../work/dd/cli-translation-failure-build --translation-failure-tests
../work/dd/cli-translation-failure-build/livelingo-cli-translation-failure-tests \
  ../work/dd/cli-translation-failure-evidence
```

The build produces the normal CLI and a separate
`livelingo-cli-translation-failure-tests` executable, just like the multilingual
option. The test runs without invoking the normal CLI. Its optional argument
names a new test directory whose parent already exists; by default it creates
one beside the test executable. Existing directories and symlink paths are
refused. It instantiates an isolated AppModel with injected translators and a
stopped, synthetic review queue, with background services and scheduled notes
disabled. No model, HTTP service, audio capture or real course is started.
Frozen enum strings, persisted JSON and event JSON are checked, along with the
production translation queue, shared CLI failure reporter and event whitelist.
The queue checks cover recovery, persistent dependency cancellation and actual
worker cancellation; normal successful English translation emits no failure
event. Synthetic caption and error text stay in memory; test output contains
only check names and counts. A zero exit status and
`translation_failure_cli_tests_passed` establish this regression's result,
separately from `run_verified` for a real CLI run.

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
`summaryStatus` and `phase` are free-form strings and are removed by the event
whitelist; their presence in AppModel callbacks does not make them CLI fields.

Only a zero exit status together with `run_verified` and confirmed runtime
cleanup is a successful complete run. `--verify-saved` checks export integrity;
it does not prove complete processing and accepts valid audio with zero captions.

Multilingual exports reuse the existing files. `transcript-en.txt` contains the
original source text without language labels. The target transcript (currently
`transcript-zh-Hans.txt`, selected by the course output language) uses the saved
usable target text for Chinese speech, or normalizes its source text to the
target writing system when that text is unavailable. Other languages, including
Cantonese, use translated text. SRT cues contain the Chinese target line once;
English and other languages retain source and target lines. JSONL keeps the
legacy `english` key for source text and the
optional `sourceLanguage` code from the existing segment encoder. Inferred legacy
Chinese keeps its absent marker for 0.2.0 revision replay. Unmarked legacy rows
infer zh only when their completed source and target text match and satisfy the
Chinese-content gate; this does not recover a separate historical yue identity.
Manifest `sourceLanguages` is an optional sorted list of unique non-English codes and is
omitted for English-only courses; `sourceLocale` retains its legacy value.
`--verify-saved` selects filenames and a supported renderer from the manifest's
`targetLocale`; unknown targets and unavailable converters are rejected.
For regional Traditional Chinese, the actual dictionary is prepared before
`savedRenderer` validation. Missing or unreadable dictionaries emit
`cli_failed` with `reason=converterUnavailable`; the verifier never substitutes
Simplified Chinese. New regional manifests include `converterVersion`.
A present version must equal the current converter version, otherwise verification
fails with `inconsistentExport`. An absent version remains accepted for old exports.
The old unmarked two-line rules apply to `zh-Hans`, `zh-Hant-TW` and `zh-Hant-HK`
without either `sourceLanguages` or `converterVersion`; regional target lines
are converted while source
lines retain their original bytes. English-target source-only captions use one-line cues;
this also applies when the saved English body differs from the source.
Separate read-only rules preserve the synthetic `zh-Hant` fixtures and the
snapshot-free, unmarked two-line `en` fixture layout (including equal bodies).
No released exporter produced these fixture formats; they are not generation
targets or evidence of Traditional Chinese conversion. Explicit JSONL source
markers still require the exact manifest language list. Verification does not
consult the current preference. When a snapshot exists, its effective target
(nil means `zh-Hans`) must match the manifest. Unreadable, damaged or incomplete
snapshots fail with `inconsistentExport`, as do target mismatches.

Generation accepts `--target zh-Hans` (also the default), `--target zh-Hant-TW`
and `--target zh-Hant-HK`. The two regional codes are explicit CLI opt-ins while
their GUI release flags remain closed. Parser rejection tests use
`parseForTesting(releasedTargets: Set(OutputLanguage.released))` to retain that
release guard. Other codes, duplicate flags, and `--target` in verification,
reopen, resume, or typed-translation modes
are rejected before files or runtimes are touched. Opening and resuming use the
course's recorded target; a changed preference applies only to new courses.
An existing snapshot with nil target always opens as `zh-Hans`, regardless of
the derived manifest. Only legacy directories without a snapshot consult the
manifest; unreadable or undecodable metadata falls back to `zh-Hans`. Their
synthetic non-regional `zh-Hant` code maps to the supported `zh-Hans` generator.
An unsupported generation target is checked before parking the current course
or preserving an incomplete journal tail.

Regional output uses `transcript-zh-Hant-TW.txt` / `summary-zh-Hant-TW.md` or
`transcript-zh-Hant-HK.txt` / `summary-zh-Hant-HK.md`. `transcript-en.txt`, JSONL
generation text, and non-pass-through SRT source lines remain unchanged.
`ZhVariants/` with its provenance and dictionaries must be beside the executable
or inside its own isolated bundle; `build-cli.sh` copies the adjacent resources.
The GUI release flag and dictionary availability are separate checks.
Run markers bind `targetLocale` and include it in their checksum; old markers
omit the field and retain the frozen Hans default. Reopen/resume retention
rejects a target change. Regional text-export fingerprints obtain their heading
from `NotesExportDocument.prepare` and `notesHeading(for:rendered:)`;
identity-profile fingerprint headings retain their existing bytes.

An `en` target uses `transcript-target-en.txt`, preserving the separate original
source file `transcript-en.txt`.
Non-English translation failures render as
`（本段翻译未完成，可对照原文）`; the English placeholder stays unchanged.

`run_verified` adds integer counts: `chineseCaptions` counts zh captions,
`otherLanguageCaptions` counts all other non-English captions (including yue), and
`languageProbes` counts auto requests submitted during this run. Failed responses
count; cached results and historical requests do not. These three event fields
accept only nonnegative Swift integers, never text, booleans or floating-point
coercions. The counter is in memory and adds no persisted fields.
Only the verifier emits `run_verified`; a same-named AppModel callback is
sanitized to `progress`, while the integer fields remain allowlisted.

`translation_failure` reports each recorded caption translation failure through
the AppModel's CLI reporter. Its exact allowlist is:

```json
{"event":"translation_failure","translationFailureCount":1,"translationFailureReason":"dependencyCancelled"}
```

No elapsed time, caption text, error message, path, session ID or unrelated
progress field is emitted. `translationFailureCount` must be a positive native
Swift integer; booleans, bridged numbers, floating-point values and strings are
rejected. `translationFailureReason` must be one of these frozen strings:
`processExited`, `requestTimedOut`, `outputLimitReached`, `translationRejected`,
`runtimeUnavailable`, `invalidResponse`, `generationInterrupted`, `requestFailed`,
`dependencyCancelled`, `unknown`, `cancelled`, `interrupted`. If either value is
invalid or missing, both fields are dropped and only the event name remains.
Counts accumulate for the same reason on that caption, including retries;
different reasons have separate counts. A successful retry retains the saved
trail without emitting another failure event. `dependencyCancelled` means a
dependency raised cancellation while the caption worker itself was still
active. The legacy `cancelled` and `interrupted` values remain readable and
allowlisted; routine pauses, parks, restarts and actual worker cancellation do
not write them as new translation failures. The CLI regression checks worker
cancellation; saved-course pause/reopen coverage belongs to the app tests.

For cleanup, first ensure the CLI has exited, keep the result/required logs,
and move only its explicit test output/build paths to Trash. Never remove
real session directories or the installed app as part of a CLI test.

## Frozen scoreboard

`python3 -B Scripts/livelingo-scoreboard.py run --build /absolute/build-directory`
runs the frozen CS50 search/structures excerpts and private classroom excerpt,
then the authored translation set, and writes `scoreboard.json` and a short
`scoreboard.md`. The build directory must contain `livelingo-cli` and its isolated
runtime. No model or fixture is downloaded. All generated files stay in this
checkout's ignored `work/`; Swift caches use the lab's `work/dd-scoreboard`.
It refuses another active LiveLingo CLI/app, an existing output directory,
changed fixture hashes, symlink outputs, or runtime paths under `/Applications`.
It never contacts the legacy ASR endpoint on port 18765.

One-time configuration is local, private, and untracked. Create
`work/scoreboard/sources.json` with these fields, replacing the example paths
and SHA-256 values with the actual frozen local sources:

```json
{
  "public_audio": {"path": "/absolute/cs50-audio.m4s", "sha256": "64 hex digits"},
  "official_srt": {"path": "/absolute/lecture3.en.srt", "sha256": "64 hex digits"},
  "private_audio": {"path": "/absolute/sealed-classroom-recording.wav", "sha256": "64 hex digits"},
  "reference_checks": {
    "cs50-w3-search": "/absolute/benchmark.json",
    "cs50-w3-structures": "/absolute/heldout-plan.json"
  }
}
```

The public source and SRT must match the committed ruler hashes. The private
source must be sealed 32 kHz mono f32 WAV; its content hash is local only.
`reference_checks` compares tokenized excerpts with existing frozen LL4 reference
text. Omitted checks are explicitly recorded as unchecked. Preparation checks
every decoded frame count and subtitle boundary. It uses sample-based trimming:
time-based AAC trimming produced 448 extra frames in the initial local test.
The corrected smoke window is **3603.199–3632.850 s**, official cues 1691–1702
(29.651 s); the draft's 3603.049–3633.000 window did not match those cues.

For `build` / `run --build auto`, create `work/scoreboard/runtime.json`:

```json
{
  "python": "/absolute/existing/python3.13",
  "asr_site_packages": "/absolute/existing/ASRRuntime/site-packages",
  "language_site_packages": "/absolute/existing/LanguageRuntime/site-packages",
  "models": "/absolute/existing/Models"
}
```

Paths must exist and resolve outside `/Applications`. Build assembly copies the
selected commit (or hashes a current dirty snapshot) without changing branches,
and hashes the CLI, worker/service, models and Python dependency contents. It
includes the optional numeric timing helper in both child runtimes. Existing
compatible builds can also be supplied directly; missing provenance is unknown.
Before execution, recorded CLI/runtime hashes and external dependency manifests
are checked again; changed files are refused. New build records also bind the
Python executable and wrapper scripts. Older builds without those records retain
`runtime_hashes_verified=false`. Absolute dependency paths stay in the local
build record and are omitted from numeric reports.

```sh
python3 -B Scripts/livelingo-scoreboard.py prepare
python3 -B Scripts/livelingo-scoreboard.py build --commit HEAD --out work/scoreboard/builds/candidate
python3 -B Scripts/livelingo-scoreboard.py run --build work/scoreboard/builds/candidate --tier smoke
python3 -B Scripts/livelingo-scoreboard.py run --build work/scoreboard/builds/candidate --profile both --repeats 3
python3 -B Scripts/livelingo-scoreboard.py run --builds /absolute/build-A,/absolute/build-B --repeats 2 --order ABBA
python3 -B Scripts/livelingo-scoreboard.py score --run-dir work/scoreboard/runs/EXISTING --out work/scoreboard/rescored-NEW
python3 -B Scripts/livelingo-scoreboard.py calibrate --build work/scoreboard/builds/candidate --repeats 3
python3 -B Scripts/livelingo-scoreboard.py compare /absolute/A/scoreboard.json /absolute/B/scoreboard.json --noise /absolute/noise-floor.json
```

`--tier standard` is the default; `full` also includes the whole private class.
Smoke omits authored-80. Standard/full run its 80 sentences in a single batch,
resuming after a failed sentence with a new CLI output directory and recording
that sentence as an error. `--skip-authored` explicitly omits this proxy.
`--profile 9b` passes `--high-quality`; `4b` omits it. Results for each build and
profile stay separate, including paired A/B differences and repeat summaries.
`calibrate` measures A/A variability, with the documented three-edit, 0.1 s and
5% energy floors. Uncalibrated comparisons retain that label; only measured
noise floors and supported paired confidence intervals permit direction claims.
Authored-80 runs once per build/profile; it has no invented repeat variance.

ASR numbers are **differences from official captions**, not human-gold WER.
Both raw tokens and `norm_v1` are reported; the latter normalizes digits and
expands `n't` (including `can't`/`cannot` → `can not`). Numbers are counted by
digit. Token associations are limited to overlapping time spans ±3 seconds.
Private audio has no reference transcript and therefore no ASR accuracy score.

Latency is per **reference subtitle cue**, with content/time association to
actual captions; private audio uses actual exported caption cues. First Chinese
text uses the earliest event. A cue spanning several captions commits/finalizes
at the latest required event; incomplete reference matching or any unfinished
required caption remains right-censored. Missing logs are separately unmeasured.
P50/nearest-rank P95 retain slow outliers and explicitly label observed,
censored populations; they do not claim full-population quantiles. `ReplayClock`
defines T0 immediately before the first PCM write. First-result latency starts
at T0. Builds lacking this anchor have unknown latency, without an assumed
preview/backend offset. Negative delays below −0.1 s invalidate latency.
The details use numeric cue sequence numbers, not classroom text or IDs.

State counts replay checksummed snapshot/journal metadata in disk sequence order.
`pending` includes retryWaiting, exactly matching `needsWork`. Completed records
with a candidate and finished runs with unresolved work each have separate
`completed_with_unresolved` counts. Pending and unresolved may overlap.
`appleEvidence` contains raw preview text: only empty/present/unknown counts
are retained. Failure reasons, CLI events and OSLog fields use fixed allowlists.

Energy defaults to **unprivileged IOReport** via the included C bridge,
compiled with the already installed Apple compiler. No sudo, powermetrics,
third-party installation, or system configuration change is used. One sampler
covers the session, with adjacent idle subtraction, boundary-bin apportionment,
coverage and baseline drift, gross/net rail joules per audio minute and phase
energy when clock boundaries can be verified. CPU/GPU/ANE counters are whole
machine OS estimates including background work; they exclude the screen and
are not App-exclusive. Unsupported counters stay null. If IOReport is unavailable,
CPU core busy seconds, GPU residency/utilization and wall time form an explicitly
marked proxy; **no proxy value is converted to joules**. `--no-energy` disables
sampling. Thermal, AC power and interference are currently unverified in the
runner, so it conservatively reports `energy.comparable=false` and excludes
energy from ranking. Zero/short idle windows do not establish a usable baseline.

Model-call timing is opt-in through the runner's exclusively created numeric
log. It separately measures ASR loading/inference, language model loading,
and generation initialization/restore/steps. Calls exclude the ASR lock wait;
wall time includes their tensor work, I/O and preprocessing, while CPU time
is process-wide, not hardware GPU busy time. The existing completion protocol
uses `text` for translation and other text work: those calls remain `text_step`,
not a falsely claimed independent translation stage. Notes/review have their
own fixed stage labels. Apple preview inference and uninstrumented builds are
unknown. Missing optional helpers leave normal release behavior unchanged.

Reports, numeric logs, stdout and stderr contain only counts, enum labels,
sequence numbers and hashes. Raw `session/` exports still contain private
classroom text and have a PRIVATE marker; keep that directory local. The
scorer never deletes source recordings, results, installed apps, or services.
A persistent advisory lock prevents concurrent writers; history is append-only.
Timeout signals target only the exact freshly checked child, and residual or
uncertain ownership stops subsequent workloads.

Exit codes: 0 scored (even `processingIncomplete` is scored), 2 preflight refusal,
3 invalid/changed ruler, 4 unavailable metrics or execution evidence. New output
files are exclusively created. Rescoring never launches a model.

Synthetic tests require no weights or audio devices:

```sh
python3 -B -m unittest discover -s Scripts -p 'test_scoreboard*.py'
python3 -B -m unittest discover -s Scripts -p 'test_livelingo_scoreboard.py'
```

Implementation acceptance used these synthetic cases, a read-only LL4 raw-token
compatibility check, compiled CLI, the complete app test suite and short rootless
energy probes. It did **not** replay real classroom/model audio or run A/A
calibration; those remain separate live acceptance steps.

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
