"""Offline route comparisons using exported App prompts and the App JSONL worker.

Run from the checkout with ``python -m Scripts.target_eval.run_strategies``.
Only --dry-run uses a fake worker; a normal invocation loads local MLX weights.
Reports are local corpus evidence, including source/reference/generated text.
The scoreboard's persistent session lock and LiveLingo process guard are reused.
No downloads, worker changes, automatic route selection or helper builds occur.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from typing import Sequence

from . import corpora as c, metrics as m
from .. import scoreboard_energy as energy

TARGETS = ("zh-Hans", "zh-Hant-TW", "zh-Hant-HK", "en", "es", "fr")
ROUTES = ("direct", "via-en", "hans-convert")
MODELS = {"4b": "mlx-community/Qwen3.5-4B-MLX-8bit",
          "9b": "lmstudio-community/Qwen3.5-9B-MLX-4bit"}
TARGET_NAMES = {"zh-Hans": "Simplified Chinese", "zh-Hant-TW": "Traditional Chinese (Taiwan)",
                "zh-Hant-HK": "Traditional Chinese (Hong Kong and Macao)",
                "en": "English", "es": "Spanish", "fr": "French"}
SOURCE_NAMES = {"ar": "Arabic", "zh": "Chinese", "en": "English", "fr": "French",
                "ru": "Russian", "es": "Spanish", "yue": "Cantonese", "ja": "Japanese",
                "ko": "Korean", "de": "German", "hi": "Hindi", "th": "Thai"}
CONTROL_MARKERS = ("<|im_start|>", "<|im_end|>", "<|endoftext|>")
UNKNOWN_STATS = ("input_tokens", "reused_prefix_tokens", "exact_first_token_seconds")


def _load_scoreboard():
    # The existing hyphenated entry point imports siblings as top-level modules.
    # Importing it runs no CLI, worker, sampler, compiler or model initialization.
    scripts = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(scripts))
    try:
        spec = importlib.util.spec_from_file_location("strategy_scoreboard", scripts / "livelingo-scoreboard.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


scoreboard = _load_scoreboard()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def positive(value, label):
    if type(value) not in (float, int) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"{label} must be finite and positive")


def distinct(values, choices, label):
    if not values or len(set(values)) != len(values) or any(v not in choices for v in values):
        raise ValueError(f"{label} must contain distinct supported values")


class PromptBundle:
    """Verify manifest byte counts/digests; never derive or rewrite a prompt."""

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        raw = (self.directory / "manifest.json").read_bytes()
        manifest = json.loads(raw)
        if (not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1
                or manifest.get("encoding") != "UTF-8" or manifest.get("addedTrailingNewline") is not False
                or not isinstance(manifest.get("prompts"), list)):
            raise ValueError("unsupported prompt export manifest")
        self.entries, self.prompts, self.files = [], {}, {"manifest.json": digest(raw)}
        for entry in manifest["prompts"]:
            if not isinstance(entry, dict):
                raise ValueError("invalid prompt entry")
            locale, name, file = (entry.get(k) for k in ("targetLocale", "name", "file"))
            if (locale not in TARGETS or not isinstance(name, str) or not name
                    or not isinstance(file, str) or Path(file).name != file or file in ("", ".", "..")
                    or (locale, name) in self.prompts or file in self.files):
                raise ValueError("invalid or duplicate prompt identity/file")
            path = self.directory / file
            if path.is_symlink() or not path.is_file():
                raise ValueError("prompt files must be regular files without symlinks")
            data = path.read_bytes()
            if (type(entry.get("byteCount")) is not int or entry["byteCount"] != len(data)
                    or entry.get("sha256") != digest(data)):
                raise ValueError("prompt bytes do not match the export manifest")
            prompt = data.decode("utf-8")
            if not prompt or any(marker in prompt for marker in CONTROL_MARKERS):
                raise ValueError("empty prompt or ChatML control marker in exported prompt")
            self.prompts[locale, name] = prompt
            self.files[file] = digest(data)
            self.entries.append({k: entry[k] for k in ("targetLocale", "name", "file", "byteCount", "sha256")})
        self.manifest_sha256 = digest(raw)

    def caption(self, target, profile):
        key = (target, f"caption-{profile}")
        if key not in self.prompts:
            raise ValueError(f"missing exported prompt {target}/caption-{profile}; "
                             "do not synthesize it from a different target")
        return self.prompts[key]

    def verify_unchanged(self):
        if any(digest((self.directory / file).read_bytes()) != sha for file, sha in self.files.items()):
            raise ValueError("prompt export changed during the run")


def load_corpus(args):
    """Keep the existing curated-turn/subtitle/line alignment, without splitting."""
    if args.corpus == "un":
        if not args.input or args.locale_file:
            raise ValueError("UN requires --input and does not use --locale-file")
        result = c.read_un(args.input, include_partial=args.include_partial)
        return result.units, {"excluded": list(result.excluded)}
    if args.include_partial:
        raise ValueError("--include-partial is UN-only")
    if args.corpus == "jsonl":
        if not args.input or args.locale_file:
            raise ValueError("JSONL requires --input and does not use --locale-file")
        rows = [json.loads(line) for line in Path(args.input).read_text(encoding="utf-8-sig").splitlines()]
        units = []
        for row in rows:
            if (not isinstance(row, dict) or not isinstance(row.get("metadata", {}), dict)
                    or not isinstance(row.get("id"), str) or not row["id"].strip()
                    or not isinstance(row.get("corpus"), str) or not row["corpus"].strip()
                    or not isinstance(row.get("texts"), dict) or not row["texts"]
                    or any(not isinstance(k, str) or not k or not isinstance(v, str) or not v.strip()
                           for k, v in row["texts"].items())):
                raise ValueError("invalid corpora.ParallelUnit JSONL row")
            units.append(c.ParallelUnit(row["id"], row["corpus"], row["texts"], row.get("metadata", {})))
        return tuple(units), {"coverage": "see each exported unit's corpus_diagnostics"}
    if args.input:
        raise ValueError("--input is only for UN/JSONL; use --locale-file")
    paths = c._locale_files(args.locale_file)
    if args.corpus == "flores-plus":
        return c.read_flores_plus(paths, split=args.split), {}
    if not args.document_id:
        raise ValueError("CS50/TED requires --document-id")
    reader = c.read_cs50_srts if args.corpus == "cs50" else c.read_ted_srts
    result = reader(paths, document_id=args.document_id)
    return result.units, {"unmatched_cues": result.unmatched}


@dataclass(frozen=True)
class Route:
    target: str
    name: str

    @property
    def hops(self):
        if self.name == "via-en":
            return ("en", self.target)
        return ("zh-Hans" if self.name == "hans-convert" else self.target,)


def reference_locale(unit, target):
    if target == "zh-Hans" and target not in unit.texts:
        return "zh"
    # A generic Hant reference is not silently labelled as TW/HK gold.
    return target


def cases_for(units, targets, routes, sources=None):
    distinct(targets, TARGETS, "targets")
    distinct(routes, ROUTES, "routes")
    if not units or len({u.id for u in units}) != len(units):
        raise ValueError("corpus must contain nonempty, uniquely identified units")
    selected = [Route(target, route) for target in targets for route in routes]
    for route in selected:
        if route.name == "via-en" and route.target not in ("es", "fr"):
            raise ValueError("via-en is only an es/fr non-English-source comparison (PLAN I.7 / II.es-fr)")
        if route.name == "hans-convert" and not route.target.startswith("zh-Hant-"):
            raise ValueError("hans-convert requires zh-Hant-TW/HK (PLAN I.7 / II.zh-Hant)")
    if sources is None:
        common = set.intersection(*(set(u.texts) for u in units))
        sources = sorted(common.intersection(SOURCE_NAMES) - set(targets) - {"zh" if "zh-Hans" in targets else ""})
        if "via-en" in routes:
            sources = [s for s in sources if s != "en"]
    distinct(sources, SOURCE_NAMES, "sources")
    if "via-en" in routes and "en" in sources:
        raise ValueError("via-en requires non-English sources; compare English-source direct separately")
    cases = {}
    for route in selected:
        rows = []
        for unit in units:
            ref_locale = reference_locale(unit, route.target)
            if ref_locale not in unit.texts:
                raise ValueError(f"missing reference locale {route.target}; no reference conversion is inferred")
            for source in sources:
                if source not in unit.texts:
                    raise ValueError(f"missing source locale {source}")
                if source == route.target and source != "en" or source == "zh" and route.target == "zh-Hans":
                    raise ValueError("select different source/target locales; only en/en passthrough is defined here")
                # Fail before launching a worker on invalid terms or control markers.
                if any(marker in unit.texts[source] for marker in CONTROL_MARKERS):
                    raise ValueError("source contains a model control marker")
                term_map = unit.metadata.get("terms", {})
                if not isinstance(term_map, dict):
                    raise ValueError("unit metadata.terms must map target locales to required terms")
                terms = term_map.get(route.target, [])
                m.terminology_hit_rate("", terms)
                rows.append({"id": json.dumps([unit.id, source, route.target], ensure_ascii=False),
                             "unit_id": unit.id, "corpus": unit.corpus, "source": unit.texts[source],
                             "source_locale": source, "reference": unit.texts[ref_locale],
                             "reference_locale": ref_locale, "target_locale": route.target, "terms": terms})
        cases[route] = rows
    return cases


def user_input(text, source, target, profile):
    """App ChatML + 9B JSON / 4B quoted source transport, without hints/retries."""
    instruction = (f"Source language: {SOURCE_NAMES[source]} ({source}). "
                   f"Translate the quoted lecture content into {TARGET_NAMES[target]}."
                   + (" Use standard written Mandarin wording." if source == "yue" and target.startswith("zh") else ""))
    if profile == "9b":
        payload = {"source_text_to_translate": text}
        if source != "en":
            payload["translation_instruction"] = instruction
        return json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    if source == "en":
        return text
    return (instruction + "\n--- END TRANSLATION METADATA (DO NOT TRANSLATE); BEGIN QUOTED LECTURE CONTENT ---\n"
            + text + "\n--- END QUOTED LECTURE CONTENT ---")


def chat_prompt(system, text, source, target, profile):
    if any(marker in system or marker in text for marker in CONTROL_MARKERS):
        raise ValueError("input contains a model control marker")
    return ("<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n"
            + user_input(text, source, target, profile)
            + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")


def stats(start, end, first=None, final=None, thinking=None):
    return {"input_tokens": None, "output_tokens": final + thinking if final is not None and thinking is not None else None,
            "final_tokens": final, "thinking_tokens": thinking, "reused_prefix_tokens": None,
            "first_token_seconds": first - start if first is not None else None,
            "exact_first_token_seconds": None, "first_token_method": "first_nonempty_snapshot_or_done_receive; throttled_proxy",
            "total_seconds": end - start, "start_mono": start, "end_mono": end}


class WorkerFailure(RuntimeError):
    """Codes only: raw worker diagnostics can contain local paths or text."""


class MLXWorker:
    def __init__(self, python, worker, model, state, profile, timeout=120, final_budget=160):
        self.command = [str(python), "-u", "-B", str(worker), "--model", str(model), "--state-directory", str(state)]
        self.profile, self.timeout, self.final_budget = profile, timeout, final_budget
        self.process = None
        self.events = queue.Queue()
        self.stderr_bytes, self.stderr_digest = 0, hashlib.sha256()
        self.threads = []

    def _read_stdout(self):
        try:
            while line := self.process.stdout.readline(2_097_153):
                if len(line) > 2_097_152 or not line.endswith(b"\n"):
                    raise WorkerFailure("oversized_or_unterminated_worker_record")
                received = time.monotonic()
                row = json.loads(line)
                if not isinstance(row, dict) or not isinstance(row.get("event"), str):
                    raise WorkerFailure("invalid_worker_record")
                self.events.put((row, received))
            self.events.put(WorkerFailure("worker_stream_ended"))
        except (ValueError, OSError, WorkerFailure):
            self.events.put(WorkerFailure("invalid_worker_stream"))

    def _read_stderr(self):
        while chunk := self.process.stderr.read(65536):
            self.stderr_bytes += len(chunk)
            self.stderr_digest.update(chunk)

    def _send(self, row):
        data = json.dumps(row, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
        if len(data) > 2_097_152:
            raise ValueError("oversized worker request")
        try:
            self.process.stdin.write(data)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise WorkerFailure("worker_input_closed") from None

    def _event(self, deadline):
        try:
            item = self.events.get(timeout=max(0., deadline - time.monotonic()))
        except queue.Empty:
            raise WorkerFailure("worker_timeout") from None
        if isinstance(item, Exception):
            raise item
        return item

    def _control(self, op, identity):
        control = f"{op}-{identity}"
        self._send({"op": op, "id": identity, "controlID": control})
        deadline = time.monotonic() + self.timeout
        while True:
            event, _ = self._event(deadline)
            if event["event"] in ("memory", "model_state"):
                continue
            if (event["event"] != op or event.get("id") != identity or event.get("controlID") != control
                    or event.get("state") != ("ready_to_exit" if op == "shutdown" else "released")):
                raise WorkerFailure("worker_control_not_confirmed")
            return

    def __enter__(self):
        env = dict(os.environ)
        for key in ("PYTHONHOME", "PYTHONPATH", "LIVELINGO_SCOREBOARD_TIMINGS"):
            env.pop(key, None)
        env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", PYTHONDONTWRITEBYTECODE="1", TOKENIZERS_PARALLELISM="false")
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        for reader in (self._read_stdout, self._read_stderr):
            thread = threading.Thread(target=reader, daemon=True)
            thread.start()
            self.threads.append(thread)
        try:
            event, _ = self._event(time.monotonic() + self.timeout)
            if event.get("event") != "ready" or event.get("version") != 2:
                raise WorkerFailure("unsupported_worker_protocol")
        except BaseException:
            self.close()
            raise
        return self

    def generate(self, system, text, source, target):
        identity = f"route-{time.monotonic_ns()}"
        prompt = chat_prompt(system, text, source, target, self.profile)
        start, first = time.monotonic(), None
        self._send({"op": "generate", "id": identity, "prompt": prompt, "prefix": "", "purpose": "text",
                    "thinking": False, "thinkingBudget": 16384, "finalBudget": self.final_budget, "usePrefixCache": True})
        deadline = start + self.timeout
        while True:
            event, received = self._event(deadline)
            kind = event["event"]
            if kind in ("memory", "model_state"):
                continue
            if event.get("id") != identity:
                raise WorkerFailure("unexpected_worker_request_id")
            if kind == "loading":
                continue
            if kind == "snapshot":
                if not isinstance(event.get("wire"), str):
                    raise WorkerFailure("invalid_worker_snapshot")
                if event["wire"] and first is None:
                    first = received
                continue
            if kind == "error":
                self._control("cancel", identity)
                raise WorkerFailure("output_budget_exhausted" if event.get("code") == "output_budget_exhausted" else "worker_generation_failed")
            if kind != "done" or not isinstance(event.get("text"), str):
                raise WorkerFailure("invalid_worker_completion")
            counts = []
            for key in ("finalTokens", "thinkingTokens"):
                value = event.get(key)
                if value is not None and (type(value) is not int or value < 0):
                    raise WorkerFailure("invalid_worker_token_count")
                counts.append(value)
            if first is None and event["text"]:
                first = received
            result = {"output": event["text"], **stats(start, received, first, *counts)}
            self._control("ack", identity)
            return result

    def close(self):
        if self.process is None:
            return
        # Only this Popen-owned child is stopped; never search/kill other workers.
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        for thread in self.threads:
            thread.join(timeout=5)
        for handle in (self.process.stdin, self.process.stdout, self.process.stderr):
            handle.close()

    def __exit__(self, exc_type, exc, traceback):
        try:
            if exc_type is None:
                self._control("shutdown", "runner")
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    raise WorkerFailure("worker_shutdown_timeout") from None
                if self.process.returncode != 0:
                    raise WorkerFailure("worker_nonzero_exit")
        finally:
            self.close()


class FakeWorker:
    """Deterministic fake translations, no subprocess/tokenizer/model imports."""
    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def generate(self, system, text, source, target):
        start = time.monotonic()
        return {"output": f"DRY-RUN {target}: {text}", **stats(start, time.monotonic())}


def guard_other_workers(worker, owned_pid=None):
    """Also refuse standalone App workers, which the CLI/App census cannot see."""
    text = subprocess.check_output(["/bin/ps", "-ww", "-axo", "pid=,stat=,args="], text=True)
    for line in text.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            raise WorkerFailure("unrecognized_worker_process_census")
        pid, state, command = fields
        if int(pid) in (os.getpid(), owned_pid) or state.startswith("Z"):
            continue
        if ("--model" in command and "--state-directory" in command
                and (str(worker) in command or "mlx_runtime/worker.py" in command or "LanguageRuntime/worker.py" in command)):
            raise scoreboard.Rejected("another_livelingo_run_active")


def convert(text, target, executable, timeout, dry_run):
    if dry_run:
        return f"DRY-RUN converted {target}: {text}"
    env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([str(executable)], input=json.dumps({"targetLocale": target, "text": text}),
                            capture_output=True, text=True, encoding="utf-8", timeout=timeout, env=env)
    if result.returncode:
        raise WorkerFailure("converter_nonzero_exit")
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or not isinstance(value.get("text"), str) or not value["text"].strip():
        raise WorkerFailure("invalid_converter_response")
    return value["text"]


def complete_sum(values):
    return sum(values) if all(value is not None for value in values) else None


def summarize(rows, quality):
    calls = [call for row in rows for call in row["calls"]]
    terms = [row["quality"]["terminology"] for row in rows]
    term_count, hit_count = sum(t["term_count"] for t in terms), sum(t["hit_count"] for t in terms)
    purity = [row["quality"]["purity"] for row in rows]
    letters, forbidden = sum(p["letter_count"] for p in purity), sum(p["forbidden_letter_count"] for p in purity)
    durations = sorted(row["total_seconds"] for row in rows)
    first = sorted(row["first_token_seconds"] for row in rows if row["first_token_seconds"] is not None)
    return {"sample_count": len(rows), "call_count": len(calls), "chrfpp": quality["chrfpp"],
            "terminology": {"hit_count": hit_count, "term_count": term_count, "rate": hit_count / term_count if term_count else None},
            "script_purity": 1 - forbidden / letters if letters else None,
            "input_tokens": complete_sum([call["input_tokens"] for call in calls]),
            "output_tokens": complete_sum([call["output_tokens"] for call in calls]),
            "reused_prefix_tokens": complete_sum([call["reused_prefix_tokens"] for call in calls]),
            "total_seconds": sum(durations), "mean_seconds": sum(durations) / len(rows),
            "p95_seconds": durations[math.ceil(.95 * len(durations)) - 1],
            "first_token_seconds": {"sample_count": len(first), "mean": sum(first) / len(first) if first else None,
                                    "p95": first[math.ceil(.95 * len(first)) - 1] if first else None},
            "gross_j": complete_sum([row["energy"]["gross_j"] for row in rows]),
            "energy_comparable": False}


def disabled_energy(reason):
    return {"mode": reason, "gross_j": None, "rails_j": dict.fromkeys(energy.RAILS),
            "comparable": False, "scope": energy.SCOPE}


def markdown(report):
    lines = ["# Target route comparison", "", f"Mode: {'DRY RUN — synthetic outputs; no quality/performance evidence' if report['dry_run'] else 'local MLX worker'}.", "",
             "| Target | Route | Units | Calls | chrF++ | Output tokens | Total s | Gross J |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for route in report["routes"]:
        s = route["summary"]
        def display(value):
            return "unknown" if value is None else (f"{value:.3f}" if isinstance(value, float) else str(value))
        lines.append(f"| {route['target_locale']} | {route['route']} | " + " | ".join(display(s[k]) for k in
                     ("sample_count", "call_count", "chrfpp", "output_tokens", "total_seconds", "gross_j")) + " |")
    lines += ["", "Input tokens, reused prefix tokens and exact first-token time are unavailable in protocol v2.",
              "First-token seconds use the first visible snapshot/done receipt (a throttled proxy).",
              "Energy is whole-machine gross CPU/GPU/ANE energy; AC, thermal and interference are unverified.",
              "No App acceptance/retries, human review, classroom weighting or route-switch gate is established.",
              "UN units are curated turns, SRT units are overlap groups; no sentence/audio times are inferred."]
    return "\n".join(lines) + "\n"


def run(args, *, process_provider=None, worker_factory=None, sampler_factory=None):
    out = c.validate_output_path(args.output_dir)
    if out.exists() or out.is_symlink():
        raise FileExistsError("output directory already exists; refusing to overwrite")
    positive(args.timeout_seconds, "timeout seconds")
    if type(args.final_budget) is not int or not 1 <= args.final_budget <= 4096:
        raise ValueError("final budget must be between 1 and 4096")
    if type(args.bootstrap_iterations) is not int or args.bootstrap_iterations < 1:
        raise ValueError("bootstrap iterations must be a positive integer")
    if not math.isfinite(args.sample_interval) or not .01 <= args.sample_interval <= 3600:
        raise ValueError("sample interval must be between .01 and 3600 seconds")
    bundle = PromptBundle(args.prompts_dir)
    units, diagnostics = load_corpus(args)
    cases = cases_for(units, args.targets, args.routes, args.sources)
    for route, rows in cases.items():
        if not (route.target == "en" and all(row["source_locale"] == "en" for row in rows)):
            for target in route.hops:
                bundle.caption(target, args.profile)
    converter = Path(args.converter).resolve() if args.converter else None
    if "hans-convert" in args.routes and not args.dry_run and (converter is None or not converter.is_file() or not os.access(converter, os.X_OK)):
        raise ValueError("hans-convert needs --converter: an audited local executable; no conversion table is invented")
    worker_path = Path(args.worker or os.environ.get("LIVELINGO_MLX_WORKER", Path(__file__).resolve().parents[1] / "mlx_runtime/worker.py")).resolve()
    runtime = {"worker_sha256": digest(worker_path.read_bytes()), "profile": args.profile}
    converter_sha = digest(converter.read_bytes()) if converter is not None else None
    has_calls = any(route.target != "en" or any(row["source_locale"] != "en" for row in rows) for route, rows in cases.items())
    if not args.dry_run and has_calls:
        python = args.python or os.environ.get("LIVELINGO_MLX_PYTHON")
        models = args.models_root or os.environ.get("LIVELINGO_MLX_MODELS")
        if not python or not models:
            raise ValueError("set LIVELINGO_MLX_PYTHON and LIVELINGO_MLX_MODELS (or --python/--models-root)")
        python, model = Path(python).resolve(), Path(models).resolve() / MODELS[args.profile]
        if not python.is_file() or not os.access(python, os.X_OK):
            raise ValueError("worker Python must be an existing executable")
        for file in ("config.json", "tokenizer.json"):
            runtime[file + "_sha256"] = digest((model / file).read_bytes())
        runtime["model_relative_directory"] = MODELS[args.profile]
        if not args.no_energy and not args.energy_helper:
            raise ValueError("supply --energy-helper (existing IOReport executable) or --no-energy; no helper is built")
        if args.energy_helper and (not Path(args.energy_helper).is_file() or not os.access(args.energy_helper, os.X_OK)):
            raise ValueError("energy helper must be an existing executable")
    provider = process_provider or scoreboard.read_processes
    # The default path is exactly the scoreboard's lock, never the output leaf.
    with scoreboard.session_lock(scoreboard.DEFAULT):
        scoreboard.preflight_processes(provider)
        if not args.dry_run:
            guard_other_workers(worker_path)
        out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        c.validate_output_path(out)
        out.mkdir(mode=0o700)  # atomic reservation; refuse files, dirs and races
        factory = worker_factory or (FakeWorker if args.dry_run or not has_calls else
            lambda: MLXWorker(python, worker_path, model, out / "worker-state", args.profile,
                              args.timeout_seconds, args.final_budget))
        sampler = None if args.dry_run or args.no_energy or not has_calls else (sampler_factory or energy.PowerSampler)(
            helper_path=args.energy_helper, interval=args.sample_interval)
        route_results = [{"target_locale": route.target, "route": route.name,
                          "hops": list(route.hops), "results": []} for route in cases]
        call_count = 0
        try:
            if sampler:
                sampler.start()
            with factory() as worker:
                # Alternate routes on the exact same unit/source pair rather
                # than running an entire baseline before the candidate.
                for index in range(len(next(iter(cases.values())))):
                    for route, route_result in zip(cases, route_results, strict=True):
                        example = cases[route][index]
                        row = {**example, "calls": [], "hypothesis": example["source"], "passthrough": False}
                        start = time.monotonic()
                        source = example["source_locale"]
                        if route.target == "en" and source == "en":
                            row["passthrough"] = True
                        else:
                            for target in route.hops:
                                scoreboard.preflight_processes(provider)
                                if not args.dry_run:
                                    guard_other_workers(worker_path, getattr(getattr(worker, "process", None), "pid", None))
                                system = bundle.caption(target, args.profile)
                                text = row["hypothesis"]
                                result = worker.generate(system, text, source, target)
                                row["calls"].append({**result, "input": text, "source_locale": source,
                                                     "target_locale": target, "worker_first_generation": call_count == 0,
                                                     "prompt_sha256": digest(system.encode("utf-8"))})
                                call_count += 1
                                row["hypothesis"], source = result["output"], "en" if target == "en" else target
                            if route.name == "hans-convert":
                                row["hypothesis"] = convert(row["hypothesis"], route.target, converter, args.timeout_seconds, args.dry_run)
                        row.update(start_mono=start, end_mono=time.monotonic())
                        row["total_seconds"] = row["end_mono"] - start
                        for field in ("input_tokens", "output_tokens", "reused_prefix_tokens"):
                            row[field] = complete_sum([call[field] for call in row["calls"]])
                        last = row["calls"][-1] if row["calls"] else None
                        row["first_token_seconds"] = (last["start_mono"] - start + last["first_token_seconds"]
                            if last is not None and last["first_token_seconds"] is not None and route.name != "hans-convert" else None)
                        row["first_token_method"] = "final_generation_first_visible_output; unavailable_after_nonstreaming_conversion"
                        row["exact_first_token_seconds"] = None
                        route_result["results"].append(row)
        finally:
            if sampler:
                sampler.stop()  # final partial interval flushed before window integration
        samples = sampler.snapshot() if sampler else []
        for route in route_results:
            route["quality"] = m.evaluate(route["results"])
            for row, q in zip(route["results"], route["quality"]["examples"], strict=True):
                row["quality"] = q
            for row in route["results"]:
                row["energy"] = energy.window_energy(samples, row["start_mono"], row["end_mono"]) if sampler else disabled_energy("dry_run" if args.dry_run else "disabled")
                for call in row["calls"]:
                    call["energy"] = energy.window_energy(samples, call["start_mono"], call["end_mono"]) if sampler else disabled_energy("dry_run" if args.dry_run else "disabled")
            route["summary"] = summarize(route["results"], route["quality"])
        bundle.verify_unchanged()
        if digest(worker_path.read_bytes()) != runtime["worker_sha256"] or converter is not None and digest(converter.read_bytes()) != converter_sha:
            raise ValueError("worker/converter changed during the run")
        comparisons = []
        for target in args.targets:
            group = [r for r in route_results if r["target_locale"] == target]
            for candidate in group[1:]:
                comparisons.append({"target_locale": target, "baseline_route": group[0]["route"],
                                    "candidate_route": candidate["route"], **m.compare(group[0]["results"], candidate["results"],
                                        iterations=args.bootstrap_iterations, seed=0)})
        report = {"schema_version": 1, "dry_run": args.dry_run, "status": "completed", "runtime": runtime,
                  "prompts": {"manifest_sha256": bundle.manifest_sha256, "entries": bundle.entries},
                  "converter": {"sha256": converter_sha, "protocol": "stdin JSON {targetLocale,text}; stdout JSON {text}"} if converter else None,
                  "corpus": {"unit_count": len(units), "diagnostics": diagnostics},
                  "settings": {"profile": args.profile, "final_budget": args.final_budget, "timeout_seconds": args.timeout_seconds,
                               "sample_interval": args.sample_interval, "routes": args.routes, "targets": args.targets},
                  "methods": {"unknown_worker_fields": list(UNKNOWN_STATS), "output_tokens": "finalTokens + thinkingTokens; excludes EOS",
                              "first_token_time": "first nonempty snapshot/done receipt; snapshots throttled to 100ms; not exact TTFT",
                              "route_order": "per unit, routes in requested order; one persistent worker, sequential calls, warm shared prefix cache",
                              "timing_scope": "call starts immediately before generate and ends at done; row also includes process guards, ACK and conversion; first generation includes model load; p95 is nearest rank",
                              "input_transport": "App nonthinking ChatML; 9B JSON / 4B quoted content; no auxiliary hints, acceptance or retries",
                              "unit": "one supplied aligned unit/source pair; UN turns and SRT overlap groups are not sentence-aligned",
                              "confidence_interval": "metrics.compare paired corpus chrF++ bootstrap, 95%; supplied units, no classroom weighting",
                              "energy": "whole-machine gross rails; no idle subtraction or verified AC/thermal/interference"},
                  "route_switch_gate": {"established": False, "reason": "No acceptance/human-error/weighted-energy or end-to-end G4 evidence; no production route changes"},
                  "energy": {"enabled": sampler is not None, "sampler_metadata": sampler.metadata if sampler else {},
                             "sampler_errors": sampler.errors if sampler else [], "samples": samples},
                  "routes": route_results, "comparisons": comparisons}
        c.write_json(report, out / "report.json")
        c._write_text(out / "summary.md", markdown(report))
        return report


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--prompts-dir", required=True, type=Path)
    p.add_argument("--corpus", choices=("un", "jsonl", "cs50", "ted", "flores-plus"), default="un")
    p.add_argument("--input", type=Path)
    p.add_argument("--locale-file", action="append", default=[], metavar="LOCALE=PATH")
    p.add_argument("--document-id")
    p.add_argument("--split", default="devtest")
    p.add_argument("--include-partial", action="store_true")
    p.add_argument("--targets", nargs="+", choices=TARGETS, required=True)
    p.add_argument("--routes", nargs="+", choices=ROUTES, required=True)
    p.add_argument("--sources", nargs="+", choices=tuple(SOURCE_NAMES))
    p.add_argument("--profile", choices=tuple(MODELS), default="9b")
    p.add_argument("--output-dir", required=True, type=Path)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--python", type=Path)
    p.add_argument("--worker", type=Path)
    p.add_argument("--models-root", type=Path)
    p.add_argument("--converter", type=Path)
    p.add_argument("--energy-helper", type=Path)
    p.add_argument("--no-energy", action="store_true")
    p.add_argument("--sample-interval", type=float, default=.1)
    p.add_argument("--timeout-seconds", type=float, default=120)
    p.add_argument("--final-budget", type=int, default=160)
    p.add_argument("--bootstrap-iterations", type=int, default=1000)
    return p


def main(argv: Sequence[str] | None = None):
    p = parser()
    args = p.parse_args(argv)
    try:
        report = run(args)
    except (OSError, ValueError, RuntimeError, scoreboard.Rejected, subprocess.SubprocessError) as error:
        p.error(error.reason if isinstance(error, scoreboard.Rejected) else str(error))
    print(json.dumps({"status": report["status"], "dry_run": report["dry_run"],
                      "output": str(c.validate_output_path(args.output_dir).relative_to(c.output_root())),
                      "routes": [{"target": r["target_locale"], "route": r["route"], "calls": r["summary"]["call_count"]} for r in report["routes"]]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
