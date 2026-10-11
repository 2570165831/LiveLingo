"""Bind publisher, read-only input and final candidate bytes to separate stages.

Call record_input_provenance before preparing the ASR Python copy. After all
assembly edits and supplemental-notice copies, call finalize_app_provenance.
Call verify_app_provenance in the final gate and after any later binary change.
Only the candidate JSON notice is written; binaries are never edited or signed.
"""
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

try:
    from .privacy_package import PrivacyError
    from .macho_paths import load_paths
except ImportError:
    from privacy_package import PrivacyError
    from macho_paths import load_paths


REFERENCE = Path(__file__).resolve().parent.parent / "Packaging/MLXLicenses/ASR-audio/soundfile-binary-provenance.json"
INPUT_PATH = "lib/python3.13/site-packages/_soundfile_data/libsndfile_arm64.dylib"
BUNDLED_PATH = "Contents/Resources/ASRRuntime/python/" + INPUT_PATH
NOTICE_PATH = "Contents/Resources/LanguageRuntime/Licenses/ASR-audio/soundfile-binary-provenance.json"
INPUT_STAGE = "read-only-runtime-input-before-preparation"
COMPARISON = ("inputExactMatch compares inputSHA256 with upstreamSHA256; exactMatch compares "
              "finalBundledSHA256 with upstreamSHA256; finalMatchesInput compares finalBundledSHA256 "
              "with inputSHA256. None of these fields asserts a byte-identical source rebuild.")


def _document(value):
    if isinstance(value, dict):
        return copy.deepcopy(value)
    try:
        path = Path(value)
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
            raise PrivacyError("invalid-binary-provenance-document")
        data = json.loads(path.read_bytes())
        if not isinstance(data, dict):
            raise ValueError()
        return data
    except (OSError, ValueError, TypeError):
        raise PrivacyError("invalid-binary-provenance-document") from None


def _digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _reference(document):
    if (document.get("schemaVersion") != 2 or not _digest(document.get("upstreamSHA256"))
            or not isinstance(document.get("source"), str)
            or not re.fullmatch(r"https://raw\.githubusercontent\.com/bastibe/libsndfile-binaries/"
                                r"[0-9a-f]{40}/libsndfile_arm64\.dylib", document["source"])):
        raise PrivacyError("invalid-binary-provenance-reference")
    # Reconstruct the public fields rather than carrying forward old localSHA256
    # or exactMatch claims, arbitrary local paths, or stale final-stage fields.
    return {"schemaVersion": 2, "component": "libsndfile-arm64", "source": document["source"],
            "upstreamSHA256": document["upstreamSHA256"], "comparisonSemantics": COMPARISON,
            "inputStage": INPUT_STAGE, "inputPathBase": "asr-python-root", "inputPath": INPUT_PATH,
            "inputSHA256": None, "inputExactMatch": None, "finalStage": "pending-assembly",
            "finalPathBase": "app-root", "finalBundledPath": BUNDLED_PATH,
            "finalBundledSHA256": None, "exactMatch": None, "finalMatchesInput": None,
            "status": "awaiting-input-and-final-binding"}


def _regular_under(root, relative):
    root = Path(root)
    parts = PurePosixPath(relative).parts
    if (not parts or PurePosixPath(relative).is_absolute() or any(p in (".", "..") for p in parts)
            or root.is_symlink() or not root.is_dir()):
        raise PrivacyError("invalid-binary-provenance-path")
    path = root
    for part in parts:
        path /= part
        if path.is_symlink():
            raise PrivacyError("symlink-binary-provenance-path")
    if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise PrivacyError("missing-binary-provenance-file")
    return path


def _hash_binary(path):
    before = path.stat()
    if load_paths(path) is None:
        raise PrivacyError("non-macho-provenance-input")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    after = path.stat()
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, key) != getattr(after, key) for key in fields):
        raise PrivacyError("binary-changed-during-provenance-hash")
    return digest.hexdigest()


def _input_document(document):
    reference = _reference(document)
    if ("localSHA256" in document or any(document.get(key) != reference[key]
            for key in ("inputPath", "inputPathBase", "inputStage", "finalBundledPath", "finalPathBase"))
            or not _digest(document.get("inputSHA256"))
            or document.get("inputExactMatch") is not (document.get("inputSHA256") == document["upstreamSHA256"])):
        raise PrivacyError("invalid-input-binary-provenance")
    reference["inputSHA256"] = document["inputSHA256"]
    reference["inputExactMatch"] = document["inputExactMatch"]
    reference["status"] = "input-bound-awaiting-final-binding"
    return reference


def record_input_provenance(input_python, reference=REFERENCE):
    """Hash the real read-only input; return an input-stage receipt, not a final one."""
    document = _reference(_document(reference))
    digest = _hash_binary(_regular_under(input_python, INPUT_PATH))
    document["inputSHA256"] = digest
    document["inputExactMatch"] = digest == document["upstreamSHA256"]
    document["status"] = "input-bound-awaiting-final-binding"
    return document


def verify_input_provenance(input_python, receipt):
    """Re-read the original input before copying when the caller needs this check."""
    document = _input_document(_document(receipt))
    if _hash_binary(_regular_under(input_python, INPUT_PATH)) != document["inputSHA256"]:
        raise PrivacyError("input-binary-provenance-hash-mismatch")
    return document


def bind_final_provenance(app_root, input_receipt, *, final_stage="assembled-candidate"):
    """Return final metadata bound to this App's real dylib, without writing it."""
    document = _input_document(_document(input_receipt))
    if final_stage not in ("assembled-candidate", "signed-candidate"):
        raise PrivacyError("invalid-final-binary-provenance-stage")
    digest = _hash_binary(_regular_under(app_root, BUNDLED_PATH))
    document.update(finalStage=final_stage, finalBundledSHA256=digest,
                    exactMatch=digest == document["upstreamSHA256"],
                    finalMatchesInput=digest == document["inputSHA256"], status="final-bound")
    return document


def finalize_app_provenance(app_root, input_receipt, *, final_stage="assembled-candidate"):
    """Update only the copied candidate notice, after the bundler's last notice copy.

    The caller must pass a newly assembled candidate. This function does not
    establish input authenticity, sign anything, or grant permission to alter an
    installed App. Rebind after signing if signing later changes the dylib bytes.
    """
    notice = _regular_under(app_root, NOTICE_PATH)
    document = bind_final_provenance(app_root, input_receipt, final_stage=final_stage)
    notice.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    return verify_app_provenance(app_root)


def verify_app_provenance(app_root):
    """Fail on pending, stale or contradictory final hashes and comparison flags."""
    document = _document(_regular_under(app_root, NOTICE_PATH))
    _input_document(document)
    if (document.get("status") != "final-bound"
            or document.get("finalStage") not in ("assembled-candidate", "signed-candidate")
            or not _digest(document.get("finalBundledSHA256"))):
        raise PrivacyError("unbound-final-binary-provenance")
    digest = _hash_binary(_regular_under(app_root, BUNDLED_PATH))
    if digest != document["finalBundledSHA256"]:
        raise PrivacyError("final-binary-provenance-hash-mismatch")
    if (document.get("exactMatch") is not (digest == document["upstreamSHA256"])
            or document.get("finalMatchesInput") is not (digest == document["inputSHA256"])):
        raise PrivacyError("invalid-final-binary-provenance-comparison")
    return document
