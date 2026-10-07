"""Aggregate the synthetic suites without bypassing production path checks.

Run with ``python -m unittest Scripts.target_eval.run_tests``. Each fixture test
sets the output-root environment variable to its own temporary directory; set
``TMPDIR`` to an authorized scratch directory to confine test I/O.
"""
import unittest

from . import test_calibrate, test_corpora, test_metrics, test_public_calibration, test_recompute_es_zh_length, test_review, test_review_sidecar, test_run_strategies


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromModule(module)
                              for module in (test_corpora, test_metrics, test_review,
                                             test_calibrate, test_public_calibration, test_review_sidecar, test_run_strategies,
                                             test_recompute_es_zh_length))
