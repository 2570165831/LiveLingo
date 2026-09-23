#!/usr/bin/env python3
"""Exercise CLI exit paths with synthetic files and a fake pipe worker only.

Usage: test-cli-process.py CLI NEW_EVIDENCE_DIRECTORY SYNTHETIC_FIXTURES
The fixtures directory comes from test-cli-lifecycle.swift. Evidence is retained.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time


FAKE_WORKER = r'''
import argparse, json, os, pathlib, sys
p = argparse.ArgumentParser()
p.add_argument('--model')
p.add_argument('--state-directory')
a = p.parse_args()
evidence = pathlib.Path(os.environ['LL_CLI_TEST_EVIDENCE'])
(evidence / 'worker-pid.txt').write_text(str(os.getpid()))
(evidence / 'worker-model.txt').write_text(str(a.model))
def emit(value):
    print(json.dumps(value), flush=True)
emit({'event': 'ready', 'version': 2})
for line in sys.stdin:
    command = json.loads(line)
    op = command['op']
    if op == 'generate':
        emit({'event': 'model_state', 'loaded': True})
        (evidence / 'request-started').write_text('yes')
        mode = os.environ['LL_CLI_TEST_MODE']
        if mode == 'failure':
            emit({'event': 'error', 'id': command['id'], 'message': 'PRIVATE_CLASSROOM_ERROR_CANARY', 'recoverable': False})
        elif mode != 'hold':
            # purpose=note is the notes/9B review protocol; its answer must be a
            # real LearningNote JSON or the note batch cannot commit.
            if command.get('purpose') == 'note':
                text = json.dumps({'sourceVersion': 2, 'topic': '合成课堂主题',
                                   'points': [{'kind': '核心结论', 'text': '这是合成的知识点。', 'sourceIDs': []}],
                                   'noNewKnowledge': False}, ensure_ascii=False)
            else:
                text = '这是用于检查的合成译文。'
            emit({'event': 'done', 'id': command['id'], 'wire': text, 'text': text})
    else:
        if op == 'pause':
            state = pathlib.Path(a.state_directory)
            state.mkdir(parents=True, exist_ok=True)
            (state / 'synthetic-checkpoint.json').write_text(json.dumps({'saved': True}))
        (evidence / (op + '-received')).write_text('yes')
        emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
        if op == 'shutdown':
            break
'''

FAKE_ASR = r'''
import argparse, hmac, json, os, pathlib, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
p = argparse.ArgumentParser()
p.add_argument('--host')
p.add_argument('--port', type=int)
p.add_argument('--models-dir')
p.add_argument('--supervised', action='store_true')
a = p.parse_args()
evidence = pathlib.Path(os.environ['LL_CLI_TEST_EVIDENCE'])
token = os.environ['LIVELINGO_ASR_TOKEN']
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        authorized = hmac.compare_digest(self.headers.get('X-LiveLingo-Token', ''), token)
        (evidence / 'asr-health.json').write_text(json.dumps({'authorized': authorized}))
        self.send_response(503 if authorized else 403)
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *args):
        pass
server = ThreadingHTTPServer((a.host, a.port), Handler)
port = server.server_address[1]
(evidence / 'asr-child.json').write_text(json.dumps({'pid': os.getpid(), 'ppid': os.getppid(), 'port': port}))
threading.Thread(target=server.serve_forever, daemon=True).start()
print('LIVELINGO_ASR_READY ' + json.dumps({'protocol': 1, 'host': a.host, 'port': port,
      'pid': os.getpid(), 'auth': bool(token), 'supervised': a.supervised,
      'models_root': str(pathlib.Path(a.models_dir).resolve())}), flush=True)
sys.stdin.read()
(evidence / 'asr-stdin-closed').write_text('yes')
server.server_close()
'''


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    binary, root, fixtures = map(lambda p: Path(p).resolve(), sys.argv[1:])
    root.mkdir(exist_ok=False)
    worker = root / 'fake-worker.py'
    worker.write_text(FAKE_WORKER)
    models = root / 'fake-models'
    for name in ('mlx-community/Qwen3.5-4B-MLX-8bit', 'lmstudio-community/Qwen3.5-9B-MLX-4bit'):
        model = models / name
        model.mkdir(parents=True)
        for filename in ('config.json', 'tokenizer.json'):
            (model / filename).write_text('{}')
    outside = root / 'synthetic-outside-state'
    outside.mkdir()
    canary = outside / 'learning-review-queue.json'
    canary.write_text('SYNTHETIC_UNRELATED_QUEUE')
    original = canary.read_bytes()
    passed = []

    def environment(case: Path, mode: str = 'success') -> dict:
        env = os.environ.copy()
        for key in ('LIVELINGO_ASR_ENDPOINT', 'LIVELINGO_ASR_TOKEN', 'LIVELINGO_UNIT_TESTING', 'XCTestConfigurationFilePath'):
            env.pop(key, None)
        temporary = case / 'tmp'
        temporary.mkdir()
        env.update(TMPDIR=str(temporary) + '/', LIVELINGO_MLX_PYTHON=sys.executable,
                   LIVELINGO_MLX_WORKER=str(worker), LIVELINGO_MLX_MODELS=str(models),
                   LIVELINGO_DATA_DIRECTORY=str(outside), LIVELINGO_MLX_STATE=str(outside),
                   LIVELINGO_PREFERENCES_SUITE='com.example.LiveLingoSyntheticOutside',
                   LL_CLI_TEST_EVIDENCE=str(case), LL_CLI_TEST_MODE=mode)
        return env

    def record(case: Path, code: int, out: str, err: str) -> None:
        (case / 'stdout.log').write_text(out)
        (case / 'stderr.log').write_text(err)
        (case / 'exit.json').write_text(json.dumps({'exit': code}) + '\n')
        assert 'PRIVATE_CLASSROOM_ERROR_CANARY' not in out + err
        assert canary.read_bytes() == original
        events = [json.loads(line) for line in out.splitlines() if line.startswith('{')]
        cleanup = [event for event in events if event.get('event') == 'runtime_cleanup']
        assert len(cleanup) == 1 and cleanup[0]['confirmed'] and cleanup[0]['remainingMLX'] == 0
        assert not cleanup[0]['asrRunning']
        pid_file = case / 'worker-pid.txt'
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('owned worker survived CLI exit')

    for name, mode in [('translation-success', 'success'), ('translation-failure', 'failure')]:
        case = root / name
        case.mkdir()
        result = subprocess.run([str(binary), '--translate-text', 'This is a synthetic classroom sentence.', '--output', str(case / 'run')],
                                env=environment(case, mode), capture_output=True, text=True, timeout=40)
        record(case, result.returncode, result.stdout, result.stderr)
        assert result.returncode == (0 if mode == 'success' else 1)
        assert (case / 'shutdown-received').exists()
        if mode == 'success':
            assert 'OUTPUT[0]=这是用于检查的合成译文。' in result.stdout
        else:
            assert 'model_runtime' in result.stderr
        passed.append(name)

    for name, number in [('sigint', signal.SIGINT), ('sigterm', signal.SIGTERM)]:
        case = root / name
        case.mkdir()
        process = subprocess.Popen([str(binary), '--translate-text', 'This request deliberately waits.', '--output', str(case / 'run')],
                                   env=environment(case, 'hold'), stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not (case / 'request-started').exists():
                assert process.poll() is None, 'CLI exited before fake request started'
                if time.monotonic() >= deadline:
                    raise TimeoutError('fake request did not start')
                time.sleep(0.02)
            process.send_signal(number)
            out, err = process.communicate(timeout=40)
        except BaseException:
            if process.poll() is None:
                process.terminate()  # Exact child created by this test.
                process.communicate(timeout=40)
            raise
        record(case, process.returncode, out, err)
        assert process.returncode == 128 + number
        assert (case / 'cancel-received').exists()  # --translate-text has no resumable generation prefix.
        assert (case / 'shutdown-received').exists()
        assert (case / 'run/.cli-runtime/run.json').is_file()
        passed.append(name)

    for name, args in [('help', ['--help']), ('verify-zero', ['--verify-saved', str(fixtures / 'zero-captions')]),
                       ('verify-corrupt', ['--verify-saved', str(fixtures / 'bad-srt')]),
                       ('reject-foreign', ['--translate-text', 'Synthetic text', '--output', str(root / 'rejected-output')]),
                       ('missing-asr', ['--replay', str(fixtures / 'zero-captions/recording.wav'),
                                        '--output', str(root / 'missing-asr-output')])]:
        case = root / name
        case.mkdir()
        env = environment(case)
        if name == 'reject-foreign':
            env['LIVELINGO_ASR_ENDPOINT'] = 'http://127.0.0.1:18765'
        result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=40)
        record(case, result.returncode, result.stdout, result.stderr)
        assert result.returncode == (0 if name in ('help', 'verify-zero') else 1)
        assert not (case / 'worker-pid.txt').exists()
        if name == 'verify-zero':
            receipt = next(json.loads(line) for line in result.stdout.splitlines()
                           if line.startswith('{') and json.loads(line).get('event') == 'saved_verified')
            assert receipt['scope'] == 'export_integrity' and receipt['captionState'] == 'no_captions'
        if name == 'reject-foreign':
            assert 'unownedASR' in result.stderr and not list((case / 'tmp').iterdir())
        passed.append(name)
    # Exercise ASRRuntime's exact child ownership without any inference package
    # or audio device. A health failure ends before Speech authorization starts.
    case = root / 'owned-asr-health-failure'
    case.mkdir()
    bundle = case / 'bundle'
    runtime = bundle / 'ASRRuntime'
    interpreter = runtime / 'python/bin/python3'
    interpreter.parent.mkdir(parents=True)
    interpreter.symlink_to(Path(sys.executable).resolve())
    (runtime / 'qwen_asr_service.py').write_text(FAKE_ASR)
    (bundle / 'Models').mkdir()
    isolated_cli = bundle / 'livelingo-cli'
    shutil.copyfile(binary, isolated_cli)
    isolated_cli.chmod(0o700)
    result = subprocess.run([str(isolated_cli), '--replay', str(fixtures / 'zero-captions/recording.wav'),
                             '--output', str(case / 'run')], env=environment(case),
                            capture_output=True, text=True, timeout=40)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 1 and 'model_runtime' in result.stderr
    assert not (case / 'worker-pid.txt').exists()
    child = json.loads((case / 'asr-child.json').read_text())
    assert child['port'] > 0 and child['port'] != 18765
    assert json.loads((case / 'asr-health.json').read_text())['authorized']
    assert (case / 'asr-stdin-closed').is_file()
    try:
        os.kill(child['pid'], 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('owned ASR survived CLI failure')
    assert 'asr_owned' in result.stdout
    passed.append('owned-asr-health-failure')

    # ---------------------------------------------------------------------
    # Internal reopen / restart acceptance entries.
    #
    # Everything below drives the real CLI process against synthetic courses
    # built by test-cli-lifecycle.swift and a standard-library Python generator.
    # It proves the entry points, refusal rules, exit codes and durable
    # restart behaviour. It is NOT real-model acceptance: a fake generator
    # cannot establish transcription, translation or note quality.
    # ---------------------------------------------------------------------
    def failure_reason(text: str):
        for line in text.splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict) and value.get('event') == 'cli_failed':
                return value.get('reason')
        return None

    def cli_events(text: str) -> list[dict]:
        rows = []
        for line in text.splitlines():
            if not line.startswith('{'):
                continue
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict) and 'event' in value:
                rows.append(value)
        return rows

    def course_state(directory: Path) -> dict:
        # SessionStore persists a checksummed envelope whose payload is base64.
        envelope = json.loads((directory / 'session-snapshot.json').read_text())
        snapshot = json.loads(base64.b64decode(envelope['payload']))
        return {
            'sessionID': snapshot['sessionID'],
            'inputRevision': snapshot['inputRevision'],
            'segments': [row['id'] for row in snapshot['segments']],
            'engines': [row['english'] for row in snapshot['segments']],
            'translated': [row['id'] for row in snapshot['segments']
                           if row.get('translationState') == 'completed' and row.get('chinese')],
            'batches': [row['id'] for row in snapshot.get('batches', [])],
            'phase': snapshot.get('processing', {}).get('phase'),
        }

    restart = fixtures / 'restart-course'
    unbound = fixtures / 'unbound-course'
    legacy = fixtures / 'legacy-course'
    for name, fixture in (('restart-course', restart), ('unbound-course', unbound), ('legacy-course', legacy)):
        assert fixture.is_dir(), 'lifecycle fixture missing: ' + name
    pristine = course_state(restart)
    assert pristine['phase'] == 'paused'
    restart_marker = (restart / '.cli-runtime/run.json').read_bytes()
    unbound_marker = (unbound / '.cli-runtime/run.json').read_bytes()
    legacy_marker = (legacy / '.cli-runtime/run.json').read_bytes()

    # An unknown directory is never reopened and never receives CLI state.
    case = root / 'open-unmarked'
    case.mkdir()
    plain = case / 'plain-course'
    plain.mkdir()
    (plain / 'unrelated.txt').write_text('unrelated user file')
    listing = sorted(p.name for p in plain.iterdir())
    result = subprocess.run([str(binary), '--open-saved', str(plain)], env=environment(case),
                            capture_output=True, text=True, timeout=60)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 1 and failure_reason(result.stderr) == 'markerMissing'
    assert sorted(p.name for p in plain.iterdir()) == listing
    assert not (plain / '.cli-runtime').exists()
    assert not (case / 'worker-pid.txt').exists()
    passed.append('open-unmarked-refused-without-writes')

    for name, fixture, expected, before_bytes in (
            ('open-legacy', legacy, 'legacyMarkerUnsupported', legacy_marker),
            ('open-unbound', unbound, 'sessionUnbound', unbound_marker)):
        case = root / name
        case.mkdir()
        result = subprocess.run([str(binary), '--open-saved', str(fixture)], env=environment(case),
                                capture_output=True, text=True, timeout=60)
        record(case, result.returncode, result.stdout, result.stderr)
        assert result.returncode == 1 and failure_reason(result.stderr) == expected, result.stderr
        assert (fixture / '.cli-runtime/run.json').read_bytes() == before_bytes
        assert not (case / 'worker-pid.txt').exists()
        passed.append(name)

    # A bound course opens paused, without capture and without any model call.
    case = root / 'open-pristine'
    case.mkdir()
    result = subprocess.run([str(binary), '--open-saved', str(restart)], env=environment(case),
                            capture_output=True, text=True, timeout=120)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 0, result.stderr
    events = cli_events(result.stdout)
    opened = [row for row in events if row.get('event') == 'opened']
    verified = [row for row in events if row.get('event') == 'reopen_verified']
    assert opened and opened[-1]['paused'] is True and opened[-1]['capture'] is False
    assert verified and verified[-1]['mode'] == 'open-saved' and verified[-1]['segments'] == 3
    assert not (case / 'worker-pid.txt').exists(), 'reopening must not start a model worker'
    assert not (case / 'request-started').exists()
    assert course_state(restart) == pristine, 'reopening changed the saved course'
    passed.append('open-bound-paused-without-model')

    # Interrupted restart: SIGINT during the resumed generation keeps state.
    case = root / 'resume-sigint'
    case.mkdir()
    marker_before_sigint = (restart / '.cli-runtime/run.json').read_bytes()
    process = subprocess.Popen([str(binary), '--resume-saved', str(restart)], env=environment(case, 'hold'),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 60
        while not (case / 'request-started').exists():
            assert process.poll() is None, 'CLI exited before the resumed request started'
            if time.monotonic() >= deadline:
                raise TimeoutError('resumed generation did not start')
            time.sleep(0.05)
        process.send_signal(signal.SIGINT)
        out, err = process.communicate(timeout=180)
    except BaseException:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=60)
        raise
    record(case, process.returncode, out, err)
    assert process.returncode == 130, err
    assert failure_reason(err) == 'cancelled'
    # A cancelled translation request is not resumable, so the owned worker gets
    # cancel (not pause) and must still confirm shutdown before the CLI exits.
    assert (case / 'shutdown-received').exists()
    assert (case / 'cancel-received').exists() or (case / 'pause-received').exists()
    after_signal = course_state(restart)
    for key in ('sessionID', 'inputRevision', 'segments', 'engines', 'translated', 'batches'):
        assert after_signal[key] == pristine[key], 'interrupted restart changed ' + key
    assert after_signal['phase'] == 'paused'
    assert (restart / '.cli-runtime/run.json').read_bytes() == marker_before_sigint
    passed.append('resume-sigint-retains-saved-state')

    # Restart recovery: the same explicit entry completes the saved work with
    # the 9B profile, four real exports and no capture.
    case = root / 'resume-complete'
    case.mkdir()
    result = subprocess.run([str(binary), '--resume-saved', str(restart), '--high-quality', '--export-notes'],
                            env=environment(case, 'success'), capture_output=True, text=True, timeout=300)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 0, result.stderr
    events = cli_events(result.stdout)
    assert any(row.get('event') == 'resumed' for row in events)
    assert {row.get('format') for row in events if row.get('event') == 'exported'} == {
        'markdown', 'plainText', 'word', 'pdf'}
    assert Path((case / 'worker-model.txt').read_text()).resolve() == \
        (models / 'lmstudio-community/Qwen3.5-9B-MLX-4bit').resolve(), \
        'the resumed 9B request must use its resolved local model directory'
    final = [row for row in events if row.get('event') == 'reopen_verified'][-1]
    assert final['mode'] == 'resume-saved' and final['paused'] is False and final['capture'] is False
    state = course_state(restart)
    assert state['sessionID'] == pristine['sessionID'] and state['segments'] == pristine['segments']
    assert state['inputRevision'] == pristine['inputRevision']
    assert state['translated'] == pristine['segments'], 'not every caption completed'
    assert state['batches'], 'no completed note batch was persisted'
    assert state['phase'] == 'completed'
    # summary-zh-Hans.md is a course artefact, not a notes export.
    export_files = [p for p in restart.iterdir()
                    if p.suffix in {'.md', '.txt', '.docx', '.pdf'}
                    and p.stem.endswith('整课笔记')]
    exports = {}
    for path in export_files:
        exports.setdefault(path.suffix, []).append(path)
    assert set(exports) == {'.md', '.txt', '.docx', '.pdf'}, sorted(p.name for p in export_files)
    assert all(len(paths) == 1 for paths in exports.values()), sorted(p.name for p in export_files)
    exports = {suffix: paths[0] for suffix, paths in exports.items()}
    assert '学习笔记' in exports['.md'].read_text(encoding='utf-8')
    assert '学习笔记' in exports['.txt'].read_text(encoding='utf-8')
    assert exports['.docx'].read_bytes()[:4] == b'PK\x03\x04'
    assert exports['.pdf'].read_bytes()[:4] == b'%PDF'
    assert all(p.stat().st_size > 0 for p in exports.values())
    passed.append('resume-restart-recovery-completes')

    # Reopening the completed course must still run no model at all.
    case = root / 'open-after-complete'
    case.mkdir()
    result = subprocess.run([str(binary), '--open-saved', str(restart)], env=environment(case),
                            capture_output=True, text=True, timeout=120)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 0, result.stderr
    assert not (case / 'request-started').exists() and not (case / 'worker-pid.txt').exists()
    opened = [row for row in cli_events(result.stdout) if row.get('event') == 'opened'][-1]
    assert opened['paused'] is False and opened['batches'] >= 1
    assert course_state(restart) == state
    passed.append('open-completed-without-model')

    # Drift after binding must be refused, not silently accepted.
    marker_before_drift = (restart / '.cli-runtime/run.json').read_bytes()
    for name, mutation in (('open-drifted-caption', 'caption'), ('open-tampered-marker', 'marker')):
        case = root / name
        case.mkdir()
        if mutation == 'caption':
            target = restart / 'session-snapshot.json'
            target_original = target.read_bytes()
            envelope = json.loads(target_original)
            snapshot = json.loads(base64.b64decode(envelope['payload']))
            snapshot['segments'][0]['english'] = 'Tampered synthetic caption'
            payload = json.dumps(snapshot, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            envelope['payload'] = base64.b64encode(payload).decode('ascii')
            envelope['checksum'] = hashlib.sha256(payload).hexdigest()
            target.write_text(json.dumps(envelope), encoding='utf-8')
            arguments = [str(binary), '--open-saved', str(restart)]
        else:
            target = restart / '.cli-runtime/run.json'
            target_original = target.read_bytes()
            marker = json.loads(target_original)
            marker['runID'] = '00000000-0000-0000-0000-000000000000'
            target.write_text(json.dumps(marker), encoding='utf-8')
            arguments = [str(binary), '--open-saved', str(restart)]
        try:
            result = subprocess.run(arguments, env=environment(case), capture_output=True, text=True, timeout=120)
        finally:
            target.write_bytes(target_original)
        record(case, result.returncode, result.stdout, result.stderr)
        assert result.returncode == 1, result.stdout
        assert not any(row.get('event') == 'reopen_verified' for row in cli_events(result.stdout))
        assert failure_reason(result.stderr) in {'sessionIdentityMismatch', 'captionRetentionFailed',
                                                 'session_archive', 'invalid_saved_data', 'markerInvalid'}, result.stderr
        assert not (case / 'worker-pid.txt').exists()
        passed.append(name)
    assert course_state(restart) == state and (restart / '.cli-runtime/run.json').read_bytes() == marker_before_drift

    # --verify-saved success is export integrity only, never a whole-run PASS.
    case = root / 'verify-is-not-a-whole-run'
    case.mkdir()
    result = subprocess.run([str(binary), '--verify-saved', str(restart)], env=environment(case),
                            capture_output=True, text=True, timeout=60)
    record(case, result.returncode, result.stdout, result.stderr)
    assert result.returncode == 0, result.stderr
    receipt = [row for row in cli_events(result.stdout) if row.get('event') == 'saved_verified'][-1]
    assert receipt['scope'] == 'export_integrity' and receipt['wholeRunVerified'] is False
    passed.append('verify-saved-is-not-whole-run')
    print(json.dumps({'event': 'process_tests_passed', 'count': len(passed), 'cases': passed}))


if __name__ == '__main__':
    main()
