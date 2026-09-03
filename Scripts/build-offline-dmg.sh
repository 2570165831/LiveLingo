#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
release_app="${LIVELINGO_RELEASE_APP:-${project_root}/work/ReleaseDerivedData/Build/Products/Release/LiveLingo.app}"
portable_python="${LIVELINGO_PORTABLE_PYTHON:-/private/tmp/LiveLingoRuntimeRelocated-20260903/python}"
lm_studio_dmg="${LIVELINGO_LM_STUDIO_DMG:-/private/tmp/LM-Studio-0.4.23-1-arm64.dmg}"
output_dir="${LIVELINGO_OFFLINE_OUTPUT_DIR:-${project_root}/work/OfflineDMG}"
output_dmg="${LIVELINGO_OFFLINE_DMG:-${output_dir}/LiveLingo-Offline-2026-09-03-arm64.dmg}"
stage_dir="${output_dir}/stage-$(/bin/date +%Y%m%d-%H%M%S)-$$"
package_root="${stage_dir}/LiveLingo 全离线安装包"

sign_identity="${LIVELINGO_SIGN_IDENTITY:-Developer ID Application: Jianhong Li (6L6KQXUJM3)}"
keychain_path="${LIVELINGO_KEYCHAIN_PATH:-/Users/li/Library/Keychains/login.keychain-db}"

fail() {
  print -u2 "错误：$*"
  exit 1
}

[[ -d "${release_app}" ]] || fail "Release App 不存在：${release_app}"
[[ -x "${portable_python}/bin/python3" ]] || fail "便携 Python 不存在：${portable_python}"
[[ -f "${lm_studio_dmg}" ]] || fail "LM Studio DMG 不存在：${lm_studio_dmg}"
[[ ! -e "${output_dmg}" ]] || fail "输出已存在，未覆盖：${output_dmg}"

model_sources=(
  "/Users/li/.lmstudio/models/mlx-community/parakeet-tdt-0.6b-v2"
  "/Users/li/.lmstudio/models/mlx-community/Qwen3-ASR-1.7B-4bit"
  "/Users/li/.lmstudio/models/mlx-community/Qwen3.5-4B-MLX-8bit"
  "/Users/li/.lmstudio/models/lmstudio-community/Qwen3.5-9B-MLX-4bit"
)
for source_path in "${model_sources[@]}"; do
  [[ -d "${source_path}" ]] || fail "模型目录不存在：${source_path}"
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "${release_app}"
signature="$('/usr/bin/codesign' -d --verbose=4 "${release_app}" 2>&1)"
[[ "${signature}" == *"Authority=${sign_identity}"* ]] || fail "Release App 签名身份不匹配。"
/usr/bin/hdiutil verify "${lm_studio_dmg}"
actual_lm_hash="$(/usr/bin/shasum -a 256 "${lm_studio_dmg}" | /usr/bin/awk '{print $1}')"
[[ "${actual_lm_hash}" == "f450f510d975608a45fbf54cd892915c285066cc07cbf3441d7ddb0ba3329f0e" ]] \
  || fail "LM Studio DMG SHA-256 不匹配。"

print "创建离线包暂存目录：${package_root}"
/bin/mkdir -p \
  "${package_root}/Payload/ASRService" \
  "${package_root}/Payload/Models/mlx-community" \
  "${package_root}/Payload/Models/lmstudio-community" \
  "${package_root}/Payload/LMStudio" \
  "${package_root}/Payload/LMStudioHub/qwen"

/usr/bin/ditto --rsrc --extattr "${release_app}" "${package_root}/Payload/LiveLingo.app"
/usr/bin/ditto "${portable_python}" "${package_root}/Payload/ASRService/python"
/usr/bin/install -m 0644 "${project_root}/Scripts/qwen_asr_service.py" \
  "${package_root}/Payload/ASRService/qwen_asr_service.py"

for source_path in "${model_sources[@]}"; do
  organization="${source_path:h:t}"
  model_name="${source_path:t}"
  /usr/bin/ditto "${source_path}" \
    "${package_root}/Payload/Models/${organization}/${model_name}"
done

/usr/bin/ditto "/Users/li/.lmstudio/hub/models/qwen/qwen3.5-9b" \
  "${package_root}/Payload/LMStudioHub/qwen/qwen3.5-9b"
/usr/bin/ditto "${lm_studio_dmg}" \
  "${package_root}/Payload/LMStudio/LM-Studio-0.4.23-1-arm64.dmg"

/usr/bin/install -m 0755 "${project_root}/Packaging/install.command" \
  "${package_root}/安装 LiveLingo.command"
/usr/bin/install -m 0755 "${project_root}/Packaging/verify.command" \
  "${package_root}/验证安装包.command"
/usr/bin/install -m 0644 "${project_root}/Packaging/README-zh-Hans.txt" \
  "${package_root}/使用说明.txt"
/usr/bin/install -m 0644 "${project_root}/Packaging/THIRD_PARTY_NOTICES.md" \
  "${package_root}/THIRD_PARTY_NOTICES.md"

print "生成全文件 SHA-256 清单…"
(
  cd "${package_root}"
  : > SHA256SUMS.txt
  while IFS= read -r -d '' file_path; do
    relative="${file_path#./}"
    [[ "${relative}" == "SHA256SUMS.txt" ]] && continue
    hash="$(/usr/bin/shasum -a 256 "${relative}" | /usr/bin/awk '{print $1}')"
    print -r -- "${hash}  ${relative}" >> SHA256SUMS.txt
  done < <(/usr/bin/find . -type f -print0 | /usr/bin/sort -z)
)

print "暂存包自检…"
LIVELINGO_NONINTERACTIVE=1 "${package_root}/验证安装包.command"
/bin/mkdir -p "${stage_dir}/DryRunHome" "${stage_dir}/DryRunApplications"
LIVELINGO_NONINTERACTIVE=1 \
LIVELINGO_DRY_RUN=1 \
LIVELINGO_USER_HOME="${stage_dir}/DryRunHome" \
LIVELINGO_APPLICATIONS_DIR="${stage_dir}/DryRunApplications" \
  "${package_root}/安装 LiveLingo.command"

/bin/mkdir -p "${output_dir}"
print "创建压缩 DMG：${output_dmg}"
/usr/bin/hdiutil create \
  -srcfolder "${package_root}" \
  -volname "LiveLingo Offline" \
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

print "离线 DMG 已生成并校验：${output_dmg}"
print "暂存目录保留至最终挂载验收完成：${stage_dir}"
