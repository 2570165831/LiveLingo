"""Relocate generated runtime configuration in copies, without executing input.

Only CPython's generated build dictionary and NumPy/SciPy's generated CONFIG
dictionary are eligible. Other Python files retain their complete AST.
"""
import ast
from pathlib import Path
import shlex

try:
    from .privacy_package import PrivacyError
    from .reviewed_resources import scan_host_paths
except ImportError:
    from privacy_package import PrivacyError
    from reviewed_resources import scan_host_paths


INSTALL_PATHS = {
    "prefix": "", "exec_prefix": "", "BINDIR": "/bin", "EXENAME": "/bin/python3.13",
    "BINLIBDEST": "/lib/python3.13", "CONFINCLUDEDIR": "/include",
    "CONFINCLUDEPY": "/include/python3.13", "INCLUDEDIR": "/include",
    "INCLUDEPY": "/include/python3.13", "DESTLIB": "/lib/python3.13",
    "DESTSHARED": "/lib/python3.13/lib-dynload", "LIBDEST": "/lib/python3.13",
    "LIBDIR": "/lib", "LIBPC": "/lib/pkgconfig", "LIBPL": "/lib/python3.13/config-3.13-darwin",
    "MACHDESTLIB": "/lib/python3.13", "MANDIR": "/share/man", "SCRIPTDIR": "/lib",
    "datarootdir": "/share",
}
BUILD_ONLY = frozenset({
    "COVERAGE_INFO", "COVERAGE_REPORT", "FREEZE_MODULE", "FREEZE_MODULE_BOOTSTRAP",
    "LLVM_PROF_MERGER", "PYTHON_FOR_BUILD", "PYTHON_FOR_FREEZE", "RUNSHARED",
    "TESTPYTHON", "TESTRUNNER", "abs_builddir", "abs_srcdir",
})
RELOCATOR = (
    "import os as _runtime_os\n"
    "_runtime_prefix = _runtime_os.path.dirname(_runtime_os.path.dirname(\n"
    "    _runtime_os.path.dirname(_runtime_os.path.abspath(__file__))))\n"
)


def has_host_path(value):
    try:
        scan_host_paths(value.encode("utf-8"), source_code=True)
    except PrivacyError:
        return True
    return False


def _replace(data, changes):
    lines = data.splitlines(keepends=True)
    offsets, offset = [], 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)
    edits = [(offsets[node.lineno - 1] + node.col_offset,
              offsets[node.end_lineno - 1] + node.end_col_offset,
              replacement.encode("utf-8")) for node, replacement in changes]
    for start, end, replacement in sorted(edits, reverse=True):
        data = data[:start] + replacement + data[end:]
    return data


def prepare_configuration(data, relative):
    """Return bytes and dated-notice field details; fail closed on new layouts."""
    relative = Path(relative)
    sysconfig = relative.name.startswith("_sysconfigdata_") and relative.suffix == ".py"
    scientific = relative.name == "__config__.py" and relative.parent.name in ("numpy", "scipy")
    if not (sysconfig or scientific):
        return data, []
    tree = ast.parse(data)
    assignment = next((node for node in tree.body if isinstance(node, ast.Assign)
                       and any(isinstance(t, ast.Name) and t.id == ("build_time_vars" if sysconfig else "CONFIG")
                               for t in node.targets)), None)
    if assignment is None:
        raise PrivacyError("unrecognized-runtime-configuration-layout")
    value = assignment.value
    if scientific and isinstance(value, ast.Call) and isinstance(value.func, ast.Name) and value.func.id == "_cleanup" and len(value.args) == 1:
        value = value.args[0]
    if not isinstance(value, ast.Dict):
        raise PrivacyError("unrecognized-runtime-configuration-layout")
    edits, details = [], []
    for dictionary in [n for n in ast.walk(value) if isinstance(n, ast.Dict)]:
        for key, literal in zip(dictionary.keys, dictionary.values):
            if not (isinstance(literal, ast.Constant) and isinstance(literal.value, str) and has_host_path(literal.value)):
                continue
            field = ast.literal_eval(key)
            if not isinstance(field, str):
                raise PrivacyError("unrecognized-runtime-configuration-field")
            action = "omit-build-time-location"
            if sysconfig:
                if field in INSTALL_PATHS:
                    replacement = "(_runtime_prefix + " + repr(INSTALL_PATHS[field]) + ")"
                    action = "relocate-install-directory"
                elif field in ("DESTDIRS", "INCLDIRSTOMAKE"):
                    suffixes = ("", "/lib", "/lib/python3.13", "/lib/python3.13/lib-dynload") if field == "DESTDIRS" else ("/include", "/include/python3.13")
                    replacement = "' '.join(_runtime_prefix + part for part in " + repr(suffixes) + ")"
                    action = "relocate-install-directories"
                elif field == "CONFIG_ARGS" or field.endswith(("FLAGS", "FLAGS_NODIST")):
                    # Remove host-bound profile/include/library/configure tokens;
                    # retain architecture, ABI, feature and optimization flags.
                    tokens = shlex.split(literal.value)
                    retained, skip = [], False
                    for index, token in enumerate(tokens):
                        if skip:
                            skip = False
                            continue
                        if token in ("-I", "-L", "-isysroot", "--prefix", "--exec-prefix"):
                            # These two-token forms must not leave a dangling flag.
                            if index + 1 < len(tokens) and has_host_path(tokens[index + 1]):
                                skip = True
                                continue
                        if not has_host_path(token):
                            retained.append(token)
                    replacement = repr(shlex.join(retained))
                    action = "omit-host-bound-build-flags"
                elif field in BUILD_ONLY:
                    replacement = "''"
                else:
                    raise PrivacyError("unrecognized-host-bound-sysconfig-field")
            else:
                if field not in ("path", "include directory", "lib directory", "pc file directory", "commands", "args", "linker args"):
                    raise PrivacyError("unrecognized-host-bound-scientific-config-field")
                replacement = "''"
            edits.append((literal, replacement))
            details.append({"field": field, "action": action})
    if not edits:
        return data, []
    clean = _replace(data, edits)
    # Insert after comments/docstring/future imports so licensing and syntax stay
    # intact. The generated CPython module normally contains one assignment.
    insertion = sum(len(line) for line in clean.splitlines(keepends=True)[:assignment.lineno - 1])
    notice = b"# Modified by Li on 2026-10-11: relocate installed paths and omit build-machine configuration; see MODIFICATIONS.json.\n"
    prefix = notice + (RELOCATOR.encode() if sysconfig else b"")
    clean = clean[:insertion] + prefix + clean[insertion:]
    ast.parse(clean)
    for node in ast.walk(ast.parse(clean)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and has_host_path(node.value):
            raise PrivacyError("runtime-configuration-path-remains")
    return clean, details
