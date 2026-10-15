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


def runtime_lock_packages(value):
    """Conservative lock reachability, excluding proven root dev-only edges.

    No feature/target edge is dropped. The exact source manifest's normal,
    build and dev dependency names are recorded in the hash-bound audit.
    """
    packages = value["packages"]
    if "rootPackage" not in value:
        return packages
    indexed = {(row["name"], row["version"]): row for row in packages}
    root = indexed.get(tuple(value["rootPackage"]))
    if root is None:
        raise PrivacyError("native-lock-root-missing")
    excluded = set(value["rootDevDependencies"]) - set(value["rootNonDevDependencies"])
    reached, pending = set(), [root]
    while pending:
        row = pending.pop()
        identity = row["name"], row["version"]
        if identity in reached:
            continue
        reached.add(identity)
        for edge in row.get("dependencies", []):
            name, *version = edge.split()
            if row is root and name in excluded:
                continue
            choices = [item for key, item in indexed.items()
                       if key[0] == name and (not version or key[1] == version[0])]
            if len(choices) != 1:
                raise PrivacyError("native-lock-dependency-ambiguous")
            pending.append(choices[0])
    return [row for row in packages if (row["name"], row["version"]) in reached]


def source_lock_audits(site, root, inventory, indexed):
    """Verify complete-lock evidence for installed, exact Python releases.

    A lock includes build/optional/platform dependencies. Until an exact linked
    inventory establishes exclusions, unresolved versions fail conservatively.
    Never treat absent panic paths as proof that a crate is absent.
    """
    installed = {(dist.metadata.get("Name", "").lower(), dist.version)
                 for dist in metadata.distributions(path=[str(site)])}
    reports = []
    for item in inventory.get("sourceLockAudits", []):
        if (item["distribution"].lower(), item["version"]) not in installed:
            continue
        relative = Path(item["path"])
        if relative.is_absolute() or len(relative.parts) != 1:
            raise PrivacyError("invalid-native-lock-audit-path")
        path = root / relative
        if (path.is_symlink() or not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]):
            raise PrivacyError("native-lock-audit-hash-mismatch")
        value = json.loads(path.read_bytes())
        if (value["distribution"], value["version"]) != (item["distribution"], item["version"]):
            raise PrivacyError("native-lock-audit-version-mismatch")
        required = [row for row in runtime_lock_packages(value) if row.get("checksum")]
        excluded = sorted(row["name"] + "-" + row["version"] for row in value["packages"]
                          if row.get("checksum") and row not in required)
        missing = []
        for row in required:
            identity = row["name"] + "-" + row["version"]
            notice = indexed.get(identity)
            if not notice or not notice.get("texts") or notice.get("checksum") != row["checksum"]:
                missing.append(identity)
        reports.append({"distribution": item["distribution"], "version": item["version"],
                        "path": item["path"], "sha256": item["sha256"],
                        "scope": value["scope"],
                        "registryPackageCount": sum(bool(row.get("checksum")) for row in value["packages"]),
                        "requiredRegistryPackageCount": len(required), "excludedDevOnlyCrates": excluded,
                        "missingCrateNotices": sorted(missing), "passed": not missing})
    return reports


def audit(site, supplements):
    """Missing versions or changed/missing notice texts fail the caller's gate."""
    root = Path(supplements) / "native-cargo-notices"
    inventory = root / "inventory.json"
    binaries = native_crates(site)
    required = sorted({crate for crates in binaries.values() for crate in crates})
    value = json.loads(inventory.read_text()) if inventory.is_file() else {}
    components = value.get("components", [])
    indexed = {row["name"] + "-" + row["version"]: row for row in components}
    locks = source_lock_audits(site, root, value, indexed)
    # Validate bytes for complete-lock components as well as observable paths.
    lock_required = {row["name"] + "-" + row["version"]
                     for item in locks for row in runtime_lock_packages(json.loads((root / item["path"]).read_bytes()))
                     if row.get("checksum")}
    missing = []
    for crate in sorted(set(required) | lock_required):
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
    return {"scope": "Observable registry source paths plus registered exact-release complete locks; locks conservatively include build, optional and platform dependencies.",
            "binaries": binaries, "requiredCrates": required, "missingCrateNotices": missing,
            "sourceLockAudits": locks, "lockRequiredCrates": sorted(lock_required),
            "missingCorrespondingSource": missing_sources,
            "passed": not missing and not missing_sources and all(item["passed"] for item in locks)}


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
    required = (set(result["requiredCrates"]) | set(result.get("lockRequiredCrates", []))) - set(result["missingCrateNotices"])
    value["components"] = [row for row in value["components"]
                           if row["name"] + "-" + row["version"] in required]
    value["scope"] = result["scope"]
    target = destination / source.name
    target.mkdir(parents=True, exist_ok=True)
    value["sourceLockAudits"] = [item for item in value.get("sourceLockAudits", [])
                                 if any(item["path"] == report["path"] for report in result.get("sourceLockAudits", []))]
    for item in value["sourceLockAudits"]:
        (target / item["path"]).write_bytes((source / item["path"]).read_bytes())
    for crate in sorted(required):
        copy_notice_tree(source / crate, target / crate)
    (target / "inventory.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
