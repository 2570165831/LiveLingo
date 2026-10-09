"""Exercise the warning gate's full-compile requirement with synthetic inputs only."""

import unittest

import check_build_warnings as gate


PBXPROJ = (
    "/* Begin PBXNativeTarget section */\n"
    "\t\tA50000000000000000000001 /* App */ = {\n"
    "\t\t\tisa = PBXNativeTarget;\n"
    "\t\t\tbuildPhases = (\n"
    "\t\t\t\tA90000000000000000000001 /* Sources */,\n"
    "\t\t\t\tA60000000000000000000001 /* Frameworks */,\n"
    "\t\t\t);\n"
    "\t\t\tname = App;\n"
    "\t\t};\n"
    "\t\tA50000000000000000000002 /* AppTests */ = {\n"
    "\t\t\tisa = PBXNativeTarget;\n"
    "\t\t\tbuildPhases = (\n"
    "\t\t\t\tA90000000000000000000002 /* Sources */,\n"
    "\t\t\t);\n"
    "\t\t\tname = AppTests;\n"
    "\t\t};\n"
    "\t\tA90000000000000000000001 /* Sources */ = {\n"
    "\t\t\tisa = PBXSourcesBuildPhase;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tB10000000000000000000001 /* First.swift in Sources */,\n"
    "\t\t\t\tB10000000000000000000002 /* Second File.swift in Sources */,\n"
    "\t\t\t\tB10000000000000000000003 /* Bridge.m in Sources */,\n"
    "\t\t\t);\n"
    "\t\t};\n"
    "\t\tA90000000000000000000002 /* Sources */ = {\n"
    "\t\t\tisa = PBXSourcesBuildPhase;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tB20000000000000000000001 /* FirstTests.swift in Sources */,\n"
    "\t\t\t);\n"
    "\t\t};\n"
)
SOURCES = "/synthetic/source\\ tree"


def compile_line(target, *files):
    paths = " ".join(f"{SOURCES}/{name.replace(' ', chr(92) + ' ')}" for name in files)
    return f"SwiftCompile normal arm64 {paths} (in target '{target}' from project 'App')\n"


class FullCompileGateTests(unittest.TestCase):
    def test_project_sources_are_read_per_target(self):
        self.assertEqual(gate.target_sources(PBXPROJ, ["App", "AppTests"]), {
            "App": {"First.swift", "Second File.swift"},
            "AppTests": {"FirstTests.swift"},
        })

    def test_full_compile_of_both_targets_passes(self):
        lines = [
            compile_line("App", "First.swift"),
            "SwiftCompile normal arm64 Compiling\\ First.swift,\\ Second\\ File.swift "
            f"{SOURCES}/First.swift {SOURCES}/Second\\ File.swift (in target 'App' from project 'App')\n",
            compile_line("AppTests", "FirstTests.swift"),
        ]
        self.assertEqual(gate.missing_compiles(lines, PBXPROJ, ["App", "AppTests"]), [])

    def test_no_op_incremental_or_wrong_target_compile_fails(self):
        cases = {
            "no-op": [],
            "incremental": [compile_line("App", "First.swift"),
                            compile_line("AppTests", "FirstTests.swift")],
            "other target": [compile_line("AppTests", "First.swift", "Second File.swift",
                                          "FirstTests.swift")],
            "driver only": ["SwiftDriver App normal arm64 com.apple.xcode.tools.swift.compiler "
                            "(in target 'App' from project 'App')\n",
                            compile_line("AppTests", "FirstTests.swift")],
        }
        for label, lines in cases.items():
            with self.subTest(label=label):
                errors = gate.missing_compiles(lines, PBXPROJ, ["App", "AppTests"])
                self.assertTrue(errors)
                self.assertTrue(any("target App:" in error for error in errors))

    def test_unknown_target_fails_closed(self):
        self.assertTrue(gate.missing_compiles([], PBXPROJ, ["Missing"]))

    def test_existing_warning_detection_is_unchanged(self):
        lines = ["/synthetic/First.swift:1:1: warning: synthetic\n",
                 "--- xcodebuild: WARNING: Using the first of multiple matching destinations:\n"]
        self.assertEqual(gate.check(lines), [(1, "/synthetic/First.swift:1:1: warning: synthetic")])


if __name__ == "__main__":
    unittest.main()
