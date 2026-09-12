#!/usr/bin/env python3
import argparse
import hmac
import ipaddress
import json
import os
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# The app bundle must stay immutable: never drop __pycache__ next to the
# bundled runtime or the bundled service script.
sys.dont_write_bytecode = True

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, sosfiltfilt

SCRIPT_DIR = Path(__file__).resolve().parent
# Real installations keep the service script in <Resources>/ASRRuntime and the
# models in <Resources>/Models, so the parent directory is the default root.
# Nothing here depends on the user home directory or an LM Studio install.
DEFAULT_MODEL_CANDIDATES = (SCRIPT_DIR.parent / "Models", SCRIPT_DIR / "Models")
MODEL_RELATIVE_PATHS = {
    "parakeet": "mlx-community/parakeet-tdt-0.6b-v2",
    "0.6b": "mlx-community/Qwen3-ASR-0.6B-4bit",
    "1.7b": "mlx-community/Qwen3-ASR-1.7B-4bit",
}
PROTOCOL_VERSION = 1
READY_PREFIX = "LIVELINGO_ASR_READY"
TOKEN_HEADER = "X-LiveLingo-Token"
BEARER_PREFIX = "bearer "
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
INFERENCE_WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr-inference")


def resolve_model_root(explicit=None, environ=None) -> Path:
    """Resolve the model root without depending on the user home directory."""
    environ = os.environ if environ is None else environ
    if explicit:
        return Path(explicit).expanduser()
    from_environment = environ.get("LIVELINGO_ASR_MODELS")
    if from_environment:
        return Path(from_environment).expanduser()
    for candidate in DEFAULT_MODEL_CANDIDATES:
        if candidate.is_dir():
            return candidate
    return DEFAULT_MODEL_CANDIDATES[0]


def build_model_paths(root) -> dict:
    root = Path(root)
    return {key: root / relative for key, relative in MODEL_RELATIVE_PATHS.items()}


MODEL_ROOT = resolve_model_root()
MODEL_PATHS = build_model_paths(MODEL_ROOT)
AUTH_TOKEN = None
SUPERVISED = False


def available_model_keys() -> list:
    return [key for key, path in MODEL_PATHS.items() if path.is_dir()]


def model_for(key: str):
    if key not in MODEL_PATHS:
        raise ValueError(f"Unsupported ASR model: {key}")
    path = MODEL_PATHS[key]
    if not path.is_dir():
        raise FileNotFoundError(f"ASR model is missing: {path}")
    if key not in MODELS:
        from mlx_audio.stt.utils import load_model

        started = time.monotonic()
        print(f"ASR loading model={key}", flush=True)
        MODELS[key] = load_model(str(path))
        print(f"ASR loaded model={key} seconds={time.monotonic() - started:.3f}", flush=True)
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


def transcribe_audio(model_input_path: str, model_key: str) -> str:
    # Keep MLX loading, evaluation and result access on one long-lived thread.
    with MODEL_LOCK:
        model = model_for(model_key)
        if model_key == "parakeet":
            result = model.generate(model_input_path, verbose=False)
        else:
            result = model.generate(
                model_input_path, language="English", max_tokens=256,
                temperature=0.0, verbose=False,
            )
        return result.text.strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "LiveLingoLocalASR/2.1"

    def do_GET(self):
        if not self.require_authorized():
            return
        if self.path != "/health":
            self.send_error(404)
            return
        self.send_json(
            200,
            {
                "ok": True,
                "pid": os.getpid(),
                "protocol": PROTOCOL_VERSION,
                "port": self.server.server_address[1],
                "auth": bool(AUTH_TOKEN),
                "supervised": bool(SUPERVISED),
                "models_root": str(MODEL_ROOT),
                "available_models": available_model_keys(),
                "loaded_models": sorted(MODELS),
            },
        )

    def do_POST(self):
        if not self.require_authorized():
            return
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
            started = time.monotonic()
            print(f"ASR request model={model_key} bytes={size}", flush=True)
            text = INFERENCE_WORKER.submit(transcribe_audio, model_input_path, model_key).result()
            print(f"ASR completed model={model_key} seconds={time.monotonic() - started:.3f}", flush=True)
            self.send_json(
                200,
                {
                    "text": text,
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

    def supplied_token(self) -> str:
        token = self.headers.get(TOKEN_HEADER, "") or ""
        if token:
            return token.strip()
        authorization = self.headers.get("Authorization", "") or ""
        if authorization.lower().startswith(BEARER_PREFIX):
            return authorization[len(BEARER_PREFIX):].strip()
        return ""

    def require_authorized(self) -> bool:
        """Reject foreign callers when the parent handed us a request token."""
        if not AUTH_TOKEN:
            return True
        if hmac.compare_digest(self.supplied_token(), AUTH_TOKEN):
            return True
        self.send_json(401, {"error": "unauthorized"})
        return False

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # The caller may have cancelled or timed out. Do not send a second
            # response or report a successful transcription as an inference error.
            pass

    def log_message(self, format_string, *args):
        print(f"[{self.log_date_time_string()}] {format_string % args}", flush=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Local-only ASR bridge for LiveLingo")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--models-dir", default=None,
                        help="Model root; defaults to the bundled Resources/Models directory.")
    parser.add_argument("--token", default=None,
                        help="Request token; every endpoint then requires it.")
    parser.add_argument("--supervised", action="store_true",
                        help="Exit when the parent process exits or closes our stdin.")
    return parser.parse_args(argv)


def validate_bind_host(host: str) -> str:
    """Only loopback binds are allowed: the ASR bridge is never a LAN service."""
    normalized = (host or "").strip().lower()
    if normalized in {"localhost", ""}:
        return "127.0.0.1"
    try:
        address = ipaddress.ip_address(normalized)
    except ValueError as error:
        raise ValueError(f"Invalid bind host: {host}") from error
    if not address.is_loopback:
        raise ValueError(f"Refusing to bind a non-loopback address: {host}")
    return str(address)


def create_server(host: str, port: int) -> tuple:
    server = ThreadingHTTPServer((host, port), Handler)
    return server, server.server_address[0], server.server_address[1]


def ready_payload(server, host: str) -> dict:
    return {
        "event": "ready",
        "protocol": PROTOCOL_VERSION,
        "host": host,
        "port": server.server_address[1],
        "pid": os.getpid(),
        "auth": bool(AUTH_TOKEN),
        "supervised": bool(SUPERVISED),
        "models_root": str(MODEL_ROOT),
        "available_models": available_model_keys(),
    }


def announce_ready(server, host: str) -> dict:
    """Publish the bound loopback port as a single JSON line.

    The parent process reads this line to learn the ephemeral port. The request
    token is intentionally never part of the announcement.
    """
    payload = ready_payload(server, host)
    print(f"{READY_PREFIX} {json.dumps(payload, ensure_ascii=False)}", flush=True)
    return payload


def request_shutdown(server, reason: str) -> None:
    """Exit immediately; the parent is gone and this process must not linger."""
    print(f"ASR shutdown reason={reason}", flush=True)
    try:
        server.shutdown()
    except Exception:
        pass
    try:
        server.server_close()
    except Exception:
        pass
    # The interpreter may still be inside an inference call or waiting on a
    # non-daemon worker thread; the parent is gone, so leave immediately.
    os._exit(0)


def start_parent_watchdog(server, parent_pid=None, poll_seconds: float = 1.0) -> tuple:
    """Watch for a dead parent: stdin EOF or reparenting both mean 'exit now'."""
    parent_pid = os.getppid() if parent_pid is None else parent_pid

    def watch_stdin():
        try:
            stream = getattr(sys.stdin, "buffer", sys.stdin)
            while True:
                chunk = stream.read(1)
                if chunk in (b"", ""):
                    break
        except Exception:
            pass
        request_shutdown(server, "parent stdin closed")

    def watch_parent():
        while True:
            if os.getppid() != parent_pid:
                request_shutdown(server, "parent process exited")
                return
            time.sleep(poll_seconds)

    stdin_thread = threading.Thread(target=watch_stdin, name="asr-parent-stdin", daemon=True)
    parent_thread = threading.Thread(target=watch_parent, name="asr-parent-pid", daemon=True)
    stdin_thread.start()
    parent_thread.start()
    return stdin_thread, parent_thread


def main(argv=None) -> int:
    args = parse_args(argv)
    global AUTH_TOKEN, SUPERVISED, MODEL_ROOT, MODEL_PATHS
    try:
        host = validate_bind_host(args.host)
    except ValueError as error:
        print(f"错误：{error}", file=sys.stderr, flush=True)
        return 2
    token = args.token if args.token is not None else os.environ.get("LIVELINGO_ASR_TOKEN")
    AUTH_TOKEN = (token or "").strip() or None
    SUPERVISED = bool(args.supervised)
    MODEL_ROOT = resolve_model_root(args.models_dir)
    MODEL_PATHS = build_model_paths(MODEL_ROOT)
    server, bound_host, bound_port = create_server(host, args.port)
    announce_ready(server, bound_host)
    print(f"LiveLingo local ASR service listening on http://{bound_host}:{bound_port}",
          flush=True)
    if SUPERVISED:
        start_parent_watchdog(server)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
