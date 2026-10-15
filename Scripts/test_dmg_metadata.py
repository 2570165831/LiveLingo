"""Synthetic UDIF metadata cases; no image mounting or release tools."""
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

from Scripts import dmg_metadata as metadata
from Scripts.privacy_package import PrivacyError


class DMGMetadataTests(unittest.TestCase):
    def inspect(self, value, alter=None):
        raw = plistlib.dumps(value)
        footer = bytearray(512); footer[:4] = b'koly'
        struct.pack_into('>II', footer, 4, 4, 512)
        struct.pack_into('>QQ', footer, 216, 0, len(raw))
        data = raw + footer
        if alter:
            data = alter(data)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'synthetic.dmg'; path.write_bytes(data)
            return metadata.inspect(path)

    def resource(self, kind, data):
        return {'resource-fork': {kind: [{'Data': data}]}}

    def test_exact_public_constant_and_structural_block_map_pass(self):
        report = self.inspect(self.resource('plst', metadata.PUBLIC_PLST))
        self.assertTrue(report['passed'])
        self.assertEqual(report['binaryResources'][0]['kind'], 'exact-public-plst-constant')
        block_map = b'mish' + bytes(200)
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
            block_map = bytearray(b'mish' + bytes(200)); block_map[offset] = 1
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
