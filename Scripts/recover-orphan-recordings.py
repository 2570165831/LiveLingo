#!/usr/bin/env python3
"""导出 LiveLingo 里“没写完头”的临时录音。

背景：录音过程中应用异常退出（崩溃、被强杀）时，WAV 的 data 块长度会停在 0，
`afinfo` 因此报 0 秒；录音数据其实还在容器 tmp 里，只是没有任何入口能取出它。
这个脚本只在**能确认头部从未收尾**时，按文件实际长度重新封成标准 WAV，
**默认只报告，加 --export 才写出文件，且始终不修改源文件**。

保守判定（必须同时成立，否则一律跳过）：
  * data 之前只有唯一一个完整合法的 fmt 块，紧随其后的 data 块声明长度为 0；
  * RIFF 长度仅接受 0、刚写完 data 块头的长度或 0xffffffff 占位值；
  * data 起点之后不是另一个可识别的块（否则 0 长度是真的，文件结构完整）；
  * data 偏移之后确有成整帧的 PCM/IEEE float 数据。

明确不做的事：data 长度非零一律跳过，不按 EOF 延长；fmt 扩展、A-law/µ-law 等
未知编码不猜；PCM 内部不搜索块标记来猜边界；导出以排他模式创建，已存在的文件
不覆盖；输出目录在扫描前固定；源文件只读，处理中源文件变化则本次不算成功。

隐私边界：必须显式指定 --root；仅检查各根目录下一层 LiveLingo-Live-* 目录的
recording.wav，不递归扫描，也不跟随其中的软链接。导出必须同时给 --export 和
--output，新建目录 0700、文件 0600；已有输出目录必须属于当前用户且权限为 0700。
stdout 默认只写汇总和显式指定的扫描/输出路径，不列会话/课程名或异常正文。
路径本身仍可能敏感；只有 --include-sensitive-diagnostics 才向 stdout/stderr
写会话名、逐文件路径和异常诊断。导出文件名保留会话名，录音和文件名需在分享前
自行检查；私有权限不会阻止当前用户的同步程序读取。脚本不写独立日志文件。

退出码：扫描完成且没有导出失败时为 0；扫描中断或任一导出失败时为 1；
参数或导出目录不符合要求时为 2。不可恢复文件的跳过仍计入汇总，不视为导出失败。

用法：
  python3 Scripts/recover-orphan-recordings.py --root ./recording-input
  python3 Scripts/recover-orphan-recordings.py --root ./recording-input --export --output ./private-export
  python3 Scripts/recover-orphan-recordings.py --root ./recording-input --include-sensitive-diagnostics
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import os
import stat
import struct
import sys
import uuid
from pathlib import Path
from typing import Iterator, NamedTuple

from private_files import BoundDirectory, open_directory, privatize_new, validate_ancestors
from privacy_cli import PrivateArgumentParser as FixedArgumentParser

FMT_NAMES = {1: "PCM 整数", 3: "IEEE float", 6: "A-law", 7: "µ-law", 0xFFFE: "扩展格式"}

# 只用来识别 data 起点之后是否还跟着真正的块；只读一个块头，绝不在 PCM 内搜索。
KNOWN_CHUNK_IDS = frozenset({
    b"LIST", b"JUNK", b"fact", b"bext", b"iXML", b"INFO", b"cue ", b"PAD ", b"id3 ",
    b"smpl", b"axml", b"plst", b"levl", b"slnt", b"wavl", b"regn", b"minf", b"elm1",
    b"ovwf", b"data", b"fmt ",
})
MAX_FMT_CHUNK = 4096
COPY_BLOCK = 1 << 20


class NotRecoverable(Exception):
    """文件结构不是可恢复的未收尾 WAV。"""


class SourceChanged(Exception):
    """源文件在检查或导出过程中被改动，本次结果不算成功。"""


class Layout(NamedTuple):
    """确认过的未收尾录音布局。"""

    fmt_tag: int
    channels: int
    rate: int
    bits: int
    fmt_chunk: bytes
    data_offset: int
    declared: int
    usable: int
    source_size: int
    source_mtime_ns: int
    source_device: int
    source_inode: int
    source_ctime_ns: int

    @property
    def block_align(self) -> int:
        return self.channels * (self.bits // 8)

    @property
    def seconds(self) -> float:
        frame_bytes = self.block_align
        return self.usable / (self.rate * frame_bytes) if self.rate and frame_bytes else 0.0


def parse_fmt(body: bytes) -> tuple[int, int, int, int]:
    """核对 fmt 块；只认确认的 PCM/IEEE float，未知扩展不猜。"""
    if len(body) < 16:
        raise NotRecoverable("fmt 块被截断")
    fmt_tag, channels, rate, _byte_rate, block_align, bits = struct.unpack("<HHIIHH", body[:16])
    if len(body) > 16:
        # 只接受标准的 18 字节 PCM 扩展（cbSize == 0）；其它扩展含义未知。
        if len(body) != 18 or struct.unpack("<H", body[16:18])[0] != 0:
            raise NotRecoverable("fmt 块含未知扩展，不猜测")
    if fmt_tag not in (1, 3):
        raise NotRecoverable("未确认的编码（%s）" % FMT_NAMES.get(fmt_tag, fmt_tag))
    if not 1 <= channels <= 64:
        raise NotRecoverable("声道数无效")
    if rate <= 0:
        raise NotRecoverable("采样率无效")
    if bits % 8 or (fmt_tag == 1 and bits not in (8, 16, 24, 32)) or (fmt_tag == 3 and bits not in (32, 64)):
        raise NotRecoverable("位深无效")
    if block_align != channels * (bits // 8):
        raise NotRecoverable("块对齐与声道数/位深不一致")
    return fmt_tag, channels, rate, bits


def follows_chunk_chain(handle, offset: int, size: int) -> bool:
    """data 起点之后是否紧接着另一个可识别块？

    零长度的 data 后面若真的还有 LIST/JUNK 等完整块，说明文件结构本来就是完整的，
    0 长度是真的没有音频。这里只读 data 起点的一个块头，不在 PCM 内部搜索块标记。
    """
    if offset + 8 > size:
        return False
    handle.seek(offset)
    chunk_header = handle.read(8)
    if len(chunk_header) < 8 or chunk_header[:4] not in KNOWN_CHUNK_IDS:
        return False
    chunk_size = struct.unpack("<I", chunk_header[4:])[0]
    return offset + 8 + chunk_size <= size


def inspect(path: Path) -> Layout:
    """解析并确认这是“头部未收尾”的录音；任何不确定都转 NotRecoverable。

    单次打开、按块/按头读取：不反复读取整个文件。
    """
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
        state = os.fstat(handle.fileno())
        if not stat.S_ISREG(state.st_mode):
            raise NotRecoverable("不是普通文件")
        size = state.st_size
        riff_header = handle.read(12)
        if len(riff_header) < 12 or riff_header[:4] != b"RIFF" or riff_header[8:12] != b"WAVE":
            raise NotRecoverable("不是 RIFF/WAVE 文件")
        riff_size = struct.unpack("<I", riff_header[4:8])[0]
        fmt = None
        fmt_chunk = None
        data_offset = None
        declared = None
        position = 12
        while position + 8 <= size:
            handle.seek(position)
            chunk_header = handle.read(8)
            if len(chunk_header) < 8:
                raise NotRecoverable("块头被截断")
            chunk_id = chunk_header[:4]
            chunk_size = struct.unpack("<I", chunk_header[4:])[0]
            if chunk_id == b"fmt ":
                if fmt_chunk is not None:
                    raise NotRecoverable("出现多个 fmt 块")
                if not 16 <= chunk_size <= MAX_FMT_CHUNK:
                    raise NotRecoverable("fmt 块长度不合法")
                if position + 8 + chunk_size > size:
                    raise NotRecoverable("fmt 块被截断")
                body = handle.read(chunk_size)
                if len(body) != chunk_size:
                    raise NotRecoverable("fmt 块被截断")
                fmt = parse_fmt(body)
                fmt_chunk = body
            elif chunk_id == b"data":
                if fmt is None or fmt_chunk is None:
                    raise NotRecoverable("data 块出现在 fmt 之前")
                data_offset = position + 8
                declared = chunk_size
                break
            else:
                # data 之前出现别的块，就没有“未收尾”的依据，交给人工判断。
                name = chunk_id.decode("latin-1", "replace")
                raise NotRecoverable(f"data 之前存在其它块（{name}），无法确认未收尾")
            position += 8 + chunk_size + (chunk_size & 1)
        else:
            raise NotRecoverable("没有找到完整的 fmt/data 块")
        if fmt is None or fmt_chunk is None:
            raise NotRecoverable("没有找到完整的 fmt 块")
        if declared != 0:
            raise NotRecoverable("data 块声明长度非 0，不按文件实际长度延长")
        if riff_size + 8 == size:
            raise NotRecoverable("RIFF 头已收尾，data 声明 0 表示确实没有音频")
        if riff_size not in (0, data_offset - 8, 0xFFFFFFFF):
            raise NotRecoverable("RIFF 长度不是已知占位值，无法确认未收尾")
        if follows_chunk_chain(handle, data_offset, size):
            raise NotRecoverable("data 之后还有完整块，文件结构并非未收尾")
        block_align = fmt[1] * (fmt[3] // 8)
        usable = ((size - data_offset) // block_align) * block_align
        if usable <= 0:
            raise NotRecoverable("data 块没有成整帧的音频数据")
        layout = Layout(fmt[0], fmt[1], fmt[2], fmt[3], fmt_chunk, data_offset, declared, usable,
                        state.st_size, state.st_mtime_ns, state.st_dev, state.st_ino, state.st_ctime_ns)
        require_unchanged_source(path, handle, layout)
        return layout


def header_bytes(fmt_chunk: bytes, data_bytes: int) -> bytes:
    """用完整的 fmt 块原样重封 WAV 头；不重建、不猜测扩展。"""
    riff_size = 4 + 8 + len(fmt_chunk) + 8 + data_bytes
    return (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt_chunk)) + fmt_chunk
            + b"data" + struct.pack("<I", data_bytes))


def require_unchanged_source(source: Path, handle, layout: Layout) -> None:
    """句柄和当前路径都必须仍指向检查时的同一普通文件。"""
    expected = (layout.source_device, layout.source_inode, layout.source_size,
                layout.source_mtime_ns, layout.source_ctime_ns)
    try:
        states = (os.fstat(handle.fileno()), source.lstat())
    except OSError as error:
        raise SourceChanged("源文件路径在处理过程中变化") from error
    for state in states:
        current = (state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns, state.st_ctime_ns)
        if not stat.S_ISREG(state.st_mode) or current != expected:
            raise SourceChanged("源文件在处理过程中被改动或替换")


def preserve_incomplete(target: Path, identity: tuple[int, int] | None, *,
                        include_sensitive_diagnostics: bool = False,
                        directory: BoundDirectory | None = None) -> None:
    """仅改名本次创建的文件；别人替换的目标不动，也不删除失败数据。"""
    if identity is None:
        return
    try:
        current = (target.lstat() if directory is None else
                   os.stat(target.name, dir_fd=directory.fd, follow_symlinks=False))
        if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != identity:
            if include_sensitive_diagnostics:
                print(f"    输出路径已被替换，未改动：{str(target)!r}", file=sys.stderr)
            return
        # UUID 名称避免与已有失败结果冲突；不复用固定的 .incomplete 名称。
        incomplete = target.with_name(f"{target.name}.{uuid.uuid4().hex}.incomplete")
        if directory is None:
            if incomplete.exists() or incomplete.is_symlink():
                raise FileExistsError(f"不完整输出路径已存在：{incomplete}")
            target.rename(incomplete)
        else:
            # Operate on the originally opened output, even when its path moved.
            try:
                os.stat(incomplete.name, dir_fd=directory.fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise FileExistsError("不完整输出名称已存在")
            os.rename(target.name, incomplete.name, src_dir_fd=directory.fd,
                      dst_dir_fd=directory.fd)
        if include_sensitive_diagnostics:
            print(f"    不完整输出已保留：{str(incomplete)!r}", file=sys.stderr)
    except OSError as error:
        if include_sensitive_diagnostics:
            print(f"    无法改名失败输出，请保留检查：{str(target)!r}（{error!s}）", file=sys.stderr)


def export_recording(source: Path, layout: Layout, target: Path, *,
                     include_sensitive_diagnostics: bool = False,
                     directory: BoundDirectory | None = None) -> int:
    """按块读取源 PCM 原样写出；不覆盖已存在文件，源文件保持只读。"""
    target = Path(target).absolute()
    if directory is None:
        with open_directory(target.parent) as bound:
            return export_recording(source, layout, target, directory=bound,
                                    include_sensitive_diagnostics=include_sensitive_diagnostics)
    if target.parent != directory.path:
        raise ValueError("输出路径不属于绑定目录")
    directory.require_bound()
    try:
        os.stat(target.name, dir_fd=directory.fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise FileExistsError("输出路径已存在，不覆盖")
    pending = target.with_name(f"{target.name}.{uuid.uuid4().hex}.pending")
    published = False
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
        require_unchanged_source(source, handle, layout)
        handle.seek(layout.data_offset)
        remaining = layout.usable
        created_identity = None
        try:
            # 以 0600 原子创建；O_EXCL 也拒绝已有软链接，不先创建宽权限文件再收紧。
            directory.require_bound()
            descriptor = os.open(pending.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory.fd)
            with os.fdopen(descriptor, "wb") as output:
                created = os.fstat(output.fileno())
                created_identity = (created.st_dev, created.st_ino)
                privatize_new(output.fileno(), 0o600)
                header = header_bytes(layout.fmt_chunk, remaining)
                output.write(header)
                while remaining > 0:
                    block = handle.read(min(COPY_BLOCK, remaining))
                    if not block:
                        raise SourceChanged("源文件在读取过程中变短")
                    output.write(block)
                    remaining -= len(block)
                output.flush()
                if os.fstat(output.fileno()).st_size != len(header) + layout.usable:
                    raise OSError("输出长度与完整录音不一致")
                os.fsync(output.fileno())
            require_unchanged_source(source, handle, layout)
            directory.require_bound()
            pending_state = os.stat(pending.name, dir_fd=directory.fd, follow_symlinks=False)
            if not stat.S_ISREG(pending_state.st_mode) or (pending_state.st_dev, pending_state.st_ino) != created_identity:
                raise OSError("临时输出路径在导出过程中被替换")
            # Hard-link publication fails atomically if another writer owns the
            # final name. A crash during copying leaves only the pending name.
            os.link(pending.name, target.name, src_dir_fd=directory.fd, dst_dir_fd=directory.fd,
                    follow_symlinks=False)
            published = True
            final_target = os.stat(target.name, dir_fd=directory.fd, follow_symlinks=False)
            if not stat.S_ISREG(final_target.st_mode) or (final_target.st_dev, final_target.st_ino) != created_identity:
                raise OSError("输出路径在发布过程中被替换")
            pending_state = os.stat(pending.name, dir_fd=directory.fd, follow_symlinks=False)
            if not stat.S_ISREG(pending_state.st_mode) or (pending_state.st_dev, pending_state.st_ino) != created_identity:
                raise OSError("临时输出路径在发布过程中被替换")
            os.unlink(pending.name, dir_fd=directory.fd)  # 完整数据仍在 target。
            os.fsync(directory.fd)
            require_unchanged_source(source, handle, layout)
            directory.require_bound()
            final_target = os.stat(target.name, dir_fd=directory.fd, follow_symlinks=False)
            if not stat.S_ISREG(final_target.st_mode) or (final_target.st_dev, final_target.st_ino) != created_identity:
                raise OSError("输出路径在导出过程中被替换，本次结果不能确认为成功")
        except BaseException:
            preserve_incomplete(target if published else pending, created_identity,
                                include_sensitive_diagnostics=include_sensitive_diagnostics,
                                directory=directory)
            raise
    return layout.usable


def candidates(roots: list[Path]) -> Iterator[Path]:
    for root in roots:
        if root.is_symlink() or not root.is_dir():
            continue
        for directory in sorted(root.glob("LiveLingo-Live-*")):
            if directory.is_symlink() or not directory.is_dir() or directory.resolve().parent != root.resolve():
                continue
            recording = directory / "recording.wav"
            if not recording.is_symlink() and recording.is_file() and recording.resolve().parent == directory.resolve():
                yield recording


def prepare_output_directory(output: Path) -> BoundDirectory:
    """只创建缺失目录；已有目录不改权限、不覆盖，也不接受软链接作为输出。"""
    return open_directory(output, create=True, private=True)


class PrivateArgumentParser(FixedArgumentParser):
    def error(self, message: str) -> None:
        # argparse 的原始错误可能带上用户误传的正文；只给固定的参数提示。
        argparse.ArgumentParser.error(self, "invalid_arguments; use --help for usage. "
                                      "参数无效：必须显式指定 --root；导出还需 --export 和 --output。"
                                      "请用 --help 查看用法。")


def main(argv: list[str] | None = None) -> int:
    with ExitStack() as directories:
        return _main(argv, directories)


def _main(argv: list[str] | None, directories: ExitStack) -> int:
    parser = PrivateArgumentParser(prog="recover-orphan-recordings.py", description=__doc__,
                                   formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, action="append", required=True,
                        help="必须显式指定扫描根目录，可重复；没有默认容器")
    parser.add_argument("--output", type=Path, help="--export 时必须显式指定的私有导出目录")
    parser.add_argument("--export", action="store_true", help="真正写出恢复文件（默认只报告）")
    parser.add_argument("--include-sensitive-diagnostics", action="store_true",
                        help="显式允许 stdout/stderr 输出会话/课程名、逐文件路径及异常正文；分享前检查")
    args = parser.parse_args(argv)
    if args.export and args.output is None:
        parser.error("--export 必须同时显式指定 --output")
    try:
        roots = []
        for root in args.root:
            checked = validate_ancestors(root)
            if checked.resolve() != checked:
                raise ValueError("扫描目录在祖先校验后被重定向")
            roots.append(checked)
        # 不解析输出末级软链接；prepare_output_directory 会拒绝它，避免改动其目标。
        output = validate_ancestors(args.output) if args.output is not None else None
        root_bindings = []
        for root in roots:
            try:
                bound = directories.enter_context(open_directory(root))
            except FileNotFoundError:
                continue
            root_bindings.append(bound)
    except Exception as error:
        print("无法解析显式指定的目录；未开始扫描。", file=sys.stderr)
        if args.include_sensitive_diagnostics:
            print(f"    诊断：{error!s}", file=sys.stderr)
        return 2

    print("stdout 默认仅含汇总和显式指定的目录路径；不列会话/课程名或异常正文。"
          "路径本身也可能敏感，分享前检查；不写独立日志文件。")
    print("扫描范围（不递归、不跟随子项软链接）：" + "，".join(repr(str(root)) for root in roots)
          + "；仅 LiveLingo-Live-*/recording.wav")
    if args.include_sensitive_diagnostics:
        print("已显式开启敏感诊断：stdout/stderr 会包含会话名、文件路径和异常正文。")
    if args.export:
        print(f"导出位置：{str(output)!r}；目录 0700，文件 0600。"
              "文件名保留会话名，录音与失败输出可能敏感；源文件不修改，已有输出不覆盖。")
        try:
            output_binding = directories.enter_context(prepare_output_directory(output))
        except Exception as error:
            print("未导出：无法准备私有输出目录；需当前用户拥有、非软链接且权限为 0700 的目录。"
                  "未开始扫描；已有目录不会被改权限。", file=sys.stderr)
            if args.include_sensitive_diagnostics:
                print(f"    诊断：{error!s}", file=sys.stderr)
            return 2
    else:
        print("输出位置：无（本次只报告，未导出录音）。")

    found = restored = skipped = failed = existing = 0
    scan_failed = False
    try:
        for bound in root_bindings:
            bound.require_bound()
        for recording in candidates(roots):
            for bound in root_bindings:
                bound.require_bound()
            found += 1
            try:
                layout = inspect(recording)
            except Exception as error:
                skipped += 1
                if args.include_sensitive_diagnostics:
                    print(f"  跳过 {recording.parent.name!r}：{error!s}")
                continue
            if args.include_sensitive_diagnostics:
                print(f"  可恢复 {recording.parent.name!r}：{layout.usable} 字节 ≈ {layout.seconds:.1f} 秒；"
                      f"{FMT_NAMES.get(layout.fmt_tag, layout.fmt_tag)} / {layout.channels} 声道"
                      f" / {layout.rate} Hz / {layout.bits} bit")
            if not args.export:
                continue
            target = output / f"{recording.parent.name}.wav"
            try:
                written = export_recording(recording, layout, target,
                                           include_sensitive_diagnostics=args.include_sensitive_diagnostics,
                                           directory=output_binding)
            except Exception as error:
                failed += 1
                existing += isinstance(error, FileExistsError)
                if args.include_sensitive_diagnostics:
                    print(f"    未导出 {str(target)!r}：{error!s}")
                continue
            restored += 1
            if args.include_sensitive_diagnostics:
                print(f"    已写出: {str(target)!r}（{written} 字节，源文件未修改）")
        for bound in root_bindings:
            bound.require_bound()
    except Exception as error:
        scan_failed = True
        print("扫描未完成：无法枚举指定根目录；汇总仅包含已检查项目。", file=sys.stderr)
        if args.include_sensitive_diagnostics:
            print(f"    诊断：{error!s}", file=sys.stderr)

    if found == 0:
        print("没找到符合扫描模式的录音。")
    print(f"共发现 {found} 段，可恢复 {found - skipped} 段，跳过 {skipped} 段"
          + (f"，已导出 {restored} 段，{failed} 段未写出，已有输出不覆盖：{existing} 段"
             if args.export else "（本次未导出，加 --export 并指定 --output 才会写文件）"))
    if failed:
        print("失败输出可能以 .incomplete 后缀保留在导出目录；输出被他人替换时不移动。")
    return 1 if scan_failed or (args.export and failed > 0) else 0


if __name__ == "__main__":
    sys.exit(main())
