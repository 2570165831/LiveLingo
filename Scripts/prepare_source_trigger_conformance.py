#!/usr/bin/env python3
"""Prepare Xcode goldens from the independently frozen offline evaluator.

No inference, audio, MLX or transcript input. Private feature files are excluded;
the only exported rows are synthetic or public, restricted to decision inputs.
Run Swift tests with run-xcode-tests.py after placing --output at
DERIVED_DATA/tmp/source-trigger-conformance.json. Never imports the collector.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load_simulator(path):
    spec = importlib.util.spec_from_file_location("frozen_trigger_simulator", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def synthetic_rows():
    def row(index, **changes):
        return {"dataset": "synthetic", "split": "dev", "track": "edges", "index": index,
                "start_s": index * 8.0, "end_s": (index + 1) * 8.0,
                "reference_language": None, "reference_trusted": False,
                "parakeet_accepted": True, "pk_mean_probability": 0.99,
                "pk_min_probability": 0.2, "pk_word_count": 8, "pk_words_per_second": 1.0,
                "nl_language": "en", "nl_probability": 1.0,
                "probe_language": "es", "probe_label_probability": 0.55,
                "probe_english_probability": 0.01, "probe_seconds": 0.1,
                "probe_error": False, **changes}

    # Adjacent confirmations, non-Latin followups, label changes, failures,
    # missing statistics, explicit scripts and gaps before/after a candidate.
    cases = [
        {}, {"pk_mean_probability": 0.8999}, {}, {},
        {"probe_language": "fr"}, {}, {"probe_error": True}, {},
        {"pk_min_probability": 0.0499}, {"probe_language": "en"}, {},
        {"parakeet_accepted": False, "probe_language": "zh", "probe_label_probability": 0.9,
         "probe_english_probability": 0.05},
        {"probe_language": "ar", "probe_label_probability": 0.9, "probe_english_probability": 0.05},
        {"probe_label_probability": None}, {}, {"pk_mean_probability": None, "pk_min_probability": None},
        {"pk_mean_probability": 0.9, "pk_min_probability": 0.05},
        {"parakeet_accepted": False, "probe_language": "zh-Latn"}, {"probe_language": "zh-Latn"},
        {"probe_language": "es-Cyrl", "probe_label_probability": 0.9, "probe_english_probability": 0.05},
        {"probe_language": "fil", "probe_label_probability": 0.9, "probe_english_probability": 0.05},
        {"probe_language": None}, {"pk_min_probability": 0.04}, {}, {},
    ]
    data = [row(i, **change) for i, change in enumerate(cases)]
    data.extend([row(27, pk_mean_probability=0.8), row(29), row(30, pk_mean_probability=0.8), row(31)])
    rng = random.Random(5509005)
    languages = ["es", "fr", "zh", "ru", "ar", "en", "fil", "xx", "zh-Latn", "es-Cyrl", None]
    for index in range(4096):
        data.append(row(index + index // 37, track="random",
            parakeet_accepted=rng.choice([True, True, False]),
            pk_mean_probability=rng.choice([None, .8999, .9, .9001, .99]),
            pk_min_probability=rng.choice([None, .0499, .05, .0501, .2]),
            probe_language=rng.choice(languages), probe_error=rng.randrange(17) == 0,
            probe_label_probability=rng.choice([None, .5499, .55, .5501, .8999, .9, .9001, 1.0]),
            probe_english_probability=rng.choice([None, 0.0, .0099, .01, .0101, .0499, .05, .0501])))
    return data


def golden_groups(rows, simulator, parameters, prefix):
    checked = simulator._check_rows(rows)
    groups = {}
    for row, decision in zip(checked, simulator._decisions(checked, parameters)):
        if row.get("private_classroom", False):
            raise ValueError("private feature export is prohibited")
        key = (row["dataset"], row["split"], row["track"])
        name = prefix + ":" + ":".join(key)
        groups.setdefault(name, []).append({
            "index": row["index"], "parakeetAccepted": row["parakeet_accepted"],
            "mean": row["pk_mean_probability"], "minimum": row["pk_min_probability"],
            "probeLanguage": row["probe_language"], "probability": row["probe_label_probability"],
            "englishProbability": row["probe_english_probability"], "probeFailed": row["probe_error"],
            "expected": {"selected": decision.selected, "baseEligible": decision.base_eligible,
                         "followup": decision.followup, "qualifiedLanguage": decision.qualified_language,
                         "language": decision.language, "reason": decision.reason},
        })
    return [{"name": name, "rows": data} for name, data in groups.items()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", type=Path, required=True)
    parser.add_argument("--parameters", type=Path, required=True)
    parser.add_argument("--features", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    parameters = json.loads(args.parameters.read_bytes())["parameters"]
    if parameters != json.loads((ROOT / "Fixtures/source-language-trigger-parameters.json").read_bytes()):
        raise ValueError("frozen parameters differ from App fixture")
    simulator = load_simulator(args.simulator)
    frozen = simulator.Parameters(**parameters)
    groups = golden_groups(synthetic_rows(), simulator, frozen, "synthetic")
    inputs, public_rows = [], []
    for path in sorted(args.features.glob("*.jsonl")):
        # Explicit public allowlist avoids reading private classroom files.
        if not (path.name.startswith("CS50-") or path.name.startswith("UN")):
            continue
        rows, identity = simulator.read_jsonl([path], allowed_splits={"dev", "original", "new"})
        if any(row.get("private_classroom", False) for row in rows):
            raise ValueError("a public-allowlisted feature file contains private rows")
        inputs.extend(identity)
        public_rows.extend(rows)
    groups.extend(golden_groups(public_rows, simulator, frozen, "public"))
    receipt = {"simulator_sha256": hashlib.sha256(args.simulator.read_bytes()).hexdigest(),
               "parameters_sha256": hashlib.sha256(args.parameters.read_bytes()).hexdigest(),
               "inputs": inputs, "synthetic_segments": sum(len(g["rows"]) for g in groups if g["name"].startswith("synthetic:")),
               "public_segments": len(public_rows), "private_segments_exported": 0,
               "groups": len(groups)}
    for path, content in [(args.output, groups), (args.receipt, receipt)]:
        if path.is_symlink() or path.resolve().is_relative_to(ROOT):
            raise ValueError("evidence must be outside the checkout without symlinks")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x") as output:
            json.dump(content, output, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
            output.write("\n")
    print(json.dumps({key: receipt[key] for key in ("synthetic_segments", "public_segments", "private_segments_exported", "groups")}))


if __name__ == "__main__":
    main()
