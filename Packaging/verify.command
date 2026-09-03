#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
payload_dir="${script_dir}/Payload"
manifest_path="${script_dir}/SHA256SUMS.txt"

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
/usr/bin/codesign --verify --deep --strict --verbose=2 "${app_path}"
signature="$('/usr/bin/codesign' -d --verbose=4 "${app_path}" 2>&1)"
[[ "${signature}" == *"Authority=Developer ID Application: Jianhong Li (6L6KQXUJM3)"* ]] \
  || fail "LiveLingo 签名身份不匹配。"
[[ "${signature}" == *"TeamIdentifier=6L6KQXUJM3"* ]] \
  || fail "LiveLingo Team ID 不匹配。"

print "[3/5] 校验 Apple Silicon 运行组件…"
/usr/bin/file "${app_path}/Contents/MacOS/LiveLingo" | /usr/bin/grep -q "arm64" \
  || fail "LiveLingo 不是 Apple Silicon 构建。"
python_path="${payload_dir}/ASRService/python/bin/python3"
[[ -x "${python_path}" ]] || fail "便携 ASR Python 不可执行。"
/usr/bin/file "${python_path}" | /usr/bin/grep -q "arm64" \
  || fail "便携 ASR Python 不是 Apple Silicon 构建。"
PYTHONDONTWRITEBYTECODE=1 "${python_path}" -c \
  'import mlx, mlx_audio, numpy, scipy, soundfile; print("    MLX ASR 运行库：正常")'

print "[4/5] 校验四个模型和 LM Studio 索引…"
required_files=(
  "${payload_dir}/Models/mlx-community/parakeet-tdt-0.6b-v2/model.safetensors"
  "${payload_dir}/Models/mlx-community/Qwen3-ASR-1.7B-4bit/model.safetensors"
  "${payload_dir}/Models/mlx-community/Qwen3.5-4B-MLX-8bit/model.safetensors"
  "${payload_dir}/Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/model-00001-of-00002.safetensors"
  "${payload_dir}/Models/lmstudio-community/Qwen3.5-9B-MLX-4bit/model-00002-of-00002.safetensors"
  "${payload_dir}/LMStudioHub/qwen/qwen3.5-9b/model.yaml"
)
for required_file in "${required_files[@]}"; do
  [[ -s "${required_file}" ]] || fail "模型文件缺失或为空：${required_file}"
done

print "[5/5] 校验官方 LM Studio 安装镜像…"
lm_dmg="${payload_dir}/LMStudio/LM-Studio-0.4.23-1-arm64.dmg"
[[ -f "${lm_dmg}" ]] || fail "缺少 LM Studio 安装镜像。"
/usr/bin/hdiutil verify "${lm_dmg}"

print "离线包校验通过。"
