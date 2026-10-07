#!/bin/zsh
# Read-only checks of the FINAL stapled DMG, including the App actually inside it.
set -euo pipefail

dmg=""
mount_dir=""
dry_run=0
fail() { print -u2 -r -- "发布自检失败：$*"; exit 1; }
while (( $# > 0 )); do
  case "$1" in
    --dmg|--mount-point)
      (( $# >= 2 )) || fail "$1 缺少参数"
      if [[ "$1" == --dmg ]]; then dmg="$2"; else mount_dir="$2"; fi
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      print -r -- "用法：Scripts/verify-release-dmg.sh [--dmg <最终 DMG>] [--mount-point <新目录>] [--dry-run]"
      print -r -- "未指定 DMG 或使用 --dry-run 时明确跳过，不代表真实发布验收通过。"
      exit 0 ;;
    *) fail "未知参数：$1" ;;
  esac
done

if [[ -z "${dmg}" ]] || (( dry_run )); then
  print -r -- "跳过真实发布自检：未提供真实产物或使用 --dry-run。"
  print -r -- "未执行 DMG 挂载、App/DMG stapler validate、codesign 验证或 spctl 评估；不能视为发布通过。"
  exit 0
fi
[[ -f "${dmg}" && "${dmg}" == *.dmg ]] || fail "最终 DMG 不存在或不是 .dmg：${dmg}"
dmg="${dmg:A}"

xcrun stapler validate "${dmg}"
codesign --verify --strict --verbose=2 "${dmg}"
hdiutil verify "${dmg}"

if [[ -n "${mount_dir}" ]]; then
  mount_dir="${mount_dir:a}"
  [[ ! -e "${mount_dir}" && ! -L "${mount_dir}" ]] || fail "挂载目录已存在，拒绝复用：${mount_dir}"
  /bin/mkdir "${mount_dir}"
else
  mount_dir="$(/usr/bin/mktemp -d "${dmg:h}/release-check-XXXXXX")"
fi
mounted=0
cleanup() {
  local exit_code=$?
  trap - EXIT
  if (( mounted )); then
    if ! hdiutil detach "${mount_dir}"; then
      print -u2 -r -- "自动卸载失败，请检查本次挂载：${mount_dir}"
      exit_code=1
    fi
  fi
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Arm cleanup before attach so a partially successful attachment is also handled.
mounted=1
hdiutil attach -readonly -nobrowse -mountpoint "${mount_dir}" "${dmg}"
mounted_app="${mount_dir}/LiveLingo.app"
[[ -d "${mounted_app}" && ! -L "${mounted_app}" ]] || fail "DMG 内缺少真实 LiveLingo.app 目录"
xcrun stapler validate "${mounted_app}"
codesign --verify --deep --strict --verbose=2 "${mounted_app}"
spctl --assess --type execute --verbose=2 "${mounted_app}"
hdiutil detach "${mount_dir}"
mounted=0
print -r -- "最终 DMG 发布自检通过：DMG 与内置 App 票据有效，签名有效，内置 App 的 spctl 评估通过。"
