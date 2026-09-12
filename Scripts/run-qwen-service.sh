#!/bin/zsh
# LEGACY developer/rollback helper: start the loopback ASR service from a local
# Python environment. The current MLX candidate runs its own bundled
# ASRRuntime inside the app and does not need this script.
#
# The interpreter is never guessed and never falls back to a developer-specific
# path. Provide it explicitly:
#   LIVELINGO_QWEN_PYTHON=/absolute/path/to/python ./Scripts/run-qwen-service.sh
# or place an environment at Scripts/asr-venv (used when that file is executable).
set -euo pipefail

script_dir="${0:A:h}"
bundled_python="${script_dir}/asr-venv/bin/python"

if [[ -n "${LIVELINGO_QWEN_PYTHON:-}" ]]; then
  python_bin="${LIVELINGO_QWEN_PYTHON}"
elif [[ -x "${bundled_python}" ]]; then
  python_bin="${bundled_python}"
else
  print -u2 "Local ASR Python environment not found."
  print -u2 "Set LIVELINGO_QWEN_PYTHON=/absolute/path/to/python (a complete environment with mlx-audio installed),"
  print -u2 "or provide one at ${bundled_python}."
  exit 1
fi

if [[ ! -x "$python_bin" ]]; then
  print -u2 "Local ASR Python environment not found: $python_bin"
  exit 1
fi

exec "$python_bin" "$script_dir/qwen_asr_service.py" "$@"
