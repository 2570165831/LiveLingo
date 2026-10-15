"""Preserve prepared third-party notices when collecting CPython's license."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

from Scripts import privacy_package


def assembler():
    scripts = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("test_unsigned_assembler", scripts / "bundle-mlx-app.py")
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, "path", [str(scripts), *sys.path]):
        spec.loader.exec_module(module)
    return module


class PythonLicenseCollectionTests(unittest.TestCase):
    def test_prepared_source_header_stays_in_its_original_notice_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            own = source / "lib/python3.13/LICENSE.txt"
            own.parent.mkdir(parents=True)
            own.write_bytes(b"Copyright Python Software Foundation\nPermission granted.\n")
            notice = source / "Licenses/embedded-pruned-notices/NOTICE-fixture.txt"
            notice.parent.mkdir(parents=True)
            raw = b"Verbatim source header notice:\n\n/*\nCopyright fixture\nAll rights reserved.\n*/\n"
            notice.write_bytes(raw)
            app = root / "LiveLingo.app"
            runtime = app / "Contents/Resources/ASRRuntime"
            shutil.copytree(source, runtime / "python")
            target = runtime / "Licenses/CPython"
            self.assertEqual(assembler().install_python_licenses(runtime / "python", target), 1)
            self.assertEqual({p.name for p in target.iterdir()}, {"lib__python3.13__LICENSE.txt"})
            self.assertEqual((runtime / "python" / notice.relative_to(source)).read_bytes(), raw)
            self.assertEqual(notice.read_bytes(), raw)
            privacy_package.inspect_tree(app, phase="prepare")

    def test_aggregated_wheel_licenses_and_site_packages_are_not_cpython_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            for name in ("LICENSE", "Licenses/fixture/LICENSE", "site-packages/fixture/LICENSE"):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"Copyright fixture\nPermission granted.\n")
            target = root / "output"
            self.assertEqual(assembler().install_python_licenses(source, target), 1)
            self.assertEqual({p.name for p in target.iterdir()}, {"LICENSE"})


if __name__ == "__main__":
    unittest.main()
