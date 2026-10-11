#!/usr/bin/env python3
"""Build-manifest regression for build-learning-quality-cli.sh.

`xcrun` is replaced by a stub on PATH, so no compiler, App, model or MLX
runtime is used. Sources live in a synthetic SOURCE_ROOT; the two real CLI
entry files are only read and hashed.
"""
from __future__ import annotations
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

import test_learning_quality as quality

HERE = Path(__file__).resolve().parent
BUILD = HERE / 'build-learning-quality-cli.sh'
MANIFEST = 'quality-build-manifest.json'
FAKE_XCRUN = """#!/bin/bash
out=""; prev=""
for arg in "$@"; do
    if [[ "$prev" == -o ]]; then out="$arg"; fi
    prev="$arg"
done
case "${FAKE_XCRUN_MODE:-ok}" in
    fail) exit 7;;
    touch) printf '// edited during build\\n' >> "$FAKE_XCRUN_TOUCH";;
esac
printf 'stub learning-quality-cli\\n' > "$out"
"""
sha = lambda data: hashlib.sha256(data).hexdigest()


class QualityBuildManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        location = os.environ.get('LIVELINGO_QUALITY_TEST_DIRECTORY')
        if not location:
            temporary = tempfile.TemporaryDirectory(prefix='livelingo-quality-build-')
            cls.addClassCleanup(temporary.cleanup)
            location = temporary.name
        cls.root = Path(location)
        if not cls.root.is_absolute(): raise RuntimeError('Test directory must be absolute')
        cls.root.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix=self._testMethodName + '.', dir=self.root))
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        bin_dir = self.work / 'bin'
        bin_dir.mkdir()
        xcrun = bin_dir / 'xcrun'
        xcrun.write_text(FAKE_XCRUN)
        xcrun.chmod(stat.S_IRWXU)
        self.sources = self.work / 'source root' / 'LiveLingo' / 'Sources'
        self.sources.mkdir(parents=True)
        for name in ('LearningNotes.swift', 'Other Model.swift', 'ContentView.swift'):
            (self.sources / name).write_text(f'// {name}\n')
        self.output = self.work / 'build out'
        self.env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}")
        self.env.pop('LIVELINGO_QUALITY_MODULE_CACHE', None)

    def build(self, mode='ok'):
        env = dict(self.env, FAKE_XCRUN_MODE=mode, FAKE_XCRUN_TOUCH=str(self.sources / 'LearningNotes.swift'))
        return subprocess.run(['/bin/bash', str(BUILD), str(self.output), str(self.sources.parent.parent)],
                              env=env, capture_output=True, text=True, timeout=60)

    def test_build_writes_manifest_the_evaluator_accepts(self):
        completed = self.build()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        path = self.output / MANIFEST
        self.assertTrue(path.is_file(), 'build must write quality-build-manifest.json next to the binary')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        manifest = json.loads(path.read_bytes())
        executable = (self.output / 'learning-quality-cli').read_bytes()
        self.assertEqual(manifest['executableSHA256'], sha(executable))
        self.assertIs(manifest['sourcesUnchangedDuringBuild'], True)
        self.assertEqual(manifest['exitCode'], 0)
        self.assertEqual(manifest['purpose'], 'production-quality-probe')
        hashes = manifest['sourceHashes']
        self.assertEqual(set(hashes), {'LiveLingo/Sources/LearningNotes.swift', 'LiveLingo/Sources/Other Model.swift',
                                       'Scripts/livelingo-cli.swift', 'Scripts/learning-quality-cli.swift'})
        self.assertEqual(hashes['LiveLingo/Sources/LearningNotes.swift'],
                         sha((self.sources / 'LearningNotes.swift').read_bytes()))
        self.assertEqual(hashes['Scripts/learning-quality-cli.swift'],
                         sha((HERE / 'learning-quality-cli.swift').read_bytes()))
        self.assertNotIn(str(self.work), path.read_text())

        # Same contract check the evaluator applies to a real-model result.
        probe = self.work / 'probe'
        case, gold, result = quality.make_probe(probe)
        result = copy.deepcopy(result)
        result['producer'].update(generationOrigin='production-model', executableSHA256=manifest['executableSHA256'],
                                  buildManifestSHA256=sha(path.read_bytes()))
        shutil.copyfile(path, probe / MANIFEST)
        report = quality.scorer.evaluate_case(gold, case, result, directory=probe,
                                              fixture_sha=result['fixtureSHA256'])
        self.assertEqual(report['integrityStatus'], 'pass', report)

    def test_failed_compile_propagates_exit_code_without_manifest(self):
        completed = self.build('fail')
        self.assertEqual(completed.returncode, 7)
        self.assertFalse((self.output / MANIFEST).exists())

    def test_source_change_during_build_writes_no_manifest(self):
        completed = self.build('touch')
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('Sources changed during build', completed.stderr)
        self.assertFalse((self.output / MANIFEST).exists())


if __name__ == '__main__':
    unittest.main()
