"""Expose the existing offline suites to ``python3 -m unittest`` at repo root.

Scripts and mlx_runtime are namespace directories, which Python 3.13 discovery
otherwise skips. Import test modules explicitly without changing their tests.
"""
from pathlib import Path
import importlib.util
import sys
import unittest


def load_tests(loader: unittest.TestLoader, tests: unittest.TestSuite, pattern: str | None):
    # Synthetic tensor regressions never need a GPU or model weights. Set the
    # device before importing suites that materialize their fixtures.
    # Missing optional MLX must not suppress discovery of the pure-Python
    # suites. Tensor modules declare their own precise dependency skips.
    # Import/API failures in an installed runtime still remain test failures.
    if importlib.util.find_spec("mlx") is not None:
        import mlx.core as mx
        mx.set_default_device(mx.cpu)
    root = Path(__file__).resolve().parent
    # Existing script tests import sibling helpers by their historical names.
    # Match their standalone invocation search path without changing old tests.
    sys.path.insert(0, str(root / "Scripts"))
    sys.path.insert(0, str(root / "Scripts" / "mlx_runtime"))
    suite = unittest.TestSuite()
    for path in sorted((root / "Scripts").rglob("test*.py")):
        # Match unittest discovery: standalone hyphenated CLI/release scripts
        # are separate entry points, not importable discovery modules.
        if not path.stem.isidentifier():
            continue
        # The existing test_target_eval bridge loads the aggregate suite once.
        if path.parent == root / "Scripts" / "target_eval":
            continue
        module = ".".join(path.relative_to(root).with_suffix("").parts)
        try:
            suite.addTests(loader.loadTestsFromName(module))
        except unittest.SkipTest as unavailable:
            # loadTestsFromName propagates import-time skips. Represent just
            # this optional module as skipped and keep discovering the rest.
            def skip_module(reason=str(unavailable)):
                raise unittest.SkipTest(reason)

            skip_module.__name__ = module + ".optional_dependency"
            suite.addTest(unittest.FunctionTestCase(skip_module))
    return suite
