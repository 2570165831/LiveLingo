#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
bundled_python="${script_dir}/asr-venv/bin/python"
development_python="/Users/li/Documents/Codex/2026-09-01/live-lingo-specialist/work/asr-venv/bin/python"

if [[ -n "${LIVELINGO_QWEN_PYTHON:-}" ]]; then
  python_bin="${LIVELINGO_QWEN_PYTHON}"
elif [[ -x "${bundled_python}" ]]; then
  python_bin="${bundled_python}"
else
  python_bin="${development_python}"
fi

if [[ ! -x "$python_bin" ]]; then
  print -u2 "Local ASR Python environment not found: $python_bin"
  exit 1
fi

exec "$python_bin" "$script_dir/qwen_asr_service.py" "$@"
