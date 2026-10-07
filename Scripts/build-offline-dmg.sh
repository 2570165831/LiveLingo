#!/bin/zsh
# Build the drag-install LiveLingo DMG (Apple Silicon, macOS 14+).
#
# The DMG only accepts an app that was already assembled by
# Scripts/bundle-mlx-app.py and fully signed by Scripts/sign-offline-app.py. It
# stages the app at the top level next to an /Applications symlink and a short
# readme; there is no Payload directory, no .command installer and no verify
# script. The historical Packaging/install.command and Packaging/verify.command
# stay in the repository and are deliberately not packaged.
#
# Signing materials are not stored here. The signing identity has no default:
# pass --identity or set LIVELINGO_SIGN_IDENTITY. An absent identity is a hard
# error; this script never falls back to a local, ad-hoc or previously used
# identity. Credentials stay in a local notarytool keychain profile. Notarize a
# ZIP of the staged App, staple/validate the App, then create/sign/notarize/staple
# the DMG and verify its mounted payload. Never use notarytool --wait: 0.2.0 saw
# exit 138 with --wait and a submission pending for nine hours. The helper polls
# by ID with deadlines and retry limits; an uncertain upload is never resubmitted.
# This script uploads release artifacts when run normally; --dry-run runs none
# of these tools. Neither mode installs anything or claims clean-machine QA.
set -euo pipefail

project_root="${0:A:h:h}"
sign_script="${project_root}/Scripts/sign-offline-app.py"
readme_source="${project_root}/Packaging/README-zh-Hans.txt"
notary_script="${project_root}/Scripts/notarize-artifact.py"
verify_script="${project_root}/Scripts/verify-release-dmg.sh"

# stdlib-only helpers; prefer the system interpreter, fall back to PATH.
if [[ -n "${LIVELINGO_PYTHON:-}" ]]; then
  python_bin="${LIVELINGO_PYTHON}"
elif [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'pass' >/dev/null 2>&1; then
  python_bin="/usr/bin/python3"
else
  python_bin="$(/usr/bin/which python3 2>/dev/null || print -r -- /usr/bin/python3)"
fi

signed_app="${LIVELINGO_SIGNED_APP:-}"
output_dir="${LIVELINGO_OFFLINE_OUTPUT_DIR:-${project_root}/work/OfflineDMG}"
output_dmg="${LIVELINGO_OFFLINE_DMG:-}"
volume_name="${LIVELINGO_DMG_VOLNAME:-LiveLingo}"
# No default identity and no hard-coded home directory: identity is required,
# and the keychain defaults to the current user's own login keychain.
sign_identity="${LIVELINGO_SIGN_IDENTITY:-}"
current_home="${HOME:-$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')}"
keychain_path="${LIVELINGO_KEYCHAIN_PATH:-${current_home}/Library/Keychains/login.keychain-db}"
# This starting revision documents only a placeholder, not an actual profile
# name. Keep it for dry-run/help, but require an explicit existing profile live.
notary_profile="${LIVELINGO_NOTARY_PROFILE:-<你的 profile>}"
notary_timeout=3600
notary_command_timeout=600
notary_poll_interval=30
notary_max_polls=120
notary_max_retries=3
dry_run=0

usage() {
  print -r -- "用法：Scripts/build-offline-dmg.sh --app <已完整签名的 LiveLingo.app> [选项]"
  print -r -- ""
  print -r -- "  --app <路径>       由 Scripts/bundle-mlx-app.py 组装、Scripts/sign-offline-app.py 完整签名的自包含 App"
  print -r -- "  --output <路径>    DMG 输出路径；默认包含 macOS14+ 与 arm64，已存在时拒绝覆写"
  print -r -- "  --identity <名称>  DMG 签名身份（必填；或用 LIVELINGO_SIGN_IDENTITY 指定）"
  print -r -- "  --keychain <路径>  含匹配私钥的钥匙串（默认当前用户 login.keychain-db；只读使用，脚本不会修改钥匙串）"
  print -r -- "  --volname <名称>   DMG 卷名（默认 LiveLingo）"
  print -r -- "  --notary-profile <名称>  本机已有的公证 keychain profile（或 LIVELINGO_NOTARY_PROFILE；占位符不能用于真实提交）"
  print -r -- "  --notary-timeout <秒>    每件产物提交和轮询的总超时（默认 3600）"
  print -r -- "  --notary-command-timeout <秒>  单次 notarytool 命令超时（默认 600，受总剩余时间限制）"
  print -r -- "  --notary-poll-interval <秒>     查询间隔（默认 30，可用小数）"
  print -r -- "  --notary-max-polls <次数>       最大查询次数，包含失败查询（默认 120）"
  print -r -- "  --notary-max-retries <次数>     连续失败后的重试上限（默认 3；提交不自动重试）"
  print -r -- "  --dry-run          只显示顺序；不签名、不公证、不挂载，不写文件"
  print -r -- "  -h, --help         显示本帮助"
  print -r -- ""
  print -r -- "先生成候选 App："
  print -r -- "  Scripts/bundle-mlx-app.py --app <Release>/LiveLingo.app --runtime <MLXRuntime> \\"
  print -r -- "      --models <模型根目录> --asr-models <ASR 模型根目录> \\"
  print -r -- "      --asr-python <便携完整 Python> --output work/OfflineCandidate/LiveLingo.app"
  print -r -- "  Scripts/sign-offline-app.py --app work/OfflineCandidate/LiveLingo.app \\"
  print -r -- "      --identity \"Developer ID Application: ...\" --certificate <证书> --keychain <钥匙串>"
}

fail() {
  print -u2 "错误：$*"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || fail "--app 缺少参数"
      signed_app="$2"; shift 2 ;;
    --output)
      (( $# >= 2 )) || fail "--output 缺少参数"
      output_dmg="$2"; shift 2 ;;
    --identity)
      (( $# >= 2 )) || fail "--identity 缺少参数"
      sign_identity="$2"; shift 2 ;;
    --keychain)
      (( $# >= 2 )) || fail "--keychain 缺少参数"
      keychain_path="$2"; shift 2 ;;
    --volname)
      (( $# >= 2 )) || fail "--volname 缺少参数"
      volume_name="$2"; shift 2 ;;
    --notary-profile|--notary-timeout|--notary-command-timeout|--notary-poll-interval|--notary-max-polls|--notary-max-retries)
      (( $# >= 2 )) || fail "$1 缺少参数"
      case "$1" in
        --notary-profile) notary_profile="$2" ;;
        --notary-timeout) notary_timeout="$2" ;;
        --notary-command-timeout) notary_command_timeout="$2" ;;
        --notary-poll-interval) notary_poll_interval="$2" ;;
        --notary-max-polls) notary_max_polls="$2" ;;
        --notary-max-retries) notary_max_retries="$2" ;;
      esac
      shift 2 ;;
    --dry-run)
      dry_run=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[[ -n "${output_dmg}" ]] || \
  output_dmg="${output_dir}/LiveLingo-Offline-$(/bin/date +%Y-%m-%d)-macOS14+-arm64.dmg"
# Keep staging next to the DMG unless an explicit staging directory was requested.
[[ -n "${LIVELINGO_OFFLINE_OUTPUT_DIR:-}" ]] || output_dir="${output_dmg:h}"

# Reject invalid bounds before invoking any signing or notarization tool.
"${python_bin}" - "${notary_timeout}" "${notary_command_timeout}" "${notary_poll_interval}" \
  "${notary_max_polls}" "${notary_max_retries}" <<'PY'
import math
import sys
try:
    if not all(math.isfinite(float(v)) and float(v) > 0 for v in sys.argv[1:4]):
        raise ValueError("invalid timeout or interval")
    if int(sys.argv[4]) <= 0 or int(sys.argv[5]) < 0:
        raise ValueError("invalid poll or retry limit")
except (ValueError, OverflowError):
    sys.exit("错误：公证超时和间隔须为有限正数，查询上限须为正整数，重试上限须为非负整数。")
PY

if (( dry_run )); then
  print -r -- "DRY RUN：只显示发布顺序；不修改 App、不生成文件、不访问钥匙串或苹果服务。"
  print -r -- "1. 用 Scripts/sign-offline-app.py 完整签名 App，然后校验签名与自包含结构。"
  print -r -- "2. 暂存 App 副本，用 ditto -c -k --sequesterRsrc --keepParent 创建公证 ZIP。"
  print -r -- "3. 提交 App ZIP（profile: ${notary_profile}），按 submission ID 轮询，禁止 --wait。"
  print -r -- "   每件产物总超时 ${notary_timeout}s；单次命令 ${notary_command_timeout}s；间隔 ${notary_poll_interval}s；最多 ${notary_max_polls} 次查询，连续失败最多重试 ${notary_max_retries} 次。"
  print -r -- "4. Accepted 后，对暂存 App 执行 stapler staple、stapler validate 和严格签名校验。"
  print -r -- "5. 用已装订的 App 创建 DMG，再签名 DMG：${output_dmg}"
  print -r -- "6. 提交 DMG，按 submission ID 轮询到 Accepted，再 staple DMG。"
  print -r -- "7. validate DMG，严格校验签名和镜像，再只读挂载检查内置 App。"
  print -r -- "   内置 App：stapler validate、codesign --verify --deep --strict、spctl --assess --type execute。"
  print -r -- "跳过真实产物检查：dry-run 未执行上述工具；不能视为签名、公证或发布自检通过。"
  exit 0
fi

# APFS staging can share immutable file blocks with the signed input. The
# resulting DMG still contains the full files and depends on nothing outside it.
stage_copy() {
  local source_path="$1" destination_path="$2"
  local source_device filesystem_type
  [[ ! -e "${destination_path}" ]] || fail "暂存目标已存在：${destination_path}"
  source_device="$(/bin/df -P "${source_path}" | /usr/bin/awk 'NR == 2 {print $1}')"
  filesystem_type="$(/usr/sbin/diskutil info -plist "${source_device}" 2>/dev/null | /usr/bin/plutil -extract FilesystemType raw -o - - 2>/dev/null || true)"
  if [[ "${filesystem_type}" == apfs && \
        "$(/usr/bin/stat -f %d "${source_path}")" == "$(/usr/bin/stat -f %d "${destination_path:h}")" ]]; then
    /bin/cp -cR "${source_path}" "${destination_path}"
  else
    /usr/bin/ditto --rsrc --extattr "${source_path}" "${destination_path}"
  fi
}

[[ -n "${signed_app}" ]] || fail "必须用 --app 指定已由 Scripts/sign-offline-app.py 完整签名的自包含 App（用 --help 查看用法）。"
[[ -x "${python_bin}" ]] || fail "找不到可用的 python3：${python_bin}（可用 LIVELINGO_PYTHON 指定）"
[[ -f "${sign_script}" ]] || fail "缺少签名校验脚本：${sign_script}"
[[ -f "${readme_source}" ]] || fail "缺少使用说明：${readme_source}"
[[ -f "${notary_script}" && -f "${verify_script}" ]] || fail "缺少公证或发布自检脚本"
[[ -d "${signed_app}" ]] || fail "App 不存在：${signed_app}"
[[ "${signed_app}" == *.app ]] || fail "不是 .app 目录：${signed_app}"
[[ ! -e "${output_dmg}" && ! -L "${output_dmg}" ]] || fail "输出已存在，未覆盖：${output_dmg}"
[[ "${output_dmg}" == *.dmg ]] || fail "输出路径必须以 .dmg 结尾：${output_dmg}"
[[ -n "${notary_profile//[[:space:]]/}" && "${notary_profile}" != '<你的 profile>' ]] || \
  fail "请用 --notary-profile 或 LIVELINGO_NOTARY_PROFILE 指定本机已有的公证 profile；文档占位符不能提交。"
signed_app="${signed_app:A}"
output_dmg="${output_dmg:a}"
output_dir="${output_dir:a}"

# Signing identity is mandatory and is never downgraded or auto-selected.
[[ -n "${sign_identity}" ]] || \
  fail "缺少签名身份：请用 --identity 或 LIVELINGO_SIGN_IDENTITY 显式提供 Developer ID Application 身份；本脚本不会自动选择、复用或降级签名。"
[[ "${sign_identity}" == "Developer ID Application: "* ]] || \
  fail "签名身份不是 Developer ID Application 身份：${sign_identity}"
[[ -n "${keychain_path}" && "${keychain_path}" == /* ]] || \
  fail "无法确定钥匙串路径；请用 --keychain 或 LIVELINGO_KEYCHAIN_PATH 显式指定当前用户可读的钥匙串。"

required_paths=(
  "Contents/Info.plist"
  "Contents/Resources/LanguageRuntime/worker.py"
  "Contents/Resources/LanguageRuntime/runtime-manifest.json"
  "Contents/Resources/ASRRuntime/qwen_asr_service.py"
  "Contents/Resources/ASRRuntime/python/bin/python3"
  "Contents/Resources/THIRD_PARTY_NOTICES.md"
  "Contents/Resources/LICENSE"
  "Contents/Resources/Models/mlx-community/Qwen3.5-4B-MLX-8bit/config.json"
  "Contents/Resources/Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/config.json"
  "Contents/Resources/Models/mlx-community/parakeet-tdt-0.6b-v2/config.json"
  "Contents/Resources/Models/mlx-community/Qwen3-ASR-1.7B-4bit/config.json"
)
for relative_path in "${required_paths[@]}"; do
  [[ -e "${signed_app}/${relative_path}" ]] || \
    fail "App 不是完整离线候选，缺少：${relative_path}（先用 Scripts/bundle-mlx-app.py 组装）"
done

forbidden_hits="$(/usr/bin/find "${signed_app}" \
  \( -name 'Payload' -o -name '*.command' -o -name '*.xctest' -o -iname '*livelingo-cli*' \
     -o -iname '*virtual*a*player*' -o -iname '*test_qwen_streaming*' \
     -o -iname '*test_qwen_asr_service*' \) -print 2>/dev/null | /usr/bin/head -5 || true)"
[[ -z "${forbidden_hits}" ]] || \
  fail "App 含测试/安装器产物，拒绝打包：${forbidden_hits}"

[[ -d "${keychain_path}" || -f "${keychain_path}" ]] || \
  fail "钥匙串不存在或无法访问：${keychain_path}（仅用于签名与校验，脚本不会修改钥匙串）"

# Structural gate: signature, entitlements, self-containment, macOS 14 min-version.
print "校验已签名自包含 App（签名、entitlement、依赖与 macOS 14 最低版本）…"
"${python_bin}" "${sign_script}" --verify-only --app "${signed_app}" --identity "${sign_identity}"

signature="$(codesign -d --verbose=4 "${signed_app}" 2>&1)"
[[ "${signature}" == *"Authority=${sign_identity}"* ]] || fail "App 签名身份与 ${sign_identity} 不匹配。"

stage_dir="${output_dir}/stage-$(/bin/date +%Y%m%d-%H%M%S)-$$"
package_root="${stage_dir}/LiveLingo"
print "创建 DMG 暂存目录：${package_root}"
/bin/mkdir -p "${output_dir}" "${output_dmg:h}"
/bin/mkdir "${stage_dir}"
/bin/mkdir "${package_root}"

stage_copy "${signed_app}" "${package_root}/LiveLingo.app"
/bin/ln -s /Applications "${package_root}/Applications"
/usr/bin/install -m 0644 "${readme_source}" "${package_root}/使用说明.txt"

# Validate payload entries; Finder may add its harmless .DS_Store metadata.
top_level="$(/bin/ls -A "${package_root}" | /usr/bin/awk '$0 != ".DS_Store"' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "${top_level}" == "Applications LiveLingo.app 使用说明.txt " ]] || \
  fail "DMG 顶层内容不符合预期（${top_level}）；不允许 Payload、安装器或校验脚本。"

notary_args=(
  --profile "${notary_profile}" --keychain "${keychain_path}"
  --timeout "${notary_timeout}" --command-timeout "${notary_command_timeout}"
  --poll-interval "${notary_poll_interval}" --max-polls "${notary_max_polls}"
  --max-retries "${notary_max_retries}"
)
notarize() {
  "${python_bin}" "${notary_script}" --artifact "$1" --receipt-dir "$2" "${notary_args[@]}"
}

# The original signed input remains untouched. Only the staged App is stapled.
# Keep the ZIP and all service output OUTSIDE package_root / the final DMG.
notary_zip="${stage_dir}/LiveLingo-notarization.zip"
print "公证 App ZIP（提交后按编号轮询，不使用 --wait）…"
ditto -c -k --sequesterRsrc --keepParent "${package_root}/LiveLingo.app" "${notary_zip}"
notarize "${notary_zip}" "${stage_dir}/notary-app"
xcrun stapler staple "${package_root}/LiveLingo.app"
xcrun stapler validate "${package_root}/LiveLingo.app"
codesign --verify --deep --strict --verbose=2 "${package_root}/LiveLingo.app"

/bin/mkdir -p "${output_dir}"
print "创建压缩 DMG：${output_dmg}"
hdiutil create \
  -srcfolder "${package_root}" \
  -volname "${volume_name}" \
  -format UDZO \
  -imagekey zlib-level=6 \
  "${output_dmg}"

codesign \
  --force \
  --sign "${sign_identity}" \
  --keychain "${keychain_path}" \
  --timestamp \
  "${output_dmg}"
codesign --verify --strict --verbose=2 "${output_dmg}"
hdiutil verify "${output_dmg}"

print "公证 DMG（提交后按编号轮询，不使用 --wait）…"
notarize "${output_dmg}" "${stage_dir}/notary-dmg"
xcrun stapler staple "${output_dmg}"
/bin/zsh "${verify_script}" --dmg "${output_dmg}" --mount-point "${stage_dir}/verify-mount"

print ""
print "离线 DMG 已生成，App 与 DMG 均已公证装订，最终挂载自检通过：${output_dmg}"
print "暂存 App、公证 ZIP、提交编号和日志保留供复核：${stage_dir}"
print ""
print "本流程的真实产物检查不代替干净 macOS 14 启动、离线 Gatekeeper 和模型功能验收。"
