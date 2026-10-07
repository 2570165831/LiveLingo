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
import uuid
import gc
import re
from importlib.metadata import version
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# The app bundle must stay immutable: never drop __pycache__ next to the
# bundled runtime or the bundled service script.
sys.dont_write_bytecode = True

try:
    from scoreboard_timing import measure
except ImportError:
    # Normal release bundles need not include the optional timing helper.
    # Missing samples are unknown timings, never zero-duration measurements.
    from contextlib import nullcontext

    def measure(stage):
        return nullcontext()

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
PROTOCOL_VERSION = 2
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
MODEL_STATE_LOCK = threading.Lock()
MODEL_LAST_USED = {}
UNLOADING_MODELS = set()
REQUEST_STATES = {}
COMPLETED_REQUESTS = {}
MAX_COMPLETION_RECEIPTS = 256
MAX_INFERENCE_REQUESTS = 3  # one running, at most two submitted ahead
INFERENCE_SLOTS = threading.BoundedSemaphore(MAX_INFERENCE_REQUESTS)
IDLE_MODEL_SECONDS = 120.0
INFERENCE_WORKER = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr-inference")
AUTO_SELF_CHECKS = {}  # model key -> (loaded object identity, check result); no model references
ASR_TEXT_TOKEN = 151704
LANGUAGE_TOKEN = 11528
ASR_EOS_TOKENS = {151645, 151643}
SOURCE_POLICY = 1
NON_LATIN_MIN_PROBABILITY = 0.90
NON_LATIN_MAX_ENGLISH_PROBABILITY = 0.05
LATIN_MIN_PROBABILITY = 0.97
LATIN_MAX_ENGLISH_PROBABILITY = 0.01
LANGUAGE_CODES = {
    "Chinese": "zh", "English": "en", "Cantonese": "yue", "Arabic": "ar",
    "German": "de", "French": "fr", "Spanish": "es", "Portuguese": "pt",
    "Indonesian": "id", "Italian": "it", "Korean": "ko", "Russian": "ru",
    "Thai": "th", "Vietnamese": "vi", "Japanese": "ja", "Turkish": "tr",
    "Hindi": "hi", "Malay": "ms", "Dutch": "nl", "Swedish": "sv",
    "Danish": "da", "Finnish": "fi", "Polish": "pl", "Czech": "cs",
    "Filipino": "fil", "Persian": "fa", "Greek": "el", "Romanian": "ro",
    "Hungarian": "hu", "Macedonian": "mk",
}
LATIN_LANGUAGE_CODES = frozenset({
    "de", "fr", "es", "pt", "id", "it", "vi", "tr", "ms", "nl", "sv",
    "da", "fi", "pl", "cs", "fil", "ro", "hu",
})


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
        with measure("asr_load"):
            loaded = load_model(str(path))
        with MODEL_STATE_LOCK:
            MODELS[key] = loaded
            MODEL_LAST_USED[key] = time.monotonic()
            AUTO_SELF_CHECKS.pop(key, None)
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


def auto_self_check(model, model_key):
    """Check the pinned private API once per loaded model, without patching it."""
    cached = AUTO_SELF_CHECKS.get(model_key)
    if cached is not None and cached[0] == id(model):
        return cached[1]
    check = None
    try:
        if version("mlx-audio") != "0.3.1" or version("mlx-lm") != "0.30.5":
            raise ValueError("Unsupported ASR runtime")
        inner = model._model
        tokenizer = inner._tokenizer
        labels = list(inner.config.support_languages)
        if len(labels) != 30 or set(labels) != set(LANGUAGE_CODES):
            raise ValueError("Unsupported language table")
        if tokenizer.encode("<asr_text>", add_special_tokens=False) != [ASR_TEXT_TOKEN]:
            raise ValueError("Unsupported ASR delimiter")
        english = tokenizer.encode(" English", add_special_tokens=False)
        if len(english) != 1:
            raise ValueError("Unsupported English token")
        prompt = np.asarray(inner._build_prompt(1, "English")).reshape(-1).tolist()
        if prompt[-3:] != [LANGUAGE_TOKEN, english[0], ASR_TEXT_TOKEN]:
            raise ValueError("Unsupported prompt suffix")
        heads = {}
        for label in labels + ["None"]:
            tokens = tokenizer.encode(" " + label, add_special_tokens=False)
            if not tokens or len(tokens) > 3 or tokenizer.decode(tokens) != " " + label:
                raise ValueError("Unsupported language head")
            heads.setdefault(tokens[0], []).append(label)
        check = {"labels": frozenset(labels + ["None"]), "english_token": english[0], "heads": heads}
    except Exception:
        # Neither exception messages nor model output belong in diagnostics.
        pass
    AUTO_SELF_CHECKS[model_key] = (id(model), check)
    return check


def probe_language(model, probe_input_path, check):
    """Prefill the unmodified English prompt through `language` on raw audio.

    The delimiter is left unconsumed so detected decoding can feed it into
    generate_step with this exact cache. All tensors stay on the inference thread.
    """
    import mlx.core as mx
    from mlx_audio.stt.utils import load_audio

    inner = model._model
    audio = load_audio(probe_input_path, sr=16000)
    features, mask, count = inner._preprocess_audio(audio)
    ids = inner._build_prompt(count, "English")
    if np.asarray(ids).reshape(-1).tolist()[-3:] != [
        LANGUAGE_TOKEN, check["english_token"], ASR_TEXT_TOKEN
    ]:
        raise ValueError("Unsupported prompt suffix")
    audio_features = inner.get_audio_features(features, mask)
    embeddings = inner._build_inputs_embeds(ids, audio_features)
    cache = inner.make_cache()
    logits = inner(ids[:, :-2], input_embeddings=embeddings[:, :-2], cache=cache)[0, -1]
    # Normalize in float32: bfloat16 rounds the partition function enough to
    # make the probability mass exceed one and can spuriously cross a gate.
    probabilities = mx.softmax(logits.astype(mx.float32))
    mx.eval(probabilities)
    head = []
    for _ in range(4):
        token = int(mx.argmax(logits).item())
        if token == ASR_TEXT_TOKEN:
            label_text = inner._tokenizer.decode(head)
            if not label_text.startswith(" ") or label_text[1:] not in check["labels"]:
                raise ValueError("Unparsed language head")
            if len(check["heads"].get(head[0], [])) != 1:
                raise ValueError("Ambiguous language head")
            return {
                "detected_label": label_text[1:],
                "language_probability": float(probabilities[head[0]].item()),
                "english_probability": float(probabilities[check["english_token"]].item()),
                "cache": cache,
            }
        head.append(token)
        logits = inner(mx.array([[token]]), cache=cache)[0, -1]
    raise ValueError("Unterminated language head")


def should_decode_detected(label, p_label, p_english):
    code = LANGUAGE_CODES.get(label)
    if code is None or code == "en":
        return False
    if not (0 <= p_label <= 1 and 0 <= p_english <= 1):
        return False
    if code in LATIN_LANGUAGE_CODES:
        return p_label >= LATIN_MIN_PROBABILITY and p_english <= LATIN_MAX_ENGLISH_PROBABILITY
    return p_label >= NON_LATIN_MIN_PROBABILITY and p_english <= NON_LATIN_MAX_ENGLISH_PROBABILITY


def transcribe_auto(model, model_input_path, probe_input_path, model_key):
    """Only the opt-in request gets metadata; failed probing uses legacy English."""
    metadata = {"language_mode": "auto", "language": "en", "decode": "forced",
                "detected_label": None, "language_probability": None,
                "english_probability": None, "generated_tokens": 0,
                "truncated": False, "policy": SOURCE_POLICY}
    try:
        check = auto_self_check(model, model_key)
        if check is not None:
            probe = probe_language(model, probe_input_path, check)
            metadata.update({key: probe[key] for key in (
                "detected_label", "language_probability", "english_probability")})
            if should_decode_detected(probe["detected_label"], probe["language_probability"], probe["english_probability"]):
                import mlx.core as mx
                from mlx_lm.generate import generate_step

                tokens = []
                ended = False
                for token, _ in generate_step(
                    prompt=mx.array([ASR_TEXT_TOKEN]), model=model._model,
                    prompt_cache=probe["cache"], max_tokens=256,
                ):
                    token = int(token)
                    if token in ASR_EOS_TOKENS:
                        ended = True
                        break
                    tokens.append(token)
                text = model._model._tokenizer.decode(tokens, skip_special_tokens=True).strip()
                return {**metadata, "text": text, "language": LANGUAGE_CODES[probe["detected_label"]],
                        "decode": "detected", "generated_tokens": len(tokens),
                        "truncated": len(tokens) == 256 and not ended}
            del probe  # English never reuses probe state.
    except Exception:
        probe = None
        metadata.update(detected_label=None, language_probability=None, english_probability=None)
    result = model.generate(
        model_input_path, language="English", max_tokens=256,
        temperature=0.0, verbose=False,
    )
    return {**metadata, "text": result.text.strip(),
            "generated_tokens": getattr(result, "generation_tokens", 0)}


def transcribe_audio(model_input_path: str, model_key: str, language_mode=None, probe_input_path=None):
    # Keep MLX loading, evaluation and result access on one long-lived thread.
    with MODEL_LOCK:
        try:
            model = model_for(model_key)
            with measure("asr_inference"):
                if language_mode == "auto":
                    return transcribe_auto(model, model_input_path, probe_input_path or model_input_path, model_key)
                if model_key == "parakeet":
                    result = model.generate(model_input_path, verbose=False)
                else:
                    result = model.generate(
                        model_input_path, language="English", max_tokens=256,
                        temperature=0.0, verbose=False,
                    )
                return result.text.strip()
        finally:
            with MODEL_STATE_LOCK:
                if model_key in MODELS: MODEL_LAST_USED[model_key] = time.monotonic()


def run_registered_transcription(request_id, model_input_path, model_key, language_mode=None, probe_input_path=None):
    with MODEL_STATE_LOCK:
        REQUEST_STATES[request_id] = {'model': model_key, 'state': 'running'}
    try:
        return transcribe_audio(model_input_path, model_key, language_mode, probe_input_path)
    finally:
        # A disconnected HTTP caller does not prove inference has stopped.
        # Keep the request registered until the model call actually returns.
        with MODEL_STATE_LOCK:
            REQUEST_STATES[request_id] = {'model': model_key, 'state': 'finished'}


def resource_snapshot():
    with MODEL_STATE_LOCK:
        return {'loaded_models': sorted(MODELS),
                'unloading_models': sorted(UNLOADING_MODELS),
                'requests': {key: dict(value) for key, value in REQUEST_STATES.items()},
                'completed_requests': {key: dict(value) for key, value in COMPLETED_REQUESTS.items()}}


def finish_request(request_id, model_key):
    """Retain bounded proof after a response is lost. Absence alone proves nothing."""
    with MODEL_STATE_LOCK:
        REQUEST_STATES.pop(request_id, None)
        COMPLETED_REQUESTS[request_id] = {'model': model_key, 'state': 'finished'}
        while len(COMPLETED_REQUESTS) > MAX_COMPLETION_RECEIPTS:
            COMPLETED_REQUESTS.pop(next(iter(COMPLETED_REQUESTS)))


def unload_idle_models(now=None, idle_seconds=IDLE_MODEL_SECONDS):
    """Run on the inference executor; publish release only after cleanup succeeds."""
    now = time.monotonic() if now is None else now
    retired = []
    with MODEL_LOCK:
        with MODEL_STATE_LOCK:
            # Even a finished handler can retain an exception traceback with
            # a model reference until its response and finalizer have settled.
            used = {value['model'] for value in REQUEST_STATES.values()}
            for key in list(MODELS):
                last = MODEL_LAST_USED.get(key)
                if key in used or last is None or now - last < idle_seconds:
                    continue
                UNLOADING_MODELS.add(key)
                del MODELS[key]
                MODEL_LAST_USED.pop(key, None)
                AUTO_SELF_CHECKS.pop(key, None)
                retired.append(key)
            pending_release = set(UNLOADING_MODELS)
        if pending_release:
            gc.collect()
            try:
                import mlx.core as mx
                mx.clear_cache()
            except ImportError:
                pass
            with MODEL_STATE_LOCK:
                UNLOADING_MODELS.difference_update(pending_release)
            print('ASR unloaded models=' + ','.join(sorted(pending_release)), flush=True)
    return sorted(retired)


def start_idle_maintenance():
    stopped = threading.Event()
    def maintain():
        while not stopped.wait(5):
            with MODEL_STATE_LOCK:
                busy = bool(REQUEST_STATES)
                loaded = bool(MODELS) or bool(UNLOADING_MODELS)
            if busy or not loaded: continue
            # One maintenance future at a time, on the same thread as MLX.
            try: INFERENCE_WORKER.submit(unload_idle_models).result()
            except Exception as error:
                print(f'ASR idle-unload failed type={type(error).__name__}', flush=True)
    threading.Thread(target=maintain, name='asr-idle-maintenance', daemon=True).start()
    return stopped


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
                **resource_snapshot(),
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
        languages = parse_qs(parsed.query, keep_blank_values=True).get("language", ["English"])
        if len(languages) != 1 or languages[0] not in {"English", "auto"} or (
            languages[0] == "auto" and model_key not in {"0.6b", "1.7b"}
        ):
            self.send_json(400, {"error": "Unsupported language mode"})
            return
        language_mode = "auto" if languages[0] == "auto" else None
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"error": "Invalid Content-Length"})
            return
        if size <= 0 or size > MAX_AUDIO_BYTES:
            self.send_json(413, {"error": "Audio body is empty or too large"})
            return
        if not INFERENCE_SLOTS.acquire(blocking=False):
            self.send_json(503, {"error": "ASR queue is full", "retryable": True})
            return
        request_id = self.headers.get('X-LiveLingo-Request-ID') or uuid.uuid4().hex
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', request_id):
            INFERENCE_SLOTS.release()
            self.send_json(400, {"error": "Invalid request ID"})
            return
        with MODEL_STATE_LOCK:
            if request_id in REQUEST_STATES or request_id in COMPLETED_REQUESTS:
                INFERENCE_SLOTS.release()
                duplicate = True
            else:
                REQUEST_STATES[request_id] = {'model': model_key, 'state': 'waiting'}
                duplicate = False
        if duplicate:
            self.send_json(409, {"error": "Request ID is already in use"})
            return
        temporary_path = None
        model_input_path = None
        enhancement = {"applied": False, "reason": "disabled"}
        try:
            audio = self.rfile.read(size)
            if len(audio) != size: raise ValueError('Incomplete audio request')
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
                temporary.write(audio)
                temporary_path = temporary.name
            model_input_path = temporary_path
            if should_enhance:
                model_input_path, enhancement = speech_band_enhance(temporary_path)
            started = time.monotonic()
            print(f"ASR request id={request_id} model={model_key} bytes={size}", flush=True)
            text = INFERENCE_WORKER.submit(run_registered_transcription, request_id, model_input_path, model_key,
                                           language_mode, temporary_path).result()
            print(f"ASR completed id={request_id} model={model_key} seconds={time.monotonic() - started:.3f}", flush=True)
            payload = {"text": text, "model": model_key, "request_id": request_id,
                       "audio_enhancement": enhancement}
            if language_mode == "auto":
                payload.update(text)
                print(f"ASR language id={request_id} label={text['detected_label']} "
                      f"p={text['language_probability']} p_en={text['english_probability']} "
                      f"decode={text['decode']}", flush=True)
            self.send_json(200, payload)
        except Exception as error:
            self.send_json(500, {"error": str(error), "request_id": request_id, "model": model_key})
        finally:
            finish_request(request_id, model_key)
            INFERENCE_SLOTS.release()
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
    try:
        # The parent may have closed stdout as well as stdin. Logging must not
        # prevent this watchdog from exiting the orphaned inference process.
        print(f"ASR shutdown reason={reason}", flush=True)
    except OSError:
        pass
    # No caller can use the service after its parent exits. A graceful server
    # close can wait for an in-flight inference, so it cannot be the exit gate.
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
    maintenance = start_idle_maintenance()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        maintenance.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
