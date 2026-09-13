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
# identity. Notarization credentials are never embedded: notarize and staple the
# finished DMG externally (see the printed instructions at the end). This script
# downloads nothing, installs nothing and does not claim that a clean macOS 14
# machine was verified.
set -euo pipefail

project_root="${0:A:h:h}"
sign_script="${project_root}/Scripts/sign-offline-app.py"
readme_source="${project_root}/Packaging/README-zh-Hans.txt"

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

usage() {
  print -r -- "用法：Scripts/build-offline-dmg.sh --app <已完整签名的 LiveLingo.app> [选项]"
  print -r -- ""
  print -r -- "  --app <路径>       由 Scripts/bundle-mlx-app.py 组装、Scripts/sign-offline-app.py 完整签名的自包含 App"
  print -r -- "  --output <路径>    DMG 输出路径；默认包含 macOS14+ 与 arm64，已存在时拒绝覆写"
  print -r -- "  --identity <名称>  DMG 签名身份（必填；或用 LIVELINGO_SIGN_IDENTITY 指定）"
  print -r -- "  --keychain <路径>  含匹配私钥的钥匙串（默认当前用户 login.keychain-db；只读使用，脚本不会修改钥匙串）"
  print -r -- "  --volname <名称>   DMG 卷名（默认 LiveLingo）"
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
[[ -d "${signed_app}" ]] || fail "App 不存在：${signed_app}"
[[ "${signed_app}" == *.app ]] || fail "不是 .app 目录：${signed_app}"
[[ ! -e "${output_dmg}" ]] || fail "输出已存在，未覆盖：${output_dmg}"

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

signature="$("/usr/bin/codesign" -d --verbose=4 "${signed_app}" 2>&1)"
[[ "${signature}" == *"Authority=${sign_identity}"* ]] || fail "App 签名身份与 ${sign_identity} 不匹配。"

stage_dir="${output_dir}/stage-$(/bin/date +%Y%m%d-%H%M%S)-$$"
package_root="${stage_dir}/LiveLingo"
print "创建 DMG 暂存目录：${package_root}"
/bin/mkdir -p "${package_root}"

stage_copy "${signed_app}" "${package_root}/LiveLingo.app"
/bin/ln -s /Applications "${package_root}/Applications"
/usr/bin/install -m 0644 "${readme_source}" "${package_root}/使用说明.txt"

# Validate payload entries; Finder may add its harmless .DS_Store metadata.
top_level="$(/bin/ls -A "${package_root}" | /usr/bin/awk '$0 != ".DS_Store"' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "${top_level}" == "Applications LiveLingo.app 使用说明.txt " ]] || \
  fail "DMG 顶层内容不符合预期（${top_level}）；不允许 Payload、安装器或校验脚本。"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${package_root}/LiveLingo.app"

/bin/mkdir -p "${output_dir}"
print "创建压缩 DMG：${output_dmg}"
/usr/bin/hdiutil create \
  -srcfolder "${package_root}" \
  -volname "${volume_name}" \
  -format UDZO \
  -imagekey zlib-level=6 \
  "${output_dmg}"

/usr/bin/codesign \
  --force \
  --sign "${sign_identity}" \
  --keychain "${keychain_path}" \
  --timestamp \
  "${output_dmg}"
/usr/bin/codesign --verify --verbose=2 "${output_dmg}"
/usr/bin/hdiutil verify "${output_dmg}"

print ""
print "离线 DMG 已生成并通过签名与 hdiutil 校验：${output_dmg}"
print "暂存目录保留供外部清理或挂载复验：${stage_dir}"
print ""
print "外部公证与装订（凭据不写入本脚本，也不属于仓库内容）："
print "  xcrun notarytool submit \"${output_dmg}\" --keychain-profile \"<你的 profile>\" --wait"
print "  xcrun stapler staple \"${output_dmg}\""
print "  xcrun stapler validate \"${output_dmg}\""
print ""
print "本次只完成脚本组装与静态校验；尚未在干净 macOS 14 实机验收，也不代表已通过 Gatekeeper 分发。"
