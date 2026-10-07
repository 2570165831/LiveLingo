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

## Pending choices

The user has not selected Spanish Spain/Latin America or French France/Canada.
Neutral language names and style instructions are temporary. Spanish-in-Spanish
and French-in-French speech pass through as suggested by the plan; the sets are
centralized for a later decision. Direct translation remains the default until
G3 evidence supports a routing choice.
