#!/usr/bin/env python3
"""Prepare Xcode goldens from the independently frozen offline evaluator.

No inference, audio, MLX or transcript input. Private feature files are excluded;
the only exported rows are synthetic or public, restricted to decision inputs.
Run Swift tests with run-xcode-tests.py after placing --output at
DERIVED_DATA/tmp/source-trigger-conformance.json. Never imports the collector.
--synthetic-only writes the portable, mandatory checkout fixture instead.
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
FROZEN_SIMULATOR_SHA256 = "ef55acac98c08f2fccfa3b11cfd6ffd7aee81d9508f3202d3cef52494d152459"
FROZEN_PARAMETERS_SHA256 = "ae05eb38a3c49a983db1f8403da7fc0bd8e36d8da9405672b9012d7fb9db26dc"
BUNDLED_FIXTURE = ROOT / "Fixtures/source-trigger-conformance-synthetic.json"
# Frozen transport vocabulary, independent of the Swift lookup under test.
QWEN_LABELS = dict(zip(
    ("Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish",
     "Portuguese", "Indonesian", "Italian", "Korean", "Russian", "Thai",
     "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch", "Swedish",
     "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian", "Greek",
     "Romanian", "Hungarian", "Macedonian"),
    ("zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru",
     "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs",
     "fil", "fa", "el", "ro", "hu", "mk"), strict=True))


def load_simulator(path):
    spec = importlib.util.spec_from_file_location("frozen_trigger_simulator", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def metadata_row(index, **changes):
    return {"dataset": "synthetic", "split": "dev", "track": "edges", "index": index,
                "start_s": index * 8.0, "end_s": (index + 1) * 8.0,
                "reference_language": None, "reference_trusted": False,
                "parakeet_accepted": True, "pk_mean_probability": 0.99,
                "pk_min_probability": 0.2, "pk_word_count": 8, "pk_words_per_second": 1.0,
                "nl_language": "en", "nl_probability": 1.0,
                "probe_language": "es", "probe_label_probability": 0.55,
                "probe_english_probability": 0.01, "probe_seconds": 0.1,
            "probe_error": False, **changes}


def synthetic_rows():
    row = metadata_row

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


def queue_groups(simulator, parameters):
    """Normalize transport inputs only; all decisions come from simulate.py.

    A failed initial formal pass has no head decision in the journal. Its
    simulator row still clears the causal candidate; expectedAfter checks that
    boundary without inventing a decision for the thrown formal pass.
    """
    def case(**changes):
        probe = {"label": "Spanish", "mode": "probe", "policy": 1,
                 "probability": .55, "englishProbability": .01,
                 "throws": False, "validated": True}
        probe.update(changes.pop("probe", {}))
        return {"parakeetAccepted": True, "mean": .8, "minimum": .2,
                "initialFailure": False, "formalErrors": False, "probe": probe, **changes}

    labels = []
    for label, code in QWEN_LABELS.items():
        latin = code in parameters.latin_languages
        p, en = (.55, .01) if latin else (.90, .05)
        head = {"label": label, "probability": p, "englishProbability": en}
        labels.extend([case(probe=head), case(mean=.99, probe=head),
                       case(probe={**head, "probability": p - .0001}),
                       case(probe={**head, "englishProbability": en + .0001})])
    edges = [case(mean=.90, minimum=.05), case(mean=None, minimum=None),
             case(mean=.8999), case(mean=.99),
             case(probe={"throws": True}), case(mean=.99),
             case(minimum=.0499), case(mean=.99),
             case(parakeetAccepted=False, mean=None, minimum=None), case(mean=.99)]
    malformed = []
    for label in ("None", None, "xx", "zh-Latn", "es-Cyrl", "spanish", " Spanish ", ""):
        for validated in (True, False):
            malformed.append(case(probe={"label": label, "validated": validated}))
            malformed.append(case(mean=.99))  # prove each abnormal head breaks followup
    for head in ({"mode": "english"}, {"mode": "auto"}, {"policy": 2}, {"policy": None},
                 {"probability": None}, {"englishProbability": None},
                 {"probability": -0.01}, {"probability": 1.01},
                 {"englishProbability": -0.01}, {"englishProbability": 1.01},
                 {"label": None, "probability": None, "englishProbability": None}):
        for validated in (True, False):
            malformed.extend([case(probe={**head, "validated": validated}), case(mean=.99)])
    failure = [case(), case(mean=.99),
               case(parakeetAccepted=False, mean=None, minimum=None,
                    formalErrors=True, initialFailure=True),
               case(mean=.99), case(), case(mean=.99)]
    formal_errors = [case(), case(mean=.99),
                     case(parakeetAccepted=False, mean=None, minimum=None, formalErrors=True),
                     case(mean=.99), case(probe={"throws": True}),
                     case(mean=.99)]
    result = []
    for name, cases in (("labels", labels), ("confidence-and-errors", edges),
                        ("abnormal-heads", malformed), ("formal-errors-stop-probe", formal_errors),
                        ("initial-failure", failure)):
        inputs = []
        for index, item in enumerate(cases):
            head = item["probe"]
            probabilities = (head["probability"], head["englishProbability"])
            valid_probabilities = all(p is None or 0 <= p <= 1 for p in probabilities)
            known_label = head["label"] == "None" or head["label"] in QWEN_LABELS
            valid_label = ((known_label and all(p is not None for p in probabilities))
                           or (head["label"] is None and all(p is None for p in probabilities)))
            failed = (head["throws"] or head["mode"] != "probe" or head["policy"] != 1
                      or head["label"] is None or not valid_probabilities
                      or (head["validated"] and not valid_label) or item["formalErrors"])
            inputs.append(metadata_row(index, track=name,
                parakeet_accepted=item["parakeetAccepted"], pk_mean_probability=item["mean"],
                pk_min_probability=item["minimum"], probe_language=QWEN_LABELS.get(head["label"]),
                probe_label_probability=head["probability"] if valid_probabilities else None,
                probe_english_probability=head["englishProbability"] if valid_probabilities else None,
                probe_error=failed))
        goldens = golden_groups(inputs, simulator, parameters, "queue")[0]["rows"]
        before = {}
        rows = []
        for item, golden in zip(cases, goldens, strict=True):
            after = {"previousIndex": golden["index"],
                     "previousLanguage": golden["expected"]["qualifiedLanguage"]}
            rows.append({"index": golden["index"], **item,
                         "expected": None if item["formalErrors"] else golden["expected"],
                         "oracleDecision": golden["expected"],
                         "expectedBefore": before, "expectedAfter": after})
            before = after
        result.append({"name": name, "rows": rows})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", type=Path, required=True)
    parser.add_argument("--parameters", type=Path, required=True)
    parser.add_argument("--features", type=Path)
    parser.add_argument("--synthetic-only", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if not args.synthetic_only and args.features is None:
        parser.error("--features is required unless --synthetic-only is used")
    simulator_hash = hashlib.sha256(args.simulator.read_bytes()).hexdigest()
    parameters_hash = hashlib.sha256(args.parameters.read_bytes()).hexdigest()
    if simulator_hash != FROZEN_SIMULATOR_SHA256 or parameters_hash != FROZEN_PARAMETERS_SHA256:
        raise ValueError("simulator or parameters changed from the reviewed frozen oracle")
    parameters = json.loads(args.parameters.read_bytes())["parameters"]
    if parameters != json.loads((ROOT / "Fixtures/source-language-trigger-parameters.json").read_bytes()):
        raise ValueError("frozen parameters differ from App fixture")
    simulator = load_simulator(args.simulator)
    frozen = simulator.Parameters(**parameters)
    groups = golden_groups(synthetic_rows(), simulator, frozen, "synthetic")
    inputs, public_rows = [], []
    for path in sorted(args.features.glob("*.jsonl")) if not args.synthetic_only else []:
        # Explicit public allowlist avoids reading private classroom files.
        if not (path.name.startswith("CS50-") or path.name.startswith("UN")):
            continue
        rows, identity = simulator.read_jsonl([path], allowed_splits={"dev", "original", "new"})
        if any(row.get("private_classroom", False) for row in rows):
            raise ValueError("a public-allowlisted feature file contains private rows")
        inputs.extend(identity)
        public_rows.extend(rows)
    if public_rows:
        groups.extend(golden_groups(public_rows, simulator, frozen, "public"))
    queue = queue_groups(simulator, frozen) if args.synthetic_only else []
    receipt = {"simulator_sha256": simulator_hash,
               "parameters_sha256": parameters_hash,
               "inputs": inputs, "synthetic_segments": sum(len(g["rows"]) for g in groups if g["name"].startswith("synthetic:")),
               "public_segments": len(public_rows), "private_segments_exported": 0,
               "groups": len(groups), "queue_groups": len(queue),
               "queue_segments": sum(len(g["rows"]) for g in queue)}
    output = ({"schema": 1, "simulatorSHA256": simulator_hash,
               "parametersSHA256": parameters_hash, "syntheticGroups": groups,
               "queueGroups": queue} if args.synthetic_only else groups)
    for path, content in [(args.output, output), (args.receipt, receipt)]:
        bundled = args.synthetic_only and path == args.output and path.absolute() == BUNDLED_FIXTURE
        if path.is_symlink() or (path.resolve().is_relative_to(ROOT) and not bundled):
            raise ValueError("evidence must be outside the checkout without symlinks")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x") as output:
            json.dump(content, output, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
            output.write("\n")
    print(json.dumps({key: receipt[key] for key in ("synthetic_segments", "public_segments",
        "private_segments_exported", "groups", "queue_groups", "queue_segments")}))


if __name__ == "__main__":
    main()
