#!/usr/bin/env python3
"""Synthetic Mach-O checks; never signs or executes a binary."""

import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('preview_metadata', Path(__file__).with_name('preview-app-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class SignatureDetectionTests(unittest.TestCase):
    def check(self, data):
        with tempfile.TemporaryDirectory(prefix='preview-metadata-') as root:
            path = Path(root) / 'synthetic-header'
            path.write_bytes(data)
            return metadata.signature_commands(path)

    @staticmethod
    def thin(signed=False):
        header = struct.pack('<8I', 0xFEEDFACF, 0x01000007, 3, 2, int(signed), 16 if signed else 0, 0, 0)
        return header + (struct.pack('<4I', 0x1D, 16, 0, 0) if signed else b'')

    def test_unsigned_thin(self):
        self.assertEqual(self.check(self.thin()), 0)

    def test_signature_load_command(self):
        self.assertEqual(self.check(self.thin(signed=True)), 1)

    def test_fat_all_slices_are_checked(self):
        first = self.thin()
        second = self.thin(signed=True)
        table = struct.pack('>2I', 0xCAFEBABE, 2)
        table += struct.pack('>5I', 0x01000007, 3, 48, len(first), 0)
        table += struct.pack('>5I', 0x0100000C, 0, 48 + len(first), len(second), 0)
        self.assertEqual(self.check(table + first + second), 1)

    def test_non_macho(self):
        self.assertIsNone(self.check(b'ordinary resource'))

    def test_invalid_load_command_fails_closed(self):
        header = struct.pack('<8I', 0xFEEDFACF, 0x01000007, 3, 2, 1, 8, 0, 0)
        with self.assertRaises(ValueError):
            self.check(header + struct.pack('<2I', 1, 0))

    def test_redirected_app_is_refused_before_reading_bundle(self):
        with tempfile.TemporaryDirectory(prefix='preview-metadata-') as root:
            app = Path(root) / 'Preview.app'
            app.symlink_to(Path(root) / 'External.app', target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'ordinary directory'):
                metadata.inspect(app)


class PreviewArgumentSafetyTests(unittest.TestCase):
    def rejects(self, *arguments):
        script = Path(__file__).with_name('build-preview-app.sh')
        result = subprocess.run(['/bin/bash', str(script), *arguments],
                                text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Building unsigned', result.stdout)
        return result.stderr

    def test_ad_hoc_identity_is_refused_before_build(self):
        self.assertIn('Ad-hoc signing', self.rejects('--sign', '-'))

    def test_signing_material_cannot_enable_signing(self):
        self.assertIn('explicit --sign', self.rejects('--certificate', '/nonexistent/example.cer'))

    def test_sandbox_model_reference_is_refused_before_keychain_access(self):
        self.assertIn('external model references are refused',
                      self.rejects('--reference-installed-models', '--sign',
                                   'Developer ID Application: Synthetic (EXAMPLE)'))

    def test_protected_output_root_is_refused(self):
        self.assertIn('dedicated output root', self.rejects('--output-root', '/'))

    def test_source_tree_is_not_an_output_root(self):
        root = str(Path(__file__).resolve().parent.parent)
        self.assertIn('dedicated output root', self.rejects('--output-root', root))


if __name__ == '__main__':
    unittest.main()
