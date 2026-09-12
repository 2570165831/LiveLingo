#!/bin/zsh
# LEGACY installer verifier for the historical `Payload/` transfer layout.
# The current pipeline does not produce that layout; it is retained so an older
# package can still be validated. The expected signing identity has no default:
# pass it explicitly through LIVELINGO_SIGN_IDENTITY / LIVELINGO_TEAM_ID.
set -euo pipefail

script_dir="${0:A:h}"
payload_dir="${script_dir}/Payload"
manifest_path="${script_dir}/SHA256SUMS.txt"
expected_identity="${LIVELINGO_SIGN_IDENTITY:-}"
expected_team="${LIVELINGO_TEAM_ID:-}"

pause_on_exit() {
  exit_code=$?
  trap - EXIT
  if [[ "${LIVELINGO_NONINTERACTIVE:-0}" != "1" ]]; then
    print
    if (( exit_code == 0 )); then
      print "校验完成。按任意键关闭。"
    else
      print -u2 "校验失败。按任意键关闭。"
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

[[ -d "${payload_dir}" ]] || fail "缺少 Payload 目录。"
[[ -f "${manifest_path}" ]] || fail "缺少 SHA256SUMS.txt。"

print "[1/5] 校验离线包全部文件（大约需要数分钟）…"
(
  cd "${script_dir}"
  /usr/bin/shasum -a 256 -c --quiet --strict "${manifest_path}"
)

app_path="${payload_dir}/LiveLingo.app"
print "[2/5] 校验 LiveLingo Developer ID 签名…"
[[ -n "${expected_identity}" ]] || \
  fail "缺少签名身份：请设置 LIVELINGO_SIGN_IDENTITY=\"Developer ID Application: <名称> (<TEAMID>)\"；本脚本不会猜测身份或降级校验。"
[[ -n "${expected_team}" ]] || \
  fail "缺少 Team ID：请设置 LIVELINGO_TEAM_ID=<TEAMID>；本脚本不会猜测 Team ID。"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_path}"
signature="$('/usr/bin/codesign' -d --verbose=4 "${app_path}" 2>&1)"
[[ "${signature}" == *"Authority=${expected_identity}"* ]] \
  || fail "LiveLingo 签名身份与 LIVELINGO_SIGN_IDENTITY 不匹配。"
[[ "${signature}" == *"TeamIdentifier=${expected_team}"* ]] \
  || fail "LiveLingo Team ID 与 LIVELINGO_TEAM_ID 不匹配。"

print "[3/5] 校验 Apple Silicon 运行组件…"
/usr/bin/file "${app_path}/Contents/MacOS/LiveLingo" | /usr/bin/grep -q "arm64" \
  || fail "LiveLingo 不是 Apple Silicon 构建。"
python_path="${payload_dir}/ASRService/python/bin/python3"
[[ -x "${python_path}" ]] || fail "便携 ASR Python 不可执行。"
/usr/bin/file -L "${python_path}" | /usr/bin/grep -q "arm64" \
  || fail "便携 ASR Python 不是 Apple Silicon 构建。"
PYTHONDONTWRITEBYTECODE=1 "${python_path}" -c \
  'import mlx.core, numpy, scipy, soundfile; from mlx_audio.stt.utils import load_model; print("    MLX ASR 运行库：正常")'

print "[4/5] 校验两个转写模型和内置语言模型…"
required_files=(
  "${payload_dir}/Models/mlx-community/parakeet-tdt-0.6b-v2/model.safetensors"
  "${payload_dir}/Models/mlx-community/Qwen3-ASR-1.7B-4bit/model.safetensors"
  "${app_path}/Contents/Resources/Models/mlx-community/Qwen3.5-4B-MLX-8bit/model.safetensors"
  "${app_path}/Contents/Resources/Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/model-00001-of-00002.safetensors"
  "${app_path}/Contents/Resources/Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/model-00002-of-00002.safetensors"
)
for required_file in "${required_files[@]}"; do
  [[ -s "${required_file}" ]] || fail "模型文件缺失或为空：${required_file}"
done

print "[5/5] 校验内置 MLX 运行库与离线许可证…"
for relative in worker.py engine.py schemas.py checks.py python/bin/python3; do
  [[ -s "${app_path}/Contents/Resources/LanguageRuntime/${relative}" ]] || fail "语言运行库缺失：${relative}"
done
[[ -d "${app_path}/Contents/Resources/LanguageRuntime/Licenses" ]] || fail "缺少运行库离线许可证。"
if /usr/bin/find "${app_path}" \( -iname '*livelingo-cli*' -o -iname '*virtual-player*' -o -name '*.xctest' -o -name 'RuntimeValidation.app' \) | /usr/bin/grep -q .; then
  fail "发布应用包含测试 CLI 或测试包。"
fi

print "离线包校验通过。"
