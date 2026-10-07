#!/usr/bin/env python3
"""Local stage bookkeeping; no credentials, release tools or network access."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid


def save(path, state):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".release-state-",
                                         dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024**2), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def image_size(folder):
    # hdiutil's automatic sizing can undercount sparse files. Use logical file
    # lengths, allow per-entry filesystem metadata, then 20% + 256 MiB slack.
    total = 0
    for directory, directories, files in os.walk(folder, followlinks=False):
        total += 8192 * (1 + len(directories) + len(files))
        for name in files:
            entry = Path(directory) / name
            if not entry.is_symlink():
                total += entry.stat().st_size
    return (total * 6 + 4) // 5 + 256 * 1024**2


def safe_path(value):
    path = Path(value).resolve()
    protected = ("/Applications", "/System", "/Library", "/usr", "/bin", "/sbin",
                 "/etc", "/private/etc", "/dev", "/opt", "/var", "/private/var", "/cores", "/Network")
    if any(path == Path(p) or path.is_relative_to(p) for p in protected):
        raise ValueError("输出/暂存/挂载点不能位于应用程序或系统目录：" + str(path))
    if path == Path.home().resolve() or os.path.ismount(path) or path in (Path("/Volumes"), Path("/Users"), Path("/private")):
        raise ValueError("不能使用主目录根或卷根：" + str(path))
    return path


def decision(state, phase, artifact, requested, resubmit):
    """Resume only a completed upload; an early ID is not a resumable upload."""
    if requested:
        requested = str(uuid.UUID(requested))
    receipt_path = state.get(phase + "Receipt")
    if not receipt_path:
        return requested or "submit"
    if not Path(receipt_path).is_file():
        admitted = state.get(phase + "PollingId")
        if admitted:
            admitted = str(uuid.UUID(admitted))
            if requested and requested != admitted:
                raise ValueError("指定编号与已确认的续查编号不匹配")
            # A query-only interruption before its new receipt exists must not
            # turn an admitted completed upload into a new submit.
            return admitted
        if resubmit and not requested:
            return "submit"
        raise ValueError("回执缺失，上传结果不明；检查后用 --resubmit-incomplete，不能猜测原编号可续查")
    receipt = json.loads(Path(receipt_path).read_text())
    if receipt.get("artifact") != str(artifact.resolve()):
        raise ValueError("提交回执不属于当前产物")
    known = str(uuid.UUID(receipt["submissionId"])) if receipt.get("submissionId") else None
    if requested and requested != known:
        raise ValueError("指定编号与当前产物回执不匹配")
    # Accepted is service evidence of completion, even for a query-only run.
    if known and receipt.get("status") == "Accepted":
        return "accepted"
    if receipt.get("status") in ("Invalid", "Rejected"):
        raise ValueError("当前提交已被拒绝；修复产物后开始新的发布暂存")
    if (known and receipt.get("submissionMode") == "explicit-resume" and
            state.get(phase + "PollingId") == known):
        # This ID was previously admitted from a completed-upload receipt or
        # explicitly supplied by the caller as a known completed upload.
        return known
    if receipt.get("uploadComplete") is not True:
        if requested:
            raise ValueError("上传未完成的编号不能续查；必须重新提交")
        if resubmit:
            return "submit"
        raise ValueError("上传未完成或结果不明；检查回执后用 --resubmit-incomplete 重新提交，不能续查旧编号")
    if known is None:
        raise ValueError("完成上传的回执缺少有效编号，不能猜测")
    return known


def main():
    action, *args = sys.argv[1:]
    if action == "safe-path":
        safe_path(args[0])
        return
    if action == "image-size":
        print(str(image_size(Path(args[0]))) + "b")
        return
    if action == "outside-app":
        app = Path(args[0]).resolve()
        if any(Path(value).resolve() == app or Path(value).resolve().is_relative_to(app)
               for value in args[1:]):
            raise ValueError("输出/暂存不能通过目录或链接写进原 App")
        return
    if action == "attach-devices":
        import plistlib
        import re
        entities = plistlib.loads(sys.stdin.buffer.read()).get("system-entities", [])
        devices = [e.get("dev-entry", "") for e in entities]
        # Detach the complete image device, not a mount directory or a slice.
        whole = [d for d in devices if re.fullmatch(r"/dev/disk[0-9]+", d)]
        if not whole:
            raise ValueError("attach 没有返回镜像设备号；保留输出以便人工检查")
        print(whole[0])
        return
    if action == "find-attached-device":
        import plistlib
        import re
        mount, image = map(lambda p: str(Path(p).resolve()), args)
        for attached in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
            if str(Path(attached.get("image-path", "")).resolve()) != image:
                continue
            entities = attached.get("system-entities", [])
            if not any(e.get("mount-point") == mount for e in entities):
                continue
            whole = [e.get("dev-entry", "") for e in entities
                     if re.fullmatch(r"/dev/disk[0-9]+", e.get("dev-entry", ""))]
            if not whole:
                raise ValueError("本次挂载存在但未找到完整设备号")
            print(whole[0])
            return
        return  # No attachment for this exact image AND newly-created mount.
    path = Path(args[0])
    if action == "init":
        if path.exists() or path.is_symlink():
            raise ValueError("暂存状态已存在")
        state = dict(version=1)
        state.update(zip(args[1::2], args[2::2]))
        save(path, state)
        return
    state = json.loads(path.read_text())
    if state.get("version") != 1:
        raise ValueError("不支持的暂存状态版本")
    for field in ("appContainer", "releaseDMG", "stapledDMG", "appReceipt", "dmgReceipt",
                  "appPreviousReceipt", "dmgPreviousReceipt"):
        if state.get(field):
            target = Path(state[field])
            if target.is_symlink() or not target.resolve().is_relative_to(path.parent.resolve()):
                raise ValueError("暂存引用越界或是符号链接：" + field)
    if action == "get":
        print(state.get(args[1], ""))
    elif action == "set":
        state[args[1]] = args[2]
        save(path, state)
    elif action == "prepare-receipt":
        phase, receipt, admitted = args[1:]
        previous = state.get(phase + "Receipt", "")
        if previous and Path(previous).is_file():
            state[phase + "PreviousReceipt"] = previous
        state[phase + "Receipt"] = receipt
        state[phase + "PollingId"] = "" if admitted == "submit" else admitted
        save(path, state)
    elif action == "record-artifact":
        artifact = Path(args[2]).resolve()
        state[args[1]] = str(artifact)
        state[args[1] + "SHA256"] = digest(artifact)
        save(path, state)
    elif action == "verify-artifact":
        artifact = Path(state[args[1]])
        if artifact.is_symlink() or digest(artifact) != state[args[1] + "SHA256"]:
            raise ValueError("暂存产物已改变，拒绝复用原提交：" + str(artifact))
    elif action == "decision":
        print(decision(state, args[1], Path(args[2]), args[3], args[4] == "1"))
    else:
        raise ValueError("unknown action: " + action)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit("发布暂存检查失败：" + str(error))
