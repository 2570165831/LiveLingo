"""Offline target-language evaluation; standard library only, no model imports.

Run from the checkout with ``python -m Scripts.target_eval.corpora --help`` or
``python -m Scripts.target_eval.metrics --help``. All generated files, including
synthetic test scratch files, belong in the sibling ``work/target-eval`` directory.
The location is derived from this checkout; it is not configurable to another
root. Existing output files are never replaced.

Corpus exports contain aligned ``id``, ``corpus``, ``texts`` (locale -> text) and
``metadata`` fields. UN alignment is by curated speech turn, not sentence or audio
time. CS50/TED local SRT alignment groups connected positive time overlaps and
reports unmatched cue IDs. FLORES+ accepts explicitly supplied, line-aligned local
text files. None of these readers acquires data or opens audio/PDF files.

Metric input is JSONL with one public or synthetic example per line:
``id``, ``source``, ``reference``, ``hypothesis``, ``source_locale``,
``target_locale``. Optional ``terms`` contains required target terms (a list of
alternatives counts as one concept). Optional ``source_tokens`` and
``hypothesis_tokens`` are measured counts from the same tokenizer. Counts are
never estimated from characters. Script purity is not language identification;
an audited simplified-only character inventory is required to measure simplified
residue in a Traditional Chinese target. Route comparisons must use identical
IDs, sources and references, and resample corpus chrF statistics in matched pairs.
"""
