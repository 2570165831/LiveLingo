"""Deterministic offline chrF, terminology, script and paired comparison metrics.

chrF defaults: character order 6, beta 2, case sensitive, whitespace excluded,
effective orders (orders with zero hypothesis or reference count are omitted).
chrF++ additionally uses word orders 1 and 2. Like sacreBLEU 2.x CHRF, each
whitespace token detaches one trailing ASCII punctuation character, or (only if
there is none) one leading character. Reference-absent orders contribute zero
hypothesis count before corpus pooling. Scores are 0..100; an empty
hypothesis/reference scores 0. Corpus scoring pools n-gram counts, rather than
averaging sentence scores. See README.md for source rules and hand-counted tests;
these tests do not constitute a run against an installed sacreBLEU.
"""
from __future__ import annotations

from collections import Counter
import json
import math
from pathlib import Path
import random
import re
import statistics
import string
import sys
from typing import Callable, Iterable, Sequence
import unicodedata

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    __package__ = "Scripts.target_eval"

try:
    from Scripts.privacy_cli import PrivateArgumentParser
except ModuleNotFoundError as error:
    if error.name != "Scripts":
        raise
    from privacy_cli import PrivateArgumentParser
from .corpora import validate_output_path, write_json


def _integer(value: object, label: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def _finite(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be finite numeric data")
    return float(value)


def _words(text: str) -> list[str]:
    words = []
    for word in text.split():
        if len(word) == 1:
            words.append(word)
            continue
        if word[-1] in string.punctuation:
            words.extend((word[:-1], word[-1]))
        elif word[0] in string.punctuation:
            words.extend((word[0], word[1:]))
        else:
            words.append(word)
    return words


def _ngrams(items: Sequence, order: int) -> Counter:
    return Counter(tuple(items[i:i + order]) for i in range(len(items) - order + 1))


def _settings(char_order: int, word_order: int, beta: float) -> None:
    _integer(char_order, "character order", 1)
    _integer(word_order, "word order")
    if _finite(beta, "beta") <= 0:
        raise ValueError("beta must be positive")


def chrf_statistics(hypothesis: str, reference: str, *, char_order: int = 6,
                    word_order: int = 0, whitespace: bool = False,
                    lowercase: bool = False) -> tuple[tuple[int, int, int], ...]:
    """Return per-order counts, omitting hypotheses for reference-absent orders."""
    _settings(char_order, word_order, 2)
    if not isinstance(hypothesis, str) or not isinstance(reference, str):
        raise ValueError("chrF inputs must be strings")
    if lowercase:
        hypothesis, reference = hypothesis.lower(), reference.lower()
    hyp_chars = hypothesis if whitespace else "".join(hypothesis.split())
    ref_chars = reference if whitespace else "".join(reference.split())
    stats = []
    for hyp, ref, maximum in ((hyp_chars, ref_chars, char_order),
                              (_words(hypothesis), _words(reference), word_order)):
        for order in range(1, maximum + 1):
            hyp_counts, ref_counts = _ngrams(hyp, order), _ngrams(ref, order)
            stats.append((sum(hyp_counts.values()) if ref_counts else 0, sum(ref_counts.values()),
                          sum((hyp_counts & ref_counts).values())))
    return tuple(stats)


def _score(stats: Sequence[Sequence[int]], beta: float) -> float:
    effective = [(matched / hyp, matched / ref) for hyp, ref, matched in stats if hyp and ref]
    if not effective:
        return 0.0
    precision = statistics.fmean(p for p, _ in effective)
    recall = statistics.fmean(r for _, r in effective)
    denominator = beta * beta * precision + recall
    return 100 * (1 + beta * beta) * precision * recall / denominator if denominator else 0.0


def _pool(stats: Iterable[Sequence[Sequence[int]]], order_count: int) -> list[list[int]]:
    pooled = [[0, 0, 0] for _ in range(order_count)]
    for row in stats:
        for i, counts in enumerate(row):
            for j, count in enumerate(counts):
                pooled[i][j] += count
    return pooled


def chrf(hypothesis: str, reference: str, *, char_order: int = 6, word_order: int = 0,
         beta: float = 2, whitespace: bool = False, lowercase: bool = False) -> float:
    _settings(char_order, word_order, beta)
    return _score(chrf_statistics(hypothesis, reference, char_order=char_order,
                                 word_order=word_order, whitespace=whitespace,
                                 lowercase=lowercase), beta)


def chrfpp(hypothesis: str, reference: str, **kwargs) -> float:
    return chrf(hypothesis, reference, word_order=2, **kwargs)


def corpus_chrf(hypotheses: Iterable[str], references: Iterable[str], *,
                char_order: int = 6, word_order: int = 0, beta: float = 2,
                whitespace: bool = False, lowercase: bool = False) -> float:
    _settings(char_order, word_order, beta)
    rows = (chrf_statistics(hyp, ref, char_order=char_order, word_order=word_order,
                            whitespace=whitespace, lowercase=lowercase)
            for hyp, ref in zip(hypotheses, references, strict=True))
    return _score(_pool(rows, char_order + word_order), beta)


def corpus_chrfpp(hypotheses: Iterable[str], references: Iterable[str], **kwargs) -> float:
    return corpus_chrf(hypotheses, references, word_order=2, **kwargs)


def _normalized(text: str) -> str:
    return " ".join(unicodedata.normalize("NFC", text).casefold().split())


def _latin_word_character(char: str) -> bool:
    return char == "_" or char.isdecimal() or unicodedata.name(char, "").startswith("LATIN ")


def _contains_term(text: str, term: str) -> bool:
    # Chinese terms may be substrings of prose. Latin terms must not earn credit
    # from unrelated longer words (ion != motion), including accented neighbors.
    for match in re.finditer(re.escape(term), text):
        if (_latin_word_character(term[0]) and match.start() and
                _latin_word_character(text[match.start() - 1])):
            continue
        if (_latin_word_character(term[-1]) and match.end() < len(text) and
                _latin_word_character(text[match.end()])):
            continue
        return True
    return False


def terminology_hit_rate(hypothesis: str, terms: Iterable[str | Sequence[str]]) -> dict:
    """Each required target concept earns one hit if any supplied alternative occurs."""
    if (not isinstance(hypothesis, str) or not isinstance(terms, Iterable)
            or isinstance(terms, (str, bytes, dict))):
        raise ValueError("terminology requires hypothesis text and an iterable of terms")
    text, hit_count, total, missing = _normalized(hypothesis), 0, 0, []
    for term in terms:
        if not isinstance(term, (str, Sequence)):
            raise ValueError("each required term must be a string or sequence of alternatives")
        alternatives = [term] if isinstance(term, str) else list(term)
        if not alternatives or any(not isinstance(t, str) or not t.strip() for t in alternatives):
            raise ValueError("required terms/alternatives must be nonempty strings")
        total += 1
        if any(_contains_term(text, _normalized(t)) for t in alternatives):
            hit_count += 1
        else:
            missing.append(alternatives)
    return {"hit_count": hit_count, "term_count": total,
            "rate": hit_count / total if total else None, "missing_terms": missing}


def _script(char: str) -> str:
    code = ord(char)
    if (0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF
            or 0xF900 <= code <= 0xFAFF or 0x20000 <= code <= 0x2FA1F
            or 0x30000 <= code <= 0x323AF or char in "〇々"):
        return "han"
    name = unicodedata.name(char, "")
    if "HIRAGANA" in name or "KATAKANA" in name:
        return "kana"
    if "HANGUL" in name:
        return "hangul"
    if "GREEK" in name or char in "µºª":
        return "scientific_symbol"
    for script in ("LATIN", "CYRILLIC", "ARABIC"):
        if script in name:
            return script.lower()
    return "other"


def text_purity(text: str, target_locale: str, *,
                simplified_only_chars: Iterable[str] | None = None) -> dict:
    """Count writing systems; this cannot distinguish English/Spanish/French.

    Chinese/Russian/Arabic permit Latin scientific symbols. Greek letters and
    µ/º/ª are allowed symbols in every supported target; 々 is Han. Other unknown
    letter scripts remain forbidden. Digits, punctuation and combining marks do
    not enter the letter denominator. Simplified residue
    for zh-Hant needs a caller-supplied audited *exclusive* character inventory;
    ambiguous/shared forms such as 后 must not be blindly treated as residue.
    Without that inventory the residue result is unknown, not zero.
    """
    if not isinstance(text, str) or not isinstance(target_locale, str) or not target_locale:
        raise ValueError("script purity requires text and a target locale")
    language = target_locale.split("-")[0]
    allowed = {"zh": {"han", "latin"}, "en": {"latin"}, "es": {"latin"},
               "fr": {"latin"}, "ru": {"cyrillic", "latin"},
               "ar": {"arabic", "latin"}, "ja": {"han", "kana", "latin"},
               "ko": {"hangul", "han", "latin"}}
    if language not in allowed:
        raise ValueError("unsupported target writing system")
    allowed[language].add("scientific_symbol")
    counts = {script: 0 for script in ("han", "kana", "hangul", "latin", "cyrillic", "arabic", "other")}
    for char in text:
        if unicodedata.category(char).startswith("L") or char == "〇":
            script = _script(char)
            counts[script] = counts.get(script, 0) + 1
    letters = sum(counts.values())
    forbidden = sum(count for script, count in counts.items() if script not in allowed[language])
    residue, residue_rate = None, None
    traditional = target_locale == "zh-Hant" or target_locale.startswith("zh-Hant-")
    if simplified_only_chars is not None:
        inventory = set(simplified_only_chars)
        if not inventory or any(not isinstance(char, str) or len(char) != 1 or _script(char) != "han"
               for char in inventory):
            raise ValueError("simplified-only inventory must be nonempty and contain individual Han characters")
        if traditional:
            residue = sum(char in inventory for char in text)
            residue_rate = residue / counts["han"] if counts["han"] else None
    return {"script_counts": counts, "letter_count": letters, "forbidden_letter_count": forbidden,
            "script_purity": 1 - forbidden / letters if letters else None,
            "simplified_residue_count": residue, "simplified_residue_rate": residue_rate,
            "simplified_inventory_provided": simplified_only_chars is not None}


def length_ratio(source: str, target: str, *, unit: str = "characters") -> dict:
    """Target/source ratio of non-whitespace code points or Unicode letters."""
    if not isinstance(source, str) or not isinstance(target, str):
        raise ValueError("length inputs must be strings")
    if unit == "characters":
        measure = lambda text: sum(not char.isspace() for char in text)
    elif unit == "letters":
        measure = lambda text: sum(unicodedata.category(char).startswith("L") for char in text)
    else:
        raise ValueError("length unit must be characters or letters")
    source_count, target_count = measure(source), measure(target)
    return {"unit": unit, "source_count": source_count, "target_count": target_count,
            "ratio": target_count / source_count if source_count else None}


def token_ratio(source_tokens: int, target_tokens: int) -> dict:
    """Only measured counts from a common tokenizer; never a character estimate."""
    _integer(source_tokens, "source token count")
    _integer(target_tokens, "target token count")
    return {"source_tokens": source_tokens, "target_tokens": target_tokens,
            "ratio": target_tokens / source_tokens if source_tokens else None}


def _percentile(values: Sequence[float], quantile: float) -> float:
    position = (len(values) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    return values[low] + (values[high] - values[low]) * (position - low)


def _bootstrap(count: int, delta: Callable[[Sequence[int]], float], *,
               iterations: int, confidence: float, seed: int) -> dict:
    _integer(count, "paired sample count", 1)
    _integer(iterations, "bootstrap iterations", 1)
    _integer(seed, "bootstrap seed")
    if not 0 < _finite(confidence, "confidence") < 1:
        raise ValueError("confidence must be strictly between zero and one")
    rng = random.Random(seed)
    draws = sorted(delta([rng.randrange(count) for _ in range(count)]) for _ in range(iterations))
    tail = (1 - confidence) / 2
    return {"sample_count": count, "iterations": iterations, "confidence": confidence, "seed": seed,
            "direction": "candidate-minus-baseline", "delta": delta(list(range(count))),
            "ci_low": _percentile(draws, tail), "ci_high": _percentile(draws, 1 - tail),
            "interval_method": "paired-percentile-linear"}


def paired_bootstrap(baseline: Sequence[float], candidate: Sequence[float], *,
                     iterations: int = 10000, confidence: float = 0.95, seed: int = 0) -> dict:
    """Mean paired metric difference, resampling both routes with the same indices."""
    if len(baseline) != len(candidate):
        raise ValueError("paired routes must have equal sample counts")
    differences = [_finite(b, "candidate score") - _finite(a, "baseline score")
                   for a, b in zip(baseline, candidate, strict=True)]
    return _bootstrap(len(differences), lambda indices: statistics.fmean(differences[i] for i in indices),
                      iterations=iterations, confidence=confidence, seed=seed)


def paired_bootstrap_chrf(baseline: Sequence[str], candidate: Sequence[str], references: Sequence[str], *,
                          char_order: int = 6, word_order: int = 2, beta: float = 2,
                          whitespace: bool = False, lowercase: bool = False,
                          iterations: int = 10000, confidence: float = 0.95, seed: int = 0) -> dict:
    """Resample pooled corpus chrF(++), not the mean of per-sentence chrF scores."""
    _settings(char_order, word_order, beta)
    if len(baseline) != len(candidate) or len(baseline) != len(references):
        raise ValueError("paired routes and references must have equal sample counts")
    def cached(hypotheses):
        return [chrf_statistics(h, r, char_order=char_order, word_order=word_order,
                                whitespace=whitespace, lowercase=lowercase)
                for h, r in zip(hypotheses, references, strict=True)]
    a, b = cached(baseline), cached(candidate)
    def delta(indices):
        return (_score(_pool((b[i] for i in indices), char_order + word_order), beta)
                - _score(_pool((a[i] for i in indices), char_order + word_order), beta))
    result = _bootstrap(len(references), delta, iterations=iterations, confidence=confidence, seed=seed)
    return {**result, "chrf_settings": {"char_order": char_order, "word_order": word_order,
            "beta": beta, "whitespace": whitespace, "lowercase": lowercase, "effective_order": True,
            **_compatibility_settings()}}


def _compatibility_settings() -> dict:
    return {"reference_absent_hypothesis_count": "zero",
            "word_tokenization": "ascii-single-edge-trailing-first"}


def _validate_examples(examples: Sequence[dict]) -> None:
    if not examples:
        raise ValueError("metric input must contain examples")
    seen = set()
    for row in examples:
        if not isinstance(row, dict):
            raise ValueError("metric example must be an object")
        for key in ("id", "source", "reference", "hypothesis", "source_locale", "target_locale"):
            if not isinstance(row.get(key), str):
                raise ValueError(f"metric example requires string {key}")
            if key != "hypothesis" and not row[key].strip():
                raise ValueError(f"metric {key} must be nonempty")
        if row["id"] in seen:
            raise ValueError("duplicate metric example id")
        seen.add(row["id"])
        if "terms" in row and not isinstance(row["terms"], list):
            raise ValueError("metric terms must be a list")


def read_examples(path: str | Path) -> list[dict]:
    """Read explicit local metric JSONL; blank lines, duplicates and incomplete rows fail."""
    examples = []
    with Path(path).open(encoding="utf-8-sig") as handle:
        for line in handle:
            row = json.loads(line)
            examples.append(row)
    _validate_examples(examples)
    return examples


def evaluate(examples: Sequence[dict], *, simplified_only_chars: Iterable[str] | None = None) -> dict:
    _validate_examples(examples)
    inventory = tuple(simplified_only_chars) if simplified_only_chars is not None else None
    rows = []
    for row in examples:
        hypothesis = row["hypothesis"]
        tokens = None
        if "source_tokens" in row or "hypothesis_tokens" in row:
            if "source_tokens" not in row or "hypothesis_tokens" not in row:
                raise ValueError("both measured token counts are required")
            tokens = token_ratio(row["source_tokens"], row["hypothesis_tokens"])
        rows.append({"id": row["id"], "source_locale": row["source_locale"],
                     "target_locale": row["target_locale"], "chrf": chrf(hypothesis, row["reference"]),
                     "chrfpp": chrfpp(hypothesis, row["reference"]),
                     "terminology": terminology_hit_rate(hypothesis, row.get("terms", [])),
                     "purity": text_purity(hypothesis, row["target_locale"], simplified_only_chars=inventory),
                     "length": length_ratio(row["source"], hypothesis),
                     "letter_length": length_ratio(row["source"], hypothesis, unit="letters"),
                     "tokens": tokens})
    groups = {}
    for row in examples:
        groups.setdefault(row["target_locale"], []).append(row)
    scores = {}
    for locale, group in sorted(groups.items()):
        hypotheses, references = [r["hypothesis"] for r in group], [r["reference"] for r in group]
        scores[locale] = {"sample_count": len(group),
                          "source_locales": sorted({r["source_locale"] for r in group}),
                          "chrf": corpus_chrf(hypotheses, references),
                          "chrfpp": corpus_chrfpp(hypotheses, references)}
    report = {"schema_version": 2, "sample_count": len(rows), "by_target_locale": scores,
              "chrf_settings": {"char_order": 6, "pp_word_order": 2, "beta": 2,
                                "whitespace": False, "lowercase": False, "effective_order": True,
                                **_compatibility_settings()}, "examples": rows}
    # Preserve the convenient single-locale fields without publishing a score
    # pooled across different targets.
    if len(scores) == 1:
        score = next(iter(scores.values()))
        report.update(chrf=score["chrf"], chrfpp=score["chrfpp"])
    return report


def compare(baseline: Sequence[dict], candidate: Sequence[dict], *, iterations: int = 10000,
            confidence: float = 0.95, seed: int = 0) -> dict:
    _validate_examples(baseline)
    _validate_examples(candidate)
    a = {row["id"]: row for row in baseline}
    b = {row["id"]: row for row in candidate}
    if len(a) != len(baseline) or len(b) != len(candidate) or a.keys() != b.keys() or not a:
        raise ValueError("paired routes must have identical unique example IDs")
    ids = sorted(a)
    for identity in ids:
        if any(a[identity].get(key) != b[identity].get(key)
               for key in ("source", "reference", "source_locale", "target_locale")):
            raise ValueError("paired routes must use identical sources, references and locales")
    groups = {}
    for identity in ids:
        groups.setdefault(a[identity]["target_locale"], []).append(identity)
    comparisons = {}
    for locale, group_ids in sorted(groups.items()):
        result = paired_bootstrap_chrf([a[i]["hypothesis"] for i in group_ids],
                                       [b[i]["hypothesis"] for i in group_ids],
                                       [a[i]["reference"] for i in group_ids], iterations=iterations,
                                       confidence=confidence, seed=seed)
        comparisons[locale] = {"example_ids": group_ids,
                               "source_locales": sorted({a[i]["source_locale"] for i in group_ids}),
                               **result}
    report = {"schema_version": 2, "metric": "corpus-chrfpp", "sample_count": len(ids),
              "example_ids": ids, "by_target_locale": comparisons}
    if len(comparisons) == 1:
        report.update(next(iter(comparisons.values())))
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = PrivateArgumentParser(prog="target-eval-metrics", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    score = subparsers.add_parser("score", help="score a local public/synthetic metric JSONL")
    score.add_argument("input")
    score.add_argument("--simplified-only", help="audited simplified-exclusive characters, one per line")
    score.add_argument("--output", required=True)
    comparison = subparsers.add_parser("compare", help="paired corpus chrF++ bootstrap")
    comparison.add_argument("baseline")
    comparison.add_argument("candidate")
    comparison.add_argument("--iterations", type=int, default=10000)
    comparison.add_argument("--confidence", type=float, default=0.95)
    comparison.add_argument("--seed", type=int, default=0)
    comparison.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        destination = validate_output_path(args.output)
        if args.command == "score":
            inventory = None
            if args.simplified_only:
                inventory = Path(args.simplified_only).read_text(encoding="utf-8-sig").splitlines()
            report = evaluate(read_examples(args.input), simplified_only_chars=inventory)
        else:
            report = compare(read_examples(args.baseline), read_examples(args.candidate),
                             iterations=args.iterations, confidence=args.confidence, seed=args.seed)
        write_json(report, destination)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
