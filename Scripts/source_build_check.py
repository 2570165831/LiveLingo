"""Offline configure/build-input checks for the source archives actually shipped.

The network-denying sandbox is mandatory. All extracted sources, logs and
generated build files stay in a new explicit work directory. Originals are
read-only. These checks establish build-input coverage, not binary equivalence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tarfile
import time
import tomllib

try:
    from .privacy_package import PrivacyError
except ImportError:
    from privacy_package import PrivacyError


REPO = Path(__file__).resolve().parent.parent
SANDBOX = "/usr/bin/sandbox-exec"
PROFILE = "(version 1) (allow default) (deny network*)"
MISSING = re.compile(r"cannot find input file|No rule to make target|No such file or directory", re.I)
GCC_FULL = "gcc-13.4.0-full.tar.xz"
GCC_PATCH = "gcc-13.4.0-darwin.diff"
GCC_MAPPING = "gcc-12-13-darwin-version-mapping.diff"


def run_offline(command, directory, log, *, extra_env=None, timeout=240):
    if not Path(SANDBOX).is_file():
        raise PrivacyError("offline-build-sandbox-unavailable")
    settings = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "DEVELOPER_DIR", "SDKROOT")
                if key in os.environ}
    settings.update(PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL="C",
                    TMPDIR=str(directory.parent), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    settings.update(extra_env or {})
    with log.open("wb") as output:
        result = subprocess.run([SANDBOX, "-p", PROFILE, *map(str, command)], cwd=directory,
                                env=settings, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(errors="replace")
    return {"exit": result.returncode, "missingInput": bool(MISSING.search(text)), "log": log.name}


def unpack(archive, directory):
    if archive.is_symlink() or not archive.is_file() or directory.exists() or directory.is_symlink():
        raise PrivacyError("invalid-source-build-check-path")
    directory.mkdir(parents=True)
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        for member in members:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts or not (member.isfile() or member.isdir()):
                raise PrivacyError("invalid-source-build-check-member")
        stream.extractall(directory, members=members, filter="data")
    roots = list(directory.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise PrivacyError("invalid-source-build-check-root")
    return roots[0]


def gcc_source_inputs(directory):
    """Require the complete base and pinned downstream patches, never the subset."""
    directory = Path(directory)
    provenance = json.loads((directory / "PROVENANCE.json").read_text())
    inputs = provenance["darwinCorrespondingSource"]["inputs"]
    expected = {GCC_FULL, GCC_PATCH, GCC_MAPPING}
    if set(inputs) != expected:
        raise PrivacyError("incomplete-gcc-darwin-source-inputs")
    for name, receipt in inputs.items():
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise PrivacyError("missing-gcc-darwin-source-input")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != receipt["sha256"]:
            raise PrivacyError("gcc-darwin-source-hash-mismatch")
    return inputs


def run_gcc_offline(command, directory, log, *, timeout, extra_env=None, stop_at=None):
    """Bound the entire make process group, including on timeout or interruption."""
    if not Path(SANDBOX).is_file():
        raise PrivacyError("offline-build-sandbox-unavailable")
    if timeout <= 0:
        raise PrivacyError("gcc-build-timeout-must-be-positive")
    if stop_at is not None:
        remaining = (stop_at - datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0:
            return {"exit": None, "status": "not-run-stop-time", "log": log.name}
        timeout = min(timeout, remaining)
    settings = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "DEVELOPER_DIR", "SDKROOT")
                if key in os.environ}
    settings.update(PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL="C",
                    TMPDIR=str(directory.parent), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    settings.update(extra_env or {})
    started = time.monotonic()
    timed_out = False
    with log.open("wb") as output:
        process = subprocess.Popen([SANDBOX, "-p", PROFILE, *map(str, command)], cwd=directory,
                                   env=settings, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                code = None
            # The make parent can exit while a descendant ignores SIGTERM.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if code is None:
                code = process.wait()
    text = log.read_text(errors="replace")
    # Keep review logs portable; raw generated build files are local work only.
    text = text.replace(str(REPO), "<checkout>").replace("/" + "Users/", "<host-home>/")
    log.write_text(text)
    return {"exit": code, "timedOut": timed_out, "elapsedSeconds": round(time.monotonic() - started, 3),
            "missingInput": bool(MISSING.search(text)), "log": log.name,
            "network": "denied-by-sandbox"}


def check_gcc_native(directory, output, *, compiler_timeout=1800, runtime_timeout=900, stop_at=None):
    """Configure/build a native Darwin arm64 compiler, then its three runtimes.

    No downloads, system installation, bootstrap, signing or binary-equivalence
    claim. The host-only version mapping is distinct from the wheel patch.
    """
    directory, output = Path(directory).resolve(), Path(output).absolute()
    inputs = gcc_source_inputs(directory)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise PrivacyError("gcc-native-check-requires-darwin-arm64")
    if output.exists() or output.is_symlink() or any(p.is_symlink() for p in output.parents):
        raise PrivacyError("invalid-source-build-check-output")
    output.mkdir(parents=True)
    result = {"archive": GCC_FULL, "sourceInputs": inputs, "network": "denied-by-sandbox",
              "scope": "native arm64 compiler and libgcc/libquadmath/libgfortran; bounded non-bootstrap check",
              "byteIdenticalRebuild": False, "passed": False, "steps": {}, "runtimeLibraries": {}}
    def save():
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    def step(name, command, cwd, timeout=240, env=None):
        outcome = run_gcc_offline(command, cwd, output / (name + ".log"), timeout=timeout,
                                  extra_env=env, stop_at=stop_at)
        result["steps"][name] = outcome
        save()
        return outcome.get("exit") == 0 and not outcome.get("timedOut")
    source = unpack(directory / GCC_FULL, output / "sources")
    patch_path = os.path.relpath(directory / GCC_PATCH, source)
    if not step("apply-darwin-patch", ["patch", "--batch", "--fuzz=0", "-p1", "-i", patch_path], source):
        return result
    kernel_major = int(platform.release().split(".")[0])
    target = "aarch64-apple-darwin" + str(kernel_major)
    result["target"] = target
    result["hostOnlyPatchApplied"] = kernel_major >= 25
    if kernel_major >= 25:
        mapping = os.path.relpath(directory / GCC_MAPPING, source)
        if not step("apply-host-version-mapping", ["patch", "--batch", "--fuzz=0", "-p1", "-i", mapping], source):
            return result
    required = ["gcc/config/aarch64/darwin.h", "gcc/config/aarch64/t-aarch64-darwin",
                "libgcc/config/aarch64/t-darwin", "libgfortran/configure", "libquadmath/configure"]
    result["nativeInputs"] = {name: (source / name).is_file() for name in required}
    save()
    if not all(result["nativeInputs"].values()):
        return result
    sdk = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                         capture_output=True, text=True, check=True).stdout.strip()
    build = output / "build"
    build.mkdir()
    args = [os.path.relpath(source / "configure", build), "--build=" + target, "--host=" + target,
            "--target=" + target, "--disable-bootstrap", "--disable-multilib", "--disable-nls",
            "--enable-checking=release", "--with-gcc-major-version-only", "--enable-languages=c,c++,fortran",
            "--with-system-zlib", "--with-sysroot=" + sdk, "--prefix=" + str(output / "local-prefix")]
    for dependency, option in [("gmp", "gmp"), ("mpfr", "mpfr"), ("libmpc", "mpc"),
                               ("isl", "isl"), ("zstd", "zstd")]:
        location = Path("/opt/homebrew/opt") / dependency
        if not location.is_dir():
            result["prerequisiteMissing"] = dependency
            save()
            return result
        args.append("--with-" + option + "=" + str(location))
    result["configureArguments"] = [arg.replace(str(output), "<output>") for arg in args]
    if not step("configure", args, build):
        return result
    if not step("compiler-configure", ["make", "configure-gcc"], build):
        return result
    if not step("compiler-build", ["make", "-j2", "all-gcc"], build, compiler_timeout):
        return result
    # Native compilers are newly linked by the platform linker. Verify their
    # signatures before configure uses them; never repair or execute a broken
    # signature as part of a build check.
    for name in ("xgcc", "cc1", "cc1plus", "f951", "collect2", "lto1"):
        compiler = build / "gcc" / name
        if compiler.is_file() and not step("verify-compiler-" + name,
                                           ["/usr/bin/codesign", "--verify", compiler], build):
            return result
    for name in ["libgcc", "libquadmath", "libgfortran"]:
        if not step(name + "-configure", ["make", "configure-target-" + name], build):
            return result
        if not step(name + "-build", ["make", "-j2", "all-target-" + name,
                                     "LDFLAGS_FOR_TARGET=-Wl,-headerpad_max_install_names"], build, runtime_timeout):
            return result
        expected = {"libgcc": "libgcc_s.1.1.dylib", "libquadmath": "libquadmath.0.dylib",
                    "libgfortran": "libgfortran.5.dylib"}[name]
        matches = [p for p in (build / target / name).rglob(expected) if p.is_file() and not p.is_symlink()]
        if len(matches) != 1:
            result["runtimeLibraries"][name] = {"status": "missing-or-ambiguous-output"}
            save()
            return result
        library = matches[0]
        arch = subprocess.run(["/usr/bin/lipo", "-archs", str(library)], capture_output=True,
                              text=True, check=True).stdout.strip()
        with library.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        result["runtimeLibraries"][name] = {"path": library.relative_to(output).as_posix(), "archs": arch,
            "sha256": digest, "bytes": library.stat().st_size}
        save()
        if arch != "arm64":
            return result
    result["passed"] = True
    save()
    return result


def check(archives, output):
    archives, output = Path(archives).resolve(), Path(output).absolute()
    if output.exists() or output.is_symlink() or any(p.is_symlink() for p in output.parents):
        raise PrivacyError("invalid-source-build-check-output")
    output.mkdir(parents=True)
    gcc_directory = archives / "GCC-runtime-13.4.0"
    if gcc_directory.is_dir() and not (gcc_directory / GCC_FULL).is_file():
        raise PrivacyError("missing-complete-gcc-darwin-source")
    results = []
    sources = {}
    files = [p for p in archives.rglob("*") if
             p.name.endswith((".tar.gz", ".tar.bz2", ".tar.xz", ".crate")) and p.name != "gcc-13.4.0.tar.xz"]
    # The codec dependency is configured/built locally first. This supplies
    # libvorbis/FLAC configure probes, without downloads or system installation.
    files.sort(key=lambda p: (0 if p.name.startswith("libogg-") else 1, p.name))
    prefix = output / "local-prefix"
    for archive in files:
        if archive.name == GCC_FULL:
            result = check_gcc_native(archive.parent, output / "gcc-native")
            result["archive"] = archive.relative_to(archives).as_posix()
            result["configure"] = result["steps"].get("configure", {"status": "not-run-source-preparation-failed"})
            results.append(result)
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            continue
        source = unpack(archive, output / archive.name.replace(".", "-"))
        sources[source.name] = source
        result = {"archive": archive.relative_to(archives).as_posix(), "network": "denied-by-sandbox"}
        if (source / "configure").is_file():
            args = [str(source / "configure")]
            build = source
            args += ["--enable-static", "--disable-shared", "--prefix=" + str(prefix)]
            if source.name.startswith("libsndfile-"):
                args += ["--disable-external-libs"]
            env = {"PKG_CONFIG_PATH": str(prefix / "lib/pkgconfig")}
            if source.name.startswith(("libvorbis-", "flac-")):
                ogg = sources["libogg-1.3.5"]
                args += ["--with-ogg-includes=" + str(ogg / "include"),
                         "--with-ogg-libraries=" + str(ogg / "src/.libs")]
            result["configure"] = run_offline(args, build, output / (source.name + "-configure.log"), extra_env=env)
            if result["configure"]["exit"] == 0:
                if source.name.startswith("libogg-"):
                    result["dependencyBootstrap"] = run_offline(["make", "-j2", "install"], build,
                        output / (source.name + "-bootstrap.log"), extra_env=env)
                if source.name.startswith(("lame-", "flac-")):
                    # Recursive make -n cannot create sibling .la files. Build
                    # these small static inputs before checking the full graph.
                    result["dependencyBootstrap"] = run_offline(["make", "-j2"], build,
                        output / (source.name + "-bootstrap.log"), extra_env=env)
                target = "all"
                result["dryRun"] = run_offline(["make", "-n", target], build,
                    output / (source.name + "-make-n.log"), extra_env=env)
            else:
                result["dryRun"] = {"status": "not-run-configure-failed"}
        else:
            # Cargo crates have no configure script. Validate their declared
            # library entry point without fetching/building missing toolchains.
            manifest = tomllib.loads((source / "Cargo.toml").read_text())
            library = manifest.get("lib", {}).get("path", "src/lib.rs")
            result["cargoInputs"] = {"package": manifest["package"]["name"],
                                     "libraryPresent": (source / library).is_file(),
                                     "configure": "not-provided-by-upstream",
                                     "dryRun": "Cargo build not run; manifest and library checked without fetching dependencies."}
        result["passed"] = (all(step.get("exit") == 0 and not step.get("missingInput")
                                 for step in [result.get("configure", {}), result.get("dryRun", {})])
                            if "configure" in result else result["cargoInputs"]["libraryPresent"])
        if "dependencyBootstrap" in result:
            result["passed"] &= result["dependencyBootstrap"]["exit"] == 0
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archives", type=Path, default=REPO / "Packaging/MLXLicenses")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--gcc-native", action="store_true", help="Check the complete downstream GCC source only")
    parser.add_argument("--compiler-timeout", type=int, default=1800)
    parser.add_argument("--runtime-timeout", type=int, default=900)
    parser.add_argument("--stop-at-utc", type=lambda value: datetime.fromisoformat(value).astimezone(timezone.utc),
                        help="Optional ISO-8601 absolute stop time for all native GCC stages")
    args = parser.parse_args()
    if args.gcc_native:
        if args.compiler_timeout <= 0 or args.runtime_timeout <= 0:
            parser.error("GCC timeouts must be positive")
        directory = args.archives / "GCC-runtime-13.4.0"
        result = check_gcc_native(directory, args.output, compiler_timeout=args.compiler_timeout,
                                  runtime_timeout=args.runtime_timeout, stop_at=args.stop_at_utc)
        print(json.dumps({"passed": result["passed"], "steps": result["steps"]}))
        return 0 if result["passed"] else 1
    results = check(args.archives, args.output)
    print(json.dumps({"archives": len(results), "passed": sum(item["passed"] for item in results),
                      "results": str(args.output / "results.json")}))
    return 0 if results and all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
