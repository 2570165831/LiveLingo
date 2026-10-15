# Shared zsh helpers. Production never takes release tools from an ambient PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

require_publication_python() {
  # Hash-bound resources and Cargo/source TOML parsing need the 3.11 stdlib.
  # Run before any staging, signature, upload or mount operation.
  "${python_bin}" - <<'PYTHON_VERSION'
import sys
if sys.version_info < (3, 11):
    sys.exit("发布工具需要 Python 3.11 或更新版本；请用 LIVELINGO_PYTHON 指定宿主解释器的绝对路径，不能使用 App 内的 Python。")
PYTHON_VERSION
}

resolve_release_tool() {
  local name="$1" resolved
  if [[ -n "${LIVELINGO_TEST_TOOL_DIR:-}" ]]; then
    [[ "${LIVELINGO_TEST_TOOL_DIR}" == /* ]] || fail "测试工具目录必须是绝对路径"
    resolved="${LIVELINGO_TEST_TOOL_DIR}/${name}"
  elif [[ "${name}" == stapler ]]; then
    resolved="$(/usr/bin/xcrun -f stapler)" || fail "无法解析 stapler"
  elif [[ "${name}" == spctl ]]; then
    resolved=/usr/sbin/spctl
  else
    resolved="/usr/bin/${name}"
  fi
  [[ "${resolved}" == /* && -x "${resolved}" ]] || fail "发布工具不可执行：${resolved}"
  print -u2 -r -- "发布工具 ${name}: ${resolved}"
  REPLY="${resolved}"
}

check_write_path() {
  "${python_bin}" "${project_root}/Scripts/release-state.py" safe-path "$1"
}

check_package_privacy() {
  # Read-only: a signed/stapled artifact must be rebuilt, never cleaned in place.
  "${python_bin}" "${project_root}/Scripts/privacy_package.py" check --root "$1" --layout "${2:-tree}"
}

check_authority() {
  local target="$1" identity="$2" details
  details="$("${codesign_bin}" -d --verbose=4 "${target}" 2>&1)" || fail "无法读取签名：${target}"
  print -r -- "${details}" | /usr/bin/grep -Fqx -- "Authority=${identity}" || \
    fail "签名身份与预期不符：${target}"
}
