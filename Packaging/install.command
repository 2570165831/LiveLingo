#!/bin/zsh
# LEGACY installer for the historical `Payload/` transfer layout. The current
# pipeline produces a self-contained DMG instead (see README.md); this script is
# retained for reference and for validating or installing an older package.
set -euo pipefail

script_dir="${LIVELINGO_PACKAGE_ROOT:-${0:A:h}}"
payload_dir="${script_dir}/Payload"
verify_script="${script_dir}/验证安装包.command"
[[ -x "${verify_script}" ]] || verify_script="${script_dir}/verify.command"

pause_on_exit() {
  exit_code=$?
  trap - EXIT
  if [[ "${LIVELINGO_NONINTERACTIVE:-0}" != "1" ]]; then
    print
    if (( exit_code == 0 )); then
      print "安装流程结束。按任意键关闭。"
    else
      print -u2 "安装未完成；原数据没有被静默覆盖。按任意键关闭。"
    fi
    read -k 1 -s
    print
  fi
  exit "${exit_code}"
}
trap pause_on_exit EXIT

fail() {
  print -u2 "错误：$*"
  exit 1
}

same_tree() {
  /usr/bin/diff -qr "$1" "$2" >/dev/null 2>&1
}

[[ -d "${payload_dir}" ]] || fail "离线包 Payload 缺失。"
[[ -x "${verify_script}" ]] || fail "找不到可执行的校验脚本。"

machine="$(/usr/bin/uname -m)"
[[ "${machine}" == "arm64" ]] || fail "本安装包只支持 Apple Silicon Mac。"
os_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
[[ "${os_major}" == <-> ]] || fail "无法识别 macOS 版本。"
(( os_major >= 14 )) || fail "需要 macOS 14.0 或更高版本。"

current_user="$(/usr/bin/id -un)"
current_uid="$(/usr/bin/id -u)"
directory_home="$(/usr/bin/dscl . -read "/Users/${current_user}" NFSHomeDirectory 2>/dev/null \
  | /usr/bin/awk '{print $2}')"
user_home="${LIVELINGO_USER_HOME:-${directory_home}}"
applications_dir="${LIVELINGO_APPLICATIONS_DIR:-/Applications}"

[[ "${user_home}" == /* && "${user_home}" != "/" && "${user_home}" != "/Users" ]] \
  || fail "用户目录不安全：${user_home}"
[[ -d "${user_home}" ]] || fail "用户目录不存在：${user_home}"
[[ "${applications_dir}" == /* && "${applications_dir}" != "/" ]] \
  || fail "应用目录不安全：${applications_dir}"
[[ -d "${applications_dir}" ]] || fail "应用目录不存在：${applications_dir}"

available_kb="$(/bin/df -Pk "${user_home}" | /usr/bin/awk 'NR == 2 {print $4}')"
[[ "${available_kb}" == <-> ]] || fail "无法读取磁盘剩余空间。"
if (( available_kb < 20 * 1024 * 1024 )); then
  fail "至少需要 20 GB 可用空间；当前不足。"
fi

print "先执行完整离线包校验。"
LIVELINGO_NONINTERACTIVE=1 /bin/zsh "${verify_script}"

app_source="${payload_dir}/LiveLingo.app"
app_target="${applications_dir}/LiveLingo.app"
service_source="${payload_dir}/ASRService"
service_target="${user_home}/Library/Application Support/LiveLingo/ASRService"
launch_agents_dir="${user_home}/Library/LaunchAgents"
logs_dir="${user_home}/Library/Logs/LiveLingo"
launch_agent="${launch_agents_dir}/com.jianhongli.LiveLingoASR.plist"
models_source="${payload_dir}/Models"
models_target="${user_home}/Library/Application Support/LiveLingo/Models"

model_relatives=(
  "mlx-community/parakeet-tdt-0.6b-v2"
  "mlx-community/Qwen3-ASR-1.7B-4bit"
)

print "预检同名模型和现有应用…"
for relative in "${model_relatives[@]}"; do
  source_path="${models_source}/${relative}"
  target_path="${models_target}/${relative}"
  [[ -d "${source_path}" ]] || fail "离线模型目录缺失：${relative}"
  if [[ -e "${target_path}" ]] && ! same_tree "${source_path}" "${target_path}"; then
    fail "已有同名模型内容不同，未覆盖：${target_path}"
  fi
done

if [[ "${LIVELINGO_DRY_RUN:-0}" == "1" ]]; then
  print "预检通过（dry run）；没有改动本机。"
  exit 0
fi

backup_root="${user_home}/Library/Application Support/LiveLingo/Installer Backups/$(/bin/date +%Y%m%d-%H%M%S)-$$"
/bin/mkdir -p "${backup_root}" "${launch_agents_dir}" "${logs_dir}" "${models_target}"

service_domain="gui/${current_uid}"
service_target_name="${service_domain}/com.jianhongli.LiveLingoASR"
if [[ "${LIVELINGO_SKIP_LAUNCHCTL:-0}" != "1" && -f "${launch_agent}" ]]; then
  /bin/launchctl bootout "${service_domain}" "${launch_agent}" 2>/dev/null || true
fi

if [[ -e "${app_target}" ]]; then
  /bin/mv "${app_target}" "${backup_root}/LiveLingo.app"
fi
if [[ -e "${service_target}" ]]; then
  /bin/mkdir -p "${backup_root}/Application Support"
  /bin/mv "${service_target}" "${backup_root}/Application Support/ASRService"
fi
if [[ -f "${launch_agent}" ]]; then
  /bin/mv "${launch_agent}" "${backup_root}/com.jianhongli.LiveLingoASR.plist"
fi

print "安装 LiveLingo 和便携 ASR 运行环境…"
/usr/bin/ditto --rsrc --extattr "${app_source}" "${app_target}"
/bin/mkdir -p "${service_target}"
/usr/bin/ditto "${service_source}" "${service_target}"
/usr/bin/codesign --verify --deep --strict "${app_target}"

print "安装两个转写模型；4B 与 9B 已内置在应用中…"
for relative in "${model_relatives[@]}"; do
  source_path="${models_source}/${relative}"
  target_path="${models_target}/${relative}"
  if [[ -e "${target_path}" ]]; then
    print "  已存在并一致：${relative}"
    continue
  fi
  /bin/mkdir -p "${target_path:h}"
  /usr/bin/ditto "${source_path}" "${target_path}"
done

print "安装并启动当前用户的 ASR 服务…"
temporary_plist="$(/usr/bin/mktemp -t livelingo-asr-plist)"
/usr/bin/plutil -create xml1 "${temporary_plist}"
/usr/bin/plutil -insert Label -string "com.jianhongli.LiveLingoASR" "${temporary_plist}"
/usr/bin/plutil -insert ProgramArguments -json \
  "[\"${service_target}/python/bin/python3\",\"${service_target}/qwen_asr_service.py\",\"--host\",\"127.0.0.1\",\"--port\",\"18765\"]" \
  "${temporary_plist}"
/usr/bin/plutil -insert EnvironmentVariables -json "{}" "${temporary_plist}"
/usr/bin/plutil -insert EnvironmentVariables.LIVELINGO_ASR_MODELS -string "${models_target}" "${temporary_plist}"
/usr/bin/plutil -insert RunAtLoad -bool true "${temporary_plist}"
/usr/bin/plutil -insert KeepAlive -bool true "${temporary_plist}"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "${temporary_plist}"
/usr/bin/plutil -insert ProcessType -string Interactive "${temporary_plist}"
/usr/bin/plutil -insert StandardOutPath -string "${logs_dir}/asr.log" "${temporary_plist}"
/usr/bin/plutil -insert StandardErrorPath -string "${logs_dir}/asr-error.log" "${temporary_plist}"
/usr/bin/plutil -lint "${temporary_plist}" >/dev/null
/usr/bin/install -m 0644 "${temporary_plist}" "${launch_agent}"
/bin/mv "${temporary_plist}" "${backup_root}/generated-asr-plist.xml"

if [[ "${LIVELINGO_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  /bin/launchctl bootstrap "${service_domain}" "${launch_agent}"
  /bin/launchctl kickstart -k "${service_target_name}"
  ready=0
  for _ in {1..30}; do
    if /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:18765/health >/dev/null; then
      ready=1
      break
    fi
    /bin/sleep 1
  done
  (( ready == 1 )) || fail "ASR 服务未在 30 秒内就绪；请查看 ${logs_dir}/asr-error.log"
fi

print "安装成功。备份位于：${backup_root}"
print "首次使用麦克风或系统内录时，请按 macOS 提示授予对应权限。"
if [[ "${LIVELINGO_SKIP_APP_OPEN:-0}" != "1" ]]; then
  /usr/bin/open -a "${app_target}"
fi
