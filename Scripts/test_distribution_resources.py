"""Offscreen resource metadata and copy-only attribute regressions."""
from collections import Counter
from pathlib import Path
import struct
import plistlib
import subprocess
import tempfile
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import patch

from Scripts import privacy_package as privacy, resource_metadata as resource
from Scripts import distribution_xattrs as attrs


def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))


def png(*metadata):
    return (resource.PNG + chunk(b'IHDR', struct.pack('>2I5B', 1, 1, 8, 6, 0, 0, 0))
            + b''.join(metadata) + chunk(b'IDAT', zlib.compress(b'\0\0\0\0\0')) + chunk(b'IEND', b''))


class ResourceMetadataTests(unittest.TestCase):
    def inspect(self, data, name='fixture.png'):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / name
            file.write_bytes(data)
            counts = Counter()
            privacy.inspect_metadata_file(file, counts, False)
            self.assertEqual(file.read_bytes(), data)
            return counts

    def test_color_and_upstream_software_metadata_remain_intact(self):
        data = png(chunk(b'tEXt', b'Software\0Matplotlib'))
        counts = self.inspect(data)
        self.assertEqual(counts['resource_metadata_fields'], 1)
        self.assertEqual(counts['png_chunks'], 4)
        self.assertEqual(counts['binary_resource_path_files'], 1)

    def test_private_plain_compressed_and_unicode_png_metadata_fail(self):
        private = b'/synthetic/private/build'
        cases = [chunk(b'tEXt', b'Author\0' + private),
                 chunk(b'zTXt', b'Comment\0\0' + zlib.compress(private)),
                 chunk(b'iTXt', b'Comment\0\1\0en\0title\0' + zlib.compress(private)),
                 chunk(b'tEXt', b'rawText\0classroom canary')]
        for data in cases:
            with self.subTest(data=data), self.assertRaises(privacy.PrivacyError):
                self.inspect(png(data))

    def test_exif_unknown_chunks_crc_and_trailing_bytes_fail_closed(self):
        data = png()
        for invalid in [png(chunk(b'eXIf', b'GPS canary')), png(chunk(b'zzZz', b'opaque')),
                        data[:-1] + bytes([data[-1] ^ 1]), data + b'hidden', data[:-12]]:
            with self.subTest(invalid=invalid), self.assertRaises(privacy.PrivacyError):
                self.inspect(invalid)

    def test_compressed_metadata_is_bounded(self):
        with self.assertRaises(privacy.PrivacyError):
            self.inspect(png(chunk(b'zTXt', b'Comment\0\0' + zlib.compress(b'a' * (resource.TEXT_LIMIT + 1)))))

    def test_icns_embedded_png_metadata_is_checked(self):
        data = png(chunk(b'zTXt', b'Comment\0\0' + zlib.compress(b'/synthetic/private')))
        icon = b'icns' + struct.pack('>I', len(data) + 16) + b'icp4' + struct.pack('>I', len(data) + 8) + data
        with self.assertRaises(privacy.PrivacyError):
            self.inspect(icon, 'fixture.icns')

    def test_only_display_exif_tags_and_zero_padding_are_accepted(self):
        exif = b'II*\0' + struct.pack('<IHHHI4sI', 8, 1, 0xA001, 3, 1, b'\1\0\0\0', 0)
        self.assertEqual(self.inspect(png(chunk(b'eXIf', exif)))['resource_metadata_fields'], 1)
        for private in (exif + b'private', exif[:10] + struct.pack('<H', 0x8825) + exif[12:]):
            with self.subTest(private=private), self.assertRaises(privacy.PrivacyError):
                self.inspect(png(chunk(b'eXIf', private)))

    def test_non_macho_known_binary_tails_are_checked_in_three_encodings(self):
        for name, prefix in [('fixture.metallib', b'MTLB' + b'\0' * 20),
                             ('Assets.car', b'BOMStore' + b'\0' * 20),
                             ('fixture.a', b'!<arch>\n' + b'\0' * 20)]:
            for encoding in ['utf-8', 'utf-16-le', 'utf-16-be']:
                with self.subTest(name=name, encoding=encoding), self.assertRaises(privacy.PrivacyError):
                    self.inspect(prefix + '/synthetic/private/file'.encode(encoding) + b'\0\0', name)


class DistributionAttributeTests(unittest.TestCase):
    def test_clean_attributes_cannot_approve_unknown_image_container_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); image = root / 'candidate.dmg'; image.write_bytes(b'synthetic image')
            mount = root / 'mount'; mount.mkdir()
            with patch.object(attrs.os.path, 'ismount', return_value=True), \
                 patch.object(attrs.os, 'statvfs', return_value=SimpleNamespace(f_flag=attrs.os.ST_RDONLY)), \
                 patch.object(attrs, 'inspect', return_value={'passed': True}), self.assertRaises(privacy.PrivacyError):
                attrs.inspect_mounted_image(image, mount)

    def test_only_exact_public_finder_records_pass_not_opaque_32_byte_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            private = bytearray(32); private[28] = 1
            for data in [*attrs.PUBLIC_FINDER_INFO, bytes(private), b'A' * 32, bytes(31)]:
                with self.subTest(data=data), patch.object(attrs, 'names', return_value=['com.apple.FinderInfo']), \
                     patch.object(attrs, 'value', return_value=data):
                    self.assertEqual(attrs.inspect(root)['passed'], data in attrs.PUBLIC_FINDER_INFO)

    def test_distribution_gate_rejects_embedded_provenance_even_with_clean_host_file(self):
        self.image_audit(False, True)

    def test_clean_image_does_not_silently_approve_host_file_attributes(self):
        self.image_audit(True, False)

    def image_audit(self, inner, outer):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); image = root / 'candidate.dmg'; image.write_bytes(b'synthetic image')
            mount = root / 'mount'; mount.mkdir()
            with patch.object(attrs.os.path, 'ismount', return_value=True), \
                 patch.object(attrs.os, 'statvfs', return_value=SimpleNamespace(f_flag=attrs.os.ST_RDONLY)), \
                 patch.object(attrs, 'inspect_container', return_value={'passed': True}), \
                 patch.object(attrs, 'inspect', side_effect=[{'passed': inner}, {'passed': outer}]):
                report = attrs.inspect_mounted_image(image, mount)
            self.assertEqual(report['passed'], inner)
            self.assertEqual(report['hostMetadataRequiresTransportReview'], not outer)
            self.assertEqual(report['imageBytes'], len(b'synthetic image'))
            self.assertEqual(report['hostFile']['passed'], outer)

    def test_a_plain_directory_or_writable_mount_cannot_stand_in_for_the_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); image = root / 'candidate.dmg'; image.write_bytes(b'synthetic image')
            mount = root / 'mount'; mount.mkdir()
            for is_mount, flags in [(False, attrs.os.ST_RDONLY), (True, 0)]:
                with patch.object(attrs.os.path, 'ismount', return_value=is_mount), \
                     patch.object(attrs.os, 'statvfs', return_value=SimpleNamespace(f_flag=flags)), \
                     self.assertRaises(ValueError):
                    attrs.inspect_mounted_image(image, mount)

    def test_tracking_removal_rechecks_copy_and_preserves_unknown_security_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            file = root / 'notice.txt'
            file.write_text('Public notice')
            for key in ['com.apple.metadata:kMDItemWhereFroms', 'com.example.unreviewed']:
                subprocess.run(['/usr/bin/xattr', '-w', key, 'synthetic', str(file)], check=True, capture_output=True)
            before = attrs.inspect(root)
            self.assertFalse(before['passed'])
            cleaned = attrs.inspect(root, strip_tracking=True)
            self.assertFalse(cleaned['passed'])
            self.assertEqual(cleaned['removedTracking']['com.apple.metadata:kMDItemWhereFroms'], 1)
            self.assertIn('com.example.unreviewed', [x['attribute'] for x in cleaned['rejected']])
            self.assertNotIn('com.apple.metadata:kMDItemWhereFroms', attrs.names(file))
            self.assertEqual(file.read_text(), 'Public notice')


class SignatureSealRuleTests(unittest.TestCase):
    def rules(self):
        return {r'.*\.dSYM($|/)': {'weight': 11.0},
                r'^(.*/)?\.DS_Store$': {'omit': True, 'weight': 2000.0},
                r'^[^/]+$': {'nested': True, 'weight': 10.0}}

    def test_exact_system_rules_pass_in_a_coderesources_file(self):
        for fmt in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / '_CodeSignature/CodeResources'
                path.parent.mkdir()
                path.write_bytes(plistlib.dumps({'rules2': self.rules()}, fmt=fmt))
                counts = Counter(); privacy.inspect_metadata_file(path, counts, False)
                self.assertEqual(counts['metadata_files'], 1)

    def test_same_strings_outside_signature_rule_keys_are_rejected(self):
        for rule in self.rules():
            for value, signature in [({'rules2': {rule: True}}, False),
                                     ({'comment': rule}, True), ({'rules': {rule: True}}, True)]:
                with self.subTest(rule=rule), self.assertRaises(privacy.PrivacyError):
                    privacy.validate_metadata(value, signature=signature)

    def test_changed_rules_and_private_payloads_do_not_inherit_approval(self):
        values = [
            {'rules2': {r'^[^/]+$': {'nested': False, 'weight': 10.0}}},
            {'rules2': {r'^[^/]+$': {'nested': 1, 'weight': 10.0}}},
            {'rules2': {r'^[^/]+$': {'nested': True, 'weight': 10.0, 'comment': '/synthetic/private'}}},
            {'rules2': {r'^[^/]+$/synthetic/private': {'nested': True, 'weight': 10.0}}},
            {'rules2': self.rules(), 'comment': '/synthetic/private'},
            {'rules2': self.rules(), 'transcript': 'synthetic sensitive canary'},
        ]
        for value in values:
            with self.subTest(value=value), self.assertRaises(privacy.PrivacyError):
                privacy.validate_metadata(value, signature=True)


if __name__ == '__main__':
    unittest.main()
