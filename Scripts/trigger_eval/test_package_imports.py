"""Root discovery and standalone entry points work without a sibling search path."""
import os
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PackageImportTests(unittest.TestCase):
    def run_python(self, *arguments):
        environment = os.environ.copy()
        environment.pop('PYTHONPATH', None)
        return subprocess.run([sys.executable, '-B', *arguments], cwd=ROOT,
                              env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, timeout=30)

    def test_root_discovery_loads_both_suites_without_sibling_path(self):
        result = self.run_python('-c', '''
import unittest
loader = unittest.TestLoader()
for name in ('Scripts.trigger_eval.test_simulate', 'Scripts.trigger_eval.test_posthoc'):
    suite = loader.loadTestsFromName(name)
    if loader.errors or suite.countTestCases() == 0:
        raise RuntimeError('Root discovery did not load the evaluation suite')
print('both evaluation suites loaded')
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'both evaluation suites loaded')

    def test_posthoc_help_works_as_script_and_package(self):
        for arguments in (('Scripts/trigger_eval/posthoc.py', '--help'),
                          ('-m', 'Scripts.trigger_eval.posthoc', '--help')):
            with self.subTest(arguments=arguments):
                result = self.run_python(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('--latin-thresholds', result.stdout)
                self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
