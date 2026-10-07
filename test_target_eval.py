"""Make the offline evaluation suite discoverable by root-level unittest.

Fixture tests configure temporary output roots through the environment;
application and model runtime modules are not imported. Use ``TMPDIR`` to keep
synthetic fixtures in an authorized scratch directory.
"""
from Scripts.target_eval.run_tests import load_tests
