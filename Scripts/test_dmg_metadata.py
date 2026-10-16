"""Synthetic UDIF metadata cases; no image mounting or release tools."""
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

from Scripts import dmg_metadata as metadata
from Scripts.privacy_package import PrivacyError


class DMGMetadataTests(unittest.TestCase):
    def inspect(self, value, alter=None, data_fork_bytes=0):
        raw = plistlib.dumps(value)
        footer = bytearray(512); footer[:4] = b'koly'
        struct.pack_into('>II', footer, 4, 4, 512)
        struct.pack_into('>QQ', footer, 24, 0, data_fork_bytes)
        struct.pack_into('>QQ', footer, 216, data_fork_bytes, len(raw))
        struct.pack_into('>Q', footer, 492, 64)
        data = raw + footer
        if alter:
            data = alter(data)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'synthetic.dmg'
            with path.open('wb') as stream:
                # A sparse synthetic data fork exercises real 64-bit offsets
                # without allocating or reading gigabytes of dummy payload.
                stream.seek(data_fork_bytes)
                stream.write(data)
            return metadata.inspect(path)

    def block_map(self, offset=16, length=8, kind=0x80000005):
        header = bytearray(204); header[:4] = b'mish'
        struct.pack_into('>IQQQII', header, 4, 1, 0, 1, 0, 2048, 0)
        struct.pack_into('>I', header, 200, 2)
        return (bytes(header) + struct.pack('>IIQQQQ', kind, 0, 0, 1, offset, length)
                + struct.pack('>IIQQQQ', 0xffffffff, 0, 1, 0, offset + length, 0))

    def test_path_like_compressed_offset_is_a_bounded_integer(self):
        # The real regression's integer contains 7e5c577b in its low word.
        block_map = self.block_map(offset=6414948219)
        result = self.inspect(self.resource('blkx', block_map), data_fork_bytes=7000000000)
        self.assertTrue(result['passed'])

    def test_path_like_crc32_is_a_numeric_checksum(self):
        block_map = bytearray(self.block_map())
        struct.pack_into('>III', block_map, 64, 2, 32, 0x7e5c577b)
        self.assertTrue(self.inspect(self.resource('blkx', bytes(block_map)), data_fork_bytes=64)['passed'])

    def test_block_map_rejects_out_of_range_or_untyped_numeric_fields(self):
        base = self.block_map()
        cases = []
        for offset, value in [(4, 2), (12, 65), (40, 1), (204 + 4, 1), (204, 0x12345678),
                              (76, 1), (204 + 12, 2), (204 + 28, 1000),
                              (204 + 36, 1000)]:
            changed = bytearray(base); struct.pack_into('>I', changed, offset, value)
            cases.append(bytes(changed))
        cases.append(self.block_map(kind=1, length=8))
        for block_map in cases:
            with self.subTest(block_map=block_map.hex()), self.assertRaises(PrivacyError):
                self.inspect(self.resource('blkx', block_map), data_fork_bytes=64)

    def test_numeric_map_bytes_in_another_field_still_fail_closed(self):
        with self.assertRaises(PrivacyError):
            self.inspect(self.resource('other', self.block_map()), data_fork_bytes=64)

    def test_readable_private_text_outside_block_map_is_still_rejected(self):
        value = self.resource('blkx', self.block_map())
        value['source'] = '/synthetic/private/build'
        with self.assertRaises(PrivacyError):
            self.inspect(value, data_fork_bytes=64)

    def resource(self, kind, data):
        return {'resource-fork': {kind: [{'Data': data}]}}

    def test_exact_public_constant_and_structural_block_map_pass(self):
        report = self.inspect(self.resource('plst', metadata.PUBLIC_PLST))
        self.assertTrue(report['passed'])
        self.assertEqual(report['binaryResources'][0]['kind'], 'exact-public-plst-constant')
        block_map = b'mish' + bytes.fromhex('00000001') + bytes(196)
        self.assertEqual(self.inspect(self.resource('blkx', block_map))['binaryResources'][0]['runs'], 0)

    def test_changed_constant_or_same_bytes_in_other_field_are_rejected(self):
        for value in [self.resource('plst', metadata.PUBLIC_PLST[:-1] + b'!'),
                      self.resource('other', metadata.PUBLIC_PLST), {'hidden': bytes(32)}]:
            with self.subTest(value=value), self.assertRaises(PrivacyError):
                self.inspect(value)

    def test_private_xml_and_embedded_metadata_are_rejected(self):
        for value in [{'author': '/synthetic/private/user'}, {'transcript': 'synthetic classroom canary'},
                      {'embedded': plistlib.dumps({'source': '/synthetic/private/build'})}]:
            with self.subTest(value=value), self.assertRaises(PrivacyError):
                self.inspect(value)

    def test_changed_block_map_reserved_bytes_or_count_are_rejected(self):
        for offset in (40, 203):
            block_map = bytearray(b'mish' + bytes.fromhex('00000001') + bytes(196)); block_map[offset] = 1
            with self.subTest(offset=offset), self.assertRaises(PrivacyError):
                self.inspect(self.resource('blkx', bytes(block_map)))

    def test_footer_version_and_metadata_range_fail_closed(self):
        for alter in [lambda data: data[:-512] + b'bad!' + data[-508:],
                      lambda data: data[:-512] + data[-512:-292] + bytes([255]) * 16 + data[-276:],
                      lambda data: b'short']:
            with self.subTest(alter=alter), self.assertRaises(PrivacyError):
                self.inspect({}, alter)


if __name__ == '__main__':
    unittest.main()
