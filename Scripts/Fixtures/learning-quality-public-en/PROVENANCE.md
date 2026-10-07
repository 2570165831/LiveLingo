# PROVENANCE

Course context: Harvard University's public CS50 / CS50x, taught by David J.
Malan. The C, Algorithms and Memory topics refer to the public 2019 and 2023
course context:

- https://cs50.harvard.edu/x/2019/
- https://cs50.harvard.edu/x/2023/

License context: CS50's Creative Commons Attribution-NonCommercial-ShareAlike
(CC BY-NC-SA), as specified by this task. The exact license version and course
pages were not independently checked during this offline run.

All caption-like English sentences and gold meanings are self-authored
summaries in our own words. They are not copied subtitles, verbatim lecturer
quotations or transcriptions. They cover stable introductory programming
concepts associated with CS50, rather than claims about a particular sentence
or timestamp in one lecture.

`LIVELINGO_CS50_REFERENCE_DIR` was not set. No reference subtitle directory,
course video or online course material was read. This is a synthetic regression
corpus with topic-level attribution; source alignment remains unverified.

The three cases contain 12 caption rows and 12 gold expectations: four for C
basics, four for algorithms and four for memory. Each case has two stages of
two captions. Stage-2 expectations require retaining the earlier stage's
knowledge. The legacy field named `chinese` contains the same English text as
`english`; run the corpus with `--target en`.

The author prepared the source rows and expectations together, before viewing
any evaluated model response. These development fixtures have no independent
holdout status. `sourceRows` provides one-based stage/row references for manual
checking; `semanticChecks` records conditions a later factual review must
consider. Regex matches provide structural signals, not semantic acceptance.

`manifest.json` freezes the three fixture files and `gold.json`. Any later
probe-generated times follow the artificial fixture timing policy, not a CS50
recording. Offline preparation and injected test responses do not establish
production-model learning quality or a comparison with the required baseline.
