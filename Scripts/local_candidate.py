"""Resume local candidate production without notarization or application launch."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parent.parent
CONTRACTS = ("Packaging/MLXRuntime.lock.json", "Packaging/ASRRuntime.lock.json",
             "Packaging/PrivacyResources.json", "Scripts/runtime_prepare.py",
             "Scripts/runtime_configuration.py", "Scripts/native_build_paths.py",
             "Scripts/macho_paths.py", "Scripts/notice_copy.py", "Scripts/prepare-model-inputs.py",
             "Scripts/model_prepare.py", "Scripts/model_files.py", "Packaging/MLXLicenses")
STAGES = ("build", "assemble", "clone", "sign", "verify-only", "strict",
          "assessment", "dmg", "dmg-verify")


def sha(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def exact(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or path.resolve() != path or path.is_symlink():
        raise ValueError("use an exact absolute path without symlink ancestors")
    if path in (Path("/"), Path.home()) or len(path.parts) < 3:
        raise ValueError("refusing broad root")
    return path


def fingerprint(root):
    root = exact(root)
    if root.is_file():
        return {"sha256": sha(root), "bytes": root.stat().st_size,
                "mode": stat.S_IMODE(root.stat().st_mode)}
    if not root.is_dir():
        raise ValueError("artifact missing")
    device = root.stat().st_dev
    rows = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            info = path.lstat()
            if info.st_dev != device:
                raise ValueError("mounted volume inside artifact; detach the exact owned image first")
            row = {"path": path.relative_to(root).as_posix(), "mode": stat.S_IMODE(info.st_mode)}
            if stat.S_ISLNK(info.st_mode):
                row.update(type="link", target=os.readlink(path))
            elif stat.S_ISREG(info.st_mode):
                row.update(type="file", bytes=info.st_size, sha256=sha(path))
            elif stat.S_ISDIR(info.st_mode):
                row.update(type="directory")
            else:
                raise ValueError("special file in candidate input")
            rows.append(row)
    rows.sort(key=lambda row: row["path"])
    encoded = json.dumps({"rootMode": stat.S_IMODE(root.stat().st_mode), "entries": rows},
                         sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "entries": len(rows),
            "bytes": sum(row.get("bytes", 0) for row in rows)}


def contract_hashes():
    return {name: fingerprint(REPO / name) if (REPO / name).is_dir() else sha(REPO / name)
            for name in CONTRACTS}


def write_json(path, value):
    temporary = path.with_name(path.name + ".pending-" + str(time.time_ns()))
    with temporary.open("x") as stream:
        json.dump(value, stream, indent=2); stream.write("\n")
    temporary.replace(path)


def check_inputs(receipt):
    if receipt.get("schema") != 1 or receipt["contracts"] != contract_hashes():
        raise ValueError("preparation policy/lock changed: prepare and review inputs again")
    for entry in receipt["inputs"].values():
        if fingerprint(entry["path"]) != entry["fingerprint"]:
            raise ValueError("prepared input changed: do not automatically renew its receipt")


def disjoint_outputs(outputs, inputs):
    def overlaps(left, right):
        return left == right or left.is_relative_to(right) or right.is_relative_to(left)
    if any(overlaps(left, right) for index, left in enumerate(outputs) for right in outputs[index + 1:]):
        raise ValueError("artifact, record and DerivedData roots must be disjoint")
    if any(overlaps(output, source) for output in outputs for source in inputs):
        raise ValueError("outputs must never contain or overwrite prepared inputs")


def pulse(parent):
    rows = {}
    for line in subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,time=,comm="], text=True).splitlines():
        values = line.split(None, 3)
        if len(values) == 4:
            rows[int(values[0])] = (int(values[1]), values[2], values[3])
    descendants = {parent}
    while True:
        new = descendants | {pid for pid, row in rows.items() if row[0] in descendants}
        if new == descendants:
            break
        descendants = new
    return (tuple(sorted((pid, rows[pid][1]) for pid in descendants if pid in rows)),
            {pid for pid, row in rows.items() if "SecurityAgent" in row[2]})


def wait_free(gate, deadline=None):
    while subprocess.run([str(gate), "0"], stdout=subprocess.DEVNULL).returncode:
        if deadline is not None and time.time() >= deadline:
            raise TimeoutError("deadline while waiting for installed application")
        print("Installed application busy; waiting 120 seconds.", flush=True)
        time.sleep(120)


def signal_other_descendants(parent, signum):
    # Some build/test tools create a new session. Signal only a fresh descendant
    # inventory, never unrelated processes or system signing/mount daemons.
    descendants, _agents = pulse(parent)
    for pid, _cpu in reversed(descendants):
        try:
            if os.getpgid(pid) != parent:
                os.kill(pid, signum)
        except ProcessLookupError:
            pass


def execute(command, log, gate, env, *, stall_seconds=900, deadline=None, before_start=None):
    """Only own process group is paused/stopped. No UI or keychain changes."""
    started = time.monotonic()
    wait_free(gate, deadline)
    if deadline is not None and time.time() >= deadline:
        raise TimeoutError("candidate deadline reached before command")
    if before_start is not None:
        before_start()
    waited = time.monotonic() - started
    baseline_agents = pulse(-1)[1]
    with log.open("x") as stream:
        child = subprocess.Popen(command, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
                                 stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        before = None; progress = time.monotonic(); next_gate = progress + 120; paused = False
        try:
            while child.poll() is None:
                process_pulse, agents = pulse(child.pid)
                current = (process_pulse, log.stat().st_size)
                if deadline is not None and time.time() >= deadline:
                    raise TimeoutError("candidate deadline reached")
                if agents - baseline_agents:
                    raise RuntimeError("SecurityAgent appeared; stopped without interacting")
                if current != before:
                    before = current; progress = time.monotonic()
                if paused:
                    progress = time.monotonic()
                if time.monotonic() - progress >= stall_seconds:
                    raise RuntimeError("15 minutes without process/CPU progress")
                if time.monotonic() >= next_gate:
                    busy = subprocess.run([str(gate), "0"], stdout=subprocess.DEVNULL).returncode != 0
                    if busy != paused:
                        os.killpg(child.pid, signal.SIGSTOP if busy else signal.SIGCONT)
                        signal_other_descendants(child.pid, signal.SIGSTOP if busy else signal.SIGCONT)
                        paused = busy; progress = time.monotonic()
                    next_gate = time.monotonic() + 120
                time.sleep(2)
        except BaseException:
            if child.poll() is None:
                signal_other_descendants(child.pid, signal.SIGCONT)
                signal_other_descendants(child.pid, signal.SIGTERM)
                os.killpg(child.pid, signal.SIGCONT); os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
            raise
    return {"exitCode": child.returncode, "wallSeconds": round(time.monotonic() - started, 3),
            "initialWaitSeconds": round(waited, 3), "command": command, "log": str(log)}


def quarantine(path, records):
    path = exact(path)
    if not path.exists():
        return
    holders = subprocess.run(["/usr/sbin/lsof", "-t", *(["+D"] if path.is_dir() else []), str(path)], capture_output=True, text=True)
    if holders.returncode not in (0, 1) or holders.stdout.strip() or holders.stderr.strip():
        raise ValueError("cannot quarantine an active or uninspectable attempt")
    before = fingerprint(path)
    trash = path.parent / "to-trash"; trash.mkdir(exist_ok=True)
    target = trash / (path.name + "-" + str(time.time_ns()))
    if path.stat().st_dev != trash.stat().st_dev:
        raise ValueError("quarantine must stay on the same volume")
    receipt = {"source": str(path), "destination": str(target), "fingerprint": before, "restorable": True}
    with (records / "quarantine.jsonl").open("a") as stream:
        stream.write(json.dumps({**receipt, "phase": "planned"}) + "\n")
    path.rename(target)
    if fingerprint(target) != before:
        raise ValueError("quarantine verification failed")
    with (records / "quarantine.jsonl").open("a") as stream:
        stream.write(json.dumps({**receipt, "phase": "completed"}) + "\n")


def plan(args, inputs):
    work = Path(args.work); records = Path(args.records); dd = Path(args.derived_data)
    bare = dd / "Build/Products/Release/LiveLingo.app"
    unsigned = work / "unsigned/LiveLingo.app"; signed = work / "signed/LiveLingo.app"
    dmg = work / "dmg/LiveLingo-candidate.dmg"; scripts = REPO / "Scripts"
    host = [args.python, "-B"]
    command = {
        "build": ["/bin/bash", str(scripts / "build-release.sh")],
        "assemble": host + [str(scripts / "bundle-mlx-app.py"), "--app", str(bare),
                             "--runtime", inputs["language"]["path"], "--asr-python", inputs["asr"]["path"],
                             "--models", inputs["models"]["path"], "--asr-models", inputs["models"]["path"],
                             "--output", str(unsigned)],
        "clone": ["/bin/cp", "-cR", str(unsigned), str(signed)],
        "sign": host + [str(scripts / "sign-offline-app.py"), "--app", str(signed),
                         "--identity", args.identity, "--certificate", args.certificate,
                         "--keychain", args.keychain, "--review-capture", str(records / "signing-run/before-signing.json")],
        "verify-only": host + [str(scripts / "sign-offline-app.py"), "--verify-only", "--app", str(signed), "--identity", args.identity],
        "strict": ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(signed)],
        "assessment": ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(signed)],
        "dmg": ["/bin/zsh", str(scripts / "build-offline-dmg.sh"), "--candidate-only", "--app", str(signed),
                "--output", str(dmg), "--identity", args.identity, "--keychain", args.keychain,
                "--image-method", "hybrid", "--mount-point", str(records / "build-verify-mount"),
                "--xattr-report", str(records / "created-image-metadata.json")],
        "dmg-verify": ["/bin/zsh", str(scripts / "verify-release-dmg.sh"), "--candidate-only", "--dmg", str(dmg),
                       "--identity", args.identity, "--mount-point", str(records / "verify-mount"),
                       "--xattr-report", str(records / "final-image-metadata.json")],
    }
    artifacts = {"build": bare, "assemble": unsigned, "clone": signed, "sign": signed, "dmg": dmg}
    return command, artifacts


def reusable(completed, artifacts):
    """Validate only the most recent completed writer of each artifact."""
    last = {}
    for stage in STAGES:
        if stage in completed and stage in artifacts:
            last[str(artifacts[stage])] = stage
    for path, stage in last.items():
        if fingerprint(path) != completed[stage]["artifact"]:
            raise ValueError("completed artifact changed: refusing resume")


def main(argv=None):
    def interrupted(signum, frame):
        raise KeyboardInterrupt("stop requested")
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    capture = sub.add_parser("capture-inputs")
    for name in ("language", "asr", "models", "output"):
        capture.add_argument("--" + name, required=True)
    run = sub.add_parser("run")
    for name in ("commit", "work", "records", "derived-data", "inputs-receipt", "machine-free", "identity", "certificate", "keychain", "expected-version"):
        run.add_argument("--" + name, required=True)
    run.add_argument("--python", default=sys.executable)
    run.add_argument("--deadline", help="optional ISO timestamp with timezone")
    args = parser.parse_args(argv)
    if args.mode == "capture-inputs":
        destination = exact(args.output)
        if destination.exists():
            raise ValueError("input receipt already exists")
        value = {"schema": 1, "contracts": contract_hashes(), "inputs": {name: {
            "path": str(exact(getattr(args, name))), "fingerprint": fingerprint(getattr(args, name))}
            for name in ("language", "asr", "models")}}
        with destination.open("x") as stream:
            json.dump(value, stream, indent=2); stream.write("\n")
        return 0
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.commit):
        raise ValueError("provide the exact 40-character final source commit")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    requested = subprocess.check_output(["git", "rev-parse", args.commit + "^{commit}"], cwd=REPO, text=True).strip()
    if head != requested or subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True).strip():
        raise ValueError("checkout must be clean at the requested final commit")
    def unchanged_source():
        if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip() != head or \
                subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True).strip():
            raise ValueError("source changed during candidate production")
    args.python = str(Path(args.python).resolve(strict=True))
    if args.python != str(Path(sys.executable).resolve()):
        raise ValueError("run this tool with the selected host interpreter")
    for name in ("work", "records", "derived_data", "inputs_receipt", "machine_free", "certificate", "keychain", "python"):
        exact(getattr(args, name))
    if any(part in ("LanguageRuntime", "ASRRuntime") for part in Path(args.python).parts) or ".app" in args.python and "Python.framework" not in args.python:
        raise ValueError("select a host interpreter")
    if not args.identity.startswith("Developer ID Application: "):
        raise ValueError("Developer ID identity required")
    work = Path(args.work); records = Path(args.records)
    receipt = json.loads(Path(args.inputs_receipt).read_text())
    disjoint_outputs([work, records, Path(args.derived_data)],
                     [exact(entry["path"]) for entry in receipt["inputs"].values()] + [REPO])
    if records.exists() and not (records / "state.json").exists() and any(
            path.name != ".local-candidate.lock" for path in records.iterdir()):
        raise ValueError("new host-record root must be empty")
    records.mkdir(mode=0o700, parents=True, exist_ok=True); work.mkdir(parents=True, exist_ok=True)
    with (records / ".local-candidate.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deadline = datetime.datetime.fromisoformat(args.deadline).timestamp() if args.deadline else None
        if args.deadline and datetime.datetime.fromisoformat(args.deadline).tzinfo is None:
            raise ValueError("deadline must include timezone")
        wait_free(Path(args.machine_free), deadline)
        check_inputs(receipt)
        config = {**{key: value for key, value in vars(args).items() if key != "deadline"},
                  "commit": head, "inputsReceiptSHA256": sha(args.inputs_receipt)}
        state_file = records / "state.json"
        if state_file.exists():
            state = json.loads(state_file.read_text())
            if state["config"] != config:
                raise ValueError("resume configuration changed; choose a fresh run")
        else:
            if any(work.iterdir()):
                raise ValueError("new run artifact root must be empty")
            state = {"config": config, "completed": {}, "running": None}
        commands, artifacts = plan(args, receipt["inputs"])
        previous = state["running"]
        if previous == "sign":
            quarantine(work / "signed", records); quarantine(records / "signing-run", records)
            state["completed"].pop("clone", None)
        elif previous in ("assemble", "clone", "dmg"):
            quarantine(work / {"assemble": "unsigned", "clone": "signed", "dmg": "dmg"}[previous], records)
        if previous in ("dmg", "dmg-verify"):
            quarantine(records / ("created-image-metadata.json" if previous == "dmg" else "final-image-metadata.json"), records)
        reusable(state["completed"], artifacts)
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", LIVELINGO_PYTHON=args.python,
                   LIVELINGO_DERIVED_DATA_PATH=args.derived_data, LIVELINGO_OFFLINE_OUTPUT_DIR=str(work / "dmg"))
        for name in ("LIVELINGO_SIGN_IDENTITY", "LIVELINGO_CERTIFICATE_PATH", "LIVELINGO_KEYCHAIN_PATH", "LIVELINGO_TEST_TOOL_DIR", "LIVELINGO_NOTARY_PROFILE", "LIVELINGO_NOTARY_KEYCHAIN"):
            env.pop(name, None)
        for stage in STAGES:
            if stage in state["completed"]:
                continue
            state["running"] = stage; write_json(state_file, state)
            if stage == "clone":
                (work / "signed").mkdir()
            if stage == "sign":
                (records / "signing-run").mkdir(mode=0o700)
            log = records / (stage + "-" + str(time.time_ns()) + ".log")
            started = time.monotonic()
            try:
                result = execute(commands[stage], log, Path(args.machine_free), env, deadline=deadline,
                                 before_start=unchanged_source)
                unchanged_source()
            except BaseException as error:
                with (records / "failed-attempts.jsonl").open("a") as stream:
                    stream.write(json.dumps({"stage": stage, "wallSeconds": time.monotonic() - started,
                                             "error": str(error), "log": str(log)}) + "\n")
                raise
            if result["exitCode"] and stage != "assessment":
                with (records / "failed-attempts.jsonl").open("a") as stream:
                    stream.write(json.dumps({"stage": stage, **result}) + "\n")
                raise RuntimeError("stage failed: " + stage + "; inspect its log before retry")
            if stage == "build":
                version = plistlib.loads((artifacts[stage] / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
                if version != args.expected_version:
                    raise ValueError("Release version does not match the requested final version")
            if stage in artifacts:
                result["artifact"] = fingerprint(artifacts[stage])
            state["completed"][stage] = result; state["running"] = None; write_json(state_file, state)
            print(stage + " completed in " + str(result["wallSeconds"]) + " seconds", flush=True)
        handoff = {"sourceCommit": head, "version": args.expected_version,
                   "signedApp": str(artifacts["sign"]), "signedAppFingerprint": fingerprint(artifacts["sign"]),
                   "dmg": str(artifacts["dmg"]), "dmgFingerprint": fingerprint(artifacts["dmg"]),
                   "inputsReceipt": str(Path(args.inputs_receipt)), "inputsReceiptSHA256": sha(args.inputs_receipt),
                   "notarization": "not performed; delegated to the release owner",
                   "vmValidation": "not performed by this runner; attach the VM owner's evidence before release handoff"}
        write_json(records / "handoff.json", handoff)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
