#!/usr/bin/env python3
import argparse
import json
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, sosfiltfilt

MODEL_PATHS = {
    "parakeet": Path.home() / ".lmstudio/models/mlx-community/parakeet-tdt-0.6b-v2",
    "0.6b": Path.home() / ".lmstudio/models/mlx-community/Qwen3-ASR-0.6B-4bit",
    "1.7b": Path.home() / ".lmstudio/models/mlx-community/Qwen3-ASR-1.7B-4bit",
}
MAX_AUDIO_BYTES = 64 * 1024 * 1024
SPEECH_BAND_LOW_HZ = 120.0
SPEECH_BAND_HIGH_HZ = 7_200.0
TARGET_ACTIVE_RMS_DBFS = -23.0
MAX_SPEECH_GAIN_DB = 12.0
MIN_USEFUL_GAIN_DB = 1.5
MIN_ACTIVE_RMS_DBFS = -55.0
PEAK_CEILING_DBFS = -1.0
MODEL_LOCK = threading.Lock()
MODELS = {}


def model_for(key: str):
    if key not in MODEL_PATHS:
        raise ValueError(f"Unsupported ASR model: {key}")
    path = MODEL_PATHS[key]
    if not path.is_dir():
        raise FileNotFoundError(f"ASR model is missing: {path}")
    if key not in MODELS:
        from mlx_audio.stt.utils import load_model

        MODELS[key] = load_model(str(path))
    return MODELS[key]


def dbfs(value: float) -> float:
    return float(20.0 * np.log10(max(value, 1e-9)))


def speech_band_enhance(source_path: str) -> tuple[str, dict]:
    audio, sample_rate = sf.read(source_path, dtype="float32", always_2d=True)
    if audio.shape[0] == 0:
        return source_path, {"applied": False, "reason": "empty_audio"}

    mono = np.mean(audio, axis=1, dtype=np.float32)
    nyquist = sample_rate / 2.0
    low_hz = min(SPEECH_BAND_LOW_HZ, nyquist * 0.25)
    high_hz = min(SPEECH_BAND_HIGH_HZ, nyquist * 0.90)
    if high_hz <= low_hz * 1.5:
        return source_path, {"applied": False, "reason": "unsupported_sample_rate"}

    speech_filter = butter(
        4,
        [low_hz, high_hz],
        btype="bandpass",
        fs=sample_rate,
        output="sos",
    )
    try:
        speech_band = sosfiltfilt(speech_filter, mono).astype(np.float32)
    except ValueError:
        speech_band = sosfilt(speech_filter, mono).astype(np.float32)

    frame_length = max(1, int(sample_rate * 0.020))
    frame_count = speech_band.size // frame_length
    if frame_count == 0:
        return source_path, {"applied": False, "reason": "audio_too_short"}

    framed = speech_band[: frame_count * frame_length].reshape(frame_count, frame_length)
    frame_rms = np.sqrt(np.mean(np.square(framed, dtype=np.float64), axis=1))
    active_rms = float(np.percentile(frame_rms, 85))
    active_rms_dbfs = dbfs(active_rms)
    requested_gain_db = float(
        np.clip(TARGET_ACTIVE_RMS_DBFS - active_rms_dbfs, 0.0, MAX_SPEECH_GAIN_DB)
    )
    if active_rms_dbfs < MIN_ACTIVE_RMS_DBFS:
        requested_gain_db = 0.0
    if requested_gain_db < MIN_USEFUL_GAIN_DB:
        requested_gain_db = 0.0

    gain = float(10.0 ** (requested_gain_db / 20.0))
    # Keep the original waveform and boost only the speech-band component.
    # This avoids deleting useful low/high-frequency cues while leaving
    # out-of-band room noise at its original level.
    enhanced = mono + speech_band * (gain - 1.0)
    peak_before_limit = float(np.max(np.abs(enhanced)))
    peak_ceiling = float(10.0 ** (PEAK_CEILING_DBFS / 20.0))
    limiter_scale = 1.0
    if peak_before_limit > peak_ceiling:
        limiter_scale = peak_ceiling / peak_before_limit
        enhanced *= limiter_scale

    output = tempfile.NamedTemporaryFile(suffix="-speech.wav", delete=False)
    output.close()
    sf.write(output.name, enhanced, sample_rate, subtype="PCM_16")
    effective_gain_db = requested_gain_db + dbfs(limiter_scale)
    return output.name, {
        "applied": True,
        "band_hz": [round(low_hz), round(high_hz)],
        "active_rms_dbfs": round(active_rms_dbfs, 1),
        "requested_gain_db": round(requested_gain_db, 1),
        "effective_gain_db": round(effective_gain_db, 1),
        "limited": limiter_scale < 0.999,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "LiveLingoLocalASR/2.0"

    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        self.send_json(
            200,
            {
                "ok": True,
                "pid": os.getpid(),
                "available_models": [key for key, path in MODEL_PATHS.items() if path.is_dir()],
                "loaded_models": sorted(MODELS),
            },
        )

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/transcribe":
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        model_key = query.get("model", ["0.6b"])[0]
        should_enhance = query.get("enhance", ["off"])[0] == "speech"
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"error": "Invalid Content-Length"})
            return
        if size <= 0 or size > MAX_AUDIO_BYTES:
            self.send_json(413, {"error": "Audio body is empty or too large"})
            return

        audio = self.rfile.read(size)
        temporary_path = None
        model_input_path = None
        enhancement = {"applied": False, "reason": "disabled"}
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
                temporary.write(audio)
                temporary_path = temporary.name
            model_input_path = temporary_path
            if should_enhance:
                model_input_path, enhancement = speech_band_enhance(temporary_path)
            with MODEL_LOCK:
                model = model_for(model_key)
                if model_key == "parakeet":
                    result = model.generate(model_input_path, verbose=False)
                else:
                    result = model.generate(
                        model_input_path,
                        language="English",
                        max_tokens=256,
                        temperature=0.0,
                        verbose=False,
                    )
            self.send_json(
                200,
                {
                    "text": result.text.strip(),
                    "model": model_key,
                    "audio_enhancement": enhancement,
                },
            )
        except Exception as error:
            self.send_json(500, {"error": str(error)})
        finally:
            if model_input_path and model_input_path != temporary_path:
                try:
                    os.unlink(model_input_path)
                except FileNotFoundError:
                    pass
            if temporary_path:
                try:
                    os.unlink(temporary_path)
                except FileNotFoundError:
                    pass

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format_string, *args):
        print(f"[{self.log_date_time_string()}] {format_string % args}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Local-only ASR bridge for LiveLingo")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    server = HTTPServer((args.host, args.port), Handler)
    print(f"LiveLingo local ASR service listening on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
