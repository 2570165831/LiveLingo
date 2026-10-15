"""Fault injection on small HFS catalog fixtures; all fixtures stay internal."""
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest.mock import patch

from Scripts import hfs_image_metadata as metadata


def fixture():
    data = bytearray(49152); data[:4] = b'ER\x08\x00'
    for index, first, sectors, name in ((1, 1, 63, b'Apple_partition_map'), (2, 64, 32, b'Apple_HFS')):
        at = index * 512; data[at:at + 2] = b'PM'
        struct.pack_into('>III', data, at + 4, 2, first, sectors)
        data[at + 48:at + 48 + len(name)] = name
    volume = 32768; header = volume + 1024; catalog = volume + 2048; leaf = catalog + 4096
    data[header:header + 4] = b'H+\x00\x04'
    struct.pack_into('>IIII', data, header + 32, 2, 0, 2048, 8)
    struct.pack_into('>QII', data, header + 272, 8192, 0, 4)
    struct.pack_into('>II', data, header + 288, 1, 4)
    struct.pack_into('>IIbBHH', data, catalog, 0, 0, 1, 0, 3, 0)
    struct.pack_into('>HIIIIHHI', data, catalog + 14, 1, 1, 6, 1, 1, 4096, 516, 2)
    cursor = 14; offsets = []; finder = bytes(10) + b'\xff' * 4 + bytes(18)
    for kind, name, mode in ((1, 'V', 0o40755), (2, 'payload', 0o100644), (2, 'link', 0o120755)):
        encoded = name.encode('utf-16-be'); key = struct.pack('>HIH', 6 + len(encoded), 1, len(encoded) // 2) + encoded
        record = bytearray(88 if kind == 1 else 248); struct.pack_into('>H', record, 0, kind)
        struct.pack_into('>H', record, 42, mode)
        record[48:80] = b'slnkrhap' + finder[8:] if kind == 2 and mode == 0o120755 else finder
        offsets.append(cursor); data[leaf + cursor:leaf + cursor + len(key + record)] = key + record; cursor += len(key + record)
        thread = struct.pack('>HIHH', 6, 2, 0, kind + 2) + bytes(8)
        offsets.append(cursor); data[leaf + cursor:leaf + cursor + len(thread)] = thread; cursor += len(thread)
    offsets.append(cursor)
    struct.pack_into('>IIbBHH', data, leaf, 0, 0, -1, 1, 6, 0)
    for index, value in enumerate(offsets):
        struct.pack_into('>H', data, leaf + 4096 - 2 * (index + 1), value)
    data[-64:] = b'Public synthetic file-fork canary.'.ljust(64, b'!')
    return data


class HFSImageMetadataTests(unittest.TestCase):
    def test_only_finder_fields_change_and_symlink_marker_and_payload_remain(self):
        data = fixture(); patches, report = metadata.plan(data)
        self.assertEqual(report['catalogDataRecords'], 3)
        before = bytes(data)
        for offset, old, new in patches:
            self.assertEqual(data[offset:offset + len(old)], old)
            data[offset:offset + len(old)] = new
        self.assertEqual(data[-64:], before[-64:])
        self.assertEqual(sum(data.count(marker) for marker in (b'slnkrhap',)), 1)
        self.assertTrue(all(after == bytes(32) or after == b'slnkrhap' + bytes(24) for _, _, after in patches))

    def test_unknown_finder_payload_is_rejected_before_output_creation(self):
        data = fixture(); patches, _ = metadata.plan(data); data[patches[0][0] + 28] = 1
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source = root / 'raw'; source.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'unreviewed Finder'):
                metadata.clean(source, root / 'clean', root / 'report.json')
            self.assertFalse((root / 'clean').exists())
            self.assertEqual(source.read_bytes(), data)

    def test_corrupt_geometry_leaf_cycle_unknown_record_and_journal_are_rejected(self):
        base = fixture(); patches, _ = metadata.plan(base)
        for offset, value in ((32768 + 1024 + 12, 1), (34816 + 4096 + 3, 1),
                              (34816 + 32, 1), (patches[0][0] - 48, 99), (512 + 4, 255)):
            data = bytearray(base); data[offset] = value
            with self.subTest(offset=offset), self.assertRaises((ValueError, UnicodeError)):
                metadata.plan(data)

    def test_clean_copy_preserves_original_and_records_complete_byte_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source = root / 'raw'; source.write_bytes(fixture())
            value = metadata.clean(source, root / 'clean', root / 'report.json')
            self.assertTrue(value['passed'])
            self.assertTrue(value['onlyKnownFinderFieldsChanged'])
            self.assertEqual(source.read_bytes(), fixture())
            self.assertEqual((root / 'clean').read_bytes()[-64:], source.read_bytes()[-64:])

    def test_whole_image_comparison_detects_changes_outside_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source = root / 'raw'; source.write_bytes(fixture())
            real_run = metadata.subprocess.run
            def run(command, **kwargs):
                result = real_run(command, **kwargs)
                if command[0] == '/bin/cp':
                    path = Path(command[-1]); data = bytearray(path.read_bytes()); data[-1] ^= 1; path.write_bytes(data)
                return result
            with patch.object(metadata.subprocess, 'run', side_effect=run), self.assertRaisesRegex(ValueError, 'non-metadata'):
                metadata.clean(source, root / 'clean', root / 'report.json')
            self.assertEqual(source.read_bytes(), fixture())
            self.assertFalse((root / 'report.json').exists())


if __name__ == '__main__':
    unittest.main()
