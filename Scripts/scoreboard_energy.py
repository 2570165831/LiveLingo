#!/usr/bin/env python3
"""Unprivileged whole-machine rail energy, using only the standard library.

PowerSampler(helper_path=None, interval=1.0) supports start/stop and ``with``.
The default helper is built/reused at work/energy-probe/scoreboard-ioreport,
with its module cache at the lab's work/dd-scoreboard/energy-module-cache.
No installation is performed. ``samples`` is a list of interval deltas, ``snapshot()``
returns a consistent copy, and ``report(start=None, end=None)`` integrates it.
All timestamps use the same mach_absolute_time clock as time.monotonic().

window_energy(samples, start, end) apportions boundary bins linearly. Missing
rails/units stay None; measured partial energy is separate from window energy.
idle_net(samples, run, pre, post, audio_seconds, conditions=None) takes pairs of
monotonic timestamps (or dictionaries with start_mono/end_mono). Conditions
must explicitly verify thermal, AC and interference before comparable is true.

IOReport counters are OS estimates, include other processes, and exclude the
display and other unselected rails. Fallback busy times are proxies, never J:
CPU uses aggregate core seconds; GPU uses residency or sampled utilization.
"""

import copy
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import threading
import time

try:
    from Scripts.privacy_cli import PrivateArgumentParser
except ModuleNotFoundError as error:
    if error.name != "Scripts":
        raise
    from privacy_cli import PrivateArgumentParser

RAILS = ("cpu", "gpu", "ane")
ENERGY_UNITS = {"J": 1.0, "mJ": 1e-3, "uJ": 1e-6, "µJ": 1e-6,
                "μJ": 1e-6, "nJ": 1e-9}
ENERGY_NAMES = {"CPU Energy": "cpu", "GPU Energy": "gpu", "ANE": "ane",
                "ANE Energy": "ane"}
RESIDENCY_UNITS = {"24Mticks": 1 / 24_000_000, "ns": 1e-9,
                   "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1.0}
SCOPE = "Whole-machine CPU/GPU/ANE model counters; includes background processes; excludes display; not App-exclusive."
HELPER_FAILURE_REASONS = frozenset(("api_unavailable", "no_supported_channels", "subscription_unavailable",
                                    "initial_snapshot_unavailable", "snapshot_unavailable", "delta_unavailable"))
ERROR_REASONS = frozenset(("invalid_helper_record", "unexpected_helper_record", "helper_stream_ended",
                           "helper_stderr_present", "helper_stderr_read_failed", "helper_build_failed",
                           "helper_start_failed", "native_helper_not_ready", "helper_not_found_or_not_executable",
                           "busy_proxy_not_ready", "helper_stop_timeout_final_interval_unknown",
                           "helper_nonzero_exit", "busy_proxy_stop_timeout", "unknown_sampler_error",
                           "ioreport:helper_unavailable")) | frozenset("ioreport:" + r for r in HELPER_FAILURE_REASONS)
SOURCES = frozenset(("ioreport", "host_statistics+ioreg", "synthetic_ioreport"))
MODES = frozenset(("energy_counters", "busy_time_proxy"))


def _number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def _nonnegative(value):
    return _number(value) and value >= 0


def _safe_id(value):
    if value is None:
        return None
    if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{16}", value):
        return value.lower()
    # User-provided helpers can put arbitrary text in every field, including
    # IDs. Preserve identity for audit/deduplication without retaining that text.
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=True).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def _safe_format(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 255 else None


def _safe_channel(ch, *, counter=False):
    """An explicit protocol whitelist; never copy an input dictionary."""
    if not isinstance(ch, dict):
        return None
    group, name = ch.get("group"), ch.get("name")
    energy = group == "Energy Model" and isinstance(name, str) and name in ENERGY_NAMES
    gpu = group == "GPU Stats" and name == "GPUPH" and ch.get("subgroup") == "GPU Performance States"
    if not energy and not gpu:
        return None
    unit = ch.get("unit")
    allowed_units = ENERGY_UNITS if energy else RESIDENCY_UNITS
    result = {"id": _safe_id(ch.get("id")), "group": group, "name": name,
              "unit": unit if isinstance(unit, str) and unit in allowed_units else "unknown",
              "format": _safe_format(ch.get("format"))}
    if gpu:
        result["subgroup"] = "GPU Performance States"
    if counter:
        result["value"] = ch.get("value") if _nonnegative(ch.get("value")) else None
    return result


def _safe_gpu_states(channels):
    result = []
    for ch in channels:
        if not isinstance(ch, dict):
            continue
        unit = ch.get("unit")
        states = []
        for state in ch.get("states", []):
            if not isinstance(state, dict):
                continue
            name = state.get("name")
            valid_name = (isinstance(name, str) and
                          (name in ("OFF", "IDLE", "DOWN") or re.fullmatch(r"P\d{1,4}", name) is not None))
            states.append({"name": name if valid_name else "unknown",
                           "residency": state.get("residency") if _nonnegative(state.get("residency")) else None})
        result.append({"id": _safe_id(ch.get("id")),
                       "unit": unit if isinstance(unit, str) and unit in RESIDENCY_UNITS else "unknown",
                       "states": states})
    return result


def _ready_metadata(raw):
    uid = raw.get("uid")
    clock = raw.get("clock")
    return {"type": "ready", "source": "ioreport", "sampler_uid": os.geteuid(),
            "uid": uid if isinstance(uid, int) and not isinstance(uid, bool) and 0 <= uid < 2 ** 32 else None,
            "clock": clock if clock == "mach_absolute_time_seconds" else "unknown",
            "ready_mono": raw.get("ready_mono") if _nonnegative(raw.get("ready_mono")) else None,
            "initial_cumulative_snapshot_discarded": raw.get("initial_cumulative_snapshot_discarded") is True,
            "channels": [safe for ch in raw.get("channels", []) if (safe := _safe_channel(ch)) is not None]}


def build_helper():
    """Build/reuse the local bridge with all compiler writes in explicit paths.

    A source+binary checksum receipt prevents reusing a stale helper. Requires
    the already installed Apple compiler/SDK; never downloads anything.
    """
    root = Path(__file__).resolve().parents[1]
    scratch = root / "work/energy-probe"
    cache = root.parent / "work/dd-scoreboard/energy-module-cache"
    source = Path(__file__).with_name("scoreboard-ioreport.c")
    for directory in (scratch, cache):
        if directory.resolve() != directory:
            raise OSError("compiler directory must not resolve through a symlink")
        directory.mkdir(parents=True, exist_ok=True)
    helper = scratch / "scoreboard-ioreport"
    receipt_path = scratch / "helper-build.json"
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    try:
        receipt = json.loads(receipt_path.read_text())
        if (helper.is_file() and not helper.is_symlink() and os.access(helper, os.X_OK) and
                receipt.get("source_sha256") == source_sha and
                receipt.get("helper_sha256") == hashlib.sha256(helper.read_bytes()).hexdigest()):
            return helper, receipt
    except (OSError, ValueError):
        pass
    env = dict(os.environ, TMPDIR=str(scratch), CLANG_MODULE_CACHE_PATH=str(cache))
    compiler = subprocess.run(["/usr/bin/xcrun", "--find", "clang"], env=env, check=True,
                              capture_output=True, text=True, timeout=10).stdout.strip()
    sdk = subprocess.run(["/usr/bin/xcrun", "--show-sdk-path"], env=env, check=True,
                         capture_output=True, text=True, timeout=10).stdout.strip()
    if not Path(compiler).is_file() or not Path(sdk).is_dir():
        raise OSError("installed Apple compiler/SDK unavailable")
    # Build to a new file so concurrent readers retain their existing inode.
    fd, temporary = tempfile.mkstemp(prefix="helper-build-", dir=scratch)
    os.close(fd)
    temporary_path = Path(temporary)
    command = [compiler, "-isysroot", sdk, "-O2", "-Wall", "-Wextra", "-Werror",
               "-fmodules-cache-path=" + str(cache), "-framework", "CoreFoundation",
               str(source), "-o", str(temporary_path)]
    try:
        subprocess.run(command, env=env, check=True, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        # Preserve the failed attempt for recoverable inspection; no deletion.
        raise
    temporary_path.chmod(0o755)
    temporary_path.replace(helper)
    receipt = {"source_sha256": source_sha,
               "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
               "helper_path": str(helper), "module_cache": str(cache), "temporary_directory": str(scratch),
               "compiler": compiler, "sdk": sdk, "uid": os.geteuid(), "requires_root": False,
               "command": command[:-1] + [str(helper)]}
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    return helper, receipt


def rails_from_channels(channels):
    """Return (joules, reasons, selected descriptors). Only canonical totals.

    Repeated identical channel IDs are read once. Ambiguous providers, aliases
    or conflicting repeated IDs invalidate that rail instead of adding them.
    Core/SRAM/combined and GPU energy in other groups are never added.
    """
    candidates = {r: {} for r in RAILS}
    conflicts = set()
    id_rails = {}
    reasons = []
    for ch in channels:
        if not isinstance(ch, dict) or ch.get("group") != "Energy Model":
            continue
        rail = ENERGY_NAMES.get(ch.get("name"))
        if rail is None:
            continue
        identity = ch.get("id")
        # Without an ID, two otherwise identical rows may be distinct providers.
        key = str(identity) if identity is not None else ("no_id", len(candidates[rail]))
        if identity is not None:
            id_rails.setdefault(key, set()).add(rail)
        if key in candidates[rail] and candidates[rail][key] != ch:
            conflicts.add(rail)
        else:
            candidates[rail][key] = ch
    for rails in id_rails.values():
        if len(rails) > 1:
            conflicts.update(rails)
    result = dict.fromkeys(RAILS)
    selected = dict.fromkeys(RAILS)
    for rail in RAILS:
        rows = list(candidates[rail].values())
        if rail in conflicts or len(rows) > 1:
            reasons.append(rail + ":ambiguous_channel")
        elif not rows:
            reasons.append(rail + ":missing_channel")
        else:
            ch = rows[0]
            scale = ENERGY_UNITS.get(ch.get("unit"))
            if scale is None:
                reasons.append(rail + ":unknown_energy_unit")
            elif ch.get("format", 1) != 1 or not _nonnegative(ch.get("value")):
                reasons.append(rail + ":invalid_counter_delta")
            else:
                value = ch["value"] * scale
                if not math.isfinite(value):
                    reasons.append(rail + ":invalid_counter_delta")
                    continue
                result[rail] = value
                selected[rail] = {"id": _safe_id(ch.get("id")), "group": "Energy Model",
                                  "name": ch["name"], "unit": ch["unit"]}
    return result, reasons, selected


def _gpu_residency(channels, duration):
    unique = {}
    for ch in channels:
        identity = ch.get("id")
        if identity is None or (identity in unique and unique[identity] != ch):
            return None
        unique[identity] = ch
    if len(unique) != 1:
        return None
    ch = next(iter(unique.values()))
    scale = RESIDENCY_UNITS.get(ch.get("unit"))
    if scale is None:
        return None
    total = active = 0.0
    names = set()
    for state in ch.get("states", []):
        name, value = state.get("name"), state.get("residency")
        if not isinstance(name, str) or name in names or not _nonnegative(value):
            return None
        names.add(name)
        if name.upper() in ("OFF", "IDLE", "DOWN"):
            pass
        elif re.fullmatch(r"P\d+", name):
            active += value * scale
        else:
            return None
        total += value * scale
    if total <= 0 or abs(total - duration) > max(0.05, duration * 0.05):
        return None
    return active


def normalise_sample(raw):
    """Decode the native bridge's interval; reject cumulative counters."""
    if raw.get("is_delta") is not True:
        raise ValueError("energy samples must explicitly be deltas")
    start, end = raw.get("start_mono"), raw.get("end_mono")
    if not _number(start) or not _number(end) or end <= start:
        raise ValueError("invalid monotonic interval")
    rails, reasons, selected = rails_from_channels(raw.get("raw_channels", []))
    if raw.get("invalid"):
        rails = dict.fromkeys(RAILS)
        reasons.append("invalid_sample")
    energy = any(v is not None for v in rails.values())
    result = {"type": "sample", "start_mono": start, "end_mono": end, "is_delta": True,
              "source": "ioreport", "mode": "energy_counters" if energy else "busy_time_proxy",
              "rails_j": rails, "energy_unit": "J" if energy else None,
              "wall_seconds": end - start, "rail_reasons": reasons, "selected_channels": selected,
              "raw_channels": [safe for ch in raw.get("raw_channels", [])
                               if (safe := _safe_channel(ch, counter=True)) is not None],
              "gpu_state_channels": _safe_gpu_states(raw.get("gpu_state_channels", [])),
              "busy_seconds": {"cpu": None,
                               "gpu": _gpu_residency(raw.get("gpu_state_channels", []), end - start),
                               "ane": None},
              "busy_time_is_proxy": True, "scope": SCOPE}
    if raw.get("invalid") is True:
        result["invalid"] = True
    for key in ("time_uncertainty_s", "read_seconds"):
        result[key] = raw.get(key) if _nonnegative(raw.get(key)) else None
    return result


def _weighted_p95(values):
    if not values:
        return None
    target = sum(weight for _, weight in values) * 0.95
    cumulative = 0.0
    for value, weight in sorted(values):
        cumulative += weight
        if cumulative >= target:
            return value
    return max(value for value, _ in values)


def window_energy(samples, start, end, *, min_coverage=0.99):
    """Integrate only disjoint deltas overlapping this local clock window.

    rails_j/gross_j require >= min_coverage for each rail; they are measured
    joules, not extrapolated across gaps. rails_measured_j retains partial data.
    Exact duplicate intervals are ignored; conflicting/overlapping intervals
    raise ValueError rather than double-counting. No wall-clock anchoring drift.
    """
    if not _number(start) or not _number(end) or end <= start:
        raise ValueError("window must have finite increasing timestamps")
    if not _number(min_coverage) or not 0 < min_coverage <= 1:
        raise ValueError("invalid minimum coverage")
    duration = end - start
    rows = {}
    duplicates = 0
    invalid = 0
    for sample in samples:
        a, b = sample.get("start_mono"), sample.get("end_mono")
        if not _number(a) or not _number(b) or b <= a:
            raise ValueError("invalid sample interval")
        if b <= start or a >= end:
            continue
        if sample.get("is_delta") is not True:
            raise ValueError("energy samples must explicitly be deltas")
        if sample.get("invalid"):
            invalid += 1
            continue
        row = normalise_sample(sample) if "rails_j" not in sample else sample
        key = (a, b)
        signature = (row.get("rails_j"), row.get("busy_seconds"), row.get("energy_unit", "J"),
                     row.get("source"), row.get("mode"))
        if key in rows:
            if rows[key][0] != signature:
                raise ValueError("conflicting duplicate energy interval")
            duplicates += 1
        else:
            rows[key] = (signature, row)
    totals = dict.fromkeys(RAILS, 0.0)
    covered = dict.fromkeys(RAILS, 0.0)
    busy = dict.fromkeys(RAILS, 0.0)
    busy_covered = dict.fromkeys(RAILS, 0.0)
    powers = {r: [] for r in RAILS}
    total_powers = []
    measured = 0.0
    last_end = None
    sources, modes = set(), set()
    read_delays, uncertainties = [], []
    for (a, b), (_, row) in sorted(rows.items()):
        if last_end is not None and a < last_end:
            raise ValueError("overlapping energy intervals")
        last_end = b
        overlap = min(b, end) - max(a, start)
        share = overlap / (b - a)
        measured += overlap
        source, mode = row.get("source"), row.get("mode")
        sources.add(source if isinstance(source, str) and source in SOURCES else "unknown")
        modes.add(mode if isinstance(mode, str) and mode in MODES else "unknown")
        values = row.get("rails_j", {})
        known = []
        for rail in RAILS:
            value = values.get(rail)
            if row.get("energy_unit", "J") == "J" and _nonnegative(value):
                totals[rail] += value * share
                covered[rail] += overlap
                powers[rail].append((value / (b - a), overlap))
                known.append(value)
            proxy = row.get("busy_seconds", {}).get(rail)
            if _nonnegative(proxy):
                busy[rail] += proxy * share
                busy_covered[rail] += overlap
        if len(known) == len(RAILS):
            total_powers.append((sum(known) / (b - a), overlap))
        for key, destination in (("read_delay_s", read_delays), ("time_uncertainty_s", uncertainties)):
            if _nonnegative(row.get(key)):
                destination.append(row[key])
    coverage = {r: min(1.0, covered[r] / duration) for r in RAILS}
    measured_j = {r: totals[r] if covered[r] > 0 else None for r in RAILS}
    accepted = {r: measured_j[r] if coverage[r] + 1e-12 >= min_coverage else None for r in RAILS}
    gross = sum(accepted.values()) if all(v is not None for v in accepted.values()) else None
    return {"start_mono": start, "end_mono": end, "wall_seconds": duration,
            "rails_j": accepted, "rails_measured_j": measured_j, "gross_j": gross,
            "energy_unit": "J" if any(v is not None for v in measured_j.values()) else None,
            "mean_w": gross / duration if gross is not None else None,
            "rails_mean_w": {r: accepted[r] / duration if accepted[r] is not None else None for r in RAILS},
            "p95_w": _weighted_p95(total_powers),
            "rails_p95_w": {r: _weighted_p95(powers[r]) for r in RAILS},
            "coverage": min(1.0, measured / duration), "coverage_by_rail": coverage,
            "coverage_min": min(coverage.values()), "measured_seconds": measured,
            "uncovered_seconds": max(0.0, duration - measured),
            "sample_count": len(rows), "duplicate_samples_ignored": duplicates,
            "invalid_samples_ignored": invalid, "sources": sorted(sources), "modes": sorted(modes),
            "busy_seconds": {r: busy[r] if busy_covered[r] > 0 else None for r in RAILS},
            "busy_coverage": {r: min(1.0, busy_covered[r] / duration) for r in RAILS},
            "busy_time_is_proxy": True, "cpu_busy_unit": "aggregate_core_seconds",
            "gpu_busy_unit": "device_busy_seconds_proxy",
            "max_read_delay_s": max(read_delays) if read_delays else None,
            "time_uncertainty_max_s": max(uncertainties) if uncertainties else None,
            "boundary_apportionment": "uniform_within_sample_interval",
            "comparable": False, "scope": SCOPE}


def _window_pair(value):
    if isinstance(value, dict):
        return value["start_mono"], value["end_mono"]
    if len(value) != 2:
        raise ValueError("a window needs start and end")
    return value[0], value[1]


def idle_net(samples, run, pre, post, audio_seconds, *, conditions=None, min_coverage=0.99):
    """Apply adjacent-idle subtraction without clamping negative results.

    conditions keys: thermal_verified, thermal_nominal_fraction, ac_verified,
    ac_power, interference_verified, interference (a checked list of flags).
    Omission is unknown, not a successful check. Caller owns these observations.
    """
    if not _number(audio_seconds) or audio_seconds <= 0:
        raise ValueError("audio_seconds must be finite and positive")
    run_pair, pre_pair, post_pair = map(_window_pair, (run, pre, post))
    if pre_pair[1] > run_pair[0] or post_pair[0] < run_pair[1]:
        raise ValueError("idle windows must bracket the run without overlap")
    windows = {name: window_energy(samples, *pair, min_coverage=min_coverage)
               for name, pair in (("run", run_pair), ("pre", pre_pair), ("post", post_pair))}
    run_w, pre_w, post_w = (windows[k] for k in ("run", "pre", "post"))
    rails_net = dict.fromkeys(RAILS)
    rail_idle = {}
    rail_drift = dict.fromkeys(RAILS)
    sensitivities = {"pre_only": dict.fromkeys(RAILS), "post_only": dict.fromkeys(RAILS)}
    for r in RAILS:
        a, b, gross = pre_w["rails_j"][r], post_w["rails_j"][r], run_w["rails_j"][r]
        p_pre = a / pre_w["wall_seconds"] if a is not None else None
        p_post = b / post_w["wall_seconds"] if b is not None else None
        used = (p_pre + p_post) / 2 if p_pre is not None and p_post is not None else None
        rail_idle[r] = {"pre": p_pre, "post": p_post, "used": used}
        if used is not None:
            rail_drift[r] = abs(p_pre - p_post) > max(1.0, 0.2 * min(p_pre, p_post))
        if gross is not None:
            if used is not None:
                rails_net[r] = gross - used * run_w["wall_seconds"]
            for label, power in (("pre_only", p_pre), ("post_only", p_post)):
                if power is not None:
                    sensitivities[label][r] = gross - power * run_w["wall_seconds"]
    def total(values):
        return sum(values.values()) if all(v is not None for v in values.values()) else None
    gross, net = run_w["gross_j"], total(rails_net)
    idle = {k: total({r: rail_idle[r][k] for r in RAILS}) for k in ("pre", "post", "used")}
    total_drift = None
    if idle["pre"] is not None and idle["post"] is not None:
        total_drift = abs(idle["pre"] - idle["post"]) > max(1.0, 0.2 * min(idle["pre"], idle["post"]))
    drift_values = [*rail_drift.values(), total_drift]
    drift = True if any(v is True for v in drift_values) else (None if None in drift_values else False)
    coverage_min = min(w["coverage_min"] for w in windows.values())
    checks = dict(conditions or {})
    thermal = checks.get("thermal_nominal_fraction")
    reasons = []
    if gross is None or net is None:
        reasons.append("missing_or_incomplete_energy_rails")
    if coverage_min + 1e-12 < min_coverage:
        reasons.append("window_coverage_below_threshold")
    if checks.get("thermal_verified") is not True:
        reasons.append("thermal_unverified")
    elif not _number(thermal) or not 0.95 <= thermal <= 1:
        reasons.append("thermal_not_nominal")
    if checks.get("ac_verified") is not True:
        reasons.append("ac_power_unverified")
    elif checks.get("ac_power") is not True:
        reasons.append("not_on_ac_power")
    flags = checks.get("interference")
    if checks.get("interference_verified") is not True or not isinstance(flags, list):
        reasons.append("interference_unverified")
    elif flags:
        reasons.append("interference_detected")
    if drift is None:
        reasons.append("idle_baseline_unknown")
    elif drift:
        reasons.append("baseline_drift")
    sources = {source for window in windows.values() for source in window["sources"]}
    modes = {mode for window in windows.values() for mode in window["modes"]}
    if len(sources) != 1 or "unknown" in sources or modes != {"energy_counters"}:
        reasons.append("mixed_or_proxy_measurement")
    safe_flags = ["background_process_detected"] * len(flags) if isinstance(flags, list) else None
    safe_checks = {"thermal_verified": checks.get("thermal_verified") is True,
                   "thermal_nominal_fraction": thermal if _number(thermal) and 0 <= thermal <= 1 else None,
                   "ac_verified": checks.get("ac_verified") is True,
                   "ac_power": checks.get("ac_power") if isinstance(checks.get("ac_power"), bool) else None,
                   "interference_verified": checks.get("interference_verified") is True,
                   "interference": safe_flags}
    minutes = audio_seconds / 60
    return {"comparable": not reasons, "not_comparable_reasons": reasons,
            "gross_j": gross, "net_j": net, "rails_gross_j": run_w["rails_j"],
            "rails_net_j": rails_net, "gross_j_per_audio_min": gross / minutes if gross is not None else None,
            "net_j_per_audio_min": net / minutes if net is not None else None,
            "audio_seconds": audio_seconds, "wall_seconds": run_w["wall_seconds"],
            "idle_w": idle, "rails_idle_w": rail_idle, "baseline_drift": drift,
            "baseline_drift_by_rail": rail_drift, "coverage_min": coverage_min,
            "sensitivity_net_j_per_audio_min": {k: total(v) / minutes if total(v) is not None else None
                                               for k, v in sensitivities.items()},
            "sensitivity_rails_net_j": sensitivities, "windows": windows,
            "thermal_nominal_fraction": safe_checks["thermal_nominal_fraction"] if safe_checks["thermal_verified"] else None,
            "ac_power": safe_checks["ac_power"] if safe_checks["ac_verified"] else None,
            "interference": safe_flags if safe_checks["interference_verified"] else None,
            "conditions": safe_checks, "scope": SCOPE}


class _CPUProxy:
    """host_statistics CPU_LOAD_INFO: load proxy, never an energy counter."""
    def __init__(self):
        self.lib = None
        self.host = None
        self.previous = None
        try:
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            lib.mach_host_self.restype = ctypes.c_uint32
            lib.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                                           ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
            lib.host_statistics.restype = ctypes.c_int
            lib.mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            self.lib, self.host = lib, lib.mach_host_self()
            self.previous = self._read()
        except (OSError, AttributeError):
            self.close()

    def _read(self):
        if self.lib is None or self.host is None:
            return None
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        if self.lib.host_statistics(self.host, 3, ticks, ctypes.byref(count)) != 0 or count.value != 4:
            return None
        return list(ticks)

    def sample(self, duration):
        current, previous = self._read(), self.previous
        self.previous = current
        if current is None or previous is None:
            return None
        delta = [(a - b) % (2 ** 32) for a, b in zip(current, previous)]
        total = sum(delta)
        # CPU_STATE_IDLE is index 2; CPU_LOAD_INFO's flavor is 3.
        return (total - delta[2]) / total * (os.cpu_count() or 1) * duration if total else None

    def close(self):
        if self.lib is not None and self.host is not None:
            task = ctypes.c_uint32.in_dll(self.lib, "mach_task_self_").value
            self.lib.mach_port_deallocate(task, self.host)
        self.lib, self.host = None, None


def _gpu_utilization():
    """Instantaneous utilization from the existing driver; unknown if ambiguous."""
    try:
        proc = subprocess.run(["/usr/sbin/ioreg", "-r", "-c", "AGXAccelerator", "-a"],
                              capture_output=True, timeout=2, check=True)
        entries = plistlib.loads(proc.stdout)
        values = []
        for entry in entries:
            statistics = entry.get("PerformanceStatistics", {})
            value = statistics.get("Device Utilization %")
            if _nonnegative(value) and value <= 100:
                values.append(value / 100)
        return values[0] if len(values) == 1 else None
    except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException, ValueError, TypeError, AttributeError):
        return None


class PowerSampler:
    def __init__(self, helper_path=None, interval=1.0):
        if not _number(interval) or not 0.01 <= interval <= 3600:
            raise ValueError("interval must be between 0.01 and 3600 seconds")
        self._default_helper = helper_path is None
        self.helper_path = Path(helper_path) if helper_path is not None else (
            Path(__file__).resolve().parents[1] / "work/energy-probe/scoreboard-ioreport")
        self.interval = float(interval)
        self.samples = []
        self.metadata = {}
        self.errors = []
        self._lock = threading.Lock()
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._process = None
        self._thread = None
        self._stderr_thread = None
        self._active = False
        self._ever_started = False
        self._stopping = False

    def __enter__(self):
        return self.start()

    def __exit__(self, exc_type, exc_value, traceback):
        self.stop()

    def _append(self, row):
        with self._lock:
            self.samples.append(row)

    def _error(self, reason):
        # This list is saved directly by the parent. Never append exception,
        # stderr, path, helper-provided reason or other free-form text.
        reason = reason if reason in ERROR_REASONS else "unknown_sampler_error"
        if reason not in self.errors:
            self.errors.append(reason)

    def _read_native(self):
        cpu_proxy = None
        try:
            for line in self._process.stdout:
                received = time.monotonic()
                try:
                    raw = json.loads(line)
                    kind = raw.get("type")
                    if kind == "ready":
                        self.metadata.update(_ready_metadata(raw))
                        cpu_proxy = _CPUProxy()
                        self._ready.set()
                    elif kind == "sample":
                        row = normalise_sample(raw)
                        row["received_mono"] = received
                        row["read_delay_s"] = max(0.0, received - row["end_mono"])
                        if cpu_proxy is not None:
                            row["busy_seconds"]["cpu"] = cpu_proxy.sample(row["wall_seconds"])
                        self._append(row)
                    elif kind == "unavailable":
                        reason = raw.get("reason")
                        self._error("ioreport:" + reason if isinstance(reason, str) and
                                    reason in HELPER_FAILURE_REASONS else "ioreport:helper_unavailable")
                        self._ready.set()
                    else:
                        self._error("unexpected_helper_record")
                except (ValueError, TypeError, AttributeError, KeyError, OverflowError, RecursionError):
                    self._error("invalid_helper_record")
                    self.metadata["invalid_helper_record_count"] = self.metadata.get("invalid_helper_record_count", 0) + 1
        finally:
            if cpu_proxy is not None:
                cpu_proxy.close()
            if not self._stopping:
                self._error("helper_stream_ended")
            self._ready.set()

    def _read_stderr(self):
        # Drain binary chunks throughout long sessions. Retain only a digest
        # and exact byte count, even for invalid UTF-8 or private helper output.
        digest = hashlib.sha256()
        size = 0
        complete = True
        try:
            while chunk := self._process.stderr.read(4096):
                digest.update(chunk)
                size += len(chunk)
        except (OSError, ValueError):
            complete = False
            self._error("helper_stderr_read_failed")
        self.metadata.update(helper_stderr_bytes=size, helper_stderr_sha256=digest.hexdigest(),
                             helper_stderr_complete=complete)
        if size:
            self._error("helper_stderr_present")

    def _proxy_loop(self):
        cpu = _CPUProxy()
        previous_gpu = _gpu_utilization()
        start = time.monotonic()
        self.metadata.update(type="ready", source="host_statistics+ioreg", mode="busy_time_proxy",
                             uid=os.geteuid(), ready_mono=start, energy_unit=None,
                             reason="energy_backend_unavailable")
        self._ready.set()
        try:
            while True:
                stopped = self._stop.wait(self.interval)
                current_gpu = _gpu_utilization()
                end = time.monotonic()
                elapsed = end - start
                if elapsed > 0:
                    gpu = ((previous_gpu + current_gpu) / 2 * elapsed
                           if previous_gpu is not None and current_gpu is not None else None)
                    self._append({"start_mono": start, "end_mono": end, "is_delta": True,
                                  "source": "host_statistics+ioreg", "mode": "busy_time_proxy",
                                  "rails_j": dict.fromkeys(RAILS), "energy_unit": None,
                                  "wall_seconds": elapsed,
                                  "busy_seconds": {"cpu": cpu.sample(elapsed), "gpu": gpu, "ane": None},
                                  "busy_time_is_proxy": True, "scope": SCOPE})
                start, previous_gpu = end, current_gpu
                if stopped:
                    break
        finally:
            cpu.close()

    def start(self):
        if self._active:
            return self
        if self._ever_started:
            raise RuntimeError("a stopped sampler cannot restart; create a new sampler")
        self._ever_started = self._active = True
        if self._default_helper:
            try:
                self.helper_path, receipt = build_helper()
                self.metadata["build"] = {"source_sha256": receipt["source_sha256"],
                                          "helper_sha256": receipt["helper_sha256"],
                                          "requires_root": False, "uid": os.geteuid(), "mode": "local_compiler"}
            except (OSError, subprocess.SubprocessError):
                self._error("helper_build_failed")
                # Do not start an old binary whose source check failed.
                self.helper_path = self.helper_path.with_name("unavailable-helper")
        if self.helper_path.is_file() and os.access(self.helper_path, os.X_OK):
            try:
                self._process = subprocess.Popen([str(self.helper_path.resolve()), "--interval", str(self.interval)],
                                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                 bufsize=0)
                self._thread = threading.Thread(target=self._read_native, daemon=True)
                self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
                self._thread.start()
                self._stderr_thread.start()
                self._ready.wait(5)
                if self.metadata.get("type") == "ready":
                    return self
                self._error("native_helper_not_ready")
                self._stopping = True
                self._finish_native()
                self._stopping = False
            except OSError:
                self._error("helper_start_failed")
        else:
            self._error("helper_not_found_or_not_executable")
        self._process = None
        self._ready.clear()
        self._thread = threading.Thread(target=self._proxy_loop, daemon=True)
        self._thread.start()
        if not self._ready.wait(5):
            self._error("busy_proxy_not_ready")
        return self

    def _finish_native(self):
        process = self._process
        if process is None:
            return
        if process.poll() is None:
            process.terminate()  # exact child only; final delta flushed on SIGTERM
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._error("helper_stop_timeout_final_interval_unknown")
            process.kill()
            process.wait(timeout=5)
        for thread in (self._thread, self._stderr_thread):
            if thread is not None:
                thread.join(timeout=5)
        self.metadata["helper_exit_code"] = process.returncode
        if process.returncode:
            self._error("helper_nonzero_exit")
        process.stdout.close()
        process.stderr.close()

    def stop(self):
        if not self._active:
            return self
        self._stopping = True
        if self._process is not None:
            self._finish_native()
        else:
            self._stop.set()
            self._thread.join(timeout=5)
            if self._thread.is_alive():
                self._error("busy_proxy_stop_timeout")
        self._active = False
        return self

    def snapshot(self):
        with self._lock:
            return copy.deepcopy(self.samples)

    def report(self, start=None, end=None):
        samples = self.snapshot()
        if start is None:
            start = min((s["start_mono"] for s in samples), default=None)
        if end is None:
            end = max((s["end_mono"] for s in samples), default=None)
        result = window_energy(samples, start, end) if start is not None and end is not None and end > start else {
            "rails_j": dict.fromkeys(RAILS), "gross_j": None, "coverage_min": 0.0,
            "sample_count": 0, "comparable": False, "scope": SCOPE}
        result.update(sampler_metadata=copy.deepcopy(self.metadata), sampler_errors=list(self.errors),
                      not_comparable_reasons=["thermal_unverified", "ac_power_unverified", "interference_unverified"])
        return result


def main(argv=None):
    parser = PrivateArgumentParser(prog="scoreboard-energy", description=__doc__)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    if not _number(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be finite and positive")
    out = args.out or (Path(__file__).resolve().parents[1] / "work/energy-probe" /
                       datetime.datetime.now(datetime.timezone.utc).strftime("probe-%Y%m%dT%H%M%S-%fZ"))
    out.mkdir(parents=True, exist_ok=False)
    with PowerSampler(args.helper, args.interval) as sampler:
        start = time.monotonic()
        threading.Event().wait(args.seconds)
        end = time.monotonic()
    result = sampler.report(start, end)
    with (out / "samples.jsonl").open("x") as stream:
        for sample in sampler.snapshot():
            stream.write(json.dumps(sample, ensure_ascii=False, allow_nan=False) + "\n")
    with (out / "report.json").open("x") as stream:
        json.dump(result, stream, ensure_ascii=False, allow_nan=False, indent=2)
        stream.write("\n")
    print(json.dumps({"evidence_directory": str(out), "rails_j": result["rails_j"],
                      "gross_j": result["gross_j"], "wall_seconds": result.get("wall_seconds"),
                      "coverage_min": result["coverage_min"], "comparable": False,
                      "sampler_errors": result["sampler_errors"]}, ensure_ascii=False, allow_nan=False))
    return 0 if result["gross_j"] is not None else 4


if __name__ == "__main__":
    sys.exit(main())
