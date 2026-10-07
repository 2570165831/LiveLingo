"""Aggregate the synthetic suites without bypassing production path checks.

Run with ``python -m unittest Scripts.target_eval.run_tests``. Each fixture test
sets the output-root environment variable to its own temporary directory; set
``TMPDIR`` to an authorized scratch directory to confine test I/O.
"""
import unittest

from . import test_corpora, test_metrics, test_review


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromModule(module)
                              for module in (test_corpora, test_metrics, test_review))
