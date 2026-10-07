# Chinese variant converter fixtures

`upstream/` contains unmodified `.in`/`.ans` files from BYVoid/OpenCC
`ver.1.1.9`; SOURCE.json records their source paths and SHA-256 values.
`s2tw`, `s2hk` and `s2twp` must match these upstream answer bytes.

`cases.tsv` is authored synthetic text for comparing ICU, s2tw, s2tw plus
reviewed project tables, s2hk and s2twp. Taiwan/Hong Kong gold columns are
intentionally empty: **待母語者審閱**. Difference counts are not accuracy
scores. No classroom data is used.

The three TWPhrases source files are kept separate, preserving first-file
priority. Project phrase and subject tables have no active mappings.
