"""Do not classify the Windows licensing API's import library as a legal text."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts import notice_copy as notices
from Scripts.privacy_package import PrivacyError


class NoticeCopyTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'native-cargo-notices'
        relative = 'winapi-fixture-1/lib/libwinapi_oemlicense.a'
        binary = b'!<arch>\nSynthetic OEMLicense.dll import data'
        path = source / relative
        path.parent.mkdir(parents=True)
        path.write_bytes(binary)
        license_file = source / 'winapi-1/LICENSE-MIT'
        license_file.parent.mkdir()
        license_file.write_bytes(b'Copyright upstream author\nPermission is granted.\n')
        digest = hashlib.sha256(binary).hexdigest()
        inventory = {'scope': 'Synthetic upstream input', 'components': [
            {'name': 'winapi-fixture', 'authors': ['Upstream author'], 'license': 'MIT/Apache-2.0',
             'texts': [{'path': relative, 'sha256': digest}]},
            {'name': 'winapi', 'texts': [{'path': 'winapi-1/LICENSE-MIT', 'sha256': hashlib.sha256(license_file.read_bytes()).hexdigest()}]}]}
        (source / 'inventory.json').write_text(json.dumps(inventory))
        return source, root / 'prepared', relative, binary, digest, license_file.read_bytes()

    def test_copy_corrects_inventory_and_preserves_real_legal_bytes_and_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, target, relative, binary, digest, legal = self.fixture(Path(temporary))
            original = (source / 'inventory.json').read_bytes()
            with patch.object(notices, 'IMPORT_LIBRARIES', {relative: digest}):
                report = notices.copy_notice_tree(source, target)
            self.assertFalse((target / relative).exists())
            self.assertEqual((source / relative).read_bytes(), binary)
            self.assertEqual((source / 'inventory.json').read_bytes(), original)
            self.assertEqual((target / 'winapi-1/LICENSE-MIT').read_bytes(), legal)
            prepared = json.loads((target / 'inventory.json').read_text())
            self.assertEqual(prepared['components'][0]['texts'], [])
            self.assertEqual(prepared['components'][0]['authors'], ['Upstream author'])
            self.assertEqual(len(prepared['components'][0]['omittedNonNoticeBuildInputs']), 1)
            self.assertEqual(len(report['removedFiles']), 1)

    def test_changed_library_is_not_silently_pruned(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, target, relative, binary, digest, legal = self.fixture(Path(temporary))
            (source / relative).write_bytes(binary + b'changed')
            with patch.object(notices, 'IMPORT_LIBRARIES', {relative: digest}), \
                    self.assertRaisesRegex(PrivacyError, 'changed-nonnotice-build-input'):
                notices.copy_notice_tree(source, target)
            self.assertFalse(target.exists())

    def test_changed_inventory_cannot_claim_the_library_is_still_a_notice(self):
        value = {'components': [{'texts': [{'path': 'pinned', 'sha256': 'changed'}]}]}
        with patch.object(notices, 'IMPORT_LIBRARIES', {'pinned': 'expected'}), \
                self.assertRaisesRegex(PrivacyError, 'changed-nonnotice-inventory-input'):
            notices.prepared_inventory(value)

    def test_hidden_legal_text_is_not_lost_in_an_excluded_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary);source = root / 'fixture';path = source / 'tests/LICENSE-MIT'
            path.parent.mkdir(parents=True);path.write_text('Copyright upstream author')
            with self.assertRaisesRegex(PrivacyError, 'supplement-license-needs-safe-relative-name'):
                notices.copy_notice_tree(source, root / 'output')


if __name__ == '__main__':
    unittest.main()
