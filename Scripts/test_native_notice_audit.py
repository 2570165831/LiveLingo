"""Version and byte checks for transitive Rust notices, without loading code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from Scripts import native_notice_audit as notices


class NativeNoticeAuditTests(unittest.TestCase):
    def test_committed_tokenizers_runtime_graph_has_exact_hash_bound_notices(self):
        supplements = Path(__file__).resolve().parent.parent / "Packaging/MLXLicenses"
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            info = site / "tokenizers-0.23.0rc0.dist-info"
            info.mkdir()
            (info / "METADATA").write_text("Metadata-Version: 2.4\nName: tokenizers\nVersion: 0.23.0rc0\n")
            result = notices.audit(site, supplements)
            self.assertTrue(result["passed"], result["missingCrateNotices"])
            self.assertEqual(len(result["lockRequiredCrates"]), 138)
            self.assertEqual(len(result["sourceLockAudits"][0]["excludedDevOnlyCrates"]), 27)

    def test_only_root_dev_only_reachability_is_excluded(self):
        packages = [
            {"name": "root", "version": "1.0.0", "dependencies": ["normal", "dev", "shared"]},
            {"name": "normal", "version": "1.0.0", "dependencies": ["shared", "optional-platform"]},
            {"name": "dev", "version": "1.0.0", "dependencies": ["dev-child"]},
            {"name": "shared", "version": "1.0.0"},
            {"name": "optional-platform", "version": "1.0.0"},
            {"name": "dev-child", "version": "1.0.0"},
        ]
        value = {"packages": packages, "rootPackage": ["root", "1.0.0"],
                 "rootDevDependencies": ["dev", "shared"], "rootNonDevDependencies": ["normal", "shared"]}
        self.assertEqual({row["name"] for row in notices.runtime_lock_packages(value)},
                         {"root", "normal", "shared", "optional-platform"})
        packages[1]["dependencies"].append("dev-child")
        self.assertIn("dev-child", {row["name"] for row in notices.runtime_lock_packages(value)})

    def lock_fixture(self, root):
        site, supplements, notice = self.fixture(root)
        info = site / "tokenizers-0.23.0rc0.dist-info"
        info.mkdir()
        (info / "METADATA").write_text("Metadata-Version: 2.4\nName: tokenizers\nVersion: 0.23.0rc0\n")
        inventory = supplements / "native-cargo-notices/inventory.json"
        value = json.loads(inventory.read_bytes())
        value["components"][0]["checksum"] = "archive-hash"
        lock = {"distribution": "tokenizers", "version": "0.23.0rc0", "scope": "Complete synthetic lock",
                "packages": [{"name": "fixture", "version": "1.2.3", "checksum": "archive-hash"},
                             {"name": "unobserved", "version": "2.0.0", "checksum": "second-hash"}]}
        path = inventory.parent / "exact-release-lock.json"
        path.write_text(json.dumps(lock))
        value["sourceLockAudits"] = [{"distribution": "tokenizers", "version": "0.23.0rc0",
                                     "path": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}]
        inventory.write_text(json.dumps(value))
        return site, supplements, notice, inventory, path

    def test_complete_lock_missing_version_fails_even_without_binary_path(self):
        with tempfile.TemporaryDirectory() as directory:
            site, supplements, notice, inventory, path = self.lock_fixture(Path(directory))
            result = notices.audit(site, supplements)
            self.assertFalse(result["passed"])
            self.assertEqual(result["missingCrateNotices"], ["unobserved-2.0.0"])
            self.assertEqual(result["sourceLockAudits"][0]["registryPackageCount"], 2)
            target = Path(directory) / "output/Licenses"
            notices.copy_asr_notices(supplements, target, result)
            self.assertEqual((target / "native-cargo-notices" / path.name).read_bytes(), path.read_bytes())
            self.assertFalse(notices.audit(site, target)["passed"])

    def test_complete_lock_checksum_and_notice_bytes_both_required(self):
        with tempfile.TemporaryDirectory() as directory:
            site, supplements, notice, inventory, path = self.lock_fixture(Path(directory))
            value = json.loads(inventory.read_bytes())
            other = notice.parent.parent / "unobserved-2.0.0/LICENSE"
            other.parent.mkdir()
            other.write_bytes(b"Copyright exact version\nPermission granted.\n")
            value["components"].append({"name": "unobserved", "version": "2.0.0", "checksum": "wrong-version-archive",
                                        "texts": [{"path": "unobserved-2.0.0/LICENSE", "sha256": hashlib.sha256(other.read_bytes()).hexdigest()}]})
            inventory.write_text(json.dumps(value))
            self.assertFalse(notices.audit(site, supplements)["passed"])
            value["components"][-1]["checksum"] = "second-hash"
            inventory.write_text(json.dumps(value))
            self.assertTrue(notices.audit(site, supplements)["passed"])
            other.write_bytes(b"changed legal bytes")
            self.assertFalse(notices.audit(site, supplements)["passed"])

    def test_complete_lock_exact_python_version_hash_and_identity_required(self):
        with tempfile.TemporaryDirectory() as directory:
            site, supplements, notice, inventory, path = self.lock_fixture(Path(directory))
            info = site / "tokenizers-0.23.0rc0.dist-info/METADATA"
            info.write_text("Metadata-Version: 2.4\nName: tokenizers\nVersion: 0.23.2\n")
            self.assertTrue(notices.audit(site, supplements)["passed"])
            info.write_text("Metadata-Version: 2.4\nName: tokenizers\nVersion: 0.23.0rc0\n")
            path.write_text(path.read_text() + "\n")
            with self.assertRaisesRegex(notices.PrivacyError, "native-lock-audit-hash-mismatch"):
                notices.audit(site, supplements)
            lock = json.loads(path.read_bytes())
            lock["version"] = "0.23.2"
            path.write_text(json.dumps(lock))
            value = json.loads(inventory.read_bytes())
            value["sourceLockAudits"][0]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            inventory.write_text(json.dumps(value))
            with self.assertRaisesRegex(notices.PrivacyError, "native-lock-audit-version-mismatch"):
                notices.audit(site, supplements)

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
