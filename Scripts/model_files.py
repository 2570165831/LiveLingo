#!/usr/bin/env python3
"""Check that every bundled model directory holds its weights and loader files.

Static only: reads model.safetensors.index.json and safetensors headers, never
tensor data, and never loads a model. A missing shard, a model without weights
or a missing tokenizer file fails here instead of at the user's first
transcription or translation. Messages name only model-relative file names.
"""
from pathlib import Path
import sys

if __package__:
    from .privacy_package import JSON_LIMIT, PrivacyError, inspect_safetensors, read_json
else:
    from privacy_package import JSON_LIMIT, PrivacyError, inspect_safetensors, read_json

INDEX_NAME = "model.safetensors.index.json"
# mlx_lm and mlx_audio load model*.safetensors when there is no shard index.
WEIGHT_PATTERN = "model*.safetensors"
# In-app model path -> files its loader needs besides the weights, matching the
# released model directories. The translation prompt is built without a chat
# template, Parakeet keeps its vocabulary in config.json, and Qwen3-ASR ships a
# vocab/merges tokenizer instead of tokenizer.json.
REQUIRED_MODEL_FILES = {
    "mlx-community/Qwen3.5-4B-MLX-8bit": ("config.json", "tokenizer.json", "tokenizer_config.json"),
    "lmstudio-community/Qwen3.5-9B-MLX-4bit": ("config.json", "tokenizer.json", "tokenizer_config.json"),
    "mlx-community/parakeet-tdt-0.6b-v2": ("config.json",),
    "mlx-community/Qwen3-ASR-1.7B-4bit": ("config.json", "tokenizer_config.json", "vocab.json", "merges.txt",
                                          "preprocessor_config.json"),
}
APP_MODELS_ROOT = "Contents/Resources/Models"


class ModelFilesError(ValueError):
    """Names model-relative files only; never file contents or absolute paths."""


def regular_file(path):
    return path.is_file() and not path.is_symlink()


def tensor_names(path):
    counts = {"metadata_files": 0, "opaque_binary_files": 0}
    try:
        header = inspect_safetensors(path, path.stat().st_size, counts)
    except (PrivacyError, OSError):
        raise ModelFilesError("invalid safetensors header: " + path.name) from None
    names = set(header) - {"__metadata__"}
    if not names:
        raise ModelFilesError("weight file has no tensors: " + path.name)
    return names


def shard_names(model_dir):
    """Return (weight files to check, tensor names the index promises or None)."""
    index = model_dir / INDEX_NAME
    if not index.exists() and not index.is_symlink():
        weights = sorted(path.name for path in model_dir.glob(WEIGHT_PATTERN))
        if not weights:
            raise ModelFilesError("no %s weights" % WEIGHT_PATTERN)
        return weights, None
    if not regular_file(index) or index.stat().st_size > JSON_LIMIT:
        raise ModelFilesError("unreadable " + INDEX_NAME)
    try:
        value = read_json(index)
    except (PrivacyError, OSError):
        raise ModelFilesError("unreadable " + INDEX_NAME) from None
    weight_map = value.get("weight_map") if isinstance(value, dict) else None
    if (not isinstance(weight_map, dict) or not weight_map
            or not all(isinstance(key, str) and isinstance(item, str) for key, item in weight_map.items())):
        raise ModelFilesError("empty or invalid weight_map in " + INDEX_NAME)
    shards = sorted(set(weight_map.values()))
    # Shards are siblings of the index; anything else could leave the bundle.
    if any("/" in name or "\\" in name or name.startswith(".") or not name.endswith(".safetensors")
           for name in shards):
        raise ModelFilesError("weight_map in %s names a file outside the model directory" % INDEX_NAME)
    return shards, set(weight_map)


def check_model_files(model_dir, required=()):
    """Raise ModelFilesError unless the directory looks loadable; never load it."""
    model_dir = Path(model_dir)
    if not model_dir.is_dir() or model_dir.is_symlink():
        raise ModelFilesError("model directory is missing")
    missing = [name for name in required
               if not regular_file(model_dir / name) or (model_dir / name).stat().st_size == 0]
    if missing:
        raise ModelFilesError("missing required file(s): " + ", ".join(missing))
    shards, indexed = shard_names(model_dir)
    tensors = set()
    for name in shards:
        path = model_dir / name
        if not regular_file(path):
            raise ModelFilesError("missing weight file: " + name)
        tensors |= tensor_names(path)
    if indexed is not None and not indexed <= tensors:
        raise ModelFilesError("%d tensor(s) in %s are absent from its shards"
                              % (len(indexed - tensors), INDEX_NAME))
    return shards


def check_app_models(app_root):
    """Return one message per incomplete bundled model; empty when all pass."""
    problems = []
    for relative, required in REQUIRED_MODEL_FILES.items():
        try:
            check_model_files(Path(app_root) / APP_MODELS_ROOT / relative, required)
        except ModelFilesError as error:
            problems.append("%s: %s" % (relative, error.args[0]))
    return problems


def main():
    if __package__:
        from .privacy_cli import PrivateArgumentParser
    else:
        from privacy_cli import PrivateArgumentParser
    parser = PrivateArgumentParser(prog="model-files", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="read-only; checks the bundled models of an assembled app")
    check.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    problems = check_app_models(args.app)
    if problems:
        for problem in problems:
            print("model-files: " + problem, file=sys.stderr)
        return 1
    print('{"modelFiles": "passed", "models": %d}' % len(REQUIRED_MODEL_FILES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
