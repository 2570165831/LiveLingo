#!/bin/zsh
# Submit an App-only DMG, staple the staged App, then build the release DMG.
# Normal runs upload/sign; --dry-run does neither. Only publish a verified image.
set -euo pipefail
project_root="${0:A:h:h}"
fail() { print -u2 -r -- "错误：$*"; exit 1; }
source "${project_root}/Scripts/release-tools.sh"
python_bin="${LIVELINGO_PYTHON:-/usr/bin/python3}"
[[ "${python_bin}" == /* && -x "${python_bin}" ]] || fail "请用 LIVELINGO_PYTHON 指定可执行的绝对 Python 路径"
sign_script="${project_root}/Scripts/sign-offline-app.py"
readme_source="${project_root}/Packaging/README-zh-Hans.txt"
notary_script="${project_root}/Scripts/notarize-artifact.py"
verify_script="${project_root}/Scripts/verify-release-dmg.sh"
state_script="${project_root}/Scripts/release-state.py"
signed_app="${LIVELINGO_SIGNED_APP:-}"
output_dir="${LIVELINGO_OFFLINE_OUTPUT_DIR:-}"
output_dmg="${LIVELINGO_OFFLINE_DMG:-}"
volume_name="${LIVELINGO_DMG_VOLNAME:-LiveLingo}"
sign_identity="${LIVELINGO_SIGN_IDENTITY:-}"
keychain_path="${LIVELINGO_KEYCHAIN_PATH:-}"
notary_profile="${LIVELINGO_NOTARY_PROFILE:-}"
notary_keychain="${LIVELINGO_NOTARY_KEYCHAIN:-}"
notary_timeout=3600
notary_submit_timeout=0
notary_command_timeout=60
notary_poll_interval=30
notary_max_polls=120
notary_max_retries=3
staple_max_attempts=4
staple_retry_delay=5
resume_stage=""
app_submission_id=""
dmg_submission_id=""
resubmit_incomplete=0
dry_run=0
usage() {
  print -r -- "用法：Scripts/build-offline-dmg.sh --app <已签名 App> --identity <Developer ID Application 身份> [选项]"
  print -r -- "续跑：Scripts/build-offline-dmg.sh --resume-stage <目录> --notary-profile <已有名称> [选项]"
  print -r -- "  --output <新 .dmg 路径>；--keychain <签名钥匙串>；--volname <卷名>"
  print -r -- "  --notary-profile <名称>；--notary-keychain <路径>（独立于签名钥匙串，默认不传）"
  print -r -- "  --notary-submit-timeout <秒>：仅上传，默认 0 不限"
  print -r -- "  --notary-timeout <秒>：上传完成后的处理总时限，默认 3600"
  print -r -- "  --notary-command-timeout <秒>：仅 info/log，默认 60"
  print -r -- "  --notary-poll-interval <秒>（30）；--notary-max-polls <次数>（120）；--notary-max-retries <次数>（3）"
  print -r -- "  --staple-max-attempts <次数>（4）；--staple-retry-delay <秒>（5，指数退避）"
  print -r -- "  --app-submission-id / --dmg-submission-id <已完成上传的编号>：仅在续跑时使用"
  print -r -- "  --resubmit-incomplete：检查回执后明确重新上传未完成/结果不明的产物；旧编号不能续查"
  print -r -- "  --dry-run：只显示步骤，不写文件、不调用发布工具；-h/--help：帮助"
}
while (( $# > 0 )); do
  case "$1" in
    --app|--output|--identity|--keychain|--volname|--notary-profile|--notary-keychain|--notary-timeout|--notary-submit-timeout|--notary-command-timeout|--notary-poll-interval|--notary-max-polls|--notary-max-retries|--staple-max-attempts|--staple-retry-delay|--resume-stage|--app-submission-id|--dmg-submission-id)
      (( $# >= 2 )) || fail "$1 缺少参数"
      case "$1" in
        --app) signed_app="$2" ;;
        --output) output_dmg="$2" ;;
        --identity) sign_identity="$2" ;;
        --keychain) keychain_path="$2" ;;
        --volname) volume_name="$2" ;;
        --notary-profile) notary_profile="$2" ;;
        --notary-keychain) notary_keychain="$2" ;;
        --notary-timeout) notary_timeout="$2" ;;
        --notary-submit-timeout) notary_submit_timeout="$2" ;;
        --notary-command-timeout) notary_command_timeout="$2" ;;
        --notary-poll-interval) notary_poll_interval="$2" ;;
        --notary-max-polls) notary_max_polls="$2" ;;
        --notary-max-retries) notary_max_retries="$2" ;;
        --staple-max-attempts) staple_max_attempts="$2" ;;
        --staple-retry-delay) staple_retry_delay="$2" ;;
        --resume-stage) resume_stage="$2" ;;
        --app-submission-id) app_submission_id="$2" ;;
        --dmg-submission-id) dmg_submission_id="$2" ;;
      esac
      shift 2 ;;
    --resubmit-incomplete) resubmit_incomplete=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数：$1" ;;
  esac
done
"${python_bin}" - "${notary_timeout}" "${notary_command_timeout}" "${notary_poll_interval}" \
  "${staple_retry_delay}" "${notary_submit_timeout}" "${notary_max_polls}" "${notary_max_retries}" "${staple_max_attempts}" <<'BOUNDS'
import math, sys
try:
    if not all(math.isfinite(float(v)) and float(v) > 0 for v in sys.argv[1:5]):
        raise ValueError()
    if not math.isfinite(float(sys.argv[5])) or float(sys.argv[5]) < 0:
        raise ValueError()
    if int(sys.argv[6]) < 1 or int(sys.argv[7]) < 0 or int(sys.argv[8]) < 1:
        raise ValueError()
except (ValueError, OverflowError):
    sys.exit("错误：超时/间隔须为有限正数（上传可为 0），查询/装订次数须为正整数，重试须非负。")
BOUNDS
if (( dry_run )); then
  print -r -- "DRY RUN：隐私检查/严格校验原 App → 暂存并检查 → 生成只含 App 的临时 DMG → 公证 → 装订/验证 App → 检查最终交付目录 → 创建/签名暂存 DMG → 公证/装订 → 挂载自检 → 移到正式输出。"
  print -r -- "上传超时 ${notary_submit_timeout}s（0 不限）；上传完成后处理时限 ${notary_timeout}s；info/log 单次 ${notary_command_timeout}s。"
  print -r -- "跳过真实产物检查：未调用发布工具，不能视为签名、公证或发布验收通过。"
  exit 0
fi
[[ -n "${notary_profile//[[:space:]]/}" && "${notary_profile}" != '<你的 profile>' ]] || fail "请指定本机已有的 --notary-profile；占位符不能提交"
[[ -z "${notary_keychain}" || "${notary_keychain}" == /* ]] || fail "--notary-keychain 必须是绝对路径"
[[ -n "${resume_stage}" || ( -z "${app_submission_id}" && -z "${dmg_submission_id}" && ${resubmit_incomplete} == 0 ) ]] || fail "提交编号/重新提交选项须配合 --resume-stage"
state_get() { "${python_bin}" "${state_script}" get "${state_file}" "$1"; }
state_set() { "${python_bin}" "${state_script}" set "${state_file}" "$1" "$2"; }
if [[ -n "${resume_stage}" ]]; then
  [[ -d "${resume_stage}" && ! -L "${resume_stage}" ]] || fail "续跑目录不存在或是符号链接"
  stage_dir="${resume_stage:A}"
  check_write_path "${stage_dir}"
  state_file="${stage_dir}/release-state.json"
  [[ -f "${state_file}" && ! -L "${state_file}" ]] || fail "缺少本流程的暂存状态文件"
  stored_identity="$(state_get identity)"
  [[ -z "${sign_identity}" || "${sign_identity}" == "${stored_identity}" ]] || fail "续跑身份与原发布不符"
  sign_identity="${stored_identity}"
  stored_keychain="$(state_get keychain)"
  [[ -z "${keychain_path}" || "${keychain_path}" == "${stored_keychain}" ]] || fail "续跑签名钥匙串与原发布不符"
  keychain_path="${stored_keychain}"
  stored_output="$(state_get output)"
  [[ -z "${output_dmg}" || "${output_dmg:a}" == "${stored_output}" ]] || fail "续跑输出路径与原发布不符"
  output_dmg="${stored_output}"
  volume_name="$(state_get volumeName)"
else
  [[ -n "${signed_app}" && -d "${signed_app}" && "${signed_app}" == *.app && ! -L "${signed_app}" ]] || fail "必须用 --app 指定已完整签名的自包含 .app 目录"
  signed_app="${signed_app:A}"
  [[ -n "${output_dmg}" ]] || output_dmg="${output_dir:-${project_root}/work/OfflineDMG}/LiveLingo-Offline-$(/bin/date +%Y-%m-%d)-macOS14+-arm64.dmg"
  output_dmg="${output_dmg:a}"
  output_dir="${output_dir:-${output_dmg:h}}"
  stage_dir="${output_dir:a}/stage-$(/bin/date +%Y%m%d-%H%M%S)-$$"
  state_file="${stage_dir}/release-state.json"
fi
[[ ! -e "${output_dmg}" && ! -L "${output_dmg}" ]] || fail "输出已存在，未覆盖：${output_dmg}"
[[ "${output_dmg}" == *.dmg ]] || fail "输出必须以 .dmg 结尾"
check_write_path "${output_dmg}"
check_write_path "${output_dmg:h}"
check_write_path "${stage_dir}"
check_write_path "${stage_dir:h}"
if [[ -n "${signed_app}" ]]; then
  "${python_bin}" "${state_script}" outside-app "${signed_app}" "${stage_dir}" "${output_dmg}"
fi
[[ "${sign_identity}" == "Developer ID Application: "* ]] || fail "必须显式指定 Developer ID Application --identity"
[[ -n "${keychain_path}" ]] || keychain_path="${HOME}/Library/Keychains/login.keychain-db"
[[ "${keychain_path}" == /* && -f "${keychain_path}" ]] || fail "签名钥匙串不存在或不是绝对文件路径"
for tool in codesign hdiutil ditto stapler; do
  resolve_release_tool "${tool}"
  case "${tool}" in
    codesign) codesign_bin="${REPLY}" ;;
    hdiutil) hdiutil_bin="${REPLY}" ;;
    ditto) ditto_bin="${REPLY}" ;;
    stapler) stapler_bin="${REPLY}" ;;
  esac
done
stage_copy() {
  local source_path="$1" destination_path="$2"
  local source_device filesystem_type
  [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || fail "暂存 App 已存在"
  # Explicit test mode exercises ditto without ever invoking a real release tool.
  filesystem_type=""
  if [[ -z "${LIVELINGO_TEST_TOOL_DIR:-}" ]]; then
    source_device="$(/bin/df -P "${source_path}" | /usr/bin/awk 'NR == 2 {print $1}')"
    filesystem_type="$(/usr/sbin/diskutil info -plist "${source_device}" 2>/dev/null | /usr/bin/plutil -extract FilesystemType raw -o - - 2>/dev/null || true)"
  fi
  if [[ "${filesystem_type}" == apfs && "$(/usr/bin/stat -f %d "${source_path}")" == "$(/usr/bin/stat -f %d "${destination_path:h}")" ]]; then
    /bin/cp -cR "${source_path}" "${destination_path}"
  else
    "${ditto_bin}" --rsrc --extattr "${source_path}" "${destination_path}"
  fi
}
if [[ -z "${resume_stage}" ]]; then
  check_package_privacy "${signed_app}"
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
  # Weights, every indexed shard and loader files; reads only JSON and safetensors headers.
  "${python_bin}" "${project_root}/Scripts/model_files.py" check --app "${signed_app}" || \
    fail "App 内模型文件不完整（缺权重、分片或分词器等），拒绝打包；先用 Scripts/bundle-mlx-app.py 重新组装"

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

  check_authority "${signed_app}" "${sign_identity}"
  /bin/mkdir -p "${stage_dir:h}" "${output_dmg:h}"
  /bin/mkdir -m 700 "${stage_dir}"
  "${python_bin}" "${state_script}" init "${state_file}" identity "${sign_identity}" keychain "${keychain_path}" output "${output_dmg}" volumeName "${volume_name}"
  /bin/mkdir "${stage_dir}/LiveLingo"
  stage_copy "${signed_app}" "${stage_dir}/LiveLingo/LiveLingo.app"
fi
package_root="${stage_dir}/LiveLingo"
staged_app="${package_root}/LiveLingo.app"
[[ -d "${staged_app}" && ! -L "${staged_app}" ]] || fail "暂存 App 缺失或是链接"
[[ "$(/usr/bin/stat -f %d "${stage_dir}")" == "$(/usr/bin/stat -f %d "${output_dmg:h}")" ]] || fail "暂存和正式输出须同卷，确保通过后原子移动"
lock_dir="${stage_dir}/.release-lock"
/bin/mkdir "${lock_dir}" || fail "同一暂存已有执行者/遗留锁，请核实 owner 后处理"
cleanup() {
  local exit_code=$?
  trap - EXIT ZERR
  /bin/rmdir "${lock_dir}" || true
  if (( exit_code != 0 )); then
    print -u2 -r -- "发布未完成，暂存保留：${stage_dir}；修复后用 --resume-stage 续跑。正式输出未放行。"
  fi
  exit "${exit_code}"
}
# zsh skips a plain EXIT trap on some errexit failures inside functions.
trap cleanup EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
print -r -- "本次发布暂存：${stage_dir}"
# Both a fresh copy and a resumed App must pass these before any upload.
if [[ -L "${package_root}/Applications" ]]; then
  check_package_privacy "${package_root}" dmg
else
  check_package_privacy "${package_root}" app-only
fi
"${python_bin}" "${sign_script}" --verify-only --app "${staged_app}" --identity "${sign_identity}"
"${codesign_bin}" --verify --deep --strict --verbose=2 "${staged_app}"
check_authority "${staged_app}" "${sign_identity}"
notary_args=(--profile "${notary_profile}" --timeout "${notary_timeout}" --submit-timeout "${notary_submit_timeout}" --command-timeout "${notary_command_timeout}" --poll-interval "${notary_poll_interval}" --max-polls "${notary_max_polls}" --max-retries "${notary_max_retries}")
[[ -z "${notary_keychain}" ]] || notary_args+=(--notary-keychain "${notary_keychain}")
run_dir="$(/usr/bin/mktemp -d "${stage_dir}/run-XXXXXX")"
print -l -r -- "codesign=${codesign_bin}" "hdiutil=${hdiutil_bin}" "ditto=${ditto_bin}" "stapler=${stapler_bin}" "python=${python_bin}" > "${run_dir}/tool-paths.txt"
notarize_phase() {
  local phase="$1" artifact="$2" requested="$3" decision receipt_dir
  decision="$("${python_bin}" "${state_script}" decision "${state_file}" "${phase}" "${artifact}" "${requested}" "${resubmit_incomplete}")" || fail "无法恢复 ${phase} 提交"
  [[ "${decision}" != accepted ]] || return 0
  receipt_dir="${run_dir}/notary-${phase}"
  "${python_bin}" "${state_script}" prepare-receipt "${state_file}" "${phase}" "${receipt_dir}/receipt.json" "${decision}"
  if [[ "${decision}" == submit ]]; then
    "${python_bin}" "${notary_script}" --artifact "${artifact}" --receipt-dir "${receipt_dir}" "${notary_args[@]}"
  else
    "${python_bin}" "${notary_script}" --artifact "${artifact}" --submission-id "${decision}" --receipt-dir "${receipt_dir}" "${notary_args[@]}"
  fi
}
staple_with_retry() {
  local target="$1" attempt delay="${staple_retry_delay}"
  for (( attempt=1; attempt<=staple_max_attempts; attempt++ )); do
    if "${stapler_bin}" staple "${target}"; then return 0; fi
    (( attempt < staple_max_attempts )) || fail "装订重试耗尽：${target}"
    print -u2 -r -- "票据装订失败，${delay}s 后重试（${attempt}/${staple_max_attempts}）：${target}"
    /bin/sleep "${delay}"
    delay="$("${python_bin}" -c 'import sys; print(float(sys.argv[1])*2)' "${delay}")"
  done
}
app_container="$(state_get appContainer)"
if [[ -z "${app_container}" ]]; then
  [[ "$(/bin/ls -A "${package_root}")" == LiveLingo.app ]] || fail "首次 App 公证容器只能含 LiveLingo.app"
  check_package_privacy "${package_root}" app-only
  app_container="${run_dir}/App-notarization.dmg"
  "${hdiutil_bin}" create -size "$("${python_bin}" "${state_script}" image-size "${package_root}")" -srcfolder "${package_root}" -volname LiveLingoAppNotarization -format UDZO -imagekey zlib-level=6 "${app_container}"
  "${hdiutil_bin}" verify "${app_container}"
  "${python_bin}" "${state_script}" record-artifact "${state_file}" appContainer "${app_container}"
fi
"${python_bin}" "${state_script}" verify-artifact "${state_file}" appContainer
notarize_phase app "${app_container}" "${app_submission_id}"
if [[ "$(state_get appStapled)" != yes ]]; then
  staple_with_retry "${staged_app}"
  "${stapler_bin}" validate "${staged_app}"
  "${codesign_bin}" --verify --deep --strict --verbose=2 "${staged_app}"
  state_set appStapled yes
else
  "${stapler_bin}" validate "${staged_app}"
  "${codesign_bin}" --verify --deep --strict --verbose=2 "${staged_app}"
fi
# The final image uses this exact stapled App; no copying or signing the App now.
if [[ ! -e "${package_root}/Applications" && ! -L "${package_root}/Applications" ]]; then
  /bin/ln -s /Applications "${package_root}/Applications"
fi
[[ -L "${package_root}/Applications" && "$(/usr/bin/readlink "${package_root}/Applications")" == /Applications ]] || fail "应用程序快捷方式不正确"
if [[ ! -e "${package_root}/使用说明.txt" ]]; then
  /usr/bin/install -m 0644 "${readme_source}" "${package_root}/使用说明.txt"
fi
top_level="$(/bin/ls -A "${package_root}" | /usr/bin/awk '$0 != ".DS_Store"' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "${top_level}" == "Applications LiveLingo.app 使用说明.txt " ]] || fail "DMG 顶层内容不符合要求"
check_package_privacy "${package_root}" dmg
staged_dmg="$(state_get releaseDMG)"
if [[ -z "${staged_dmg}" ]]; then
  staged_dmg="${run_dir}/Release.dmg"
  "${hdiutil_bin}" create -size "$("${python_bin}" "${state_script}" image-size "${package_root}")" -srcfolder "${package_root}" -volname "${volume_name}" -format UDZO -imagekey zlib-level=6 "${staged_dmg}"
  "${codesign_bin}" --force --sign "${sign_identity}" --keychain "${keychain_path}" --timestamp "${staged_dmg}"
  "${codesign_bin}" --verify --strict --verbose=2 "${staged_dmg}"
  "${hdiutil_bin}" verify "${staged_dmg}"
  check_authority "${staged_dmg}" "${sign_identity}"
  "${python_bin}" "${state_script}" record-artifact "${state_file}" releaseDMG "${staged_dmg}"
else
  "${python_bin}" "${state_script}" verify-artifact "${state_file}" releaseDMG
  "${codesign_bin}" --verify --strict --verbose=2 "${staged_dmg}"
  "${hdiutil_bin}" verify "${staged_dmg}"
  check_authority "${staged_dmg}" "${sign_identity}"
fi
notarize_phase dmg "${staged_dmg}" "${dmg_submission_id}"
verified_dmg="$(state_get stapledDMG)"
if [[ -z "${verified_dmg}" ]]; then
  # Never mutate the Accepted upload. If interrupted during staple/hash, retry
  # a new working copy; the signed original and its receipt remain reusable.
  verified_dmg="${run_dir}/Release-stapled.dmg"
  stage_copy "${staged_dmg}" "${verified_dmg}"
  staple_with_retry "${verified_dmg}"
  "${stapler_bin}" validate "${verified_dmg}"
  "${codesign_bin}" --verify --strict --verbose=2 "${verified_dmg}"
  "${python_bin}" "${state_script}" record-artifact "${state_file}" stapledDMG "${verified_dmg}"
else
  "${python_bin}" "${state_script}" verify-artifact "${state_file}" stapledDMG
fi
/bin/zsh "${verify_script}" --dmg "${verified_dmg}" --identity "${sign_identity}" --mount-point "${stage_dir}/verify-mount"
[[ ! -e "${output_dmg}" && ! -L "${output_dmg}" ]] || fail "自检期间正式输出被占用，拒绝覆盖"
/bin/mv -n "${verified_dmg}" "${output_dmg}"
[[ ! -e "${verified_dmg}" && -f "${output_dmg}" ]] || fail "正式输出移动未完成，未放行"
state_set publishedOutput "${output_dmg}"
print -r -- "离线 DMG 已生成，App 与 DMG 已公证装订，最终挂载自检通过：${output_dmg}"
print -r -- "暂存 App、App 公证临时 DMG、提交回执及日志保留：${stage_dir}"
print -r -- "真实发布仍须干净 macOS 14 离线 Gatekeeper、启动和模型功能验收。"
