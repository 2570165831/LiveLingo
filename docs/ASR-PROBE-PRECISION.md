# ASR probe precision regression investigation

## Finding

The original test combined two different checks: whether the service promotes
bfloat16 logits to float32, and whether an MLX float32 softmax over 151800
finite entries agrees with a float64 reference within roughly 5e-7 total
probability mass. The latter bound is not portable between the installed CPU
and GPU kernels. The service already delegates to the correct float32 kernel.

All inputs in this investigation were synthetic. No model weights, classroom
data, or external network access were used. The small HTTP tests in the existing
Python suite ran in process using its test transport.

The interpreter was Python 3.13.3 with MLX 0.32.2 and NumPy 2.5.3. Import paths
matched `../work/dd-tl1417/run-python-gates.sh`: `Scripts`, `Scripts/mlx_runtime`,
then the installed LanguageRuntime and ASRRuntime Python 3.13 site-packages,
in that order. Temporary/output roots were set to `../work/dd-prec`. Existing
scoreboard tests initially wrote their synthetic fixtures to a hardcoded
worktree `work/` path; those files were preserved under the scratch
`superseded/` directory, and a temporary symlink redirected subsequent writes
into the declared scratch root. No Swift build or DerivedData was needed.

## Reproduction and evidence

For the original dense fixtures, after bfloat16 quantization and a float32
softmax, summing the output in NumPy float64 produced these mass errors:

| Top logit | CPU sum minus one | GPU sum minus one |
| --- | ---: | ---: |
| 16 | 1.4237874523814753e-6 | 1.189505582921413e-8 |
| 1000 | 1.6357251775289683e-8 | 1.6386355605746417e-8 |
| -1000 | 8.538303000182879e-7 | 1.9128228778697576e-8 |

- Running the original class 50 times under `mx.stream(mx.cpu)` failed every
  time at `top=16` and `top=-1000`. The same class passed 200 times on GPU.
- Bare MLX softmax reproduced the service's errors. CPU `precise=True`,
  subtracting the maximum before softmax, and explicit float32 exp/sum did
  not eliminate them (100 repetitions of each fixture and expression).
  MLX documents `precise=True` as promoting lower precision accumulation;
  these inputs had already been promoted to float32.
- A full suite with the default device set to CPU ran 668 tests with exactly
  those two failing subtests, no errors, and six existing skips.
- Varying default/new streams, random seeds 0/42, and main/worker Python
  threads yielded the same backend distinction: 80 original CPU test runs
  each failed twice; all 80 GPU runs passed. The test itself restored device,
  stream identifiers, and its softmax patch in every condition. This varied
  Python threads, not an undocumented MLX CPU kernel thread setting.
- With a separate process repeatedly evaluating synthetic 512-by-512 GPU
  matrix multiplications, the original class passed 500 times. The workload
  evaluated 18844 matrix iterations and overlapped all probe repetitions.
- The default GPU suite passed three standard-order runs and one fully
  interleaved shuffle (seed 715); the probe still used the GPU default device
  and stream with an unmodified softmax entry point. The interleaved shuffle
  had 26 skip events because it revisited skipped classes. Final randomized
  acceptance instead preserves module/class fixture groups.

An initial grouped shuffle (seed 1417) encountered 16 unrelated missing-output
directory errors: a numeric-review class ran before the class that normally
creates the shared synthetic quality directory. The scratch runner now creates
that declared output directory before discovery; no repository tests were
changed for this runner setup issue.

These observations establish a backend-dependent test assumption. They do not
establish why the previously reported intermittent full-suite failures selected
that numerical behavior: the default GPU flake was not reproduced here, and
GPU contention alone did not reproduce it. No historical device/stream trace
was available to prove a specific earlier state leak or CPU fallback.

## Fix

Both regression tests explicitly exercise CPU and GPU inside scoped stream
contexts. The strict float64 comparison retains every original tolerance and
all three logit ranges, but uses three finite logits in the full vocabulary
shape, with the remaining entries set to negative infinity. This isolates the
bfloat16 partition-function error from long float32 accumulation. Its measured
mass errors were at most 2.418e-8 on either device; the old bfloat16 formula still
has a mass error of 0.0301513671875 at `top=16`.

A separate dense test retains all original 151800-entry finite-floor fixtures.
It requires float32 input/output and exact array equality with the same
backend's float32 softmax, including exact equality of both returned language
probabilities. It checks the service contract without assigning the GPU
kernel's reduction error bound to the CPU kernel.

`qwen_asr_service.py` is unchanged, so this patch changes no recognition or
language-selection behavior. It does not claim real-audio recognition testing.
In-memory negative controls verified that omitting the float32 cast and
restoring the old bfloat16 partition formula both fail the updated tests.

The fixed class passed all 320 test runs across the 16 device/stream/seed/thread
conditions, and passed 150 repeated class runs under the synthetic GPU workload.
The standalone ASR module ran 30 tests with no failures or errors. A full suite
with CPU as the initial default device ran 669 tests successfully with six
existing skips.

The first consecutive-suite acceptance attempt passed two runs, then failed
`SamplerTests.test_one_session_start_stop_clock_and_final_flush` with energy
coverage 0.6898006658354703 rather than 1. Both precision tests passed that run.
This existing sampler test uses a real process and monotonic clock, a 20 ms
sampling interval, and a 75 ms sleep; its failure's cause was not established
by the precision investigation. Its source and assertions were left unchanged.
The failed attempt is retained under scratch `superseded/acceptance-attempt-1-*`.

The next runner setup attempt triggered the timing tests' unchanged prohibition
on symlink fixture paths (24 failures). The final runner supplies their
`TEST_ROOT` fixture constant with the real scratch path, while retaining that
guard and every test assertion. This setup failure is retained under scratch
`superseded/acceptance-attempt-2-*`. Only the precision test file and this note
are repository changes.

## Final acceptance

Five consecutive complete root-discovery suites passed. The first four used
standard unittest order; the fifth shuffled modules, classes, and test methods
with `random.Random(1417)`, preserving fixture groups. No softmax/device tracing
patch was active during these five runs.

| Run | Order | Tests run | Failures | Errors | Existing skips |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Standard | 669 | 0 | 0 | 6 |
| 2 | Standard | 669 | 0 | 0 | 6 |
| 3 | Standard | 669 | 0 | 0 | 6 |
| 4 | Standard | 669 | 0 | 0 | 6 |
| 5 | Random, seed 1417 | 669 | 0 | 0 | 6 |

The standalone precision class ran two tests successfully. The final shuffle's
order SHA-256 is
`a3fe7b8e9e8d187f86fab2e18204361f83d3cee189f8fb97575c3b950581a3ff`.
`acceptance-summary.json`, `acceptance-full-*/unittest.log`, and the fifth run's
`order.txt` preserve the results and exact order. The scratch bootstrap only
routes fixture output into the authorized directory; it does not omit tests,
relax assertions, or replace model/numerical behavior.

Raw logs, numerical observations, exact shuffled order, negative controls, and
the offline reproduction runners are retained in `../work/dd-prec`.
