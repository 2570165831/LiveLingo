#!/usr/bin/env python3
"""Copy unsigned distribution inputs or check a package without changing it.

Recovery originals, run records and diagnostics stay in the source tree. Only a
new copy may receive a public runtime manifest. Signed/stapled inputs use check,
never in-place cleanup. This is a packaging boundary, not a claim that arbitrary
binaries or renamed classroom text can be identified by a content scanner.
JSON and XML/binary plists are recursively checked. Known binary formats are
identified, not content-reviewed; allowed scripts/licenses/prose are unreviewed.
Unsupported structured formats and unidentified binary data stop the check.
"""
import copy
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
from xml.parsers.expat import ExpatError, ParserCreate


class PrivacyError(ValueError):
    """A fixed reason code; never include file contents or local paths."""


EXCLUDED_NAMES = frozenset({
    ".git", ".hg", ".svn", ".cache", ".ds_store", ".cli-runtime", ".translation-content",
    "__pycache__", "test", "tests", "migration-recovery.json", "run.json", "release-state.json",
    "tool-paths.txt", "receipt.json", "reviewdiagnostics", "transcriptiondiagnostics",
    "checkpoints", "durable-transcription", "transcription-issues.jsonl",
})
SYSTEM_LINKS = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")
PUBLIC_MANIFEST_KEYS = (
    "components", "missingLicenseFiles", "chempyScope", "python", "workerHashes",
    "nativeTransitiveNoticeAudit",
)
CONTENT_KEYS = frozenset({
    "rawtext", "originaltext", "translatedtext", "sourcetext", "transcript",
    "transcriptsegments", "learningnotes", "reviewinput", "reviewoutput",
    "preservedsourcedirectory", "sessiondirectory",
})
CONTENT_NAMES = frozenset({
    "session.json", "snapshot.json", "work.jsonl", "notes.md", "transcript.txt",
    "transcript.json", "transcript.md", "recording.wav", "learning-review-queue.json",
})
CONTENT_SUFFIXES = (".srt", ".vtt", ".wav", ".m4a", ".mp3", ".aiff", ".flac", ".jsonl")
JSON_LIMIT = 64 * 1024 * 1024
FILE_PROBE_LIMIT = 4096
PLIST_SUFFIXES = frozenset({".plist", ".stringsdict", ".entitlements", ".xcent"})
UNSUPPORTED_METADATA_SUFFIXES = frozenset({".xml", ".yaml", ".yml", ".toml"})
STRUCTURED_SUFFIXES = PLIST_SUFFIXES | UNSUPPORTED_METADATA_SUFFIXES | {".json", ".safetensors", ".strings", ".pth", ".pem"}
TEXT_SUFFIXES = frozenset({".py", ".pyi", ".sh", ".bash", ".zsh", ".md", ".rst", ".txt",
                           ".c", ".h", ".cpp", ".hpp", ".tcl"})
TEXT_NAMES = frozenset({"license", "licence", "copying", "notice", "copyright", "readme",
                        "authors", "changes", "changelog", "install", "thanks"})
APP_RESOURCES = frozenset({
    "LanguageRuntime", "ASRRuntime", "Models", "LICENSE", "THIRD_PARTY_NOTICES.md",
    "Assets.car", "AppIcon.icns", "AppIcon.icon", "InfoPlist.strings",
})
# URL provenance is allowed. Local absolute paths (including file URLs and
# Windows paths) in structured metadata are not distribution provenance.
URL = re.compile(r"https?://[^\s\"<>]+", re.IGNORECASE)
LOCAL_PATH = re.compile(r"(?<![\w:/.])/[^\s\"<>]+|file://|~[/\\]|[A-Za-z]:[/\\]", re.IGNORECASE)


def decode_metadata_text(data):
    """Strict text only; an undecodable or control-bearing blob is not reviewed."""
    if data.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        encoding = "utf-32"
    elif data.startswith((b"\xff\xfe", b"\xfe\xff")):
        encoding = "utf-16"
    elif b"\x00" in data:
        # Accept BOM-less ASCII UTF-16 only when every code unit has the
        # expected zero high byte. Do not guess encodings for arbitrary blobs.
        if len(data) % 2:
            return None
        if all(byte == 0 for byte in data[1::2]) and all(9 <= byte <= 126 for byte in data[::2]):
            encoding = "utf-16-le"
        elif all(byte == 0 for byte in data[::2]) and all(9 <= byte <= 126 for byte in data[1::2]):
            encoding = "utf-16-be"
        else:
            return None
    else:
        encoding = "utf-8-sig"
    try:
        text = data.decode(encoding)
    except UnicodeError:
        return None
    return text if all(char.isprintable() or char in "\t\r\n" for char in text) else None


def metadata_kind(data):
    if data.lstrip().startswith(b"bplist"):
        return "plist"  # Unsupported versions must fail parsing, not pass as opaque.
    text = decode_metadata_text(data)
    if text is not None:
        text = text.lstrip()
        if text.startswith(("<?xml", "<!DOCTYPE plist", "<plist")):
            return "plist"
        if re.match(r'^\{\s*(?:"|})|^\[\s*(?:[\[{"\d-]|true|false|null|])', text):
            return "json"
    return None


class _UniqueMetadata(dict):
    def __setitem__(self, key, value):
        if key in self:
            raise PrivacyError("duplicate-metadata-key")
        super().__setitem__(key, value)


def _unique_json(pairs):
    result = _UniqueMetadata()
    for key, value in pairs:
        result[key] = value
    return result


def parse_metadata(data, kind):
    try:
        if kind == "json":
            return json.loads(data, object_pairs_hook=_unique_json)
        if not data.startswith(b"bplist"):
            # plistlib discards XML comments/attributes/processing instructions.
            # Check them without resolving a DTD or any external entity.
            parser = ParserCreate()
            parser.CommentHandler = validate_metadata
            parser.ProcessingInstructionHandler = lambda target, value: validate_metadata(value)
            parser.StartElementHandler = lambda name, attrs: validate_metadata(attrs)
            parser.Parse(data, True)
        return plistlib.loads(data, dict_type=_UniqueMetadata)
    except (UnicodeError, ValueError, TypeError, OverflowError, RecursionError,
            plistlib.InvalidFileException, ExpatError, struct.error):
        raise PrivacyError("invalid-package-" + kind) from None


def signature_hash_data(data, trail):
    # CodeResources requires these opaque digests. No other plist data field
    # is exempt, and these are counted separately from inspected values.
    if len(trail) == 2 and trail[0] == "files":
        return len(data) == 20
    if len(trail) == 3 and trail[0] in ("files", "files2"):
        return len(data) == {"hash": 20, "hash2": 32, "cdhash": 20}.get(trail[-1])
    return False


def excluded(name):
    name = name.lower()
    return (name in EXCLUDED_NAMES or name.startswith((".migration-source", "._"))
            or name.startswith(("classroom-metrics", "classroom_metrics"))
            or name.endswith((".log", ".pyc", ".pyo", ".bak", ".tmp")))


def validate_metadata(value, field=None, *, signature=False, trail=(), _active=None, _depth=0):
    """Return the number of explicitly permitted opaque signature data fields."""
    if _depth > 100:
        raise PrivacyError("metadata-too-deep-or-cyclic")
    active = set() if _active is None else _active

    def recurse(item, item_field=None, item_trail=trail):
        return validate_metadata(item, item_field, signature=signature, trail=item_trail,
                                 _active=active, _depth=_depth + 1)

    if isinstance(value, (dict, list, tuple)):
        if id(value) in active:
            raise PrivacyError("metadata-too-deep-or-cyclic")
        active.add(id(value))
        try:
            opaque = 0
            if isinstance(value, dict):
                for key, item in value.items():
                    text_key = decode_metadata_text(key) if isinstance(key, bytes) else key
                    if isinstance(text_key, str) and re.sub(r"[_-]", "", text_key.lower()) in CONTENT_KEYS:
                        raise PrivacyError("classroom-content-metadata")
                    opaque += recurse(key)
                    opaque += recurse(item, key, trail + (key,))
            else:
                for index, item in enumerate(value):
                    opaque += recurse(item, field, trail + (index,))
            return opaque
        finally:
            active.remove(id(value))
    elif isinstance(value, bytes):
        kind = metadata_kind(value)
        if kind:
            return recurse(parse_metadata(value, kind))
        text = decode_metadata_text(value)
        if text is not None:
            recurse(text, field)
            return int(signature and signature_hash_data(value, trail))
        if signature and signature_hash_data(value, trail):
            return 1
        raise PrivacyError("unreviewed-metadata-data")
    elif isinstance(value, str):
        if field in ("url", "download_url", "sourceURL", "sourceUrl") and re.fullmatch(
                r"//[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[^\s]*)?", value):
            value = "https:" + value  # Validate an upstream network-path URL; do not rewrite it.
        if value.startswith("/") or LOCAL_PATH.search(URL.sub("", value)):
            raise PrivacyError("local-path-metadata")
    elif value is not None and not isinstance(value, (bool, int, float, datetime, plistlib.UID)):
        raise PrivacyError("unsupported-metadata-value")
    return 0


def distribution_manifest(manifest):
    if not isinstance(manifest, dict) or not isinstance(manifest.get("components"), list):
        raise PrivacyError("invalid-runtime-manifest")
    public = {key: copy.deepcopy(manifest[key]) for key in PUBLIC_MANIFEST_KEYS if key in manifest}
    public["python"] = "python"
    validate_metadata(public)
    return public


def read_json(path):
    return parse_metadata(path.read_bytes(), "json")


def validate_json_metadata(value, filename):
    if filename in ("vocab.json", "added_tokens.json") and isinstance(value, dict):
        if all(isinstance(token_id, int) for token_id in value.values()):
            return  # A token-to-ID vocabulary; token spellings are required data.
    if filename in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json") and isinstance(value, dict):
        # Vocabulary spellings can themselves be paths or words such as
        # 'transcript'. They are required model data, not session metadata.
        # Still inspect all fields outside the documented vocabulary locations.
        value = dict(value)
        model = value.get("model")
        if isinstance(model, dict):
            model = dict(model)
            model.pop("vocab", None)
            model.pop("merges", None)
            value["model"] = model
        added = value.get("added_tokens")
        if isinstance(added, list):
            value["added_tokens"] = [{k: v for k, v in token.items() if k != "content"}
                                     if isinstance(token, dict) else token for token in added]
        decoder = value.get("added_tokens_decoder")
        if isinstance(decoder, dict):
            value["added_tokens_decoder"] = {
                key: {k: v for k, v in token.items() if k != "content"}
                if isinstance(token, dict) else token for key, token in decoder.items()
            }
        for key in ("bos_token", "eos_token", "unk_token", "pad_token", "sep_token", "cls_token",
                    "mask_token", "additional_special_tokens"):
            value.pop(key, None)
    validate_metadata(value)


def validate_link(path, root, allow_applications=False):
    target = os.readlink(path)
    if allow_applications and path == root / "Applications" and target == "/Applications":
        return
    if os.path.isabs(target) and os.path.realpath(target).startswith(SYSTEM_LINKS):
        return
    # Absolute source-internal links would retain the source location after copy.
    if os.path.isabs(target):
        raise PrivacyError("external-or-absolute-symlink")
    try:
        resolved = path.resolve(strict=True)
        relative = resolved.relative_to(root.resolve())
    except (OSError, ValueError, RuntimeError):
        raise PrivacyError("external-broken-or-cyclic-symlink") from None
    if any(excluded(part) for part in relative.parts):
        raise PrivacyError("symlink-to-private-record")


def known_binary(path, prefix, size):
    """Format identification only; never assert that embedded content is safe.

    Native code, Metal libraries, compiled asset catalogs and image resources
    are opaque. An extension alone is insufficient. Archives, pickle/protobuf
    models and other unidentified formats have no exemption.
    """
    suffix = path.suffix.lower()
    if path.name == "PkgInfo" and path.parent.name == "Contents" and size == 8:
        return prefix[:4] in (b"APPL", b"BNDL", b"FMWK")
    macho = prefix[:4] in (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                          b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                          b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
    if macho and size >= 28 and (suffix in (".dylib", ".so")
                                or path.parent.name in ("MacOS", "bin")
                                or any(part.endswith(".framework") for part in path.parts)):
        return True
    if suffix == ".a" and prefix.startswith(b"!<arch>\n"):
        return True
    if suffix == ".metallib" and prefix.startswith(b"MTLB") and size >= 16:
        return True
    if path.name == "Assets.car" and prefix.startswith(b"BOMStore") and size >= 16:
        return True
    if suffix == ".icns" and prefix.startswith(b"icns") and size >= 8:
        return int.from_bytes(prefix[4:8], "big") == size
    return ((suffix == ".png" and prefix.startswith(b"\x89PNG\r\n\x1a\n"))
            or (suffix in (".jpg", ".jpeg") and prefix.startswith(b"\xff\xd8\xff"))
            or (suffix == ".gif" and prefix.startswith((b"GIF87a", b"GIF89a")))
            or (suffix in (".tif", ".tiff") and prefix.startswith((b"II\x2a\x00", b"MM\x00\x2a"))))


def allowed_text_file(path, data):
    """A bounded packaging exemption, not a claim to review its text content."""
    if path.suffix.lower() in TEXT_SUFFIXES or path.name.lower() in TEXT_NAMES:
        return True
    if re.fullmatch(r"[\w.+-]+-(?:LICENSE|LICENCE|NOTICE)", path.name, re.IGNORECASE):
        return True
    if path.parent.name.endswith(".dist-info") and path.name in (
            "METADATA", "WHEEL", "RECORD", "INSTALLER", "REQUESTED"):
        return True
    if path.parent.name.endswith(".egg-info") and path.name == "PKG-INFO":
        return True
    if path.parent.name == "bin":
        return (re.fullmatch(r"python(?:[0-9]+(?:\.[0-9]+)*)?", path.name) is not None
                or (not path.suffix and data.startswith(b"#!")))
    return False


def inspect_portable_resource(path, data, counts):
    """Support bounded runtime resources without making arbitrary text exempt."""
    text = decode_metadata_text(data)
    if text is None:
        raise PrivacyError("invalid-portable-resource")
    if path.name == "py.typed":
        if text.strip() not in ("", "partial"):
            raise PrivacyError("invalid-typing-marker")
    elif path.suffix.lower() == ".pth":
        for line in text.splitlines():
            line = line.strip()
            if line.startswith(("import ", "import\t")):
                raise PrivacyError("executable-package-path-file")
            validate_metadata(line)
    elif path.suffix.lower() == ".pem":
        blocks = list(re.finditer(r"-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\s]+?)"
                                  r"\s+-----END CERTIFICATE-----", text))
        remainder = re.sub(r"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+?"
                           r"\s+-----END CERTIFICATE-----", "", text)
        if not blocks or remainder.strip():
            raise PrivacyError("unsupported-pem-resource")
        for block in blocks:
            try:
                der = base64.b64decode(re.sub(r"\s", "", block[1]), validate=True)
            except ValueError:
                raise PrivacyError("invalid-certificate-resource") from None
            result = subprocess.run(["/usr/bin/openssl", "x509", "-inform", "DER", "-noout"],
                                    input=der, capture_output=True, timeout=10)
            if result.returncode:
                raise PrivacyError("invalid-certificate-resource")
        # Certificates needed by the portable trust store are format-validated
        # opaque resources. This does not inspect all certificate identities.
        counts["opaque_binary_files"] += 1
        return
    else:  # OpenStep .strings, including UTF-16; never execute the resource.
        if path.parent.name != "Resources" and not path.parent.name.endswith(".lproj"):
            raise PrivacyError("unsupported-package-metadata-format")
        token = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:[^"\\]|\\.)*"|[^\s=;"/]+|[=;]', re.S)
        entries = []
        offset = 0
        for match in token.finditer(text):
            if match.start() != offset:
                raise PrivacyError("invalid-strings-resource")
            offset = match.end()
            value = match[0]
            if value.isspace():
                continue
            if value.startswith(("/*", "//")):
                validate_metadata(value[2:-2] if value.startswith("/*") else value[2:])
            else:
                entries.append(value)
        if offset != len(text) or len(entries) % 4 or any(
                entries[i + 1] != "=" or entries[i + 3] != ";" for i in range(0, len(entries), 4)):
            raise PrivacyError("invalid-strings-resource")
        result = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", "-"],
                                input=data, capture_output=True, timeout=10)
        if result.returncode:
            raise PrivacyError("invalid-strings-resource")
        value = parse_metadata(result.stdout, "plist")
        if not isinstance(value, dict) or len(value) != len(entries) // 4:
            raise PrivacyError("duplicate-metadata-key")
        validate_metadata(value)
    counts["metadata_files"] += 1


def inspect_safetensors(path, size, counts):
    # Read only the bounded JSON header, never load tensor/model data. Tensor
    # bytes remain opaque even when the header passes the metadata policy.
    with path.open("rb") as stream:
        length_bytes = stream.read(8)
        if len(length_bytes) != 8:
            raise PrivacyError("invalid-package-safetensors")
        length = int.from_bytes(length_bytes, "little")
        if length > JSON_LIMIT:
            raise PrivacyError("unreviewed-large-metadata")
        if length < 2 or length > size - 8:
            raise PrivacyError("invalid-package-safetensors")
        header = parse_metadata(stream.read(length), "json")
    validate_metadata(header)
    if not isinstance(header, dict):
        raise PrivacyError("invalid-package-safetensors")
    for name, tensor in header.items():
        if name == "__metadata__":
            if not isinstance(tensor, dict) or not all(isinstance(item, str) for item in tensor.values()):
                raise PrivacyError("invalid-package-safetensors")
            continue
        if not isinstance(tensor, dict) or not isinstance(tensor.get("dtype"), str):
            raise PrivacyError("invalid-package-safetensors")
        shape, offsets = tensor.get("shape"), tensor.get("data_offsets")
        if (not isinstance(shape, list) or not all(type(n) is int and n >= 0 for n in shape)
                or not isinstance(offsets, list) or len(offsets) != 2
                or not all(type(n) is int for n in offsets)
                or not 0 <= offsets[0] <= offsets[1] <= size - 8 - length):
            raise PrivacyError("invalid-package-safetensors")
    counts["metadata_files"] += 1
    counts["opaque_binary_files"] += 1
    return header


def inspect_metadata_file(path, counts, public_copy):
    suffix = path.suffix.lower()
    size = path.stat().st_size
    if path.name == "py.typed" or suffix in (".pth", ".pem", ".strings"):
        if size > JSON_LIMIT:
            raise PrivacyError("unreviewed-large-metadata")
        data = path.read_bytes()
        if suffix != ".strings" or not metadata_kind(data):
            inspect_portable_resource(path, data, counts)
            return
    if suffix == ".safetensors":
        inspect_safetensors(path, size, counts)
        return
    signature = path.name == "CodeResources" and path.parent.name == "_CodeSignature"
    if suffix == ".json":
        kind = "json"
    elif suffix in PLIST_SUFFIXES or signature:
        kind = "plist"
    else:
        with path.open("rb") as stream:
            prefix = stream.read(FILE_PROBE_LIMIT)
        kind = metadata_kind(prefix)
        if not kind and suffix in UNSUPPORTED_METADATA_SUFFIXES:
            raise PrivacyError("unsupported-package-metadata-format")
        if not kind:
            if known_binary(path, prefix, size):
                counts["opaque_binary_files"] += 1
                return
            if size > JSON_LIMIT:
                raise PrivacyError("unreviewed-large-unknown-file")
            # Check the whole bounded unknown file's encoding and signature.
            # A textual prefix cannot hide later binary or structured data.
            data = path.read_bytes()
            kind = metadata_kind(data)
            if not kind:
                if decode_metadata_text(data) is None:
                    raise PrivacyError("unreviewed-binary-package-entry")
                if not allowed_text_file(path, data):
                    raise PrivacyError("unsupported-package-file-format")
                counts["unreviewed_text_files"] += 1
                return
    if size > JSON_LIMIT:
        raise PrivacyError("unreviewed-large-json" if suffix == ".json" else "unreviewed-large-metadata")
    value = parse_metadata(path.read_bytes(), kind)
    if path.name == "runtime-manifest.json":
        public = distribution_manifest(value)
        if not public_copy and value != public:
            raise PrivacyError("nonpublic-runtime-manifest")
        counts["manifests"] += 1
    elif kind == "json":
        validate_json_metadata(value, path.name)
    else:
        counts["opaque_metadata_fields"] += validate_metadata(value, signature=signature)
    counts["metadata_files"] += 1


def inspect_tree(root, *, omit_private=False, public_copy=False, layout="tree"):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise PrivacyError("package-root-not-real-directory")
    if layout in ("app-only", "dmg"):
        expected = {"LiveLingo.app"} if layout == "app-only" else {"LiveLingo.app", "Applications", "使用说明.txt"}
        if {p.name for p in root.iterdir()} != expected:
            raise PrivacyError("unexpected-package-top-level")
        if not (root / "LiveLingo.app").is_dir() or (root / "LiveLingo.app").is_symlink():
            raise PrivacyError("package-app-not-real-directory")
        if layout == "dmg" and (not (root / "Applications").is_symlink()
                                or os.readlink(root / "Applications") != "/Applications"
                                or not (root / "使用说明.txt").is_file()
                                or (root / "使用说明.txt").is_symlink()):
            raise PrivacyError("invalid-dmg-install-entries")
    # files is an inventory, not a content-review count. The other counts make
    # exemptions and incomplete coverage visible to release callers.
    counts = {"files": 0, "excluded": 0, "manifests": 0, "metadata_files": 0,
              "opaque_metadata_fields": 0, "opaque_binary_files": 0, "unreviewed_text_files": 0}

    def walk(directory):
        entries = sorted(directory.iterdir())
        # Reject metadata links before reading their same-directory targets;
        # their error must not depend on the filename sort order.
        for path in entries:
            if (not excluded(path.name) and path.is_symlink()
                    and (path.suffix.lower() in STRUCTURED_SUFFIXES
                         or (path.name == "CodeResources" and directory.name == "_CodeSignature"))):
                raise PrivacyError("structured-metadata-symlink")
        for path in entries:
            if excluded(path.name):
                if not omit_private:
                    raise PrivacyError("private-or-unrelated-package-entry")
                counts["excluded"] += 1
                continue  # Never descend into recovery copies or read their contents.
            if directory.name == "Resources" and directory.parent.name == "Contents":
                if path.name not in APP_RESOURCES and not path.name.endswith(".lproj"):
                    raise PrivacyError("unexpected-app-resource")
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                if path.suffix.lower() in STRUCTURED_SUFFIXES:
                    raise PrivacyError("structured-metadata-symlink")
                validate_link(path, root, layout == "dmg")
            elif stat.S_ISDIR(mode):
                walk(path)
            elif stat.S_ISREG(mode):
                counts["files"] += 1
                if path.name.lower() in CONTENT_NAMES or path.name.lower().endswith(CONTENT_SUFFIXES):
                    raise PrivacyError("classroom-content-file")
                inspect_metadata_file(path, counts, public_copy)
            else:
                raise PrivacyError("special-package-entry")

    walk(root)
    return counts


def copy_distribution_tree(source, destination, *, clone_files=False):
    """Only write a new disjoint tree; inputs and signed packages stay untouched."""
    source, destination = Path(source), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise PrivacyError("destination-already-exists")
    source_real, destination_real = source.resolve(), destination.resolve()
    if source_real == destination_real or source_real in destination_real.parents or destination_real in source_real.parents:
        raise PrivacyError("overlapping-package-trees")
    # Reject destination symlink ancestors before creating anything.
    if any(p.is_symlink() for p in [destination.parent, *destination.parent.parents]):
        raise PrivacyError("symlink-destination-parent")
    counts = inspect_tree(source, omit_private=True, public_copy=True)

    def copy_file(src, dst):
        src, dst = Path(src), Path(dst)
        if src.name == "runtime-manifest.json":
            dst.write_text(json.dumps(distribution_manifest(read_json(src)), ensure_ascii=False, indent=2) + "\n")
            shutil.copystat(src, dst)
        elif clone_files and src.stat().st_size >= 1024 * 1024:
            result = subprocess.run(["/bin/cp", "-c", str(src), str(dst)], capture_output=True)
            if result.returncode:
                raise PrivacyError("package-clone-failed")
        else:
            shutil.copy2(src, dst)
        return str(dst)

    shutil.copytree(source, destination, symlinks=True, copy_function=copy_file,
                    ignore=lambda directory, names: [name for name in names if excluded(name)])
    inspect_tree(destination)
    return counts


def main():
    if __package__:
        from .privacy_cli import PrivateArgumentParser
    else:
        from privacy_cli import PrivateArgumentParser
    parser = PrivateArgumentParser(prog="privacy-package", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="read-only; rejects signed-package residues without editing them")
    check.add_argument("--root", type=Path, required=True)
    check.add_argument("--layout", choices=("tree", "app-only", "dmg"), default="tree")
    stage = sub.add_parser("copy", help="create a new unsigned distribution copy; preserve all sources")
    stage.add_argument("--source", type=Path, required=True)
    stage.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        counts = (inspect_tree(args.root, layout=args.layout) if args.command == "check"
                  else copy_distribution_tree(args.source, args.output))
    except PrivacyError as error:
        print("privacy-package: " + error.args[0] + "; rebuild an unsigned copy", file=sys.stderr)
        return 1
    except (OSError, shutil.Error):
        # Do not echo arbitrary source names, paths, contents or exception text.
        print("privacy-package: rejected; inspect the local input and rebuild an unsigned copy", file=sys.stderr)
        return 1
    print(json.dumps({"privacyPackage": "passed", "operation": args.command,
                      "scope": "structured-metadata-and-entry-policy", **counts}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
