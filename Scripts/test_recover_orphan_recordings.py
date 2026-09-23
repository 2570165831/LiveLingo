#!/usr/bin/env python3
"""recover-orphan-recordings.py 的回归测试。

对应场景：应用异常退出时 WAV 的 data 块长度会停在 0（afinfo 报 0 秒），
音频数据其实完整。脚本只在能确认“头部没写完”时按文件实际长度重新封装，
必须**不修改源文件**、**不覆盖已有输出**，遇到结构可疑的文件一律跳过。

全部数据都是合成字节，只在测试自己的 TemporaryDirectory 里读写。
"""
import os
import contextlib
import io
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib import import_module

recover = import_module("recover-orphan-recordings")


def fmt_chunk(fmt_tag: int = 1, channels: int = 1, rate: int = 48_000, bits: int = 16,
              extension: bytes = b"", block_align: int | None = None) -> bytes:
    width = bits // 8
    align = channels * width if block_align is None else block_align
    body = struct.pack("<HHIIHH", fmt_tag, channels, rate, rate * channels * width,
                       align, bits) + extension
    return b"fmt " + struct.pack("<I", len(body)) + body


def pcm_bytes(frames: int, channels: int = 1) -> bytes:
    return b"".join(struct.pack("<h", (i * 37) % 2000 - 1000) for i in range(frames * channels))


def wav_file(fmt: bytes, declared: int, audio: bytes, riff_size: int | None = None,
             before_data: bytes = b"", after_data: bytes = b"") -> bytes:
    body = fmt + before_data + b"data" + struct.pack("<I", declared) + audio + after_data
    if riff_size is None:
        riff_size = 4 + len(body)          # RIFF 已按真实长度收尾
    return b"RIFF" + struct.pack("<I", riff_size) + b"WAVE" + body


def orphan_wav(audio: bytes, fmt: bytes | None = None, **kwargs) -> bytes:
    """应用异常退出时留下的形态：data 声明 0，RIFF 头停在初始占位值。"""
    fmt = fmt_chunk() if fmt is None else fmt
    return wav_file(fmt, 0, audio, riff_size=4 + len(fmt) + 8, **kwargs)


class RecoverOrphanRecordingsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory(prefix="LiveLingo-recover-test.")
        self.addCleanup(self._temporary.cleanup)
        self.directory = Path(self._temporary.name)

    def container(self, name: str = "LiveLingo-Live-TEST") -> Path:
        root = self.directory / "tmp"
        (root / name).mkdir(parents=True, exist_ok=True)
        return root

    def put(self, payload: bytes, name: str = "LiveLingo-Live-TEST") -> Path:
        root = self.container(name)
        path = root / name / "recording.wav"
        path.write_bytes(payload)
        return path

    def script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(Path(recover.__file__)), *args],
            capture_output=True, text=True, check=False,
        )

    # ---- 解析与恢复 ----

    def test_recovers_unfinalized_wav_and_leaves_source_untouched(self) -> None:
        audio = pcm_bytes(4_800)
        source = self.put(orphan_wav(audio))
        before = source.read_bytes()

        layout = recover.inspect(source)

        self.assertEqual(layout.declared, 0, "源文件的 data 块长度应为 0（模拟未收尾）")
        self.assertEqual(layout.usable, len(audio))
        self.assertEqual((layout.channels, layout.rate, layout.bits), (1, 48_000, 16))
        self.assertAlmostEqual(layout.seconds, 0.1, places=3)

        target = self.directory / "out.wav"
        written = recover.export_recording(source, layout, target)
        self.assertEqual(written, len(audio))
        with wave.open(str(target)) as handle:
            self.assertEqual(handle.getnframes(), 4_800, "恢复出的文件应能按真实长度打开")
            self.assertEqual(handle.getframerate(), 48_000)
        self.assertEqual(source.read_bytes(), before, "脚本不得修改源文件")

    def test_export_preserves_a_full_fmt_extension(self) -> None:
        audio = pcm_bytes(240)
        source = self.put(orphan_wav(audio, fmt=fmt_chunk(extension=b"\x00\x00")))
        layout = recover.inspect(source)
        self.assertEqual(len(layout.fmt_chunk), 18, "完整 fmt 块要原样保留")
        target = self.directory / "ext.wav"
        recover.export_recording(source, layout, target)
        written = target.read_bytes()
        self.assertEqual(written[12:16], b"fmt ")
        self.assertEqual(struct.unpack("<I", written[16:20])[0], 18, "导出必须保留完整的 fmt 块")
        with wave.open(str(target)) as handle:
            self.assertEqual(handle.getnframes(), 240)

    def test_unknown_encodings_and_extensions_are_not_guessed(self) -> None:
        audio = pcm_bytes(240)
        cases = {
            "扩展编码 0xFFFE": fmt_chunk(fmt_tag=0xFFFE),
            "A-law": fmt_chunk(fmt_tag=6),
            "µ-law": fmt_chunk(fmt_tag=7),
            "未知 fmt 扩展": fmt_chunk(extension=b"\x01\x00"),
            "块对齐不一致": fmt_chunk(block_align=8),
        }
        for label, fmt in cases.items():
            path = self.put(orphan_wav(audio, fmt=fmt), name="LiveLingo-Live-X")
            with self.assertRaises(recover.NotRecoverable, msg=label):
                recover.inspect(path)

    def test_parse_fmt_rejects_every_short_header_directly(self) -> None:
        body = fmt_chunk()[8:]
        for length in range(16):
            with self.subTest(length=length), self.assertRaises(recover.NotRecoverable):
                recover.parse_fmt(body[:length])

    def test_normal_file_is_reported_as_not_needing_recovery(self) -> None:
        audio = pcm_bytes(1_000)
        source = self.put(wav_file(fmt_chunk(), len(audio), audio))
        with self.assertRaises(recover.NotRecoverable):
            recover.inspect(source)

    def test_finalized_file_with_trailing_list_chunk_is_not_recovered(self) -> None:
        audio = pcm_bytes(1_000)
        listing = b"LIST" + struct.pack("<I", 12) + b"INFOIART" + struct.pack("<I", 0)
        source = self.put(wav_file(fmt_chunk(), len(audio), audio, after_data=listing))
        with self.assertRaises(recover.NotRecoverable):
            recover.inspect(source)

    def test_complete_riff_with_zero_data_is_not_recovered(self) -> None:
        audio = pcm_bytes(600)
        # RIFF 头与文件长度一致，data 声明 0：结构本来就完整，确实没有音频。
        source = self.put(wav_file(fmt_chunk(), 0, audio))
        with self.assertRaises(recover.NotRecoverable) as error:
            recover.inspect(source)
        self.assertIn("已收尾", str(error.exception))

    def test_only_known_riff_placeholders_are_accepted(self) -> None:
        audio = pcm_bytes(600)
        header_end = 4 + len(fmt_chunk()) + 8
        for riff_size in (0, header_end, 0xFFFFFFFF):
            with self.subTest(accepted=riff_size):
                source = self.put(wav_file(fmt_chunk(), 0, audio, riff_size=riff_size))
                self.assertEqual(recover.inspect(source).usable, len(audio))
        for riff_size in (1, header_end - 1, header_end + 2, header_end + len(audio) + 2):
            with self.subTest(rejected=riff_size):
                source = self.put(wav_file(fmt_chunk(), 0, audio, riff_size=riff_size))
                with self.assertRaisesRegex(recover.NotRecoverable, "不是已知占位值"):
                    recover.inspect(source)

    def test_zero_data_followed_by_a_real_chunk_chain_is_not_recovered(self) -> None:
        # data 声明 0，紧随其后就是一个完整的 LIST 块：那 0 长度是真的，
        # 绝不能把后面的元数据当成 PCM 恢复出来。
        payload = b"INFOIART" + struct.pack("<I", 4) + b"meta"
        listing = b"LIST" + struct.pack("<I", len(payload)) + payload
        source = self.put(orphan_wav(b"", after_data=listing))
        with self.assertRaises(recover.NotRecoverable) as error:
            recover.inspect(source)
        self.assertIn("完整块", str(error.exception))

    def test_nonzero_data_size_is_never_extended_to_eof(self) -> None:
        audio = pcm_bytes(1_000)
        for declared in (len(audio) - 200, len(audio) + 500):
            source = self.put(wav_file(fmt_chunk(), declared, audio, riff_size=36))
            with self.assertRaises(recover.NotRecoverable, msg=declared):
                recover.inspect(source)

    def test_other_chunks_before_data_are_skipped(self) -> None:
        audio = pcm_bytes(600)
        junk = b"JUNK" + struct.pack("<I", 4) + b"\x00\x00\x00\x00"
        source = self.put(orphan_wav(audio, before_data=junk))
        with self.assertRaises(recover.NotRecoverable):
            recover.inspect(source)

    def test_pcm_containing_list_bytes_is_recovered_as_one_block(self) -> None:
        audio = bytearray(pcm_bytes(4_800))
        audio[64:72] = b"LIST" + struct.pack("<I", 16)   # PCM 里恰好出现块标记
        source = self.put(orphan_wav(bytes(audio)))
        layout = recover.inspect(source)
        self.assertEqual(layout.usable, len(audio), "不得把 PCM 内部的 LIST 当成边界")

    def test_source_change_is_not_reported_as_success(self) -> None:
        audio = pcm_bytes(2_400)
        source = self.put(orphan_wav(audio))
        layout = recover.inspect(source)
        source.write_bytes(source.read_bytes() + b"\x00\x00")   # 检查之后源文件变了
        target = self.directory / "changed.wav"
        with self.assertRaises(recover.SourceChanged):
            recover.export_recording(source, layout, target)
        self.assertFalse(target.exists(), "失败时不得留下不完整的输出")

    def test_same_size_and_mtime_source_replacement_is_rejected(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        replacement = self.directory / "replacement.wav"
        replacement.write_bytes(source.read_bytes())
        os.utime(replacement, ns=(layout.source_mtime_ns, layout.source_mtime_ns))
        source.rename(self.directory / "original.wav")
        replacement.rename(source)
        target = self.directory / "replaced.wav"
        with self.assertRaises(recover.SourceChanged):
            recover.export_recording(source, layout, target)
        self.assertFalse(target.exists())

    def test_source_device_is_part_of_identity(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "wrong-device.wav"
        with self.assertRaises(recover.SourceChanged):
            recover.export_recording(source, layout._replace(source_device=layout.source_device + 1), target)
        self.assertFalse(target.exists())

    def test_source_changed_during_export_is_preserved_as_incomplete(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "changed-during-export.wav"
        original_header = recover.header_bytes

        def change_source(*args):
            source.write_bytes(source.read_bytes() + b"\x00\x00")
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=change_source):
            with self.assertRaises(recover.SourceChanged):
                recover.export_recording(source, layout, target)
        self.assertFalse(target.exists(), "失败输出不能保留正常导出名称")
        incomplete = list(self.directory.glob("changed-during-export.wav.*.incomplete"))
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(incomplete[0].read_bytes()[:4], b"RIFF", "失败数据应保留供核查")

    def test_source_path_replaced_during_export_is_detected(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "path-replaced.wav"
        replacement = self.directory / "replacement.wav"
        replacement.write_bytes(source.read_bytes())
        os.utime(replacement, ns=(layout.source_mtime_ns, layout.source_mtime_ns))
        original_header = recover.header_bytes

        def replace_source(*args):
            source.rename(self.directory / "original.wav")
            replacement.rename(source)
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=replace_source):
            with self.assertRaises(recover.SourceChanged):
                recover.export_recording(source, layout, target)
        self.assertFalse(target.exists())
        self.assertEqual(len(list(self.directory.glob("path-replaced.wav.*.incomplete"))), 1)

    def test_failure_does_not_move_or_remove_replaced_target(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "replaced-target.wav"
        displaced = self.directory / "owned-output.wav"
        foreign_content = b"another writer's output"
        original_header = recover.header_bytes

        def replace_target_and_change_source(*args):
            target.rename(displaced)
            target.write_bytes(foreign_content)
            source.write_bytes(source.read_bytes() + b"\x00\x00")
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=replace_target_and_change_source):
            with self.assertRaises(recover.SourceChanged):
                recover.export_recording(source, layout, target)
        self.assertEqual(target.read_bytes(), foreign_content)
        self.assertTrue(displaced.exists())
        self.assertEqual(list(self.directory.glob("replaced-target.wav.*.incomplete")), [])

    def test_short_read_preserves_incomplete_output(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "short-read.wav"
        original_header = recover.header_bytes

        def truncate_source(*args):
            source.write_bytes(source.read_bytes()[:layout.data_offset])
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=truncate_source):
            with self.assertRaises(recover.SourceChanged):
                recover.export_recording(source, layout, target)
        self.assertFalse(target.exists())
        self.assertEqual(len(list(self.directory.glob("short-read.wav.*.incomplete"))), 1)

    def test_replaced_target_alone_cannot_be_reported_as_success(self) -> None:
        source = self.put(orphan_wav(pcm_bytes(600)))
        layout = recover.inspect(source)
        target = self.directory / "replaced-target-only.wav"
        displaced = self.directory / "owned-output.wav"
        foreign_content = b"another writer's output"
        original_header = recover.header_bytes

        def replace_target(*args):
            target.rename(displaced)
            target.write_bytes(foreign_content)
            return original_header(*args)

        with patch.object(recover, "header_bytes", side_effect=replace_target):
            with self.assertRaisesRegex(OSError, "输出路径"):
                recover.export_recording(source, layout, target)
        self.assertEqual(target.read_bytes(), foreign_content)
        self.assertTrue(displaced.exists())

    def test_ignores_files_that_are_not_wav(self) -> None:
        source = self.put("这不是音频".encode("utf-8"))
        with self.assertRaises(recover.NotRecoverable):
            recover.inspect(source)

    # ---- 命令行行为 ----

    def test_dry_run_reports_without_writing(self) -> None:
        self.put(orphan_wav(pcm_bytes(2_400)))

        result = self.script("--root", str(self.directory / "tmp"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("可恢复", result.stdout)
        self.assertIn("未导出", result.stdout, "默认必须只报告")
        self.assertFalse((self.directory / "out").exists())

    def test_export_writes_a_readable_file(self) -> None:
        audio = pcm_bytes(2_400)
        source = self.put(orphan_wav(audio))
        before = source.read_bytes()
        output = self.directory / "导出"

        result = self.script("--root", str(self.directory / "tmp"), "--export", "--output", str(output))

        self.assertEqual(result.returncode, 0, result.stderr)
        written = list(output.glob("*.wav"))
        self.assertEqual(len(written), 1, f"应写出一个文件，实际 {written}")
        with wave.open(str(written[0])) as handle:
            self.assertEqual(handle.getnframes(), 2_400)
        self.assertEqual(source.read_bytes(), before, "导出不得改动源文件")

    def test_corrupt_file_is_skipped_and_the_next_file_is_recovered(self) -> None:
        audio = pcm_bytes(1_200)
        broken = b"RIFF" + struct.pack("<I", 36) + b"WAVE" + b"fmt " + struct.pack("<I", 16) + b"\x01\x00"
        self.put(broken, name="LiveLingo-Live-BAD")
        self.put(orphan_wav(audio), name="LiveLingo-Live-GOOD")
        output = self.directory / "导出"

        result = self.script("--root", str(self.directory / "tmp"), "--export", "--output", str(output))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("跳过 LiveLingo-Live-BAD", result.stdout)
        self.assertIn("fmt 块被截断", result.stdout)
        self.assertIn("已写出", result.stdout)
        written = list(output.glob("*.wav"))
        self.assertEqual([path.name for path in written], ["LiveLingo-Live-GOOD.wav"])
        self.assertEqual(struct.unpack("<I", written[0].read_bytes()[40:44])[0], len(audio))

    def test_export_never_overwrites_an_existing_file(self) -> None:
        self.put(orphan_wav(pcm_bytes(1_200)))
        output = self.directory / "导出"
        first = self.script("--root", str(self.directory / "tmp"), "--export", "--output", str(output))
        self.assertIn("已写出", first.stdout)
        target = next(output.glob("*.wav"))
        original = target.read_bytes()

        second = self.script("--root", str(self.directory / "tmp"), "--export", "--output", str(output))

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("不覆盖", second.stdout)
        self.assertNotIn("已写出", second.stdout)
        self.assertEqual(target.read_bytes(), original, "已存在的输出不得被覆盖")

    def test_output_directory_is_fixed_before_the_scan(self) -> None:
        self.put(orphan_wav(pcm_bytes(600)), name="LiveLingo-Live-A")
        self.put(orphan_wav(pcm_bytes(900)), name="LiveLingo-Live-B")
        fake_home = self.directory / "test-home"
        (fake_home / "Downloads").mkdir(parents=True)
        output = io.StringIO()
        arguments = [str(Path(recover.__file__)), "--root", str(self.directory / "tmp"), "--export"]
        with patch.object(Path, "home", return_value=fake_home), patch.object(sys, "argv", arguments), \
                contextlib.redirect_stdout(output):
            self.assertEqual(recover.main(), 0)
        directories = list((fake_home / "Downloads").glob("LiveLingo-未收尾录音-*"))
        self.assertEqual(len(directories), 1, "一次运行只应固定一个输出目录")
        self.assertEqual(len(list(directories[0].glob("*.wav"))), 2)

    def test_missing_root_is_not_an_error(self) -> None:
        result = self.script("--root", str(self.directory / "nope"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("没找到", result.stdout)


if __name__ == "__main__":
    unittest.main()
