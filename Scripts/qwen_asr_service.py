#!/usr/bin/env python3
import argparse
import ctypes
import errno
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
import stat
from contextlib import contextmanager
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
BODY_TIMEOUT_SECONDS = 30.0
INFERENCE_TIMEOUT_SECONDS = 120.0
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
_TEMP_LOCK = threading.RLock()
_TEMPORARY_FILES = {}
_TEMP_STOPPING = False
_ACL_API = None


def private_audio_file(fd):
    """Set 0600 and remove only macOS ALLOW entries through the owned fd."""
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise ValueError('Invalid temporary audio owner or type')
    os.fchmod(fd, 0o600)
    if sys.platform != 'darwin':
        return
    global _ACL_API
    if _ACL_API is None:
        api = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        signatures = {
            'acl_get_fd_np': ([ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
            'acl_get_entry': ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
            'acl_get_tag_type': ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
            'acl_delete_entry': ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            'acl_set_fd_np': ([ctypes.c_int, ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            'acl_free': ([ctypes.c_void_p], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            getattr(api, name).argtypes = arguments
            getattr(api, name).restype = result
        _ACL_API = api
    api = _ACL_API
    def read_acl():
        ctypes.set_errno(0)
        acl = api.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED.
        if acl or ctypes.get_errno() == errno.ENOENT:
            return acl
        raise OSError(ctypes.get_errno(), 'Private audio ACL read failed')

    def first_allow(acl):
        selector = 0
        while True:
            entry = ctypes.c_void_p()
            ctypes.set_errno(0)
            result = api.acl_get_entry(acl, selector, ctypes.byref(entry))
            if not entry.value and (result >= 0 or
                                    (result == -1 and ctypes.get_errno() == errno.EINVAL)):
                return None
            if result < 0 or not entry.value:
                raise OSError(ctypes.get_errno(), 'Private audio ACL read failed')
            tag = ctypes.c_int()
            if api.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                raise OSError(ctypes.get_errno(), 'Private audio ACL read failed')
            if tag.value == 1:  # ACL_EXTENDED_ALLOW; preserve DENY and other entries.
                return entry
            selector = -1  # ACL_NEXT_ENTRY in the macOS SDK.

    acl = read_acl()
    if not acl:
        return
    changed = False
    try:
        while (entry := first_allow(acl)) is not None:
            if api.acl_delete_entry(acl, entry) != 0:
                raise OSError(ctypes.get_errno(), 'Private audio ACL update failed')
            changed = True
        if changed and api.acl_set_fd_np(fd, acl, 0x100) != 0:
            raise OSError(ctypes.get_errno(), 'Private audio ACL update failed')
    finally:
        api.acl_free(acl)
    if changed:
        verified = read_acl()
        if verified:
            try:
                if first_allow(verified) is not None:
                    raise OSError('Private audio ACL verification failed')
            finally:
                api.acl_free(verified)


def safe_exception_code(error):
    """Fixed categories only; dependency messages and class names are private."""
    if isinstance(error, MemoryError): return 'resource_exhausted'
    if isinstance(error, TimeoutError): return 'timeout'
    if isinstance(error, OSError): return 'audio_io_failed'
    if isinstance(error, (ValueError, TypeError, KeyError)): return 'invalid_audio'
    return 'inference_failed'


def release_temporary_audio(path):
    """Unlink only an inode registered by this service, never an arbitrary path."""
    with _TEMP_LOCK:
        expected = _TEMPORARY_FILES.get(path)
        if expected is None:
            return
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            _TEMPORARY_FILES.pop(path, None)
            return
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or (info.st_dev, info.st_ino) != expected):
            raise ValueError('Invalid temporary audio owner or type')
        os.unlink(path)
        _TEMPORARY_FILES.pop(path, None)


@contextmanager
def temporary_audio(suffix):
    """Register before writing and exclude shutdown until that write settles."""
    with _TEMP_LOCK:
        if _TEMP_STOPPING:
            raise RuntimeError('ASR is shutting down')
        output = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
        info = os.fstat(output.fileno())
        _TEMPORARY_FILES[output.name] = (info.st_dev, info.st_ino)
        try:
            private_audio_file(output.fileno())
            yield output
        except BaseException:
            output.close()
            release_temporary_audio(output.name)
            raise
        finally:
            output.close()


def cleanup_temporary_audio():
    global _TEMP_STOPPING
    with _TEMP_LOCK:
        _TEMP_STOPPING = True
        for path in list(_TEMPORARY_FILES):
            try:
                release_temporary_audio(path)
            except (OSError, ValueError):
                try:
                    print('ASR cleanup failed code=temporary_audio_cleanup_failed', flush=True)
                except OSError:
                    pass


def available_model_keys() -> list:
    return [key for key, path in MODEL_PATHS.items() if path.is_dir()]


def model_for(key: str):
    if key not in MODEL_PATHS:
        raise ValueError("Unsupported ASR model")
    path = MODEL_PATHS[key]
    if not path.is_dir():
        raise FileNotFoundError("ASR model is missing")
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

    with temporary_audio('-speech.wav') as output:
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


def _language_probabilities(logits):
    """Accumulate the vocabulary's small probabilities without float32 loss."""
    values = np.asarray(logits, dtype=np.float64)
    weights = np.exp(values - np.max(values))
    probabilities = weights / np.sum(weights, dtype=np.float64)
    import mlx.core as mx
    return mx.array(probabilities.astype(np.float32))


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
    # Preserve quantized logits, but sum the full vocabulary in float64.
    # A float32 softmax can also lose small terms and spuriously cross a gate.
    probabilities = _language_probabilities(logits.astype(mx.float32))
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
                print(f'ASR idle-unload failed code={safe_exception_code(error)}', flush=True)
    threading.Thread(target=maintain, name='asr-idle-maintenance', daemon=True).start()
    return stopped


class Handler(BaseHTTPRequestHandler):
    server_version = "LiveLingoLocalASR/2.1"

    def read_audio_body(self, size):
        deadline = time.monotonic() + BODY_TIMEOUT_SECONDS
        connection = getattr(self, 'connection', None)
        read = getattr(self.rfile, 'read1', self.rfile.read)
        audio = bytearray()
        while len(audio) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError('Audio upload deadline exceeded')
            if connection is not None: connection.settimeout(remaining)
            chunk = read(min(size - len(audio), 65536))
            if time.monotonic() >= deadline: raise TimeoutError('Audio upload deadline exceeded')
            if not chunk: raise ValueError('Incomplete audio request')
            audio.extend(chunk)
        return bytes(audio)

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
        if model_key not in MODEL_RELATIVE_PATHS:
            self.send_json(400, {"error": "Unsupported ASR model"})
            return
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
        cleanup_deferred = False
        receiving_audio = True
        enhancement = {"applied": False, "reason": "disabled"}

        def cleanup():
            finish_request(request_id, model_key)
            INFERENCE_SLOTS.release()
            for path in {temporary_path, model_input_path} - {None}:
                try:
                    release_temporary_audio(path)
                except (OSError, ValueError):
                    try:
                        print('ASR cleanup failed code=temporary_audio_cleanup_failed', flush=True)
                    except OSError:
                        pass

        try:
            audio = self.read_audio_body(size)
            receiving_audio = False
            with temporary_audio('.wav') as temporary:
                temporary_path = temporary.name
                temporary.write(audio)
            model_input_path = temporary_path
            if should_enhance:
                model_input_path, enhancement = speech_band_enhance(temporary_path)
            started = time.monotonic()
            log_id = uuid.uuid4().hex
            print(f"ASR request id={log_id} model={model_key} bytes={size}", flush=True)
            future = INFERENCE_WORKER.submit(run_registered_transcription, request_id, model_input_path, model_key,
                                             language_mode, temporary_path)
            try:
                text = future.result(timeout=INFERENCE_TIMEOUT_SECONDS)
            except TimeoutError:
                if future.done(): raise  # The inference itself raised, rather than a wait deadline.
                if future.cancel():
                    self.send_json(504, {"error": "ASR queue deadline exceeded", "request_id": request_id,
                                         "model": model_key, "retryable": True})
                    return
                # A running tensor call cannot be cancelled by a HTTP timeout.
                # Retain its input/slot until actual completion or process exit.
                cleanup_deferred = True
                future.add_done_callback(lambda finished: cleanup())
                request_shutdown(self.server, 'inference deadline exceeded')
                return
            print(f"ASR completed id={log_id} model={model_key} seconds={time.monotonic() - started:.3f}", flush=True)
            payload = {"text": text, "model": model_key, "request_id": request_id,
                       "audio_enhancement": enhancement}
            if language_mode == "auto":
                payload.update(text)
                label = text['detected_label'] if text['detected_label'] in LANGUAGE_CODES else 'unknown'
                print(f"ASR language id={log_id} label={label} "
                      f"p={text['language_probability']} p_en={text['english_probability']} "
                      f"decode={text['decode']}", flush=True)
            self.send_json(200, payload)
        except TimeoutError as error:
            self.send_json(408 if receiving_audio else 500,
                           {"error": safe_exception_code(error), "request_id": request_id, "model": model_key})
        except Exception as error:
            self.send_json(500, {"error": safe_exception_code(error),
                                 "request_id": request_id, "model": model_key})
        finally:
            if not cleanup_deferred: cleanup()

    def supplied_token(self) -> str:
        token = self.headers.get(TOKEN_HEADER, "") or ""
        if token:
            return token.strip()
        authorization = self.headers.get("Authorization", "") or ""
        if authorization.lower().startswith(BEARER_PREFIX):
            return authorization[len(BEARER_PREFIX):].strip()
        return ""

    def require_authorized(self) -> bool:
        """All routes require a token and the bound local HTTP origin."""
        if not AUTH_TOKEN or not hmac.compare_digest(self.supplied_token().encode('utf-8'),
                                                      AUTH_TOKEN.encode('utf-8')):
            self.send_json(401, {"error": "unauthorized"})
            return False
        def values(name):
            get_all = getattr(self.headers, 'get_all', None)
            return get_all(name, []) if get_all else ([self.headers[name]] if name in self.headers else [])
        hosts, origins = values('Host'), values('Origin')
        if len(hosts) != 1 or len(origins) > 1:
            self.send_json(403, {"error": "invalid local origin"})
            return False
        try:
            raw_host = hosts[0]
            if any(character.isspace() for character in raw_host):
                raise ValueError('Invalid Host')
            target = urlparse('http://' + raw_host)
            if (target.path or target.query or target.fragment or target.username is not None
                    or target.password is not None or target.port != self.server.server_address[1]):
                raise ValueError('Invalid Host')
            hostname = target.hostname
            if hostname != 'localhost' and not ipaddress.ip_address(hostname).is_loopback:
                raise ValueError('Invalid Host')
            if origins:
                origin = urlparse(origins[0])
                if (origin.scheme != 'http' or origin.hostname != hostname or origin.port != target.port
                        or origin.path or origin.query or origin.fragment
                        or origin.username is not None or origin.password is not None):
                    raise ValueError('Invalid Origin')
        except (ValueError, TypeError):
            self.send_json(403, {"error": "invalid local origin"})
            return False
        return True

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
        # BaseHTTPRequestHandler arguments contain the raw request target,
        # including query strings and malformed request lines. Never format it.
        return


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Local-only ASR bridge for LiveLingo")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--models-dir", default=None,
                        help="Model root; defaults to the bundled Resources/Models directory.")
    parser.add_argument("--token", default=None,
                        help="Required request token, or LIVELINGO_ASR_TOKEN; every endpoint requires it.")
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
        raise ValueError("Invalid bind host") from None
    if not address.is_loopback:
        raise ValueError("Refusing to bind a non-loopback address")
    return str(address)


def create_server(host: str, port: int) -> tuple:
    server = ThreadingHTTPServer((host, port), Handler)
    server.handle_error = lambda *_: print('ASR http failure code=http_error', flush=True)
    return server, server.server_address[0], server.server_address[1]


def ready_payload(server, host: str) -> dict:
    available = available_model_keys()
    payload = {
        "event": "ready",
        "protocol": PROTOCOL_VERSION,
        "host": host,
        "port": server.server_address[1],
        "pid": os.getpid(),
        "auth": bool(AUTH_TOKEN),
        "supervised": bool(SUPERVISED),
        "model_count": len(available),
    }
    if SUPERVISED:
        # Only the app's private pipe needs the absolute root for its handshake.
        payload.update(models_root=str(MODEL_ROOT), available_models=available)
    return payload


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
    # An open, full stdout pipe blocks instead of raising. Never put synchronous
    # diagnostics in front of this exit, including an inference-deadline exit.
    # No caller can use the service after its parent exits. A graceful server
    # close can wait for an in-flight inference, so it cannot be the exit gate.
    try:
        # Normally cleanup finishes before exit. A writer holding _TEMP_LOCK or
        # a blocked cleanup diagnostic must not defeat the watchdog deadline.
        cleanup = threading.Thread(target=cleanup_temporary_audio,
                                   name='asr-exit-cleanup', daemon=True)
        cleanup.start()
        cleanup.join(timeout=0.05)
    finally:
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
    if AUTH_TOKEN is None:
        print('错误：ASR request token is required', file=sys.stderr, flush=True)
        return 2
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
        cleanup_temporary_audio()
        server.server_close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        cleanup_temporary_audio()
        print('ASR startup failed code=' + safe_exception_code(error), file=sys.stderr, flush=True)
        sys.exit(1)
