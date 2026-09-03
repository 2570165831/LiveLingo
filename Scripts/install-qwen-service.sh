#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
user_root="/Users/li"
label="com.jianhongli.LiveLingoASR"
launch_agents_dir="${user_root}/Library/LaunchAgents"
log_dir="${user_root}/Library/Logs/LiveLingo"
service_dir="${user_root}/Library/Application Support/LiveLingo/ASRService"
plist_path="${launch_agents_dir}/${label}.plist"
source_runner_path="${script_dir}/run-qwen-service.sh"
source_service_path="${script_dir}/qwen_asr_service.py"
source_python_env="/Users/li/Documents/Codex/2026-09-01/live-lingo-specialist/work/asr-venv"
runner_path="${service_dir}/run-qwen-service.sh"
user_id="$(/usr/bin/id -u li)"
service_domain="gui/${user_id}"
service_target="${service_domain}/${label}"

if [[ ! -x "${source_runner_path}" ]]; then
  print -u2 "ASR service runner is missing or not executable: ${source_runner_path}"
  exit 1
fi

if [[ ! -f "${source_service_path}" ]]; then
  print -u2 "ASR service implementation is missing: ${source_service_path}"
  exit 1
fi

if [[ ! -x "${source_python_env}/bin/python" ]]; then
  print -u2 "ASR Python environment is missing: ${source_python_env}"
  exit 1
fi

/bin/mkdir -p "${launch_agents_dir}" "${log_dir}" "${service_dir}"
/usr/bin/install -m 0755 "${source_runner_path}" "${runner_path}"
/usr/bin/install -m 0644 "${source_service_path}" "${service_dir}/qwen_asr_service.py"
/usr/bin/ditto "${source_python_env}" "${service_dir}/asr-venv"
temporary_plist="$(/usr/bin/mktemp -t livelingo-asr-plist)"
trap '/bin/rm -f -- "${temporary_plist}"' EXIT

/usr/bin/plutil -create xml1 "${temporary_plist}"
/usr/bin/plutil -insert Label -string "${label}" "${temporary_plist}"
/usr/bin/plutil -insert ProgramArguments -json "[\"${runner_path}\",\"--host\",\"127.0.0.1\",\"--port\",\"18765\"]" "${temporary_plist}"
/usr/bin/plutil -insert RunAtLoad -bool true "${temporary_plist}"
/usr/bin/plutil -insert KeepAlive -bool true "${temporary_plist}"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "${temporary_plist}"
/usr/bin/plutil -insert ProcessType -string Background "${temporary_plist}"
/usr/bin/plutil -insert StandardOutPath -string "${log_dir}/asr.log" "${temporary_plist}"
/usr/bin/plutil -insert StandardErrorPath -string "${log_dir}/asr-error.log" "${temporary_plist}"
/usr/bin/plutil -lint "${temporary_plist}"

if [[ -f "${plist_path}" ]]; then
  backup_path="${log_dir}/${label}.$(/bin/date +%Y%m%d-%H%M%S).plist.backup"
  /bin/cp -p "${plist_path}" "${backup_path}"
  print "Backed up existing LaunchAgent to: ${backup_path}"
fi

/bin/launchctl bootout "${service_domain}" "${plist_path}" 2>/dev/null || true
/usr/bin/install -m 0644 "${temporary_plist}" "${plist_path}"
/bin/launchctl bootstrap "${service_domain}" "${plist_path}"
/bin/launchctl kickstart -k "${service_target}"

for _ in {1..30}; do
  if /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:18765/health >/dev/null; then
    print "LiveLingo ASR service is ready: ${service_target}"
    exit 0
  fi
  /bin/sleep 1
done

print -u2 "LaunchAgent loaded, but the ASR health check did not pass within 30 seconds."
print -u2 "Inspect ${log_dir}/asr-error.log for details."
exit 1
