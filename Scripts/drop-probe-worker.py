"""Local Parakeet JSON-lines worker, launched ONLY on the host interpreter.

The caller supplies a read-only local model and site-packages. No bundle
interpreter, network fetch, HTTP service, classroom storage or app is used.
"""
import importlib.machinery
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
original_create = importlib.machinery.ExtensionFileLoader.create_module

def verified_create(loader, spec):
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', loader.path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return original_create(loader, spec)

importlib.machinery.ExtensionFileLoader.create_module = verified_create
import mlx.core as mx
from mlx_audio.stt.utils import load_model
import qwen_asr_service as service

model_path = Path(sys.argv[1])
assert model_path.is_dir() and (model_path / 'model.safetensors').is_file()
model = load_model(str(model_path))
print(json.dumps({'ready': True}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if request.get('stop'):
        break
    start = time.monotonic()
    path = request['path']
    enhanced_path = None
    if request.get('enhance'):
        enhanced_path, _ = service.speech_band_enhance(path)
        path = enhanced_path
    # Use the production confidence recorder and identical generation options.
    result = service.transcribe_parakeet(model, path)
    result['seconds'] = time.monotonic() - start
    result['gpu_active_bytes'] = mx.get_active_memory()
    result['gpu_peak_bytes'] = mx.get_peak_memory()
    # Retain any enhancement file; this task explicitly forbids cleanup.
    if enhanced_path:
        result['retained_enhancement'] = enhanced_path
    print(json.dumps(result), flush=True)
