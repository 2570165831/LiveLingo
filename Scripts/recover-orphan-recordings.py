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
未知编码不猜；PCM 内部不搜索块标记来猜边界；导出用 "xb" 打开，已存在的文件
不覆盖；输出目录在扫描前固定；源文件只读，处理中源文件变化则本次不算成功。

用法：
  python3 Scripts/recover-orphan-recordings.py            # 只报告，不写文件
  python3 Scripts/recover-orphan-recordings.py --export   # 导出到 --output（默认 ~/Downloads/…）
  python3 Scripts/recover-orphan-recordings.py --export --output /某个目录 --root /另一个容器/Data/tmp
"""
from __future__ import annotations

import argparse
import os
import stat
import struct
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Iterator, NamedTuple

DEFAULT_ROOTS = [
    Path.home() / "Library/Containers/com.jianhongli.LiveLingo/Data/tmp",
    Path.home() / "Library/Containers/com.jianhongli.LiveLingoSandboxTests/Data/tmp",
]

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
    with path.open("rb") as handle:
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
        states = (os.fstat(handle.fileno()), source.stat())
    except OSError as error:
        raise SourceChanged("源文件路径在处理过程中变化") from error
    for state in states:
        current = (state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns, state.st_ctime_ns)
        if not stat.S_ISREG(state.st_mode) or current != expected:
            raise SourceChanged("源文件在处理过程中被改动或替换")


def preserve_incomplete(target: Path, identity: tuple[int, int] | None) -> None:
    """仅改名本次创建的文件；别人替换的目标不动，也不删除失败数据。"""
    if identity is None:
        return
    try:
        current = target.lstat()
        if not stat.S_ISREG(current.st_mode) or (current.st_dev, current.st_ino) != identity:
            print(f"    输出路径已被替换，未改动：{target}", file=sys.stderr)
            return
        # UUID 名称避免与已有失败结果冲突；不复用固定的 .incomplete 名称。
        incomplete = target.with_name(f"{target.name}.{uuid.uuid4().hex}.incomplete")
        if incomplete.exists() or incomplete.is_symlink():
            raise FileExistsError(f"不完整输出路径已存在：{incomplete}")
        target.rename(incomplete)
        print(f"    不完整输出已保留：{incomplete}", file=sys.stderr)
    except OSError as error:
        print(f"    无法改名失败输出，请保留检查：{target}（{error}）", file=sys.stderr)


def export_recording(source: Path, layout: Layout, target: Path) -> int:
    """按块读取源 PCM 原样写出；不覆盖已存在文件，源文件保持只读。"""
    with source.open("rb") as handle:
        require_unchanged_source(source, handle, layout)
        handle.seek(layout.data_offset)
        remaining = layout.usable
        created_identity = None
        try:
            with target.open("xb") as output:  # 已存在即失败，绝不覆盖
                created = os.fstat(output.fileno())
                created_identity = (created.st_dev, created.st_ino)
                output.write(header_bytes(layout.fmt_chunk, remaining))
                while remaining > 0:
                    block = handle.read(min(COPY_BLOCK, remaining))
                    if not block:
                        raise SourceChanged("源文件在读取过程中变短")
                    output.write(block)
                    remaining -= len(block)
            require_unchanged_source(source, handle, layout)
            final_target = target.lstat()
            if not stat.S_ISREG(final_target.st_mode) or (final_target.st_dev, final_target.st_ino) != created_identity:
                raise OSError("输出路径在导出过程中被替换，本次结果不能确认为成功")
        except BaseException:
            preserve_incomplete(target, created_identity)
            raise
    return layout.usable


def candidates(roots: list[Path]) -> Iterator[Path]:
    for root in roots:
        if not root.is_dir():
            continue
        for directory in sorted(root.glob("LiveLingo-Live-*")):
            recording = directory / "recording.wav"
            if recording.is_file():
                yield recording


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, action="append", help="容器 tmp 目录（可重复；默认查两个 LiveLingo 容器）")
    parser.add_argument("--output", type=Path, help="导出目录（默认 ~/Downloads/LiveLingo-未收尾录音-<时间戳>）")
    parser.add_argument("--export", action="store_true", help="真正写出恢复文件（默认只报告）")
    args = parser.parse_args()

    roots = args.root or DEFAULT_ROOTS
    # 输出目录在循环前固定：一次运行只对应一个目录，不会每个文件换一个时间戳。
    output = args.output or (Path.home() / "Downloads" /
                             f"LiveLingo-未收尾录音-{datetime.now():%Y%m%d-%H%M%S}")
    found = restored = skipped = failed = 0
    for recording in candidates(roots):
        found += 1
        try:
            layout = inspect(recording)
        except NotRecoverable as error:
            skipped += 1
            print(f"  跳过 {recording.parent.name}：{error}")
            continue
        except SourceChanged as error:
            skipped += 1
            print(f"  跳过 {recording.parent.name}：{error}")
            continue
        except OSError as error:
            skipped += 1
            print(f"  跳过 {recording.parent.name}：无法读取（{error.strerror or error}）")
            continue
        print(f"  可恢复 {recording.parent.name}")
        print(f"    源: data 块声明 {layout.declared} 字节（应用异常退出，头部没写完）"
              f" → 实际可用 {layout.usable} 字节 ≈ {layout.seconds:.1f} 秒")
        print(f"    格式: {FMT_NAMES.get(layout.fmt_tag, layout.fmt_tag)}"
              f" / {layout.channels} 声道 / {layout.rate} Hz / {layout.bits} bit")
        if not args.export:
            continue
        try:
            output.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            failed += 1
            print(f"    未导出：无法创建输出目录（{error.strerror or error}）")
            continue
        target = output / f"{recording.parent.name}.wav"
        try:
            written = export_recording(recording, layout, target)
        except FileExistsError:
            failed += 1
            print(f"    未导出：{target} 已存在，不覆盖")
            continue
        except SourceChanged as error:
            failed += 1
            print(f"    未导出：源文件在处理过程中变化，结果不可信（{error}）")
            continue
        except OSError as error:
            failed += 1
            print(f"    未导出：写入失败（{error.strerror or error}）")
            continue
        restored += 1
        print(f"    已写出: {target}（{written} 字节，源文件未修改）")

    if found == 0:
        print("没找到未收尾的录音（查过：" + "，".join(str(r) for r in roots) + "）")
        return 0
    print(f"\n共发现 {found} 段，可恢复 {found - skipped} 段"
          + (f"，已导出 {restored} 段" if args.export else "（本次未导出，加 --export 才会写文件）")
          + (f"，{failed} 段未写出" if failed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
