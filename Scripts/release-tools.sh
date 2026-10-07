# Shared zsh helpers. Production never takes release tools from an ambient PATH.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

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

check_authority() {
  local target="$1" identity="$2" details
  details="$("${codesign_bin}" -d --verbose=4 "${target}" 2>&1)" || fail "无法读取签名：${target}"
  print -r -- "${details}" | /usr/bin/grep -Fqx -- "Authority=${identity}" || \
    fail "签名身份与预期不符：${target}"
}
