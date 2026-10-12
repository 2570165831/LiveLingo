"""Prepare offline model loader inputs from a read-only model root.

Only the four reviewed model IDs are selected. Omit training/repository extras
that their App loaders do not use, including Parakeet's unused training
tokenizer vocabulary. Weights and retained inference vocabularies are never
edited or loaded; large files are copied with APFS clones when possible.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

try:
    from .model_files import REQUIRED_MODEL_FILES, check_model_files, ModelFilesError
    from .privacy_package import PrivacyError, inspect_tree, excluded
except ImportError:
    from model_files import REQUIRED_MODEL_FILES, check_model_files, ModelFilesError
    from privacy_package import PrivacyError, inspect_tree, excluded


OPTIONAL_UNUSED = frozenset({".gitattributes", "chat_template.jinja"})
PUBLIC_FILES = frozenset({"config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
                          "merges.txt", "added_tokens.json", "special_tokens_map.json", "generation_config.json",
                          "preprocessor_config.json", "model.safetensors.index.json", "LICENSE", "README.md"})
PUBLIC_FILES |= frozenset({"processor_config.json", "video_preprocessor_config.json", "vocab.txt", "chat_template.json"})
PARAKEET = "mlx-community/parakeet-tdt-0.6b-v2"


def modification_reason(item):
    if item["file"] == ".gitattributes":
        return "Omit Git attributes and Git LFS tracking metadata; offline loaders use the materialized model files."
    if item["file"] == ".git":
        return "Omit Git repository history and bookkeeping; these are not inference inputs."
    if excluded(item["file"]):
        return "Omit download caches and local loader bookkeeping; these are not model inputs."
    if item["file"] == "config.json" and item["model"] == PARAKEET:
        return "Remove tokenizer.dir, an export-time training directory; decoding uses joint.vocabulary."
    if item["model"] == PARAKEET and item["file"] in ("tokenizer.model", "tokenizer.vocab"):
        return "Omit unused training tokenizer inputs; decoding uses joint.vocabulary."
    return "The application constructs translation prompts itself; omit unused chat templates."


def modification_notice(identifier, records):
    """Rebuild notice wording from existing change records without touching model data.

    An outer assembler may reuse this with a copied MODIFICATIONS.json instead
    of preparing the weights again. Existing source/prepared hashes are retained;
    this wording refresh does not assert those hashes were freshly verified.
    """
    if (identifier not in REQUIRED_MODEL_FILES or not isinstance(records, list)
            or any(not isinstance(item, dict) or not isinstance(item.get("file"), str)
                   or item.get("model", identifier) != identifier for item in records)):
        raise PrivacyError("invalid-model-modification-records")
    changes = [{**item, "model": identifier, "contributor": "Li", "date": "2026-10-11",
                "reason": modification_reason({**item, "model": identifier})} for item in records]
    files = {item["file"] for item in records}
    scopes = []
    if any(file in (".git", ".gitattributes") or excluded(file) for file in files):
        scopes.append("Omit unused repository and local loader metadata.")
    if identifier != PARAKEET and identifier != "mlx-community/Qwen3-ASR-1.7B-4bit" and files & {"chat_template.jinja", "tokenizer_config.json"}:
        scopes.append("Omit unused translation prompt-template metadata; the application constructs its prompts.")
    if identifier == PARAKEET:
        if "config.json" in files:
            scopes.append("Remove Parakeet's export-time training tokenizer directory metadata; decoding uses the retained joint vocabulary.")
        training = files & {"tokenizer.model", "tokenizer.vocab"}
        if training == {"tokenizer.model", "tokenizer.vocab"}:
            scopes.append("Parakeet's unused training tokenizer model and vocabulary are omitted.")
        elif training == {"tokenizer.model"}:
            scopes.append("Parakeet's unused training tokenizer model is omitted.")
        elif training == {"tokenizer.vocab"}:
            scopes.append("Parakeet's unused training tokenizer vocabulary is omitted.")
    scope = " ".join(scopes) if scopes else (
        "Distribution changes are limited to the recorded files." if records else
        "No model-file modifications are recorded for this prepared copy.")
    return {"model": identifier, "contributor": "Li", "date": "2026-10-11", "changes": changes,
            "scope": scope,
            "unchanged": "Weights, retained inference vocabularies, original attribution and licenses are preserved."}


def _preparation_paths(base, output):
    base, output = Path(base), Path(output)
    if base.is_symlink() or not base.is_dir() or output.exists() or output.is_symlink():
        raise PrivacyError("invalid-model-preparation-path")
    if (base.resolve() == output.resolve() or base.resolve() in output.resolve().parents
            or output.resolve() in base.resolve().parents):
        raise PrivacyError("overlapping-model-trees")
    if any(p.is_symlink() for p in [output.parent, *output.parent.parents]):
        raise PrivacyError("symlink-destination-parent")
    return base, output


def refresh_notices(base, output):
    """Write four refreshed notices to a new tree, reading no weights or configs.

    The source is an existing Models directory. Original change records and
    their hashes are retained, without asserting fresh model integrity checks.
    All source notices are validated before creating the destination tree.
    """
    base, output = _preparation_paths(base, output)
    notices = {}
    for identifier in REQUIRED_MODEL_FILES:
        folder = base
        for part in Path(identifier).parts:
            folder /= part
            if folder.is_symlink() or not folder.is_dir():
                raise PrivacyError("invalid-model-modification-notice")
        path = folder / "MODIFICATIONS.json"
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
            raise PrivacyError("invalid-model-modification-notice")
        try:
            document = json.loads(path.read_bytes())
        except (OSError, ValueError):
            raise PrivacyError("invalid-model-modification-notice") from None
        if not isinstance(document, dict) or document.get("model") != identifier:
            raise PrivacyError("invalid-model-modification-notice")
        notices[identifier] = modification_notice(identifier, document.get("changes"))
    output.mkdir(parents=True)
    for identifier, document in notices.items():
        folder = output / identifier
        folder.mkdir(parents=True)
        (folder / "MODIFICATIONS.json").write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    return {"modelNotices": "refreshed", "models": len(notices), "modelHashesReverified": False}


def prepare(base, output):
    base, output = _preparation_paths(base, output)
    # Integrity before copying gigabytes; only bounded safetensors headers read.
    for identifier, required in REQUIRED_MODEL_FILES.items():
        check_model_files(base / identifier, required)
    output.mkdir(parents=True)
    report = []
    for identifier in REQUIRED_MODEL_FILES:
        source = base / identifier
        destination = output / identifier
        destination.mkdir(parents=True)
        for path in sorted(source.iterdir()):
            if excluded(path.name) or path.name in OPTIONAL_UNUSED or (identifier == PARAKEET and path.name in ("tokenizer.model", "tokenizer.vocab")):
                report.append({"model": identifier, "file": path.name, "action": "omitted-unused-loader-input"})
                continue
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(base.resolve()):
                raise PrivacyError("unreviewed-model-input-entry")
            if path.name not in PUBLIC_FILES and not (path.name.startswith("model") and path.suffix == ".safetensors"):
                raise PrivacyError("unreviewed-model-input-entry")
            target = destination / path.name
            if path.name == "tokenizer_config.json" and identifier != "mlx-community/Qwen3-ASR-1.7B-4bit":
                value = json.loads(path.read_bytes())
                if not isinstance(value, dict):
                    raise PrivacyError("unreviewed-tokenizer-metadata-layout")
                if "chat_template" not in value:
                    shutil.copy2(path, target)
                    continue
                value.pop("chat_template", None)
                target.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            elif path.name == "config.json" and identifier == PARAKEET:
                value = json.loads(path.read_bytes())
                if (not isinstance(value, dict) or not isinstance(value.get("joint"), dict)
                        or not isinstance(value["joint"].get("vocabulary"), list)
                        or not isinstance(value.get("tokenizer", {}), dict)):
                    raise PrivacyError("unreviewed-parakeet-vocabulary-layout")
                if "dir" not in value.get("tokenizer", {}):
                    shutil.copy2(path, target)
                    continue
                value.get("tokenizer", {}).pop("dir", None)
                target.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            else:
                if path.stat().st_size >= 1024 * 1024 and path.stat().st_dev == destination.stat().st_dev:
                    result = subprocess.run(["/bin/cp", "-c", str(path), str(target)], capture_output=True)
                    if result.returncode:
                        raise PrivacyError("model-apfs-clone-failed")
                else:
                    shutil.copy2(path, target)
                continue
            report.append({"model": identifier, "file": path.name, "action": "omitted-unused-metadata",
                           "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                           "preparedSHA256": hashlib.sha256(target.read_bytes()).hexdigest()})
        check_model_files(destination, REQUIRED_MODEL_FILES[identifier])
        records = [item for item in report if item["model"] == identifier]
        (destination / "MODIFICATIONS.json").write_text(json.dumps(modification_notice(identifier, records),
            ensure_ascii=False, indent=2) + "\n")
    inspect_tree(output)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--base-models", type=Path, help="Prepare model inputs from the read-only source.")
    source.add_argument("--notices-from-models", type=Path,
                        help="Refresh only existing MODIFICATIONS.json files into a new notice tree.")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.notices_from_models is not None:
            report = refresh_notices(args.notices_from_models, args.output)
        else:
            changes = prepare(args.base_models, args.output)
            report = {"modelInputs": "passed", "models": len(REQUIRED_MODEL_FILES), "changes": changes}
    except (PrivacyError, ModelFilesError) as error:
        print("prepare-model-inputs: " + error.args[0] + "; input unchanged")
        return 1
    except (OSError, ValueError):
        print("prepare-model-inputs: invalid input or copy failure; input unchanged")
        return 1
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
