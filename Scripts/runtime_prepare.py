"""Prepare a locked portable runtime from an explicit read-only input.

Selection uses the INPUT's metadata, never the tool's Python environment.
Unrecognized resources still go through the real distribution privacy gate.
Rejected output remains available for diagnosis; no input is changed or deleted.
"""
import argparse
import ast
from collections import Counter
import csv
import hashlib
from importlib import metadata
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tokenize

try:
    from .privacy_package import PrivacyError, excluded, inspect_tree, license_filename, validate_link
except ImportError:
    from privacy_package import PrivacyError, excluded, inspect_tree, license_filename, validate_link


REPO = Path(__file__).resolve().parent.parent
RUNTIME_MODULES = ("worker.py", "engine.py", "schemas.py", "checks.py",
                   "review_diagnostics.py", "grammar_vocabulary.py", "latin_numbers.py", "checkpoints.py")
STDLIB_UNUSED = frozenset({"idlelib", "turtledemo", "tkinter", "ensurepip", "venv", "turtle.py"})
DEVELOPMENT_SUFFIXES = frozenset({".pyx", ".pxd", ".pxi", ".f", ".f90", ".o", ".exe",
                                 ".pc", ".cmake", ".in", ".ini", ".cfg", ".tmpl", ".template",
                                 ".tp", ".bat", ".csh", ".fish", ".ps1", ".gdb", ".cu"})
# The app uses inference and formula composition, not tokenizer training,
# datasets, symbolic LaTeX/MathML conversion, or extension compilation.
UNUSED_PACKAGE_TREES = (
    "sentencepiece/package_data", "sympy/parsing/autolev", "sympy/parsing/latex",
    "sympy/utilities/mathml/data", "sklearn/datasets/data", "sklearn/datasets/descr",
    "sklearn/datasets/images", "sklearn/svm/src", "mlx/share/cmake", "mlx/lib/cmake",
)


def canonical_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def locked_distributions(site, lock, mode):
    expected = lock if mode == "language" else {p["name"]: p["version"] for p in lock["packages"]}
    expected = {canonical_name(name): version for name, version in expected.items()}
    installed = {}
    for info in site.iterdir():
        if info.name.endswith((".dist-info", ".egg-info")):
            if info.is_symlink() or any((info / name).is_symlink() for name in ("METADATA", "PKG-INFO", "RECORD")):
                raise PrivacyError("input-distribution-metadata-symlink")
    for dist in metadata.distributions(path=[str(site)]):
        name = canonical_name(dist.metadata["Name"])
        if name in installed:
            raise PrivacyError("duplicate-input-distribution")
        installed[name] = dist
    if any(name not in installed or installed[name].version != version for name, version in expected.items()):
        raise PrivacyError("runtime-version-lock-mismatch")
    return {name: installed[name] for name in sorted(expected)}


def portable_layout(base):
    if base.is_symlink() or not base.is_dir() or (base / "pyvenv.cfg").exists():
        raise PrivacyError("input-not-portable-python")
    if (base / "lib").is_symlink() or (base / "bin").is_symlink():
        raise PrivacyError("input-python-layout-symlink")
    libraries = [p for p in (base / "lib").glob("python3.*") if p.is_dir() and not p.is_symlink()]
    if len(libraries) != 1 or not (base / "bin/python3").is_file():
        raise PrivacyError("input-python-layout-mismatch")
    if libraries[0].name != "python3.13":
        raise PrivacyError("input-python-minor-version-mismatch")
    if (base / "bin").is_symlink() or (libraries[0] / "site-packages").is_symlink():
        raise PrivacyError("input-python-layout-symlink")
    try:
        (base / "bin/python3").resolve(strict=True).relative_to(base.resolve())
    except (OSError, ValueError):
        raise PrivacyError("input-python-executable-external") from None
    return libraries[0].relative_to(base), libraries[0] / "site-packages"


def python_version(base):
    # Distributed executables carry sandbox-inherit entitlements and cannot be
    # launched by an unsandboxed build tool. Read the shared library's unique
    # NUL-terminated version constant without loading a second Python runtime
    # into this process or changing any code signature.
    library = base / "lib/libpython3.13.dylib"
    if library.is_symlink() or not library.is_file():
        raise PrivacyError("input-python-shared-library-missing")
    versions = set(re.findall(rb"(?<![0-9.])(3\.13\.\d+)\x00", library.read_bytes()))
    if len(versions) != 1:
        raise PrivacyError("input-python-version-constant-ambiguous")
    return versions.pop().decode("ascii")


def removal_reason(relative, stdlib, selected_files):
    parts = relative.parts
    if any(excluded(part) for part in parts):
        return "tests-caches-private-records"
    if relative.name in ("EXTERNALLY-MANAGED", ".empty", "zip-safe", ".lock", "fetch_macholib"):
        return "install-build-markers"
    if any(part.lower() in ("test-examples", "_examples", "examples", "benchmarks", "demos") for part in parts):
        return "examples-benchmarks"
    if parts[0] == "bin":
        return None if len(parts) == 2 and re.fullmatch(r"python(?:3(?:\.13)?)?", parts[1]) else "console-install-build-tools"
    if parts[0] != "lib":
        return "headers-build-manuals"
    if len(parts) == 2 and parts[1] == "libpython3.13.dylib":
        return None
    if not relative.is_relative_to(stdlib):
        return "tcl-tk"
    tail = relative.relative_to(stdlib)
    if tail.parts[0] in STDLIB_UNUSED or tail.parts[0].startswith("config-"):
        return "unused-stdlib-install-gui"
    if tail.parts[0] == "lib-dynload" and tail.name.startswith("_tkinter."):
        return "tcl-tk"
    if tail.parts[0] == "site-packages":
        package_file = Path(*tail.parts[1:])
        if package_file not in selected_files:
            return "unlocked-packages"
        if package_file.name in ("direct_url.json", "distutils-precedence.pth", "py.typed") or "sboms" in package_file.parts:
            return "install-provenance-typing-build-hooks"
        if (package_file.suffix.lower() not in (".py", ".pyi") and
                any(package_file == Path(tree) or Path(tree) in package_file.parents for tree in UNUSED_PACKAGE_TREES)):
            return "unused-package-apis"
        if package_file == Path("setuptools/config/setuptools.schema.json"):
            return "development-resources"
        if package_file.name == "meson.build" or package_file.suffix.lower() in DEVELOPMENT_SUFFIXES:
            return "development-resources"
        # Read only by optional notebook display/manual APIs, not app inference.
        if (package_file.parent == Path("sklearn/utils/_repr_html") and package_file.suffix == ".css"):
            return None  # sklearn reads its CSS eagerly during import.
        if package_file.suffix.lower() in (".css", ".html", ".js", ".cc", ".1") or package_file.name == "port.yaml":
            return "presentation-manual-resources"
    elif tail.suffix.lower() in DEVELOPMENT_SUFFIXES or tail.suffix.lower() in (".css", ".bat", ".ctypes"):
        return "development-resources"
    return None


def normalized_python(data):
    """Escape unprintable source characters while preserving the complete AST."""
    encoding, _ = tokenize.detect_encoding(io.BytesIO(data).readline)
    text = data.decode(encoding)
    clean = "".join(char if char.isprintable() or char in "\t\r\n" else
                    (f"\\u{ord(char):04x}" if ord(char) <= 0xffff else f"\\U{ord(char):08x}") for char in text)
    lines = clean.splitlines(keepends=True)
    for index in range(min(2, len(lines))):
        lines[index] = re.sub(r"^(\s*#.*?coding[:=]\s*)[-\w.]+", r"\1utf-8", lines[index])
    clean = "".join(lines)
    if clean.encode("utf-8") == data:
        return data
    if ast.dump(ast.parse(text), include_attributes=False) != ast.dump(ast.parse(clean), include_attributes=False):
        raise PrivacyError("source-normalization-changes-ast")
    return clean.encode("utf-8")


def copy_runtime_file(source, destination, *, clone):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
        return "copied"
    data = None
    change = "copied"
    if source.suffix == ".py":
        original = source.read_bytes()
        normalized = normalized_python(original)
        if original != normalized:
            data, change = normalized, "python-encoding-ast-verified"
    elif source.name == "METADATA" and source.parent.name.endswith(".dist-info"):
        original = source.read_bytes()
        # Retain all package headers (versions/dependencies/licensing). The
        # optional README description is not an import-time resource.
        headers = original.split(b"\n\n", 1)[0] + b"\n\n"
        if headers != original:
            data, change = headers, "metadata-description-omitted"
    elif source.name == "cacert.pem" and source.parent.name == "certifi":
        original = source.read_bytes()
        blocks = re.findall(rb"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+?-----END CERTIFICATE-----", original)
        if not blocks:
            raise PrivacyError("input-certifi-certificates-missing")
        # Preserve every certificate block byte for byte; omit label comments.
        data, change = b"\n".join(blocks) + b"\n", "certifi-comments-omitted"
    if data is not None:
        destination.write_bytes(data)
        shutil.copystat(source, destination)
    elif clone and source.stat().st_size >= 1024 * 1024:
        result = subprocess.run(["/bin/cp", "-c", str(source), str(destination)], capture_output=True)
        if result.returncode:
            raise PrivacyError("runtime-apfs-clone-failed")
    else:
        shutil.copy2(source, destination)
    return change


def prepare(base, output, *, mode="language", repo=REPO, clone=True):
    base, output, repo = Path(base), Path(output), Path(repo)
    stdlib, site = portable_layout(base)
    if output.exists() or output.is_symlink():
        raise PrivacyError("destination-already-exists")
    base_real, output_real = base.resolve(), output.resolve()
    if base_real == output_real or base_real in output_real.parents or output_real in base_real.parents:
        raise PrivacyError("overlapping-runtime-trees")
    if any(p.is_symlink() for p in [output.parent, *output.parent.parents]):
        raise PrivacyError("symlink-destination-parent")
    lock_path = repo / "Packaging" / ("MLXRuntime.lock.json" if mode == "language" else "ASRRuntime.lock.json")
    lock = json.loads(lock_path.read_text())
    selected = locked_distributions(site, lock, mode)
    version = python_version(base)
    if not re.fullmatch(r"3\.13\.\d+", version) or (mode == "asr" and version != lock["python"]):
        raise PrivacyError("input-python-version-lock-mismatch")
    owners = {}
    declared_licenses = set()
    for name, dist in selected.items():
        if dist.files is None:
            raise PrivacyError("input-distribution-record-missing")
        for relative in dist.files:
            if relative.is_absolute() or ".." in relative.parts:
                continue  # Console scripts must not escape site-packages.
            owners[Path(relative)] = name
        info = next((p.parent for p in dist.files if p.name == "METADATA" and p.parent.name.endswith(".dist-info")), None)
        if info is None:
            raise PrivacyError("input-distribution-metadata-missing")
        for raw in dist.metadata.get_all("License-File", []):
            relative = Path(raw)
            if relative.is_absolute() or ".." in relative.parts:
                raise PrivacyError("external-license-file-declaration")
            candidates = [site / info / "licenses" / relative, site / info / relative]
            source = next((p for p in candidates if p.is_file() and not p.is_symlink()), None)
            if source is None:
                raise PrivacyError("declared-license-file-missing")
            if not source.resolve().is_relative_to(base_real):
                raise PrivacyError("external-license-file-declaration")
            declared_licenses.add(source)
    entries = []
    for directory, directories, files in os.walk(base, followlinks=False):
        for name in sorted(directories + files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_dir():
                entries.append(path)
    # Discover notices BEFORE pruning, including notices in test/demo trees and
    # unlocked installation tools. Their bytes are never rewritten.
    licenses = []
    before = Counter(files=0, bytes=0)
    for path in entries:
        if path.is_symlink():
            continue
        if not stat.S_ISREG(path.lstat().st_mode):
            raise PrivacyError("special-input-runtime-entry")
        before["files"] += 1
        before["bytes"] += path.stat().st_size
        if license_filename(path) or path in declared_licenses:
            licenses.append(path)
    output.mkdir(parents=True)
    python = output / "python" if mode == "language" else output
    python.mkdir(exist_ok=True)
    notice_root = output / "Licenses"
    removed, changed = Counter(), Counter()
    for path in entries:
        relative = path.relative_to(base)
        reason = removal_reason(relative, stdlib, owners)
        if reason:
            removed[reason] += 1
            continue
        if path.is_symlink():
            validate_link(path, base)
        changed[copy_runtime_file(path, python / relative,
                                 clone=clone and path.stat().st_dev == python.stat().st_dev)] += 1
    inventory = []
    component_licenses = {name: [] for name in selected}
    for path in licenses:
        relative = path.relative_to(base)
        name = owners.get(relative.relative_to(stdlib / "site-packages")) if relative.is_relative_to(stdlib / "site-packages") else None
        owner = name or "CPython-and-pruned-components"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        filename = path.name[:80] + "-" + hashlib.sha256(str(relative).encode()).hexdigest()[:16] + ".txt"
        target = notice_root / owner / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise PrivacyError("license-copy-hash-mismatch")
        inventory.append({"source": str(relative), "copy": str(target.relative_to(output)), "sha256": digest})
        if name:
            component_licenses[name].append(filename)
    missing = []
    components = []
    supplements = repo / "Packaging/MLXLicenses"
    for name, dist in selected.items():
        if not component_licenses[name]:
            supplement = supplements / f"{name}-{dist.version}-LICENSE"
            if supplement.is_file() and not supplement.is_symlink():
                target = notice_root / name / "LICENSE"
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(supplement, target)
                component_licenses[name].append("LICENSE")
            else:
                missing.append(name)
        components.append({"name": dist.metadata["Name"], "version": dist.version, "licenses": component_licenses[name]})
    # Keep importlib.metadata truthful about staged files. Empty hashes are
    # valid wheel RECORD entries; removed paths and old hashes are not retained.
    destination_site = python / stdlib / "site-packages"
    for dist in selected.values():
        record = next((Path(p) for p in dist.files if p.name == "RECORD" and p.parent.name.endswith(".dist-info")), None)
        if record is None:
            raise PrivacyError("input-distribution-record-missing")
        rows = [(str(p), "", "") for p in dist.files if not p.is_absolute() and ".." not in p.parts
                and (destination_site / p).is_file()]
        with (destination_site / record).open("w", newline="") as stream:
            csv.writer(stream).writerows(rows)
    if mode == "language":
        for name in RUNTIME_MODULES:
            source = repo / "Scripts/mlx_runtime" / name
            if source.is_symlink() or not source.is_file():
                raise PrivacyError("required-worker-module-missing")
            shutil.copy2(source, output / name)
        for source in supplements.iterdir():
            if source.is_dir() and not source.is_symlink():
                shutil.copytree(source, notice_root / source.name)
            elif source.name in ("AUDIT.json", "README.md"):
                shutil.copy2(source, notice_root / source.name)
        manifest = {"components": components, "missingLicenseFiles": missing, "python": "python",
                    "chempyScope": "Only Substance.from_formula and composition; solver, plotting and notebook dependencies intentionally omitted.",
                    "workerHashes": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in RUNTIME_MODULES},
                    "nativeTransitiveNoticeAudit": json.loads((supplements / "AUDIT.json").read_text())}
        (output / "runtime-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    after_files = [p for p in python.rglob("*") if p.is_file() and not p.is_symlink()]
    report = {"mode": mode, "pythonVersion": version, "components": {name: dist.version for name, dist in selected.items()},
              "before": dict(before), "afterPython": {"files": len(after_files), "bytes": sum(p.stat().st_size for p in after_files)},
              "removed": dict(removed), "changed": dict(changed), "licenses": inventory, "missingLicenseFiles": missing}
    (output / "runtime-preparation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if missing:
        raise PrivacyError("runtime-license-files-missing")
    inspect_tree(output)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-python", type=Path, required=True, help="read-only portable CPython tree; never a venv")
    parser.add_argument("--output", type=Path, required=True, help="new LanguageRuntime or (with --mode asr) portable ASR Python")
    parser.add_argument("--mode", choices=("language", "asr"), default="language")
    args = parser.parse_args()
    try:
        report = prepare(args.base_python, args.output, mode=args.mode)
    except PrivacyError as error:
        print("prepare-runtime: " + error.args[0] + "; input unchanged, inspect the new staging tree", file=sys.stderr)
        return 1
    except (OSError, ValueError, shutil.Error):
        print("prepare-runtime: invalid input or copy failure; input unchanged", file=sys.stderr)
        return 1
    print(json.dumps({"mode": report["mode"], "components": len(report["components"]),
                      "before": report["before"], "afterPython": report["afterPython"],
                      "licenseFilesPreserved": len(report["licenses"]), "missingLicenseFiles": report["missingLicenseFiles"]}))
    return 0
