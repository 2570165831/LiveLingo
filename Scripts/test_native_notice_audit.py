"""Version and byte checks for transitive Rust notices, without loading code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from Scripts import native_notice_audit as notices


class NativeNoticeAuditTests(unittest.TestCase):
    def test_soxr_binary_requires_exact_registered_source_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            site, supplements, _ = self.fixture(root)
            (site / "soxr").mkdir()
            (site / "soxr/soxr_ext.abi3.so").write_bytes(b"synthetic native binary")
            info = site / "soxr-1.1.0.dist-info"
            info.mkdir()
            (info / "METADATA").write_text("Metadata-Version: 2.4\nName: soxr\nVersion: 1.1.0\n")
            self.assertEqual(notices.audit(site, supplements)["missingCorrespondingSource"], ["soxr"])
            source = supplements / "python-soxr-1.1.0.tar.gz"
            source.write_bytes(b"synthetic archive input")
            audit = supplements / "source-preparation/SourceArchiveAudit.json"
            audit.parent.mkdir()
            row = {"package": "python-soxr", "version": "1.1.0", "preparedSHA256": hashlib.sha256(source.read_bytes()).hexdigest()}
            audit.write_text(json.dumps({"archives": [row]}))
            self.assertTrue(notices.audit(site, supplements)["passed"])
            source.write_bytes(b"changed archive")
            self.assertFalse(notices.audit(site, supplements)["passed"])

    def test_registry_and_remapped_source_paths_are_exact_and_deduplicated(self):
        data = (b"registry/src/index.crates.io-abc/fixture-1.2.3/src/lib.rs\0"
                b"cargo-source/____/other-2.0.0-rc.1/src/lib.rs\0"
                b"registry/src/github-abc/fixture-1.2.3/src/lib.rs\0")
        self.assertEqual(set(notices.CRATE_PATH.findall(data)), {b"fixture-1.2.3", b"other-2.0.0-rc.1"})

    def fixture(self, root):
        site, supplements = root / "site", root / "supplements"
        site.mkdir()
        (site / "fixture.so").write_bytes(b"registry/src/index.crates.io-abc/fixture-1.2.3/src/lib.rs\0")
        notice = supplements / "native-cargo-notices/fixture-1.2.3/LICENSE-MIT"
        notice.parent.mkdir(parents=True)
        notice.write_bytes(b"Copyright fixture\nPermission granted.\n")
        value = {"components": [{"name": "fixture", "version": "1.2.3", "texts": [
            {"path": "fixture-1.2.3/LICENSE-MIT", "sha256": hashlib.sha256(notice.read_bytes()).hexdigest()}]}]}
        (notice.parents[1] / "inventory.json").write_text(json.dumps(value))
        return site, supplements, notice

    def test_exact_notice_required_and_available_asr_notice_bytes_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            site, supplements, notice = self.fixture(root)
            result = notices.audit(site, supplements)
            self.assertTrue(result["passed"])
            target = root / "output/Licenses"
            notices.copy_asr_notices(supplements, target, result)
            self.assertEqual((target / "native-cargo-notices/fixture-1.2.3/LICENSE-MIT").read_bytes(), notice.read_bytes())
            self.assertTrue(notices.audit(site, target)["passed"])
            (site / "fixture.so").write_bytes(b"registry/src/index.crates.io-abc/fixture-1.2.4/src/lib.rs\0")
            self.assertEqual(notices.audit(site, supplements)["missingCrateNotices"], ["fixture-1.2.4"])

    def test_changed_missing_and_symlink_notice_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            site, supplements, notice = self.fixture(Path(directory))
            original = notice.read_bytes()
            notice.write_bytes(b"changed notice")
            self.assertFalse(notices.audit(site, supplements)["passed"])
            notice.unlink()
            self.assertFalse(notices.audit(site, supplements)["passed"])
            outside = Path(directory) / "outside"
            outside.write_bytes(original)
            notice.symlink_to(outside)
            self.assertFalse(notices.audit(site, supplements)["passed"])


if __name__ == "__main__":
    unittest.main()
