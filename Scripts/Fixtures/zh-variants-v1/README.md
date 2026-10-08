# Chinese variant converter fixtures

`upstream/` contains unmodified `.in`/`.ans` files from BYVoid/OpenCC
`ver.1.1.9`; SOURCE.json records source paths and SHA-256 values.
Raw `s2tw`, `s2hk` and `s2twp` must match these upstream answer bytes.

`cases.tsv` retains the original ten authored synthetic inputs. The `llmTW`
and `llmHK` columns are literal rendering regression expectations reviewed by
Codex. Isolated ambiguous characters use upstream defaults, without asserting
that the missing semantic context has been resolved. No classroom data is used.

`terms.tsv` contains one positive and one counterexample for every one of the
75 project entries: 150 cases, with literal regional outputs. Counterexamples
exercise code preservation and academic contexts. Additional regressions cover
longer accepted spellings, enzyme compounds, and quantity-vs-name bit usage.

用语经大模型审阅，非母语者人工审校。 The full 356-sentence corpus, per-row
judgments and review report live in the task's work directory, outside Git.
These fixtures are LLM-reviewed regression gold, not native-speaker accuracy
scores. Each table entry cites its own public source. Taiwan/Hong Kong tables
are separate and are tested in both regions. Unscoped mappings for functions,
objects, files, programs and data are intentionally excluded.
