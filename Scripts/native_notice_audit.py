"""Check observable Rust dependencies against exact, hash-bound local notices.

Panic/source paths are a lower bound, not a complete linked-component inventory.
The upstream Cargo.lock collection remains the broader provenance inventory.
No native file is loaded or executed here.
"""
import hashlib
from importlib import metadata
import json
from pathlib import Path
import re

try:
    from .privacy_package import PrivacyError
    from .notice_copy import copy_notice_tree
except ImportError:
    from privacy_package import PrivacyError
    from notice_copy import copy_notice_tree


CRATE_PATH = re.compile(
    rb"(?:registry/src/[^/\x00\s]+/|cargo-source/[^/\x00\s]+/)"
    rb"([A-Za-z0-9_-]+-[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+_-]+)?)/"
)


def native_crates(site):
    result = {}
    for path in sorted(Path(site).rglob("*")):
        if path.is_symlink() or not path.is_file() or path.suffix not in (".so", ".dylib"):
            continue
        crates = sorted({match.decode("ascii") for match in CRATE_PATH.findall(path.read_bytes())})
        if crates:
            result[path.relative_to(site).as_posix()] = crates
    return result


def audit(site, supplements):
    """Missing versions or changed/missing notice texts fail the caller's gate."""
    root = Path(supplements) / "native-cargo-notices"
    inventory = root / "inventory.json"
    binaries = native_crates(site)
    required = sorted({crate for crates in binaries.values() for crate in crates})
    components = json.loads(inventory.read_text())["components"] if inventory.is_file() else []
    indexed = {row["name"] + "-" + row["version"]: row for row in components}
    missing = []
    for crate in required:
        row = indexed.get(crate)
        texts = row.get("texts", []) if row else []
        valid = bool(texts)
        for item in texts:
            relative = Path(item["path"])
            if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != crate:
                raise PrivacyError("invalid-native-notice-inventory-path")
            path = root / relative
            if (path.is_symlink() or any(p.is_symlink() for p in path.parents if p == root or root in p.parents)
                    or not path.is_file()
                    or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]):
                valid = False
        if not valid:
            missing.append(crate)
    missing_sources = []
    # Python-SoXR wheels statically include libsoxr. A wheel LICENSE cannot
    # replace corresponding source; reject accidental reintroduction without
    # an exact, registered, hash-bound source archive.
    soxr = Path(site) / "soxr"
    if soxr.is_dir() and any(soxr.glob("*.so")):
        versions = [dist.version for dist in metadata.distributions(path=[str(site)])
                    if dist.metadata.get("Name", "").lower() == "soxr"]
        source_audit = Path(supplements) / "source-preparation/SourceArchiveAudit.json"
        archives = json.loads(source_audit.read_text()).get("archives", []) if source_audit.is_file() else []
        expected = {row.get("preparedSHA256") for row in archives
                    if row.get("package") in ("soxr", "python-soxr") and row.get("version") in versions}
        found = False
        if expected:
            for path in Path(supplements).rglob("*soxr*.tar.*"):
                if not path.is_symlink() and path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() in expected:
                    found = True
        if not found:
            missing_sources.append("soxr")
    return {"scope": "Observable registry source paths only; a lower bound, not an exhaustive linked inventory.",
            "binaries": binaries, "requiredCrates": required, "missingCrateNotices": missing,
            "missingCorrespondingSource": missing_sources, "passed": not missing and not missing_sources}


def copy_asr_notices(supplements, destination, result):
    """Copy available exact Rust notices and common embedded-source supplements.

    Corresponding source archives remain at the canonical LanguageRuntime/Licenses
    location in the App. No archive is duplicated under an unreviewed ASR path.
    """
    supplements, destination = Path(supplements), Path(destination)
    embedded = supplements / "embedded-source-notices"
    if embedded.is_dir():
        copy_notice_tree(embedded, destination / embedded.name)
    source = supplements / "native-cargo-notices"
    inventory = source / "inventory.json"
    if not inventory.is_file():
        return
    value = json.loads(inventory.read_text())
    required = set(result["requiredCrates"]) - set(result["missingCrateNotices"])
    value["components"] = [row for row in value["components"]
                           if row["name"] + "-" + row["version"] in required]
    value["scope"] = result["scope"]
    target = destination / source.name
    target.mkdir(parents=True, exist_ok=True)
    for crate in sorted(required):
        copy_notice_tree(source / crate, target / crate)
    (target / "inventory.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
