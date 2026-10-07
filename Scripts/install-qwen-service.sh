#!/bin/zsh
# LEGACY developer/rollback helper: install the loopback ASR service as a
# per-user LaunchAgent. The current MLX candidate ships and starts its own
# bundled ASRRuntime and does not need this script; it is kept for local
# development and for rolling back to the older development layout.
#
# The Python environment is never guessed: set
#   LIVELINGO_QWEN_PYTHON_ENV=/absolute/path/to/python-env
# to a complete environment with mlx-audio installed.
set -euo pipefail

script_dir="${0:A:h}"
current_user="$(/usr/bin/id -un)"
directory_records="/Users"
user_root="${HOME:-$(/usr/bin/dscl . -read "${directory_records}/${current_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')}"
label="com.jianhongli.LiveLingoASR"
launch_agents_dir="${user_root}/Library/LaunchAgents"
log_dir="${user_root}/Library/Logs/LiveLingo"
service_dir="${user_root}/Library/Application Support/LiveLingo/ASRService"
plist_path="${launch_agents_dir}/${label}.plist"
source_runner_path="${script_dir}/run-qwen-service.sh"
source_service_path="${script_dir}/qwen_asr_service.py"
source_private_helper="${script_dir}/installer_token_private.py"
source_python_env="${LIVELINGO_QWEN_PYTHON_ENV:-}"
runner_path="${service_dir}/run-qwen-service.sh"
private_helper="${service_dir}/installer_token_private.py"
user_id="$(/usr/bin/id -u)"
service_domain="gui/${user_id}"
service_target="${service_domain}/${label}"

if [[ -z "${user_root}" ]]; then
  print -u2 "Cannot determine the current user's home directory; set HOME before running this script."
  exit 1
fi

if [[ -z "${source_python_env}" ]]; then
  print -u2 "Set LIVELINGO_QWEN_PYTHON_ENV=/absolute/path/to/python-env (a complete Python environment with mlx-audio installed)."
  print -u2 "This script does not fall back to a developer-specific or home-directory environment."
  exit 1
fi

if [[ ! -x "${source_runner_path}" ]]; then
  print -u2 "ASR service runner is missing or not executable: ${source_runner_path}"
  exit 1
fi

if [[ ! -f "${source_service_path}" ]]; then
  print -u2 "ASR service implementation is missing: ${source_service_path}"
  exit 1
fi

if [[ ! -f "${source_private_helper}" ]]; then
  print -u2 "Private ASR installer helper is missing."
  exit 1
fi

if [[ ! -x "${source_python_env}/bin/python" ]]; then
  print -u2 "ASR Python environment is missing: ${source_python_env}"
  exit 1
fi

"${source_python_env}/bin/python" -B "${source_private_helper}" check-target --plist "${plist_path}"
/bin/mkdir -p "${launch_agents_dir}" "${log_dir}" "${service_dir}"
/usr/bin/install -m 0755 "${source_runner_path}" "${runner_path}"
/usr/bin/install -m 0644 "${source_service_path}" "${service_dir}/qwen_asr_service.py"
/usr/bin/ditto "${source_python_env}" "${service_dir}/asr-venv"

"${source_python_env}/bin/python" -B "${source_private_helper}" export-helper \
  --source "${source_private_helper}" --output "${private_helper}"
# The helper generates secrets.token_hex(32) inside EnvironmentVariables.LIVELINGO_ASR_TOKEN.
# Unlike install -m 0600, it removes and verifies inherited ALLOW ACLs before writing.
# Existing readonly/public/linked targets are refused; private backups use exclusive names.
"${source_python_env}/bin/python" -B "${private_helper}" install --plist "${plist_path}" \
  --runner "${runner_path}" --logs-dir "${log_dir}" --backup-dir "${log_dir}"

/bin/launchctl bootout "${service_domain}" "${plist_path}" 2>/dev/null || true
/bin/launchctl bootstrap "${service_domain}" "${plist_path}"
/bin/launchctl kickstart -k "${service_target}"

for _ in {1..30}; do
  # The helper reads X-LiveLingo-Token from the private file, never from argv.
  if "${source_python_env}/bin/python" -B "${private_helper}" health --token-file "${plist_path}"; then
    print "LiveLingo ASR service is ready: ${service_target}"
    exit 0
  fi
  /bin/sleep 1
done

print -u2 "LaunchAgent loaded, but the ASR health check did not pass within 30 seconds."
print -u2 "Inspect ${log_dir}/asr-error.log for details."
exit 1
