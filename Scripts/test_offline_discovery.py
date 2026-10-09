"""Missing optional runtimes must not prevent independent offline discovery."""
import sys
import unittest
from unittest.mock import Mock, patch

import test_offline_suite as bridge


class OfflineDiscoveryTests(unittest.TestCase):
    def test_missing_optional_module_keeps_pure_python_tests_runnable(self):
        observed = []

        def load(name):
            if name == "Scripts.mlx_runtime.test_checkpoints":
                raise unittest.SkipTest("synthetic optional CPU package is absent")
            if name == "Scripts.test_livelingo_scoreboard":
                return unittest.TestSuite([unittest.FunctionTestCase(
                    lambda: observed.append("pure Python test ran"))])
            return unittest.TestSuite()

        loader = Mock(spec=unittest.TestLoader)
        loader.loadTestsFromName.side_effect = load
        with patch.object(bridge.importlib.util, "find_spec", return_value=None), \
                patch.object(sys, "path", list(sys.path)):
            suite = bridge.load_tests(loader, unittest.TestSuite(), None)
        result = unittest.TestResult()
        suite.run(result)
        self.assertEqual(observed, ["pure Python test ran"])
        self.assertEqual(result.testsRun, 2)
        self.assertEqual(len(result.skipped), 1)
        self.assertEqual(result.skipped[0][1], "synthetic optional CPU package is absent")
        self.assertTrue(result.wasSuccessful())

    def test_installed_runtime_errors_are_not_converted_to_skips(self):
        loader = Mock(spec=unittest.TestLoader)
        loader.loadTestsFromName.side_effect = RuntimeError("synthetic installed API failure")
        with patch.object(bridge.importlib.util, "find_spec", return_value=None), \
                patch.object(sys, "path", list(sys.path)), \
                self.assertRaisesRegex(RuntimeError, "synthetic installed API failure"):
            bridge.load_tests(loader, unittest.TestSuite(), None)
