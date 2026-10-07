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
Each target/source pair has 85 reference ratios. NFC Unicode letter-count
p99.5 uses linear interpolation at `(85 - 1) * 0.995`, rounded upward to 0.01:

| Target | en | es | fr | zh | ar | ru |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| es | 1.26 | — | 1.23 | 5.44 | 2.25 | 1.24 |
| fr | 1.26 | 1.10 | — | 4.96 | 1.84 | 1.19 |

These are **provisional in-sample values**, not a G2 release result. The prior
fr/ru 1.20 lacked a derivation; its measured ceiling is 1.19. The guard remains
`max(sourceLetters, 24) * ratio + 12`. English ratios are unchanged. Among the
85 Chinese-source turns, 55 contain Han letters only and 30 also contain other
letters; the counts and ratios do not represent an independent subtitle set.

A fresh production acceptance CLI judged 5,100 comparisons. es reference false
rejections: 0/425; fr: 2/425 (length guard, one zh and one ru source). Each target
intercepted 425/425 source echoes and 1,700/1,700 wrong-language references.
These comparisons share 85 references per target and are not independent
samples. No threshold was raised to fit the largest reference. G2 still needs
expanded meetings/sources and an independent holdout of the planned size.

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
