# Offline target-language evaluation

These standard-library tools read explicitly supplied local files and never
download corpora or alter the app's English lecture / Simplified Chinese
production path. Calibration and metric tools do not load models. The route
runner described below loads local MLX weights only in normal mode; its
`--dry-run` and every regression test use synthetic workers and no GPU.

## Output location and tests

Set the production output root explicitly before running a writer, replacing
`<lab>` with the absolute path of your lab directory:

```sh
export LIVELINGO_TARGET_EVAL_OUTPUT_ROOT="<lab>/work/target-eval"
```

`LIVELINGO_TARGET_EVAL_OUTPUT_ROOT` is the only source of the output root; an
absent or empty variable rejects writing with an error naming the variable.
Its value must be an existing absolute directory outside the repository, with
no symlink or `..` components. Writers can create subdirectories only after
validating the root and destination. Destinations outside that root, repository
destinations, symlinks and existing output files are rejected. Moving or merging
the checkout does not move the configured root; a checkout relocated to contain
that root makes it invalid.

Use the aggregate suite from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=error \
PYTHONPATH="Scripts" \
TMPDIR="<lab>/work/dd-target-eval" \
python3.13 -m unittest Scripts.target_eval.run_tests
```

The `TMPDIR` scratch directory must already exist, lie outside the checkout and
be within the task's write authorization. Without `TMPDIR`, tests use Python's
system temporary directory. Each fixture test configures its own temporary
directory through `LIVELINGO_TARGET_EVAL_OUTPUT_ROOT` and exercises the production
validation function. The aggregate runner and root-level `test_target_eval`
discovery bridge load all corpus, metric, review and calibration regressions without path
overrides, filtering or skips. Temporary synthetic fixtures and environment
changes are cleaned up by unittest. No UserDefaults suites are used.

## Independent public-corpus length calibration

`calibrate --public-manifest` reads only the explicitly supplied local manifest.
It does not open the legacy UN default or discover recordings, sessions or
classroom files. Downloads and license verification are separate caller-owned
steps; no network, model, tokenizer or GPU is used by this mode.

```sh
LIVELINGO_TARGET_EVAL_OUTPUT_ROOT="<authorized-work>" \
TMPDIR="<authorized-work>/tmp" PYTHONDONTWRITEBYTECODE=1 \
python3.13 -m Scripts.target_eval.calibrate \
  --cli "<authorized-work>/cli/target-acceptance-cli" \
  --public-manifest "<public-data>/public-manifest.json" \
  --output "<authorized-work>/public-calibration.json" --batch-size 2048
```

The manifest has `schema_version: 1` and a `corpora` array. File paths are caller
parameters, relative to the manifest directory or absolute. Supported formats:

- `opus-ted2020`: `raw` maps en/es/fr/zh/ru/ar to raw ZIPs. Five `alignments`
  objects contain `source`, `target` (OPUS raw locale codes), `locale` (mapped
  evaluation locale), and `path` (XCES XML gzip). Each has one English pivot.
  Only identical English sentence-ID tuples shared by all five alignments join;
  many-to-many ID order and talk identity are preserved. No ZIP is extracted.
- `cs50-srt`: `document_id`, `files` locale map, and explicit `reference_status`.
  SRTs use the existing positive time-overlap component alignment. This is not
  an assertion of semantic alignment or human authorship.
- `flores-plus-jsonl`: `files` locale map to official JSONL containing `split`,
  `id`, `text` and source article `url`. Join by split/ID, then use article URL
  as the split group across official dev/devtest boundaries. Plain line files
  without article metadata cannot establish a document-isolated holdout.

Only `human` or `community-human` references qualify for fitting and the primary
holdout; other explicit statuses remain auxiliary diagnostics. These labels
must be supported by the external provenance audit. Selection retains one
SHA-256-ranked nonduplicate reference per talk/article, independently of length
and verdict. Entire documents, including all language directions, share the
same SHA-256 split (default seed 20261008; modulo 3 selects the holdout). Repeated
NFC reference text across documents does not increase sample size. TED first
ranks exact anchors by SHA-256 and chooses the first whose six locale texts are
unique; later partitioning again prevents duplicates between corpus sources.

Production `CLI judge` supplies all acceptance verdicts and counts. NFC Unicode
letter scalars (Lu/Ll/Lt/Lm/Lo) are checked against Python on every reply. Both
raw target/source ratios and effective required-policy ratios report p01, p05,
p50, p90, p95, p99, p99.5 and max. The proposed ratio is the training p99.5 of
`max(0, (targetLetters - existingAllowance) / max(sourceLetters, existingFloor))`,
rounded up to 0.01 without added margin. Existing floor/absolute allowance are
incorporated into this formula; they are not newly fitted or independently
justified. Proposals remain frozen after the training phase. Fewer than 600
distinct documents per direction in either split prevents sample eligibility
for a production update. The Python code never edits Swift constants.

The report separates reference length rejection from complete acceptance
rejection, and includes unchanged-source and wrong-language interception on
the same held-out documents. Negative candidates equal to the human target
reference are labelled ambiguous and retained visibly in the raw metrics.
For correlated comparisons (e.g. two Latin sources share a target reference),
confidence uses the conservative event "any rejection in this document",
not an inflated comparison count. One-sided exact 95% Clopper-Pearson bounds
remain positive with zero failures. Negative diagnostics report bounds on
missed interception. These bounds assume approximately independent documents,
are per direction/stratum, and do not establish a simultaneous 15-direction
or classroom population guarantee. Repeated speakers/translators, domain,
direction and unspecified regional variants remain limitations.

Input and CLI SHA-256 checks bind each run; inputs are hashed before reading and
again after judging. The report hashes the Python implementation and each new
JSONL verdict sidecar. Existing report/sidecar files are never overwritten;
all generated evaluation outputs use the configured external output boundary.
`PYTHONPATH=Scripts` in the aggregate-test command supports the existing
`latin_learning` absolute import without importing any MLX/weights module.

## Route runner (PLAN step 24)

`python -m Scripts.target_eval.run_strategies` consumes step 19's `prompts`
directory, validates its manifest/SHA-256/byte counts, and preserves the exact
UTF-8 system prompt, including whitespace. It selects `caption-9b` or
`caption-4b`; no prompt is derived by replacing a different target's words.
The current exporter only supplies **zh-Hans**. Translation calls for en/es/fr
and direct Traditional Chinese fail before worker/output creation until their
App prompt exports exist; zero-call passthrough does not need a model prompt. Synthetic test manifests exercise those future routes without claiming
that the App already exports them.

| Route | Definition | PLAN |
|---|---|---|
| `direct` | One generation in the target language, except App passthrough sources (zero model calls; excluded from comparisons). | I.7; II.en and II.es/fr; Traditional direct generation is an evaluation control only. |
| `via-en` | Non-English source → generated English → es/fr, using the exported English and target prompts. Two sequential calls, with no reference text fed to either call. | I.7; II.es/fr; step 25. |
| `hans-convert` | One zh-Hans generation → caller-supplied reviewed TW/HK converter. | I.7; II.zh-Hant-TW/HK. |

`--targets` and `--routes` form a Cartesian list; unsupported combinations fail.
For a direct/pivot pair, `--sources` must exclude English. Without `--sources`,
the common corpus source locales are selected, excluding target locales and,
for pivots, English. The passthrough table matches `OutputLanguage.passThroughSources`:
`zh` to any Chinese output and `en` to English make zero model calls. Chinese
passthrough uses the explicit normalizer/renderer adapter, including zh-Hans
normalization before TW/HK rendering. Passthrough rows are labelled and excluded
from translation quality, latency summaries and paired route comparisons.
A source equal to a target outside that table is rejected.
Traditional references must explicitly use `zh-Hant-TW` or `zh-Hant-HK`; generic
`zh-Hant` gold is not silently assigned a regional label.

Use `--corpus un --input LOCAL_UN_ROOT` for the existing curated UN reader.
Other choices reuse `corpora.py`: `cs50`/`ted` take repeated
`--locale-file LOCALE=PATH` and `--document-id`; `flores-plus` takes locale files;
`jsonl --input FILE` reads `corpora.py`'s exported `ParallelUnit` rows. UN turns
and SRT overlap groups remain intact, rather than inventing aligned sentences.
Optional JSONL `metadata.terms` maps each target to the required term list used
by `metrics.terminology_hit_rate`; absent terms have an unknown hit rate.

Targets run in separate blocks in requested order. Within a block, routes
rotate left by the unit/source-pair index modulo route count, so two routes
alternate which runs first. Only the target plus English (or target plus Hans)
prompts can be active in a block, matching the worker's two-entry prefix cache.
Each distinct prompt gets a short unmeasured generation before the block. Its
model load, prefill, time and energy are recorded in `warmups`, outside measured
row/call windows and route totals. A stream restart repeats that warm-up before
timing resumes. Cache reuse is read from the worker, never assumed from warm-up.

Both tools hold `<git-common-dir>/work/scoreboard/.lock` for their full sessions,
including the scoreboard's idle baseline and runner warm-ups. Git discovery is
anchored to each script's checkout, ignores inherited Git routing overrides and
uses the common metadata directory shared by all repository worktrees. This is
writable repository metadata, outside tracked content, independent of the output
leaf or current directory; its persistent inode is never unlinked. Existing
path checks remain for explicit fixture lock directories. The App/CLI/standalone
worker census is checked before startup and before/after each generation; only
the runner's owned child is excluded. No other process is stopped to make room.
Separate repository clones and unrelated GPU applications are outside this lock.

Set `LIVELINGO_MLX_PYTHON` and `LIVELINGO_MLX_MODELS` to the existing App-compatible
Python and model-root directory. `LIVELINGO_MLX_WORKER` optionally selects the
worker script (default: this checkout's `Scripts/mlx_runtime/worker.py`). Flags
`--python`, `--models-root`, `--worker` override those variables. The runner uses
an isolated checkpoint directory inside the new output directory, never the
App's `LIVELINGO_MLX_STATE` or paused jobs. HF/Transformers offline mode is forced.

Normal runs require `--energy-helper EXISTING_IOREPORT_EXECUTABLE` or explicit
`--no-energy`. This runner never compiles a helper, installs anything or uses
root. `scoreboard_energy.PowerSampler` provides sanitized interval samples;
`window_energy` integrates each invocation and input unit after stopping/flushing
the sampler. Missing rails/coverage or busy-time fallback remain unknown joules.
Gross energy includes other processes and has **no idle subtraction**. Thermal,
AC and interference are unverified, so energy comparability stays false.

Protocol v2 keeps its existing completion fields and adds optional read-only
`inputTokens` and `reusedPrefixTokens`. The input count is captured at generation
construction before consuming the pending tokens; reuse comes from the existing
cache statistic. `finalTokens + thinkingTokens` is output tokens excluding EOS.
Older workers lacking the optional counters report `null`; no token estimate is
substituted. Swift decodes its existing `Event` type with `JSONDecoder`, ignoring extra keys.
Exact TTFT stays `null`. `first_token_seconds` is the first nonempty snapshot/done
receipt, with snapshots throttled to 100 ms, a visible-output proxy. Successful
call time ends at `done`; failed call time ends at failure receipt/control
completion. Row time includes guards, ACK waits and conversion. Initial model
load and restart warm-ups occur outside these windows. For a pivot, first-output
time includes the first hop; after nonstreaming conversion it is unknown.
p95 uses nearest rank. Mean/p95 and quality use successful translation rows;
route totals and gross energy include failed attempts. `paired_summaries` use
only the identical common successful rows used by the quality comparison.

`hans-convert` needs an explicit local `--converter` executable, once the reviewed
converter exists. This worktree has no converter or reviewed tables. The adapter
contract is one stdin JSON object `{"targetLocale":"zh-Hant-TW","text":"..."}`
and one stdout JSON object `{"text":"..."}` per invocation. For Chinese
passthrough, `targetLocale` can also be `zh-Hans`; the adapter must normalize the
source to Hans and then render the requested region, without a model call.
Its binary SHA-256 is recorded. The runner implements no conversion rules;
dry runs use a labelled fake conversion and never execute that adapter.

`--output-dir` must name a **new** descendant of the existing directory in
`LIVELINGO_TARGET_EVAL_OUTPUT_ROOT`. Existing files/directories, symlinks and
repository outputs are refused; the leaf is reserved atomically. A finished
run writes `report.json` (all input/reference/output text, per-call/unit stats,
unmeasured warm-ups, route summaries, samples and paired chrF++ 95% bootstrap)
and `summary.md`. Single-row generation, budget, timeout/EOF, converter and
intermediate-control-marker failures are recorded with sanitized codes and
elapsed time, and the next row continues. Only stream faults restart the owned
worker; budget errors cancel/confirm release and keep that worker. Failed rows
have no quality score. Each target's comparisons use rows successful in every
requested route, excluding passthrough; an empty intersection reports
`no_common_successes` with null deltas instead of bootstrapping empty input.
Each route reports its failure count and codes; such runs have
`completed_with_failures` status. Fatal configuration, process-interference or
artifact-integrity errors still retain the output directory without publishing
a completed report; retry with a new output path. These files are local public-corpus
evidence, not the numeric-only scoreboard reports. Worker stderr is drained and
hashed in memory, never copied into the report. Dry-run scores/times are synthetic.
There is no App acceptance/retry loop or audited simplified-only inventory, so
language rejection, Traditional simplified residue and the full G3/G4 switch
gates are not established. Production route constants are never changed.

Current-export dry-run example (replace all placeholders with existing paths):

```sh
export LIVELINGO_TARGET_EVAL_OUTPUT_ROOT="<authorized-existing-output-root>"
PYTHONDONTWRITEBYTECODE=1 python3.13 -m Scripts.target_eval.run_strategies \
  --prompts-dir "<step-19-export>" --corpus un --input "<local-un-root>" \
  --targets zh-Hans --routes direct --sources en --profile 9b \
  --output-dir "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/new-dry-run" --dry-run
```

Real comparison example, **after** en/es/fr prompt exports exist and the machine
is free of other LiveLingo runtimes (this command loads weights/GPU):

```sh
export LIVELINGO_MLX_PYTHON="<existing-app-runtime-python>"
export LIVELINGO_MLX_MODELS="<existing-models-root>"
export LIVELINGO_TARGET_EVAL_OUTPUT_ROOT="<authorized-existing-output-root>"
PYTHONDONTWRITEBYTECODE=1 python3.13 -m Scripts.target_eval.run_strategies \
  --prompts-dir "<future-app-export-with-en-es-fr>" --corpus un --input "<local-un-root>" \
  --targets es fr --routes direct via-en --sources zh ru ar --profile 9b \
  --final-budget 4096 --energy-helper "<existing-scoreboard-ioreport>" \
  --output-dir "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/new-real-comparison"
```

`--final-budget` defaults to the App's 160-token caption budget (max 4096).
Long UN turns can exceed even 4096; budget exhaustion is a recorded failed row,
never a completed translation. Subsequent rows continue without an App retry loop. This command is an invocation example, not a measured
claim about those turns or future targets. For current zh-Hans exports use
`--targets zh-Hans --routes direct --sources en` instead.

To run the task's explicit module selection from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 TMPDIR="<lab>/work/dd-target-eval" \
python3.13 -m unittest Scripts.target_eval.test_metrics \
  Scripts.target_eval.test_corpora Scripts.target_eval.test_review test_target_eval
```

This selection runs each suite directly and again through the discovery bridge.

## chrF / chrF++ source rules and evidence

The reference is sacreBLEU 2.x's public
[`sacrebleu/metrics/chrf.py`](https://github.com/mjpost/sacrebleu/blob/master/sacrebleu/metrics/chrf.py),
particularly `CHRF._get_match_statistics` and `CHRF._remove_punctuation`:

* For each character or word n-gram order, record the hypothesis total only when
  the corresponding reference n-gram counter is nonempty; otherwise record zero.
  Clip matches by the intersection of the counters. Apply this rule **before**
  pooling sentence statistics or resampling the paired corpus.
* Split text on whitespace. For each token longer than one character, detach one
  trailing ASCII punctuation character. Only when there is no trailing mark,
  detach one leading ASCII punctuation character. Do not detach both edges.
  Internal apostrophes and Unicode punctuation remain part of the word.
* Pool counts by order. Average precision and recall over orders with nonzero
  hypothesis and reference totals, then compute `F_beta`. Defaults are character
  order 6, word orders 1–2 for chrF++, beta 2, case sensitive, whitespace excluded,
  and effective order. These correspond to sacreBLEU's `eps_smoothing=False`.

The reference-absent counting rule is supplied by the task's review/instructions;
no upstream source was fetched in this offline run. The tokenizer was also
checked by reading the locally installed TorchMetrics 1.8.2 source function
`_separate_word_and_punctuation`, which attributes this rule to sacreBLEU and
Popović's chrF++. This is corroboration of tokenization, not verification of
TorchMetrics corpus counting. sacreBLEU is not installed here. No claim is made
that these tests were generated by, or executed against, sacreBLEU.

Every test expectation below is calculated from explicit n-gram counts. For
averaged precision `P` and recall `R`, the score is `100 * 5*P*R/(4*P+R)`.

| Synthetic hypotheses / references | Hand expectation |
| --- | --- |
| `aa` / `ab` | char matches `1/2, 0/1`; `P=R=1/4`, chrF **25** |
| `[a,b]` / `[a,c]` | pooled unigram matches `1/2`, chrF **50** |
| `[abcdefgh,好的没问题啊]` / `[abcdefgh,好的]` | char `(H,R,M)` = `(14,10,10),(12,8,8),(6,6,6),(5,5,5),(4,4,4),(3,3,3)`; `P=113/126,R=1`, chrF `100*565/578` = **97.75086505190312** |
| `[这是 DNA 分子。,他说 OK 了。]` / `[这是 DNA 分子。,他说好了。]` | char triples `14/13/12,12/11/9,10/9/6,8/7/5,6/5/4,3/3/3`; word triples `6/4/3,2/2/2`; `P=5039/6720,R=400733/480480`, chrF++ `100*2019293587/2475496128` = **81.57126824639494** |
| `He said "yes."` / `He said "yes".` | char matches `12/12,9/11,8/10,7/9,6/8,5/7`; word matches `2/4,1/3`; `P=R=78913/110880`, chrF++ **71.16973304473305** |

The short-reference bootstrap regression uses seed 0 and four paired draws
`[1,1],[0,1],[1,1],[1,1]`. For a candidate equal to the reference, the two delta
values are `100*13/578` (both pairs) and `100*11/31` (short pair twice). The lower
95% percentile is `low + (high-low)*3/40`; the upper percentile is `high`.
Settings in reports name both counting and tokenization rules.

## Corpus and diagnostic behavior

* FLORES+ rows are separated only by LF, with explicit CRLF normalization and at
  most one final empty split element removed. Bare CR, VT, FF, file/group/record
  separators, NEL, U+2028 and U+2029 are rejected. Blank rows and unequal counts
  still fail rather than shifting alignment.
* SRT cue boundaries accept one or more blank lines, including spaces/tabs and
  CRLF files. Multiline cue text, timestamps and validation remain intact.
* UN metadata retains matching `language_note_conflicts` by `index` and
  `mapping_corrections` by `affected_english_indices`, including the full original
  diagnostic objects. Corrections affecting multiple turns appear on each one.
  Partial turns keep these notes in exclusion diagnostics and, when explicitly
  included, in unit metadata. Invalid diagnostic types and unknown turn indices
  fail instead of silently losing notes. No timing or dispute resolution is
  invented.
* Script purity allows Greek letters and `µ`, `º`, `ª` as a reported
  `scientific_symbol` class for all supported targets; `々` is Han. The additional
  class appears only when present, preserving the existing zero-count keys.
  Non-target Han/kana/Hangul/Cyrillic/Arabic and unknown scripts remain forbidden.
  This diagnostic does not identify the language of Latin or Greek prose.

## Report schema 2 and pairing

`score` and `compare` group results under `by_target_locale`, keyed by the exact
input locale (for example `es`, `fr`, `zh-Hant`). Each group records its own sample
count and source locales. `score` pools chrF/chrF++ within each target. `compare`
pairs identical unique IDs, sources, references and locales before independently
resampling each target group with the requested seed, iterations and confidence.
Multiple source locales can coexist within a target and are explicitly listed.

A single-target report retains the original top-level score or delta/interval
fields for convenience. A mixed-target report omits these fields: its top-level
sample count and ID list describe coverage, not a cross-language score or route
decision. Per-example scores remain available.

`terms`, when present, must be a JSON list. Each entry is a nonempty string or a
nonempty list of nonempty alternative strings; an empty outer list means no
required concepts. Null, numbers, booleans, objects and strings in place of the
outer list produce an argparse error without a traceback or output file.

## Offline Latin-target calibration

`calibrate.py` invokes the compiled Swift target-acceptance CLI through `judge`
JSONL. Python does not implement acceptance, identify languages, import a model,
download data or load a tokenizer. Tests use invented inputs and canned replies.
Use Python 3.13; `python3` below must select that interpreter.

From the checkout, set the existing external output root as described
above. Build the offline CLI and use new destinations under that root:

```sh
Scripts/build-target-eval-cli.sh "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/latin-cli-delivery"

"$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/latin-cli-delivery/target-acceptance-cli" \
  prompts --output-dir "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/latin-prompts"

PYTHONDONTWRITEBYTECODE=1 python3 -m Scripts.target_eval.calibrate \
  --cli "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/latin-cli-delivery/target-acceptance-cli" \
  --un-root ../data/un \
  --output "$LIVELINGO_TARGET_EVAL_OUTPUT_ROOT/new-report.json"
```

Existing outputs are never replaced. `corpora.validate_output_path` rejects
checkout writes, symlinks and destinations outside the configured root. UN input
defaults to `../data/un`; calibration reads curated `S_PV.*/turns.json`, without
opening audio, raw records or quarantines. Partial turns are excluded and counted
by default; `--include-partial` is a diagnostic opt-in.

One explicit reference annotation is applied **in memory at corpus load**:
S/PV.10142, turn 9, English, U+03A4 (Greek capital Tau) becomes U+0054 (Latin T).
`reference_annotations.py` binds it to the complete original reference SHA-256
and zero-based Unicode scalar offset 3408. A mismatch stops loading. No other
occurrence, meeting or language is corrected. Metadata retains the annotation
ID, before/after hashes, code points, offset and official-record URL, PDF/text
hashes, page and line. The local PDF text layer independently confirmed the Tau;
calibration does not re-read those record files. Raw corpus files stay unchanged,
and the Swift `nonLatinScript` rule is not relaxed. See [PROVENANCE.md](PROVENANCE.md).

The evaluation unit is a complete curated speech turn, not a sentence. For each
es/fr/en target, a turn supplies five source comparisons: a human target
reference, a loaded-source echo and four wrong-language references for each
source. No source equals its target, including en/en. The explicit annotation
affects every use of that loaded English reference consistently. Nothing is
discarded because of length, script, identical wording or a verdict.

Reports retain descriptive comparison counts and ratios, with a separate
`clustered_by_turn_reference` summary. Five uses of one target reference form
**one turn/reference cluster**, not five independent observations. Clustered
false rejection is the equal-weight mean of within-turn rejection fractions;
`any_false_rejection` also counts turns with at least one rejected reference.
Every cluster retains its comparison/rejection counts. Echo and wrong-language
interception, source breakdowns and wrong-candidate breakdowns are clustered too.

Confidence intervals use a deterministic percentile bootstrap: lexicographically
sort turn IDs, resample whole turn/reference clusters with replacement, then
take the interpolated 2.5th and 97.5th percentiles of mean turn rates.
`--bootstrap-resamples` defaults to 10000 and `--bootstrap-seed` to 0; both are
recorded. Intervals condition on the observed turns and fixed policy. All-zero
or all-one outcomes give degenerate bootstrap intervals and **do not establish
a population bound**. Turns within one meeting may remain correlated; that
dependence is not estimated here. As a separate best-case diagnostic, zero
failures among 85 IID turn references would still have a one-sided 95% binomial
upper bound of about 3.46%, from `1 - 0.05 ** (1 / 85)`. This is not a confidence
bound for observed nonzero failures.

Length ratios include rejected references. Count NFC-normalized Unicode letters
(Lu/Ll/Lt/Lm/Lo, Python `isalpha`), preserving accents and excluding combining
marks, digits and punctuation. Every CLI count and ratio is checked; mismatches
stop calibration. Zero-letter source ratios are null. Quantiles use linear
interpolation at `(n - 1) * q`. Reports include p50/p95/p99/p99.5/max, rejection
codes and length rejections. Each source breakdown compares the observed p99.5
ceiling with the CLI's configured ratio; mismatches are reported, never tuned.

`--maximum-length-ratio` is an explicit diagnostic override to Swift. Without
it, the CLI selects its fixed target/source parameters; the documented formula
is `max(sourceLetters, 24) * maximumRatio + 12`. The 12-letter allowance is a
heuristic. Effective limit ratios include that allowance and differ from the
configured ratio. The reviewed `fr <- ru` parameter 1.20 does **not** equal the
documented p99.5 ceiling of 1.19; [PROVENANCE.md](PROVENANCE.md) gives the evidence.
This review retains the existing 1.20 parameter, discloses the unconfirmed
extra 0.01 in Swift's comment, and changes no policy ratio.

The same UN turns supplied the parameters and the evaluation references. These
are **in-sample diagnostics**, with **no independent holdout** and no sentence,
short-caption or formula generalization evidence. Reports explicitly leave the
1% population false-rejection gate unestablished. Synthetic tests verify code,
not held-out accuracy. Wrong-language labels test language/script interception,
not semantic quality; script-different negatives can make interception easier.
Token ratios remain unmeasured. No real corpus is downloaded or exported here.

Schema 2 reports retain all CLI verdicts, exclusions, relative input manifests,
reference annotations, code hashes and counting/resampling methods. The CLI
identity is only its **basename and SHA-256**, without its machine path. Stderr
is represented by byte counts and hashes, without raw diagnostic text. The
command prints its output path relative to the configured output root. Input and CLI
mutations are detected before writing. `--batch-size` defaults to 128 and
`--timeout-seconds` to 120 per batch; both pipes are drained while sending input.
Unknown, duplicate, missing or inconsistent replies fail.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  Scripts.target_eval.test_corpora \
  Scripts.target_eval.test_metrics \
  Scripts.target_eval.test_calibrate \
  Scripts.target_eval.test_review_sidecar
```

Initial reuse provenance is `src-target-eval` commit
`b4abd77454e74c4646b62bbde8c26e1bb94703f4`: `__init__.py`, `corpora.py`,
`metrics.py`, `test_corpora.py` and `test_metrics.py` originated there.
`corpora.py` now adds the explicit annotation. Reports hash current Python files,
including the additional annotation and clustering modules; the reuse commit
identifies origin, not byte identity of every current file.

The Swift `judge` command receives `id`, `source`, `candidate`, `sourceLanguage`,
`targetLocale` and optional `maximumLengthRatio` per stdin line, and emits one
verdict per line. Latin acceptance remains the Swift owner's responsibility.
The Python runner evaluates only en/es/fr; it does not assert that the diagnostic
zh-Hans CLI reproduces every production App branch.

`prompts` exports UTF-8 bytes and a SHA-256 manifest. Build and prompt output
directories must be new descendants of `LIVELINGO_TARGET_EVAL_OUTPUT_ROOT`,
without symlinks. The build and prompt export read that variable; neither
checkout placement, binary placement nor the current directory supplies
a fallback. An absent, relative, missing, symlinked or checkout root fails
before output creation.
The build uses `work/dd-latin/target-acceptance-cli/<output-directory-name>/ModuleCache.noindex`
and the sibling `tmp` directory. A different output name isolates concurrent
CLI builds without conflicting with the App's DerivedData. Synthetic Swift CLI integration tests remain in
`Scripts/test_target_acceptance_cli.py`; set `LIVELINGO_TARGET_ACCEPTANCE_CLI`
when using a different build directory. Those tests require an existing binary.

The root `test_offline_suite.py` exposes all existing Python script suites to
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest` on Python 3.13, which otherwise
skips the namespace directories. The complete suite also requires the existing
runtime dependencies, a current offline CLI via `LIVELINGO_TARGET_ACCEPTANCE_CLI`,
and `LIVELINGO_QUALITY_TEST_DIRECTORY` pointing to an isolated directory under
`work/dd-latin`. Set `TMPDIR` to an existing authorized temporary directory
under `work/target-eval` for fixture output, and
`LIVELINGO_ASR_TEST_IN_PROCESS=1` to run the ASR handlers without sockets.
If the selected Python lacks runtime dependencies, add existing tested Python
3.13 site-packages directories to `PYTHONPATH`. Include `$PWD/Scripts` and
`$PWD/Scripts/mlx_runtime` there for the in-process ASR child probe. This reuses
installed dependencies and never installs packages or loads model weights.
The existing `test_target_eval` bridge loads all evaluation suites once;
the new discovery bridge loads the remaining script suites without
duplicating them. It follows unittest's module-name rules; standalone CLI/release
scripts with hyphenated names retain their separate entry points. It never
acquires dependencies or model weights automatically.
