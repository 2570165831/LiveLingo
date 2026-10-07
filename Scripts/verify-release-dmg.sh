#!/bin/zsh
# Read-only checks of the exact stapled image and its mounted App.
set -euo pipefail
project_root="${0:A:h:h}"
fail() { print -u2 -r -- "发布自检失败：$*"; exit 1; }
source "${project_root}/Scripts/release-tools.sh"
python_bin="${LIVELINGO_PYTHON:-/usr/bin/python3}"
dmg=""
mount_dir=""
identity=""
detach_max_attempts=3
detach_retry_delay=1
dry_run=0
while (( $# > 0 )); do
  case "$1" in
    --dmg|--mount-point|--identity|--detach-max-attempts|--detach-retry-delay)
      (( $# >= 2 )) || fail "$1 缺少参数"
      case "$1" in
        --dmg) dmg="$2" ;;
        --mount-point) mount_dir="$2" ;;
        --identity) identity="$2" ;;
        --detach-max-attempts) detach_max_attempts="$2" ;;
        --detach-retry-delay) detach_retry_delay="$2" ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      print -r -- "用法：Scripts/verify-release-dmg.sh --dmg <DMG> [--identity <Authority>] [--mount-point <新目录>] [--detach-max-attempts <次数>] [--detach-retry-delay <秒>] [--dry-run]"
      print -r -- "无 DMG 或 dry-run 时明确跳过，不算发布验收。"
      exit 0 ;;
    *) fail "未知参数：$1" ;;
  esac
done
if [[ -z "${dmg}" ]] || (( dry_run )); then
  print -r -- "跳过真实发布自检：未提供真实产物或使用 --dry-run。"
  print -r -- "未挂载、未验证票据/签名、未评估 Gatekeeper；不能视为发布通过。"
  exit 0
fi
[[ -f "${dmg}" && "${dmg}" == *.dmg ]] || fail "最终 DMG 不存在或不是 .dmg：${dmg}"
dmg="${dmg:A}"
[[ "${python_bin}" == /* && -x "${python_bin}" ]] || fail "Python 必须为绝对可执行路径"
"${python_bin}" - "${detach_max_attempts}" "${detach_retry_delay}" <<'PY'
import math, sys
try:
    if int(sys.argv[1]) < 1 or not math.isfinite(float(sys.argv[2])) or float(sys.argv[2]) <= 0:
        raise ValueError()
except (ValueError, OverflowError):
    sys.exit("发布自检失败：卸载次数须为正整数，间隔须为有限正数")
PY
if [[ -n "${mount_dir}" ]]; then
  mount_dir="${mount_dir:a}"
  check_write_path "${mount_dir}"
  check_write_path "${mount_dir:h}"
  [[ ! -e "${mount_dir}" && ! -L "${mount_dir}" ]] || fail "挂载目录已存在，拒绝复用"
else
  check_write_path "${dmg:h}"
fi
for tool in codesign hdiutil stapler spctl; do
  resolve_release_tool "${tool}"
  case "${tool}" in
    codesign) codesign_bin="${REPLY}" ;;
    hdiutil) hdiutil_bin="${REPLY}" ;;
    stapler) stapler_bin="${REPLY}" ;;
    spctl) spctl_bin="${REPLY}" ;;
  esac
done
"${stapler_bin}" validate "${dmg}"
"${codesign_bin}" --verify --strict --verbose=2 "${dmg}"
[[ -z "${identity}" ]] || check_authority "${dmg}" "${identity}"
"${hdiutil_bin}" verify "${dmg}"
assessment="$("${spctl_bin}" --assess --type open --context context:primary-signature --verbose=2 "${dmg}" 2>&1)" || fail "DMG Gatekeeper 评估失败：${assessment}"
[[ "${assessment}" == *"Notarized Developer ID"* ]] || fail "DMG 评估没有返回 Notarized Developer ID：${assessment}"
print -r -- "${assessment}"
if [[ -n "${mount_dir}" ]]; then
  /bin/mkdir "${mount_dir}"
else
  mount_dir="$(/usr/bin/mktemp -d "${dmg:h}/release-check-XXXXXX")"
fi
mounted=0
attach_started=0
detach_failed=0
device=""
detach_image() {
  local attempt
  for (( attempt=1; attempt<=detach_max_attempts; attempt++ )); do
    if "${hdiutil_bin}" detach "${device}"; then mounted=0; return 0; fi
    (( attempt == detach_max_attempts )) || /bin/sleep "${detach_retry_delay}"
  done
  detach_failed=1
  print -u2 -r -- "卸载重试耗尽，请检查设备 ${device}（挂载点 ${mount_dir}）；未报告发布通过。"
  return 1
}
cleanup() {
  local exit_code=$? recovered=""
  trap - EXIT ZERR
  if (( attach_started && ! mounted )); then
    # attach can mount the volume before returning its plist. Recover only this
    # exact image and our unique mount point; never detach an ordinary folder.
    if recovered="$("${hdiutil_bin}" info -plist | "${python_bin}" "${project_root}/Scripts/release-state.py" find-attached-device "${mount_dir}" "${dmg}")"; then
      if [[ -n "${recovered}" ]]; then device="${recovered}"; mounted=1; fi
    else
      print -u2 -r -- "挂载中断后设备查询失败，请检查本次镜像 ${dmg} 和挂载点 ${mount_dir}"
      exit_code=1
    fi
  fi
  if (( mounted && ! detach_failed )); then
    detach_image || exit_code=1
  fi
  if (( ! mounted )); then
    /bin/rmdir "${mount_dir}" || exit_code=1
  fi
  exit "${exit_code}"
}
trap cleanup EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
attach_code=0
attach_started=1
attach_output="$("${hdiutil_bin}" attach -plist -readonly -nobrowse -mountpoint "${mount_dir}" "${dmg}")" || attach_code=$?
# A failed attach may still report an attached device. Clean only that device.
if device="$(print -r -- "${attach_output}" | "${python_bin}" "${project_root}/Scripts/release-state.py" attach-devices)"; then
  mounted=1
  attach_started=0
else
  fail "attach 未返回可清理的设备号（exit ${attach_code}）；未对普通目录执行 detach"
fi
(( attach_code == 0 )) || fail "attach 失败（exit ${attach_code}），清理已返回的设备 ${device}"
mounted_app="${mount_dir}/LiveLingo.app"
[[ -d "${mounted_app}" && ! -L "${mounted_app}" ]] || fail "DMG 内缺少真实 LiveLingo.app 目录"
check_package_privacy "${mount_dir}" dmg
"${stapler_bin}" validate "${mounted_app}"
"${codesign_bin}" --verify --deep --strict --verbose=2 "${mounted_app}"
[[ -z "${identity}" ]] || check_authority "${mounted_app}" "${identity}"
"${spctl_bin}" --assess --type execute --verbose=2 "${mounted_app}"
detach_image || fail "自检结束但镜像仍挂载"
print -r -- "最终 DMG 发布自检通过：DMG 与内置 App 票据、严格签名和 Gatekeeper 评估通过。"
