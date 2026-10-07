# Spanish and French implementation evidence

## Step 25: unreleased captions

Spanish and French remain unreleased. The GUI exposes neither target. Independent
literal caption, 4B, wrapper and recovery prompts use neutral Spanish/French;
regional wording, same-language pass-through sets and the default direct route
are centralized in `LatinOutputDefaults`. The optional non-English English-pivot
route makes two translation calls; direct translation makes one. Same-language
speech makes none. English-target behavior stays on its existing path.

Apple en-to-es/fr preview runs only with an installed language package. Supported
but undownloaded, unsupported, and preparation-error states retain the formal
translation path. Both Han supplementary repair types are disabled. Production
es/fr tail repair joins a stable sentence prefix and its tail with one space.

The local UN corpus was read without modification or network access. Four
meetings contain 85 complete aligned turns and two excluded partial turns.
Each target/source pair has 85 reference ratios. The original Step 25 values
used raw target/source NFC Unicode letter counts and linear interpolation at
`(85 - 1) * 0.995`, rounded upward to 0.01:

| Target | en | es | fr | zh | ar | ru |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| es | 1.26 | — | 1.23 | 5.44 | 2.25 | 1.24 |
| fr | 1.26 | 1.10 | — | 4.96 | 1.84 | 1.19 |

These are **provisional in-sample values**, not a G2 release result. The prior
fr/ru 1.20 lacked a derivation; its measured ceiling is 1.19. The guard remains
`max(sourceLetters, 24) * ratio + 12`. English ratios are unchanged. Among the
85 Chinese-source turns, 55 contain Han letters only and 30 also contain other
letters; the counts and ratios do not represent an independent subtitle set.

At those original values, the Step 25 production acceptance CLI judged 5,100
comparisons. es reference false
rejections: 0/425; fr: 2/425 (length guard, one zh and one ru source). Each target
intercepted 425/425 source echoes and 1,700/1,700 wrong-language references.
These comparisons share 85 references per target and are not independent
samples. No threshold was raised to fit the largest reference. G2 still needs
expanded meetings/sources and an independent holdout of the planned size.

### Copyfix: Chinese-source Spanish provisional ratio

The existing `tl2526/calibration-audit/REVIEW-CALIBRATION.md` and
`short-source-diagnostic.json` identify two repeated short sources controlling
the original es/zh 5.44. `recompute_es_zh_length.py` independently rereads the
four original `turns.json` files under the lab's `data/un`; it does not use CLI
verdicts as inputs or change `calibrate.py`. The raw files have 87 mapped turns:
18/18, 17/17, 22/24 and 28/28 included for meetings 10142, 10153, 10168 and 10192.
All six texts must be nonempty and all six statuses `extracted`. The only
excluded turns are 10168:10 and :11, because their Russian text is partial.
No whole turn is split or realigned; no es/zh reference annotation is applied.

Raw input identities, relative to `data/un`, are:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `S_PV.10142/turns.json` | 634207 | `8f23724176b6bfab8011556c1fe1149440e880d574934118bfa0c6ca95f8f459` |
| `S_PV.10153/turns.json` | 518875 | `28edc8c70bae200a5d9cbfe392eaaf6ee5676a292908b30c1e811b3c44a13326` |
| `S_PV.10168/turns.json` | 587796 | `8411e448f9ab11dda919e3ad9b240a94ede6088d24e99cb1de23eba9d12d8331` |
| `S_PV.10192/turns.json` | 656580 | `44ce01bcd28997f781062bb378f32729e3e798da3eeb413d3b59303a2cb940ca` |

This is the same manifest as the existing Step 25 report, SHA-256
`adb5f492bf1d8646cebf704cb4d15b786a2eb2e87e370b7630d295d0177da86f`.
The manifest hashes the compact UTF-8 sorted-key array of `path`, `bytes` and
`sha256` objects in the file order above. The script pins each input hash and
rechecks the files after calculation. Its output retains all 85 observations,
text hashes, counts, duplicate identities and exact interpolation endpoints.

Counting is NFC followed by Unicode Lu/Ll/Lt/Lm/Lo scalars, including letters
from other scripts in mixed Chinese sources; marks, digits and punctuation do
not count. Each source group below is selected before any acceptance decision.
Deduplication means identical NFC Chinese **whole text**, without trimming or
punctuation removal, retaining the largest es/zh ratio once per group (ties use
the smallest turn ID). This produces 84 distinct sources, not 84 independent
samples. Stratification keeps `<24` and `>=24` sources separate. The additional
all-turn diagnostic uses `esLetters / max(zhLetters, 24)`, matching the production
denominator. Neither quantile subtracts the existing +12 allowance.

For every group, sort ratios and linearly interpolate at `(n - 1) * 199/200`:
`lower + (upper - lower) * (position - floor(position))`. The dedicated script
uses exact fractions and integer `ceil(p99.5 * 100) / 100`, avoiding rounding
ambiguity at a hundredth. The recomputed values are:

| Method | n | Zero-based position | p99.5 | Ceiling to 0.01 |
| --- | ---: | ---: | ---: | ---: |
| Original raw es/zh | 85 | 83.58 | 5.4375 | 5.44 |
| Source deduplicated, raw es/zh | 84 | 82.585 | 5.240536296389167 | 5.25 |
| Source >=24, raw es/zh | 83 | 81.59 | 4.947313799104824 | 4.95 |
| Source <24, raw es/zh | 2 | 0.995 | 5.4375 | 5.44 |
| All turns, production floor denominator | 85 | 83.58 | 4.946933924302552 | 4.95 |

The two short sources are 10168:1 and 10192:1: identical Chinese text, 16 source
letters and 87 Spanish letters each. Raw ratios are 87/16; floor-adjusted ratios
are 87/24 = 3.625. Source deduplication alone still puts that template at the
upper quantile endpoint. Both the >=24 group and all floor-adjusted turns instead
use 10192:20 (3738/759) and 10168:13 (4948/997) as their endpoints, with upper
weights 0.59 and 0.58 respectively. The separate short group has only one source
template and provides no evidence for a general short-caption threshold.

The adopted provisional es/zh coefficient is **4.95**, derived from the >=24
source p99.5 and corroborated by the all-turn floor-adjusted ceiling. Its known
in-sample length effect is 10168:13: 4948 Spanish letters exceed the unchanged
24/+12 guard's 4947.15 limit by **0.85 letters**. Arithmetic gives 1/85 length
rejections at 4.95 versus 0/85 at 5.44 and the source-deduplicated 5.25; these
are not new Swift verdicts.

For diagnosis, preserving every reference length pass in this sample would
require `(4948 - 12) / 997 = 4.950852557673019`, ceiling **4.96**. This is the
maximum sample boundary with +12, not p99.5, and was not adopted. Expanded data
and an independent holdout, including overlength-leak checks, remain required.

Reproduce from the checkout, with the existing external scratch directory:

```sh
TMPDIR=../work/dd-copyfix/tmp python3 -B Scripts/target_eval/recompute_es_zh_length.py \
  --un-root ../data/un --output ../work/dd-copyfix/es-zh-length-recompute.json
TMPDIR=../work/dd-copyfix/tmp python3 -B -m unittest \
  Scripts.target_eval.test_recompute_es_zh_length -v
```

Reports are created exclusively in `work/dd-copyfix` and existing files are never
replaced; use a new report basename for a repeat. Seven synthetic focused tests
cover NFC counts, fractional interpolation/ceil, source deduplication, floor
strata, inclusive length boundaries, six-language completeness/raw hashes and
output preservation. The saved calculation is `work/dd-copyfix/es-zh-length-recompute.json`
and the test log is `work/dd-copyfix/es-zh-recompute-tests.log`. This recomputation
uses the same 85 calibration turns and runs no Swift CLI, model or independent
quality gate. The original 5,100-comparison results above do not validate a
changed coefficient.

### Copyfix: Latin source-copy and retained-name boundaries

`int-fix2/REVIEW.md` L1/R1 and `tl2526/REVIEW.md` medium 1/2 now share this
decision order in `LatinTargetAcceptance`: existing structural/JSON/script
checks; structurally supported formulas/acronyms; source-backed nominal
entities and explicit book-title roles, vetoing ordinary greetings/actions and
predicates; language, English-clause and copied-prose checks on the remaining
text; the existing length guard. No synthesized "The name is ..." carrier or
generic capitalized-title exemption remains. Entity evidence comes from fresh
offline NaturalLanguage taggers on the source, with sorted fixed languages and
an additional casing view only for an entirely uppercase source. No asset
request, recognizer hint, network or shared mutable tagger is used.

Two remaining words suffice to reject an unchanged foreign fragment, covering
`Producto Escalar`, `Matrice Inverse` and `Good Morning`. Singleton decisions
combine shared-word, dictionary-lemma, greeting/action and existing language
evidence. General wrong-language bounds remain >5 words with score >=0.8 and
forced classification >=0.9; the former dual-0.98/three-word predicate remains
only as a diagnostic, not as an exemption. Copied-clause scanning preserves the
old four-word/function-word proof and adds three/four-word source-language
evidence >=0.8 after names are removed. These word counts are review-derived
policy bounds; OS scores are not calibrated correctness probabilities.

The spelling-only acronym bound is 2..5 characters, chosen to retain the
reviewed DNA/ATP/FTIR/NASA/NADH controls. Local ordinary-word lemmas disambiguate
STUDY/REST/SLEEP; chemical syntax, `O(VE)` and numeric identifiers such as STOP2
have separate structural evidence. Names embedded in translated prose are
protected as source literals. A quoted book title protects only its quoted or
explicit title-role occurrence, so the same words in a later ordinary copied
sentence still face the prose veto. Typed institutions require an actual
source proper-noun lemma (Wales/Polynésie); capitalization of ordinary internal
nouns such as Students/Pressure is insufficient. Actual named-person
possessives can supply bounded nominal context, without extending into verbs.

The additive table in `LatinTargetAcceptanceTests` records the original review
and probe ID on every row; exact duplicate inputs merge their provenance.
Case and other-target variants are explicitly labelled. Ambiguous bare
product/place names are not assigned invented verdicts; four established
academic borrowings are neutral translated controls.

| Target | Reject | Accept | Neutral control | Total |
| --- | ---: | ---: | ---: | ---: |
| en | 151 | 42 | 9 | 202 |
| es | 106 | 18 | 6 | 130 |
| fr | 99 | 18 | 6 | 123 |
| All | 356 | 78 | 21 | 455 |

Every row checks final acceptance through the Latin gate, translation adapter
and injected-request Qwen client, including the expected request count. No new
test locks an OS confidence or entity label. This is a directed regression
matrix, not an independent translation-quality sample or a cross-OS guarantee.

For `tl2526` medium 3, Python checks the exact parsed unit exponent before Pint,
including normalized scientific notation and both sides of an equality; the
absolute exponent limit stays 12. Seven additional CPU tests cover +/-12 and
out-of-range 13/20/1000, including legal v2 input/schema/check/prompt binding.
For low 1, two additional es/fr tests run the default client and actual
pause/resume queue with a nonempty prefix. Only the final subprocess is a
standard-library protocol double; no Generator, weights or GPU are used.

Copyfix local verification, on macOS 27.2 / 26B5091g / arm64:

- Full `xcodebuild test`: XCTest 1146, skipped 1, failures 0; Swift Testing 166,
  failures 0. The baseline was XCTest 1142 and Swift Testing 166; four XCTest
  methods were added. Saved log: `work/dd-copyfix/xcodebuild-institution.log`.
- `check_build_warnings.py`: 0 for both the final focused compilation and full
  test logs. `check_test_preferences.py`: PASS, 282 created/282 cleaned and all
  corresponding preference files absent.
- Python root suite: 682, skipped 6, failures 0; runtime CPU suite: 127, skipped
  2, failures 0, using the existing `dd-tl1417/run-python-gates.sh` environment.
  The two known baseline CPU precision subcases did not fail in this run.
- All nine standalone CLI entries passed with source hashes bound to the final
  acceptance source: 455 acceptance rows, normal CLI help, 20 multilingual
  checks, 6 target-review checks, 7 translation-failure groups, 23 lifecycle
  cases, and learning-quality assertion counts 44/61/50. Their builds reported
  warnings at four unchanged code sites: the CLI's unnecessary `try?` and three
  unused lifecycle-fixture results. These are separate from the zero-warning
  Xcode logs.
- All 35 tracked fixture files and 107 untouched original test-code files are
  byte-identical to `9014439`; original bodies in the two extended XCTest files
  are preserved. The 630-verdict zh-Hans fixture, non-Latin acceptance prefix
  and release profiles are unchanged. The original full suite remains intact.

The source/log binding and CLI receipts are in `work/dd-copyfix`. All runs were
offline with no weights or GPU; en/es/fr remain unreleased. macOS 14 runtime
behavior and an independent model/quality holdout were not tested. Compiling a
macOS 14 deployment target does not establish those results.

Tokenizer-only inspection read the installed 4B/9B `tokenizer.json` files and
loaded no weights. For both es/fr the shared production caption/repair prefix
has 729 tokens on 4B and 1,010 on 9B, exceeding the planned 512/768 boundaries.
This proves prefix length, not cache hits, latency or generated translation
quality. Injected production requests freeze prompt digests in tests.

Step 25 validation: XCTest 1,118 tests, one skip, zero failures; Swift Testing
166 tests, zero failures; Xcode compiler warnings zero; preference cleanup
268 created/268 cleaned with corresponding plists absent. Root Python discovery
658 tests/six skips and CPU-only runtime discovery 116 tests/two skips passed.
The frozen default/English prompt, verdict, course, schema and export assertions
passed without relaxation. No model, GPU, publication or G2–G6 release claim.

## Step 26: unreleased learning notes and review

Independent Spanish/French generation, recovery and review instances retain the
Chinese wire kind/state codes and grammar sentinel. Tests freeze all six prompt
digests. Narrow display mappings cover the six kinds and four follow-up states;
ordinary fixed classroom wording keeps its current policy. The default Chinese
4,000-character batch budget is unchanged.

Arabic literals use exact coefficient/exponent identities, preserving signs and
large integers. Parsing follows the evidence language: English `1,000`, Spanish
`1.000`/`3,14`, French `1\u202f000`/`3,14`. Source scope remains cited quote,
its caption, then this batch. Numeric matching is advisory, not semantic proof.
Accented retrieval, stop words and possessive-pronoun hints apply only to es/fr.
Same-language speech ignores stale text stored in the translation column.
Legacy pending evidence keeps each language group and its caption origin separate.

App-level tests cover target-bound generation, output-limit recovery, legacy
manifest import/rebuild/reopen, and refusal to process unreleased saved courses
without the test override. Queue tests run the actual job and inspect its forwarded
prompt, input, prefix and quote catalog. Neither target is available in the GUI.

`checks.py` normalizes es/fr comma decimals for arithmetic/Pint; chemical equations
retain their existing path. Review quote IDs and languages allow es/fr. The new
shared numeric helper is included in runtime identity and both packaging paths.
Unsupported-locale fixtures now use `de` where `fr` has become supported; their
rejection assertions remain unchanged.
The next release changes worker identity and invalidates paused checkpoints once;
`worker.py` already changed after v0.2.0, so this is part of that next-release
boundary, not an additional reset of the installed app during this task.

Each language has three self-authored synthetic cases, six caption pairs and
12 clause-level coverage hints. The author also wrote the expectations; no
independent original lecture/native-language review or model-quality result is
claimed. Offline injected quality runs exercise real preparation, decoding,
binding, follow-ups and Markdown. The Python scorer cross-checks their saved
artifacts while semantic correctness remains `pending-independent-readback`.

## Review findings: es/fr disposition

The following numbers preserve the nine-item order in the step 15–16 review:

| Item | Disposition and production regression |
| --- | --- |
| 1 | Target source IDs are bound and committed through the notebook/App path. |
| 2 | Pending quotes, prior evidence and origins use the target's groups; English fallback groups remain separate. |
| 3 | Manual typed translation uses independent es/fr prompts and preserves accents. |
| 4 | Adjacent and deferred clients receive es/fr; both supplementary Han repair plans are disabled. |
| 5 | App call-site tests cover direct, pivot, pass-through, Apple preparation and release gates. |
| 6 | Actual adjacent/deferred requests contain only eligible English recent/repair context. |
| 7 | Production clients test Traditional self-description in candidate and licensed source; Chinese verdicts stay frozen. |
| 8 | Production clients forward the target to leakage, self-description, acceptance and numeric veto checks. |
| 9 | The duplicate binding finding is covered by item 1 and actual follow-up commit. |

The step 17 sentence-prefix finding is fixed for es/fr only: the stable sentence
and repaired tail have one boundary space. English behavior stays frozen.

| Step 18–22 review item | Disposition for es/fr |
| --- | --- |
| B1 | Real translation clients reject short English source echoes, preserving the baseline English fix. |
| B2 | Manifest-bound legacy targets persist before transcription restore; actual rebuild/reopen and saved-entry release-gate tests cover es/fr. |
| B3 | Scorer source scope and locale parsing match target-bound Swift evidence; actual saved quality artifacts cross-check. |
| B4 | Notebook Markdown uses target kind/state labels through the narrow exception; wire codes and other fixed wording remain unchanged. |
| B5 | Actual review-queue jobs inspect the forwarded es/fr prompt, input, prefix and catalog. |

An initial step 26 full run caught a regression in Traditional written-number
inspection for es/fr. Restoring non-Chinese inspection folding and the prior
uncertainty result fixes it without changing the old assertions. The 34 focused
old/new regression tests passed; final full-run numbers are recorded below.

Step 26 final validation: clean Xcode test build in the same task-specific fresh
DerivedData, XCTest 1,136 tests/one skip/zero failures and Swift Testing 166/zero
failures. `check_build_warnings.py`: zero compiler warnings;
`check_test_preferences.py`: 278 created/278 cleaned, corresponding plists absent.
Root Python discovery: 668 tests/six skips; CPU-only runtime: 120/two skips, both
passed. The two noted baseline CPU precision failures did not recur in this run.
The environment matches the earlier Python gate script, with all scratch roots
redirected to this task. Optional tokenizer integration tests remain skipped.

Offline CLI regressions passed: multilingual 20 checks, translation failure seven
groups, target review six checks, quality 44 default + 61 target + 50 es/fr
assertions. es/fr made 12 injected calls over six two-stage cases; the Python
scorer accepted every final saved artifact. Standalone CLI compilation retains
the pre-existing unnecessary-`try` warning in `livelingo-cli.swift`; its source
line is unchanged. Xcode's required compiler-warning gate is zero.

All protected default/English tests and fixtures, the 630-entry verdict snapshot,
EE06, export constants, default course/input fingerprints, note/schema/grammar
bytes and traditional rendering passed without changing their frozen values.
Test hosts use unsigned, unsandboxed command overrides; application build settings
are unchanged. No signing, installation, push, weights, GPU or network operation.
G0b real-model replay and G2–G6 release gates were not run.

## Pending choices

The user has not selected Spanish Spain/Latin America or French France/Canada.
Neutral language names and style instructions are temporary. Spanish-in-Spanish
and French-in-French speech pass through as suggested by the plan; the sets are
centralized for a later decision. Direct translation remains the default until
G3 evidence supports a routing choice.
