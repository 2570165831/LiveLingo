#!/usr/bin/env python3
"""Synthetic energy/clock tests; fixture writes stay in work/energy-probe."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import scoreboard_energy as e


def channel(name, value, unit="mJ", identity=None, group="Energy Model", **extra):
    return dict(id=identity or name, group=group, name=name, value=value, unit=unit, format=1, **extra)


def sample(a, b, cpu=1.0, gpu=0.0, ane=0.0, **extra):
    dt = b - a
    return dict(start_mono=a, end_mono=b, is_delta=True, source="synthetic_ioreport",
                mode="energy_counters", energy_unit="J",
                rails_j={r: None if p is None else p * dt for r, p in zip(e.RAILS, (cpu, gpu, ane))}, **extra)


VERIFIED = {"thermal_verified": True, "thermal_nominal_fraction": 1.0,
            "ac_verified": True, "ac_power": True, "interference_verified": True, "interference": []}


class RailTests(unittest.TestCase):
    def test_helper_sample_extra_fields_and_untrusted_ids_are_not_copied(self):
        secret = "PRIVATE-CLASSROOM-SENTINEL-WORDS"
        ch = channel("CPU Energy", 1000, identity=secret, private_text=secret)
        raw = {"start_mono": 0, "end_mono": 1, "is_delta": True,
               "source": secret, "error": secret, "private_text": secret, "raw_channels": [ch],
               "gpu_state_channels": [{"id": secret, "unit": secret,
                                       "states": [{"name": secret, "residency": 1, "text": secret}]}]}
        result = e.normalise_sample(raw)
        self.assertNotIn(secret, json.dumps(result))
        self.assertNotIn("private_text", result)
        self.assertEqual(result["rails_j"]["cpu"], 1)
        self.assertTrue(result["selected_channels"]["cpu"]["id"].startswith("sha256:"))

    def test_units_are_converted_per_channel_including_gpu_nanojoules(self):
        values, reasons, selected = e.rails_from_channels([
            channel("CPU Energy", 2000), channel("GPU Energy", 3_000_000_000, "nJ"),
            channel("ANE", 400_000, "uJ")])
        for rail, expected in (("cpu", 2.0), ("gpu", 3.0), ("ane", 0.4)):
            self.assertAlmostEqual(values[rail], expected)
        self.assertEqual(reasons, [])
        self.assertEqual(selected["gpu"]["unit"], "nJ")
        for unit, scale in e.ENERGY_UNITS.items():
            with self.subTest(unit=unit):
                result, _, _ = e.rails_from_channels([channel("CPU Energy", 10, unit)])
                self.assertEqual(result["cpu"], 10 * scale)

    def test_missing_rails_stay_unknown_and_measured_zero_is_valid(self):
        values, reasons, _ = e.rails_from_channels([channel("CPU Energy", 0)])
        self.assertEqual(values, {"cpu": 0.0, "gpu": None, "ane": None})
        self.assertIn("gpu:missing_channel", reasons)

    def test_power_ticks_and_invalid_deltas_are_not_joules(self):
        for unit, value in [("mW", 1000), ("24Mticks", 10), (None, 1), ("mJ", -1),
                            ("mJ", float("nan")), ("mJ", True)]:
            with self.subTest(unit=unit, value=value):
                rails, reasons, _ = e.rails_from_channels([channel("CPU Energy", value, unit)])
                self.assertIsNone(rails["cpu"])
                self.assertTrue(reasons)
        ch = channel("CPU Energy", 1000)
        ch["format"] = 2
        self.assertIsNone(e.rails_from_channels([ch])[0]["cpu"])

    def test_subrails_and_combined_are_not_added_to_totals(self):
        rows = [channel("CPU Energy", 1000), channel("GPU Energy", 2000), channel("ANE", 0),
                channel("EACC_CPU0", 100_000), channel("PACC0_CPU_SRAM", 100_000),
                channel("combined_power", 999999), channel("Combined Energy", 999999),
                channel("GPU Energy", 999999, group="GPU Stats")]
        self.assertEqual(e.rails_from_channels(rows)[0], {"cpu": 1, "gpu": 2, "ane": 0})

    def test_identical_channel_ids_count_once(self):
        row = channel("CPU Energy", 1000)
        self.assertEqual(e.rails_from_channels([row, copy.deepcopy(row)])[0]["cpu"], 1)

    def test_ambiguous_providers_aliases_or_conflicting_ids_are_unknown(self):
        pairs = [[channel("CPU Energy", 1000, identity="one"), channel("CPU Energy", 1000, identity="two")],
                 [channel("CPU Energy", 1000, identity="one"), channel("CPU Energy", 2000, identity="one")],
                 [channel("ANE", 1000, identity="one"), channel("ANE Energy", 1000, identity="two")]]
        for rows in pairs:
            with self.subTest(rows=rows):
                rails, reasons, _ = e.rails_from_channels(rows)
                self.assertTrue(any("ambiguous" in s for s in reasons))
                self.assertIsNone(rails[e.ENERGY_NAMES[rows[0]["name"]]])
        rows = [channel("CPU Energy", 1000, identity="same"), channel("GPU Energy", 1000, identity="same")]
        self.assertIsNone(e.rails_from_channels(rows)[0]["cpu"])
        self.assertIsNone(e.rails_from_channels(rows)[0]["gpu"])

    def test_missing_ids_cannot_be_used_to_guess_duplicates(self):
        row = channel("CPU Energy", 1000)
        del row["id"]
        self.assertIsNone(e.rails_from_channels([row, row])[0]["cpu"])

    def test_raw_cumulative_samples_are_rejected(self):
        for is_delta in (False, None):
            with self.subTest(is_delta=is_delta), self.assertRaises(ValueError):
                e.normalise_sample({"is_delta": is_delta, "start_mono": 0, "end_mono": 1})

    def test_gpu_residency_is_busy_time_only_and_units_are_checked(self):
        states = {"id": "gpu", "unit": "24Mticks", "states": [
            {"name": "OFF", "residency": 12_000_000}, {"name": "IDLE", "residency": 6_000_000},
            {"name": "P1", "residency": 6_000_000}]}
        row = e.normalise_sample({"start_mono": 0, "end_mono": 1, "is_delta": True,
                                  "gpu_state_channels": [states]})
        self.assertEqual(row["busy_seconds"]["gpu"], 0.25)
        self.assertEqual(row["mode"], "busy_time_proxy")
        self.assertEqual(row["rails_j"], dict.fromkeys(e.RAILS))
        self.assertIsNone(row["energy_unit"])
        for change in ({"unit": "unknown"}, {"id": "different", "states": []}):
            self.assertIsNone(e._gpu_residency([dict(states, **change)], 1))
        self.assertIsNone(e._gpu_residency([states], 2))
        self.assertIsNone(e._gpu_residency([states, dict(states, id="second")], 1))


class WindowTests(unittest.TestCase):
    def test_known_constant_power_and_fractional_boundaries(self):
        rows = [sample(i, i + 1, 4, 5, 1) for i in range(3)]
        result = e.window_energy(rows, 0.25, 2.5)
        self.assertEqual(result["rails_j"], {"cpu": 9, "gpu": 11.25, "ane": 2.25})
        self.assertEqual(result["gross_j"], 22.5)
        self.assertEqual(result["coverage_min"], 1)
        self.assertEqual(result["mean_w"], 10)

    def test_actual_variable_intervals_not_nominal_sampling_period(self):
        result = e.window_energy([sample(0, 0.7, 2), sample(0.7, 3, 4)], 0, 3)
        self.assertAlmostEqual(result["gross_j"], 10.6)
        self.assertEqual(result["wall_seconds"], 3)

    def test_local_window_does_not_inherit_distant_clock_or_read_delay(self):
        result = e.window_energy([sample(-1000, -999, 999, read_delay_s=100),
                                  sample(20, 21, 2, read_delay_s=0.02)], 20, 21)
        self.assertEqual(result["gross_j"], 2)
        self.assertEqual(result["max_read_delay_s"], 0.02)
        self.assertEqual(result["sample_count"], 1)

    def test_gaps_retain_measured_lower_bound_and_no_headline_energy(self):
        result = e.window_energy([sample(0, 1, 2), sample(2, 3, 2)], 0, 3)
        self.assertAlmostEqual(result["coverage"], 2 / 3)
        self.assertAlmostEqual(result["coverage_min"], 2 / 3)
        self.assertEqual(result["rails_measured_j"]["cpu"], 4)
        self.assertIsNone(result["rails_j"]["cpu"])
        self.assertIsNone(result["gross_j"])
        self.assertEqual(result["uncovered_seconds"], 1)

    def test_missing_one_rail_does_not_make_total_zero_or_other_rails_unknown(self):
        result = e.window_energy([sample(0, 1, 2, 3, None)], 0, 1)
        self.assertEqual(result["rails_j"], {"cpu": 2, "gpu": 3, "ane": None})
        self.assertEqual(result["coverage_by_rail"], {"cpu": 1, "gpu": 1, "ane": 0})
        self.assertIsNone(result["gross_j"])

    def test_exact_coverage_threshold_is_not_extrapolated(self):
        result = e.window_energy([sample(0, 0.99, 2)], 0, 1)
        self.assertEqual(result["coverage_min"], 0.99)
        self.assertEqual(result["gross_j"], 1.98)
        self.assertIsNone(e.window_energy([sample(0, 0.98, 2)], 0, 1)["gross_j"])

    def test_empty_windows_are_unknown(self):
        result = e.window_energy([], 0, 1)
        self.assertIsNone(result["gross_j"])
        self.assertEqual(result["rails_j"], dict.fromkeys(e.RAILS))
        self.assertEqual(result["coverage_min"], 0)

    def test_duplicates_and_combined_do_not_double_count(self):
        row = sample(0, 1, 2, 3, 1, combined_power=999999, gpu_energy=999999)
        result = e.window_energy([row, copy.deepcopy(row)], 0, 1)
        self.assertEqual(result["gross_j"], 6)
        self.assertEqual(result["duplicate_samples_ignored"], 1)

    def test_overlapping_or_conflicting_intervals_are_rejected(self):
        for rows in ([sample(0, 2), sample(1, 3)], [sample(0, 1, 1), sample(0, 1, 2)]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                e.window_energy(rows, 0, 3)

    def test_cumulative_energy_is_rejected_and_invalid_bins_reduce_coverage(self):
        with self.assertRaises(ValueError):
            e.window_energy([dict(sample(0, 1), is_delta=False)], 0, 1)
        result = e.window_energy([sample(0, 1), sample(1, 2, invalid=True)], 0, 2)
        self.assertEqual(result["coverage_min"], 0.5)
        self.assertEqual(result["invalid_samples_ignored"], 1)
        self.assertIsNone(result["gross_j"])

    def test_p95_power_is_weighted_by_duration(self):
        result = e.window_energy([sample(0, 99, 1), sample(99, 100, 100)], 0, 100)
        self.assertEqual(result["p95_w"], 1)

    def test_busy_proxy_remains_without_joules(self):
        row = sample(0, 2, None, None, None, busy_seconds={"cpu": 4, "gpu": 0.5, "ane": None})
        row.update(mode="busy_time_proxy", energy_unit=None)
        result = e.window_energy([row], 0.5, 1.5)
        self.assertEqual(result["busy_seconds"], {"cpu": 2, "gpu": 0.25, "ane": None})
        self.assertIsNone(result["gross_j"])
        self.assertIsNone(result["energy_unit"])
        self.assertFalse(result["comparable"])


class IdleTests(unittest.TestCase):
    def setUp(self):
        self.rows = [sample(0, 2, 1, 0.5, 0), sample(2, 6, 5, 2, 0.25), sample(6, 8, 1, 0.5, 0)]

    def result(self, **kwargs):
        return e.idle_net(self.rows, [2, 6], [0, 2], [6, 8], 60, **kwargs)

    def test_per_rail_idle_subtraction_and_audio_denominator(self):
        result = self.result()
        self.assertEqual(result["gross_j"], 29)
        self.assertEqual(result["rails_net_j"], {"cpu": 16, "gpu": 6, "ane": 1})
        self.assertEqual(result["net_j"], 23)
        self.assertEqual(result["net_j_per_audio_min"], 23)
        self.assertEqual(result["idle_w"], {"pre": 1.5, "post": 1.5, "used": 1.5})
        self.assertFalse(result["baseline_drift"])

    def test_unverified_thermal_ac_and_interference_cannot_be_comparable(self):
        result = self.result()
        self.assertFalse(result["comparable"])
        self.assertTrue({"thermal_unverified", "ac_power_unverified", "interference_unverified"}.issubset(
            result["not_comparable_reasons"]))
        values_only = {k: VERIFIED[k] for k in ("thermal_nominal_fraction", "ac_power", "interference")}
        self.assertFalse(self.result(conditions=values_only)["comparable"])

    def test_all_explicit_conditions_allow_synthetic_comparability(self):
        result = self.result(conditions=VERIFIED)
        self.assertTrue(result["comparable"])
        self.assertEqual(result["not_comparable_reasons"], [])
        for key, value in (("thermal_verified", False), ("thermal_nominal_fraction", 0.94),
                           ("ac_verified", False), ("ac_power", False),
                           ("interference_verified", False), ("interference", ["background_load"])):
            with self.subTest(key=key):
                self.assertFalse(self.result(conditions=dict(VERIFIED, **{key: value}))["comparable"])

    def test_idle_drift_and_pre_post_sensitivity(self):
        rows = [sample(0, 1, 1), sample(1, 3, 5), sample(3, 4, 3)]
        result = e.idle_net(rows, [1, 3], [0, 1], [3, 4], 30, conditions=VERIFIED)
        self.assertEqual(result["net_j"], 6)
        self.assertEqual(result["sensitivity_net_j_per_audio_min"], {"pre_only": 16, "post_only": 8})
        self.assertTrue(result["baseline_drift"])
        self.assertFalse(result["comparable"])

    def test_negative_net_is_not_clamped(self):
        rows = [sample(0, 1, 2), sample(1, 3, 1), sample(3, 4, 2)]
        result = e.idle_net(rows, [1, 3], [0, 1], [3, 4], 60)
        self.assertEqual(result["net_j"], -2)

    def test_missing_baseline_rail_keeps_net_unknown(self):
        self.rows[-1]["rails_j"]["ane"] = None
        result = self.result(conditions=VERIFIED)
        self.assertIsNone(result["net_j"])
        self.assertIsNone(result["rails_net_j"]["ane"])
        self.assertIsNone(result["baseline_drift"])
        self.assertFalse(result["comparable"])

    def test_coverage_gate_and_proxy_gate_override_verified_environment(self):
        self.rows[0]["end_mono"] = 1
        result = self.result(conditions=VERIFIED)
        self.assertEqual(result["coverage_min"], 0.5)
        self.assertFalse(result["comparable"])
        rows = [sample(0, 1), sample(1, 2), sample(2, 3)]
        rows[1]["mode"] = "busy_time_proxy"
        result = e.idle_net(rows, [1, 2], [0, 1], [2, 3], 60, conditions=VERIFIED)
        self.assertFalse(result["comparable"])
        self.assertIn("mixed_or_proxy_measurement", result["not_comparable_reasons"])

    def test_idle_windows_must_bracket_run_and_audio_is_required(self):
        for run, pre, post, seconds in (([2, 6], [0, 3], [6, 8], 60),
                                        ([2, 6], [0, 2], [5, 8], 60),
                                        ([2, 6], [0, 2], [6, 8], 0)):
            with self.subTest(run=run, pre=pre, post=post, seconds=seconds), self.assertRaises(ValueError):
                e.idle_net(self.rows, run, pre, post, seconds)

    def test_environment_notes_and_unknown_sources_are_not_echoed(self):
        secret = "PRIVATE-ENVIRONMENT-SENTINEL"
        result = self.result(conditions=dict(VERIFIED, interference=[secret], private_text=secret, ac_power=secret))
        self.assertNotIn(secret, json.dumps(result))
        self.assertFalse(result["comparable"])
        self.rows[1]["source"] = secret
        result = self.result(conditions=VERIFIED)
        self.assertNotIn(secret, json.dumps(result))
        self.assertFalse(result["comparable"])


class FakeCPU:
    def sample(self, duration):
        return duration * 2

    def close(self):
        pass


class SamplerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = Path(__file__).resolve().parents[1] / "work/energy-probe"
        scratch.mkdir(parents=True, exist_ok=True)
        cls.fixtures = Path(tempfile.mkdtemp(prefix="unit-fixtures-", dir=scratch))
        cls.helper = cls.fixtures / "fake-helper.py"
        cls.helper.write_text('''#!/usr/bin/env python3
import json,signal,threading,time,sys
event=threading.Event()
signal.signal(signal.SIGTERM,lambda *args:event.set())
interval=float(sys.argv[sys.argv.index('--interval')+1])
a=time.monotonic()
print(json.dumps({'type':'ready','source':'synthetic_ioreport','ready_mono':a}),flush=True)
while True:
 stopped=event.wait(interval)
 b=time.monotonic()
 channels=[{'id':r,'group':'Energy Model','name':n,'unit':'J','value':(b-a)*p,'format':1}
           for r,n,p in [('cpu','CPU Energy',2),('gpu','GPU Energy',1),('ane','ANE',0)]]
 print(json.dumps({'type':'sample','start_mono':a,'end_mono':b,'is_delta':True,'raw_channels':channels}),flush=True)
 a=b
 if stopped:break
''')
        cls.helper.chmod(0o755)
        cls.unavailable = cls.fixtures / "unavailable-helper.py"
        cls.unavailable.write_text("#!/usr/bin/env python3\nprint('{\"type\":\"unavailable\",\"reason\":\"subscription_unavailable\"}',flush=True)\nraise SystemExit(2)\n")
        cls.unavailable.chmod(0o755)

    def test_one_session_start_stop_clock_and_final_flush(self):
        with patch.object(e, "_CPUProxy", FakeCPU):
            sampler = e.PowerSampler(self.helper, 0.02)
            sampler.start()
            process = sampler._process
            self.assertIs(sampler.start(), sampler)
            self.assertIs(sampler._process, process)
            start = time.monotonic()
            time.sleep(0.075)
            end = time.monotonic()
            sampler.stop()
            sampler.stop()
        result = sampler.report(start, end)
        self.assertEqual(result["coverage_min"], 1)
        self.assertAlmostEqual(result["gross_j"], (end - start) * 3)
        self.assertEqual(sampler.metadata["helper_exit_code"], 0)
        self.assertEqual(sampler.errors, [])
        self.assertIsNotNone(process.poll())
        self.assertFalse(result["comparable"])
        with self.assertRaises(RuntimeError):
            sampler.start()
        snapshot = sampler.snapshot()
        snapshot[0]["rails_j"]["cpu"] = -999
        self.assertGreaterEqual(sampler.samples[0]["rails_j"]["cpu"], 0)

    def test_failed_native_subscription_falls_back_to_busy_time_without_energy(self):
        with patch.object(e, "_CPUProxy", FakeCPU), patch.object(e, "_gpu_utilization", return_value=0.25):
            with e.PowerSampler(self.unavailable, 0.02) as sampler:
                start = time.monotonic()
                time.sleep(0.04)
                end = time.monotonic()
        result = sampler.report(start, end)
        self.assertEqual(sampler.metadata["source"], "host_statistics+ioreg")
        self.assertIsNone(result["gross_j"])
        self.assertIsNone(result["energy_unit"])
        self.assertEqual(result["rails_j"], dict.fromkeys(e.RAILS))
        self.assertGreater(result["busy_seconds"]["cpu"], 0)
        self.assertGreater(result["busy_seconds"]["gpu"], 0)
        self.assertIn("ioreport:subscription_unavailable", sampler.errors)

    def test_interval_validation_and_stop_before_start(self):
        for interval in (0, -1, float("nan"), True):
            with self.subTest(interval=interval), self.assertRaises(ValueError):
                e.PowerSampler(self.helper, interval)
        e.PowerSampler(self.helper).stop()

    def test_last_native_record_without_newline_is_read(self):
        helper = self.fixtures / "no-newline-helper.py"
        row = {"type": "sample", "start_mono": 1, "end_mono": 2, "is_delta": True,
               "raw_channels": [channel("CPU Energy", 1000), channel("GPU Energy", 2000), channel("ANE", 0)]}
        helper.write_text("#!/usr/bin/env python3\nimport sys\n"
                          "print('{\"type\":\"ready\",\"source\":\"synthetic_ioreport\"}',flush=True)\n"
                          "sys.stdout.write(" + repr(json.dumps(row)) + ")\nsys.stdout.flush()\n")
        helper.chmod(0o755)
        with patch.object(e, "_CPUProxy", FakeCPU):
            sampler = e.PowerSampler(helper, 0.02).start()
            sampler._process.wait(timeout=5)
            sampler.stop()
        self.assertEqual(sampler.report(1, 2)["gross_j"], 3)

    def test_injected_stdout_metadata_stderr_and_invalid_records_do_not_leak(self):
        secret = "PRIVATE-HELPER-SENTINEL-NOT-ALLOWED"
        helper = self.fixtures / "private-helper.py"
        descriptor = channel("CPU Energy", 1000, identity=secret, private_text=secret)
        records = [{"type": "ready", "source": secret, "clock": secret, "uid": secret,
                    "ready_mono": 1, "channels": [descriptor], "build": {"path": secret}, "private_text": secret},
                   {"type": "sample", "start_mono": 1, "end_mono": 2, "is_delta": True,
                    "raw_channels": [descriptor], "private_text": secret, "source": secret},
                   {"type": "sample", "start_mono": secret, "end_mono": 2, "is_delta": True}]
        stderr = secret.encode() + b"\xff"
        helper.write_text("#!/usr/bin/env python3\nimport json,os\n"
                          "records=" + repr(records) + "\n"
                          "for record in records:print(json.dumps(record),flush=True)\n"
                          "os.write(2," + repr(stderr) + ")\nraise SystemExit(2)\n")
        helper.chmod(0o755)
        with patch.object(e, "_CPUProxy", FakeCPU):
            sampler = e.PowerSampler(helper, 0.02).start()
            sampler._process.wait(timeout=5)
            sampler.stop()
        output = {"samples": sampler.snapshot(), "metadata": sampler.metadata,
                  "errors": sampler.errors, "report": sampler.report(1, 2)}
        self.assertNotIn(secret, json.dumps(output))
        self.assertNotIn("/Users/", json.dumps(sampler.metadata))
        self.assertEqual(sampler.metadata["helper_stderr_bytes"], len(stderr))
        self.assertEqual(sampler.metadata["helper_stderr_sha256"], hashlib.sha256(stderr).hexdigest())
        self.assertEqual(sampler.metadata["invalid_helper_record_count"], 1)
        self.assertIn("helper_stderr_present", sampler.errors)
        self.assertIn("invalid_helper_record", sampler.errors)
        self.assertIn("helper_nonzero_exit", sampler.errors)
        self.assertTrue(set(sampler.errors) <= e.ERROR_REASONS)

    def test_build_and_start_exceptions_never_echo_private_exception_text(self):
        secret = "PRIVATE-EXCEPTION-SENTINEL"
        for method, path, expected in (("build_helper", None, "helper_build_failed"),
                                       ("subprocess.Popen", self.helper, "helper_start_failed")):
            owner, attribute = (e.subprocess, "Popen") if method == "subprocess.Popen" else (e, method)
            with self.subTest(method=method), patch.object(owner, attribute, side_effect=OSError(secret)), \
                    patch.object(e, "_CPUProxy", FakeCPU), patch.object(e, "_gpu_utilization", return_value=None):
                with e.PowerSampler(path, 0.02) as sampler:
                    time.sleep(0.03)
                self.assertIn(expected, sampler.errors)
                self.assertNotIn(secret, json.dumps({"metadata": sampler.metadata, "errors": sampler.errors,
                                                    "samples": sampler.samples, "report": sampler.report()}))


if __name__ == "__main__":
    unittest.main()
