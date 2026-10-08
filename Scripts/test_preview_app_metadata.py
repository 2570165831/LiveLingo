#!/usr/bin/env python3
"""Synthetic Mach-O checks; never signs or executes a binary."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('preview_metadata', Path(__file__).with_name('preview-app-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
sign_spec = importlib.util.spec_from_file_location('preview_signing', Path(__file__).with_name('sign-preview-app.py'))
signer = importlib.util.module_from_spec(sign_spec)
sign_spec.loader.exec_module(signer)
log_spec = importlib.util.spec_from_file_location('preview_log', Path(__file__).with_name('run-preview-tool.py'))
tool_log = importlib.util.module_from_spec(log_spec)
log_spec.loader.exec_module(tool_log)


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

    def test_ad_hoc_identity_never_accepts_keychain_material(self):
        self.assertIn('explicit --sign', self.rejects('--sign', '-', '--keychain', '/nonexistent/example.keychain'))

    def test_default_ad_hoc_refuses_external_models_before_reading_them(self):
        self.assertIn('external model references are refused', self.rejects('--reference-installed-models'))

    def test_conflicting_signing_modes_are_refused(self):
        self.assertIn('Conflicting signing modes', self.rejects('--unsigned', '--ad-hoc'))

    def test_derived_data_cannot_escape_output_root(self):
        self.assertIn('inside the output root', self.rejects('--derived-data', '/private/tmp/other-cache'))

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


class NestedSigningSafetyTests(unittest.TestCase):
    def test_framework_binaries_and_nested_helpers_precede_bundle_seals(self):
        with tempfile.TemporaryDirectory(prefix='preview-signing-') as root:
            app = Path(root) / 'Preview.app'
            names = ['Contents/MacOS/LiveLingo', 'Contents/Helpers/tool',
                     'Contents/Frameworks/Example.framework/Versions/A/Example']
            for name in names:
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(SignatureDetectionTests.thin())
            receipt = {'symlinks': {}, 'info': {'CFBundleExecutable': 'LiveLingo'},
                       'code_signature_commands': dict.fromkeys(names, 0)}
            targets = signer.code_targets(app, receipt)
            framework = app / 'Contents/Frameworks/Example.framework'
            self.assertLess(targets.index(app / names[2]), targets.index(framework))
            self.assertLess(targets.index(framework), targets.index(app))
            self.assertLess(targets.index(app / names[1]), targets.index(app))
            self.assertNotIn(app / names[0], targets)
            self.assertEqual(targets[-1], app)

    def test_external_code_link_is_refused_before_any_signing(self):
        with tempfile.TemporaryDirectory(prefix='preview-signing-') as root:
            app = Path(root) / 'Preview.app'
            app.mkdir()
            outside = Path(root) / 'production-canary'
            outside.write_text('do not sign')
            (app / 'alias').symlink_to(outside)
            receipt = {'symlinks': {'alias': str(outside)}}
            with mock.patch.object(signer.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'inside the app'):
                    signer.code_targets(app, receipt)
                run.assert_not_called()
            self.assertEqual(outside.read_text(), 'do not sign')

    def test_ad_hoc_keychain_argument_is_refused_before_inspection(self):
        with mock.patch.object(signer.metadata, 'inspect') as inspect:
            with self.assertRaisesRegex(ValueError, 'must not access a keychain'):
                signer.sign(Path('/nonexistent/app'), Path('/nonexistent/rights'), keychain=Path('/nonexistent/keychain'))
            inspect.assert_not_called()

    def test_environment_diagnostics_are_filtered_before_recording(self):
        lines = ['ordinary diagnostic\n', 'export SYNTHETIC_SECRET=canary\n',
                 'EnvironmentVariables = {\n', '  TOKEN = canary;\n', '}\n',
                 'Test Environment:\n', '    ANOTHER_TOKEN=canary\n', '\n',
                 'warning: environment has SYNTHETIC_SECRET=canary\n',
                 'TEST_PREFERENCE_CREATED suite=synthetic\n', '** TEST SUCCEEDED **\n']
        self.assertEqual(''.join(tool_log.filtered(lines)),
                         'ordinary diagnostic\nwarning: [environment diagnostic omitted]\n'
                         'TEST_PREFERENCE_CREATED suite=synthetic\n** TEST SUCCEEDED **\n')


class RealAdHocSigningTests(unittest.TestCase):
    def test_signs_real_nested_code_without_launching_or_using_an_identity(self):
        with tempfile.TemporaryDirectory(prefix='preview-native-signing-') as root:
            root = Path(root)
            app = root / 'Preview.app'
            main = app / 'Contents/MacOS/LiveLingo'
            helper = app / 'Contents/Helpers/tool'
            framework = app / 'Contents/Frameworks/Example.framework'
            library = framework / 'Versions/A/Example'
            for path in (main, helper, library, framework / 'Versions/A/Resources/Info.plist'):
                path.parent.mkdir(parents=True, exist_ok=True)
            source = root / 'fixture.c'
            source.write_text('int main(void) { return 0; }\n')
            for binary in (main, helper, library):
                command = ['/usr/bin/clang', '-arch', 'arm64', '-Wl,-no_adhoc_codesign']
                if binary == library:
                    command += ['-dynamiclib']
                subprocess.run(command + [str(source), '-o', str(binary)], check=True,
                               capture_output=True)
            (framework / 'Versions/Current').symlink_to('A')
            (framework / 'Example').symlink_to('Versions/Current/Example')
            (framework / 'Resources').symlink_to('Versions/Current/Resources')
            framework_info = {'CFBundleIdentifier': 'com.jianhongli.LiveLingo.preview.fixture',
                              'CFBundleExecutable': 'Example', 'CFBundlePackageType': 'FMWK',
                              'CFBundleVersion': '1'}
            (framework / 'Versions/A/Resources/Info.plist').write_bytes(plistlib.dumps(framework_info))
            info = {'CFBundleIdentifier': 'com.jianhongli.LiveLingo.preview',
                    'CFBundleDisplayName': 'LiveLingo 预览版', 'CFBundleExecutable': 'LiveLingo',
                    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1-preview.12345678',
                    'LiveLingoPreviewCommit': '12345678' + '0' * 32}
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            rights = Path(__file__).resolve().parent.parent / 'LiveLingo/Resources/LiveLingo.entitlements'
            signer.sign(app, rights)
            receipt = metadata.inspect(app, adhoc=True)
            self.assertEqual(len(receipt['signing']), 3)
            self.assertTrue(receipt['sandbox']['signed_app_sandbox'])
            self.assertFalse(receipt['sandbox']['runtime_verified'])
            self.assertIn('Containers/com.jianhongli.LiveLingo.preview/',
                          receipt['sandbox']['expected_data_directory'])
            result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(helper)],
                                    check=True, capture_output=True)
            self.assertEqual(plistlib.loads(result.stdout),
                             {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})


if __name__ == '__main__':
    unittest.main()
