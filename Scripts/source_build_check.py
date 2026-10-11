"""Offline configure/build-input checks for the source archives actually shipped.

The network-denying sandbox is mandatory. All extracted sources, logs and
generated build files stay in a new explicit work directory. Originals are
read-only. These checks establish build-input coverage, not binary equivalence.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tomllib

try:
    from .privacy_package import PrivacyError
except ImportError:
    from privacy_package import PrivacyError


REPO = Path(__file__).resolve().parent.parent
SANDBOX = "/usr/bin/sandbox-exec"
PROFILE = "(version 1) (allow default) (deny network*)"
MISSING = re.compile(r"cannot find input file|No rule to make target|No such file or directory", re.I)


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


def check(archives, output):
    archives, output = Path(archives).resolve(), Path(output).absolute()
    if output.exists() or output.is_symlink() or any(p.is_symlink() for p in output.parents):
        raise PrivacyError("invalid-source-build-check-output")
    output.mkdir(parents=True)
    results = []
    sources = {}
    files = [p for p in archives.rglob("*") if p.name.endswith((".tar.gz", ".tar.bz2", ".tar.xz", ".crate"))]
    # The codec dependency is configured/built locally first. This supplies
    # libvorbis/FLAC configure probes, without downloads or system installation.
    files.sort(key=lambda p: (0 if p.name.startswith("libogg-") else 1, p.name))
    prefix = output / "local-prefix"
    for archive in files:
        source = unpack(archive, output / archive.name.replace(".", "-"))
        sources[source.name] = source
        result = {"archive": archive.relative_to(archives).as_posix(), "network": "denied-by-sandbox"}
        if (source / "configure").is_file():
            args = [str(source / "configure")]
            build = source
            if source.name.startswith("gcc-"):
                build = output / "gcc-build"
                build.mkdir()
                args += ["--disable-bootstrap", "--disable-multilib", "--enable-languages=c,c++,fortran"]
                # Upstream GCC 13 does not support an AArch64 Darwin target.
                # A supported cross target exercises the compiler's real
                # documentation graph on this host without claiming a native
                # Apple Silicon runtime rebuild or supplying downstream patches.
                args += ["--target=x86_64-apple-darwin23"]
                result["targetScope"] = "x86_64-apple-darwin23 cross configuration; native AArch64 Darwin compiler rebuild is not verified."
                for dependency in ["gmp", "mpfr", "libmpc"]:
                    location = Path("/opt/homebrew/opt") / dependency
                    if not location.is_dir():
                        raise PrivacyError("offline-gcc-prerequisite-unavailable")
                    args += ["--with-" + ("mpc" if dependency == "libmpc" else dependency) + "=" + str(location)]
            else:
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
                if source.name.startswith("gcc-"):
                    target = "configure-gcc"
                result["dryRun"] = run_offline(["make", "-n", target], build,
                    output / (source.name + "-make-n.log"), extra_env=env)
                if source.name.startswith("gcc-"):
                    required = ["gcc/doc/gcov.texi", "gcc/doc/invoke.texi", "gcc/doc/tm.texi.in",
                                "gcc/doc/include/gcc-common.texi", "gcc/doc/gcov.1"]
                    result["documentationInputs"] = {name: (source / name).is_file() for name in required}
                    result["compilerConfigure"] = run_offline(["make", "configure-gcc"], build,
                        output / (source.name + "-compiler-configure.log"), extra_env=env)
                    if result["compilerConfigure"]["exit"] == 0:
                        result["documentationDryRun"] = run_offline(["make", "-C", "gcc", "-n", "doc"], build,
                            output / (source.name + "-doc-make-n.log"), extra_env=env)
                    result["dryRunScope"] = "Top-level configure-gcc, real compiler configuration and gcc/doc dry-run; full compiler bootstrap not executed."
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
                                     "dryRun": "Cargo toolchain unavailable; manifest and library checked only."}
        result["passed"] = (all(step.get("exit") == 0 and not step.get("missingInput")
                                 for step in [result.get("configure", {}), result.get("dryRun", {})])
                            if "configure" in result else result["cargoInputs"]["libraryPresent"])
        if "documentationInputs" in result:
            result["passed"] &= all(result["documentationInputs"].values())
            result["passed"] &= (result["compilerConfigure"]["exit"] == 0 and
                                 result.get("documentationDryRun", {}).get("exit") == 0)
        if "dependencyBootstrap" in result:
            result["passed"] &= result["dependencyBootstrap"]["exit"] == 0
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archives", type=Path, default=REPO / "Packaging/MLXLicenses")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    results = check(args.archives, args.output)
    print(json.dumps({"archives": len(results), "passed": sum(item["passed"] for item in results),
                      "results": str(args.output / "results.json")}))
    return 0 if results and all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
