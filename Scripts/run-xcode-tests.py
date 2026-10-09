#!/usr/bin/env python3
"""Thirty-minute test watchdog; retain only filtered output and owned stacks."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import re
import shutil
import stat
import subprocess
import threading
import time
import sys

REPO = Path(__file__).resolve().parent.parent
DD = OUT = None
WORKER = re.compile(r'worker-(\d+)-[0-9A-Fa-f-]{36}')
# The warning gate only counts when this log compiled every Swift source of both.
COMPILED_TARGETS = ('LiveLingo', 'LiveLingoTests')
spec = importlib.util.spec_from_file_location('redact', REPO / 'Scripts/run-preview-tool.py')
redact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(redact)


def processes():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid,ppid,uid,comm'], text=True)
    result = {}
    for line in rows.splitlines()[1:]:
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, parent, uid = map(int, fields[:3])
            result[pid] = (parent, uid, fields[3])
    return result


def owned_hosts():
    products = (DD / 'Build/Products').resolve()
    if not products.is_relative_to(DD):
        return {}
    result = {}
    for pid, row in processes().items():
        executable = Path(row[2])
        if row[1] != os.getuid() or not executable.is_absolute():
            continue
        resolved = executable.resolve()
        if resolved.is_relative_to(products) and str(resolved).endswith('/Contents/MacOS/LiveLingo'):
            result[pid] = row
    return result


def test_host_output(section):
    """Read each host's outer output once; child activities repeat that output.

    Never export commandInvocationDetails, attachments, or diagnostic metadata.
    The caller filters each emitted test-output stream before writing it.
    """
    output = section.get('testDetails', {}).get('emittedOutput', '')
    if output:
        yield output
        return
    for child in section.get('subsections', []):
        yield from test_host_output(child)


def invocation_workers(scratch, host_pids, previous_workers):
    """Return new worker directories of observed hosts, plus unattributed new names."""
    owned, unattributed = [], []
    for worker in sorted(scratch.glob('worker-*')):
        if worker.name in previous_workers:
            continue
        match = WORKER.fullmatch(worker.name)
        if not match or int(match[1]) not in host_pids:
            unattributed.append(worker.name)
            continue
        if worker.is_symlink() or worker.resolve().parent != scratch.resolve():
            raise ValueError('invalid worker directory')
        owned.append(worker)
    return owned, unattributed


def preference_events(scratch, host_pids, previous_workers, allow_empty=False):
    """Read only new, observed hosts' UUID-only audit streams, never old runs.

    allow_empty is for focused runs: their tests may create no preference suite.
    Zero events then still require an observed host worker and no new worker
    this runner cannot attribute, so an unread audit stream cannot be skipped.
    """
    events = []
    paths = []
    owned, unattributed = invocation_workers(scratch, host_pids, previous_workers)
    for worker in owned:
        path = worker / 'test-preferences.events'
        try:
            status = path.lstat()
        except FileNotFoundError:
            continue
        if status.st_uid != os.getuid() or not stat.S_ISREG(status.st_mode):
            raise ValueError('invalid preference audit file')
        lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
        for line in lines:
            if not re.fullmatch(r'TEST_PREFERENCE_(CREATED|CLEANED) suite=[A-Za-z][A-Za-z0-9-]*-'
                                r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\n', line):
                raise ValueError('invalid preference audit event')
        events.extend(lines)
        paths.append(str(path))
    if not events and (not allow_empty or not owned or unattributed):
        raise ValueError('no preference audit events for this invocation')
    return events, paths


def retire_workers(scratch, host_pids, previous_workers):
    """Remove this invocation's audited worker directories, all inside DerivedData/tmp."""
    owned, _ = invocation_workers(scratch, host_pids, previous_workers)
    removed = []
    for worker in owned:
        status = worker.lstat()
        if status.st_uid != os.getuid() or not stat.S_ISDIR(status.st_mode):
            raise ValueError('invalid worker directory')
        shutil.rmtree(worker)
        removed.append(worker.name)
    return removed


def sandboxed_host(app):
    """True unless the existing Debug host is readable and carries no sandbox entitlement."""
    if not (app / 'Contents/MacOS/LiveLingo').is_file():
        return True
    shown = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, errors='replace')
    # An unsigned (linker-signed) host has no entitlements; codesign may report
    # "not signed" with a non-zero status, which is also safe here.
    return 'com.apple.security.app-sandbox' in shown.stdout


def main():
    parser = argparse.ArgumentParser()
    global DD, OUT
    parser.add_argument('--name', required=True)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--output-root', required=True, type=Path)
    parser.add_argument('--parallel', choices=('YES', 'NO'), default='YES')
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--only', action='append', default=[])
    parser.add_argument('--action', choices=('test', 'test-without-building'), default='test')
    parser.add_argument('--keep-workers', action='store_true',
                        help="keep this run's worker directories under DerivedData/tmp after success")
    args = parser.parse_args()
    if not args.name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._' for c in args.name) or args.name in ('.', '..'):
        parser.error('name must be a simple file stem')
    if args.workers < 1:
        parser.error('workers must be positive')
    if args.derived_data.is_symlink():
        parser.error('DerivedData must not be a symbolic link')
    DD = args.derived_data.resolve()
    OUT = args.output_root.resolve()
    if DD in (Path('/'), Path.home(), REPO) or OUT in (Path('/'), Path.home(), REPO):
        parser.error('choose dedicated work directories')
    if DD.is_relative_to(REPO) or OUT.is_relative_to(REPO):
        parser.error('build products and evidence must be outside the repository')
    for path in (DD, DD / 'tmp', OUT):
        path.mkdir(parents=True, exist_ok=True)
    lock_file = (DD / '.test-run.lock').open('a')
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('another test invocation owns this DerivedData')
    if owned_hosts():
        parser.error('a test host is already running from this DerivedData')
    # CODE_SIGNING_ALLOWED=NO keeps the Debug host (production bundle ID,
    # ENABLE_APP_SANDBOX=YES) out of the real app container. test-without-building
    # reuses whatever host exists, so refuse one that was built signed.
    if args.action == 'test-without-building' and sandboxed_host(
            DD / 'Build/Products/Debug/LiveLingo.app'):
        parser.error('the existing Debug host is missing or sandboxed; rebuild with --action test')
    previous_workers = {path.name for path in (DD / 'tmp').glob('worker-*')}
    log_path = OUT / (args.name + '.log')
    result_path = OUT / (args.name + '.xcresult')
    command = ['/usr/bin/xcodebuild', '-project', 'LiveLingo.xcodeproj',
               '-scheme', 'LiveLingo', '-configuration', 'Debug',
               '-destination', 'platform=macOS,arch=arm64',
               '-derivedDataPath', str(DD), '-resultBundlePath', str(result_path),
               '-hideShellScriptEnvironment', '-disableAutomaticPackageResolution',
               '-skipPackageUpdates', '-parallel-testing-enabled', args.parallel,
               '-test-timeouts-enabled', 'YES',
               '-default-test-execution-time-allowance', '120',
               '-maximum-test-execution-time-allowance', '180',
               'CODE_SIGNING_ALLOWED=NO']
    # Clean first: warnings appear only for files Xcode compiles, so the warning
    # gate needs a full compile of both targets in this very log.
    command += ['clean', 'test'] if args.action == 'test' else [args.action]
    if args.parallel == 'YES':
        command += ['-parallel-testing-worker-count', str(args.workers)]
    command += ['-only-testing:' + name for name in args.only]
    load_before = os.getloadavg()
    started = time.monotonic()
    state = {'last_output': started, 'last_test': None, 'last_test_at': started}
    samples = []
    observed_hosts = {}
    timed_out = False
    with log_path.open('x', encoding='utf-8') as log:
        process = subprocess.Popen(command, cwd=REPO, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, errors='replace',
                                   start_new_session=True,
                                   env=dict(os.environ, TMPDIR=str(DD / 'tmp')))
        (OUT / (args.name + '.pid')).write_text(str(process.pid) + '\n')

        def consume():
            for line in redact.filtered(process.stdout):
                log.write(line)
                log.flush()
                state['last_output'] = time.monotonic()
                if ('Test Case ' in line and " started." in line) or ('◇ Test ' in line and ' started.' in line):
                    state['last_test'] = line.strip()
                    state['last_test_at'] = time.monotonic()

        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        next_sample = started + 90

        def capture(reason):
            hosts = owned_hosts()
            observed_hosts.update(hosts)
            ids = {process.pid: processes().get(process.pid)} | hosts
            for pid, identity in ids.items():
                if identity is None or processes().get(pid) != identity:
                    continue
                target = OUT / f'{args.name}-sample-{len(samples) + 1}-pid{pid}.txt'
                record = {'reason': reason, 'pid': pid, 'identity': identity,
                          'path': None, 'last_test': state['last_test'], 'exit_code': None}
                # Diagnostic failures never disable the test deadline, and a
                # duplicate name cannot overwrite an older stack capture.
                try:
                    with target.open('x', encoding='utf-8') as output:
                        record['path'] = str(target)
                        try:
                            completed = subprocess.run(
                                ['/usr/bin/sample', str(pid), '3', '10', '-file', '/dev/stdout'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors='replace', timeout=20)
                            raw = completed.stdout
                            record['exit_code'] = completed.returncode
                        except subprocess.TimeoutExpired as error:
                            raw = error.stdout or ''
                            if isinstance(raw, bytes):
                                raw = raw.decode('utf-8', errors='replace')
                            record['error'] = 'sample timeout'
                        except OSError:
                            raw = ''
                            record['error'] = 'sample invocation failed'
                        output.writelines(redact.filtered(raw.splitlines(keepends=True)))
                except FileExistsError:
                    record['error'] = 'sample evidence already exists'
                record['elapsed_s'] = round(time.monotonic() - started, 3)
                samples.append(record)

        while process.poll() is None:
            now = time.monotonic()
            hosts = owned_hosts()
            observed_hosts.update(hosts)
            silent = now - state['last_output']
            same_test = now - state['last_test_at'] if state['last_test'] else 0
            if now >= next_sample and (silent >= 60 or same_test >= 60) and len(samples) < 8:
                capture('no output or same test for at least 60s')
                next_sample = time.monotonic() + 120
            if now - started >= 1800:
                timed_out = True
                capture('30 minute deadline')
                # Re-check identity and target path immediately before termination.
                current = processes()
                for pid, identity in observed_hosts.items():
                    if current.get(pid) == identity:
                        try:
                            os.kill(pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                break
            time.sleep(1)
        returncode = process.wait()
        reader.join(timeout=10)
    receipt = {'name': args.name, 'parallel': args.parallel, 'workers': args.workers,
               'action': args.action, 'only': args.only, 'deadline_s': 1800,
               'load_before': load_before, 'load_after': os.getloadavg(), 'wall_s': round(time.monotonic() - started, 3),
               'exit_code': returncode, 'timed_out': timed_out, 'samples': samples,
               'host_identities': [{'pid': pid, 'identity': row} for pid, row in observed_hosts.items()],
               'log': str(log_path), 'xcresult': str(result_path), 'last_test': state['last_test']}
    (OUT / (args.name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({key: receipt[key] for key in ('name', 'wall_s', 'exit_code', 'timed_out', 'last_test')}), flush=True)
    if timed_out or returncode != 0:
        return 124 if timed_out else returncode
    # Parallel Xcode execution retains host stdout in the result bundle instead
    # of streaming it. Preserve real cleanup events without counting duplicates
    # from nested activity logs or manufacturing a successful completion marker.
    if 'TEST_PREFERENCE_CREATED' not in log_path.read_text(encoding='utf-8'):
        action_log = subprocess.run(
            ['/usr/bin/xcrun', 'xcresulttool', 'get', 'log', '--type', 'action',
             '--path', str(result_path), '--compact'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors='replace')
        try:
            if action_log.returncode != 0:
                raise ValueError('action log unavailable')
            sections = json.loads(action_log.stdout)
            with log_path.open('a', encoding='utf-8') as log:
                for output in test_host_output(sections):
                    log.writelines(redact.filtered(output.splitlines(keepends=True)))
                    log.write('\n')
            receipt['host_output_source'] = 'xcresult action log testDetails.emittedOutput'
        except (ValueError, OSError, TypeError):
            receipt['host_output_error'] = 'could not read filtered test output from result bundle'
            (OUT / (args.name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
            print(receipt['host_output_error'])
            return 1
    try:
        events, audit_paths = preference_events(DD / 'tmp', set(observed_hosts), previous_workers,
                                                allow_empty=bool(args.only))
        verification_log = OUT / (args.name + '-preferences.log')
        with verification_log.open('x', encoding='utf-8') as log:
            # Preserve the actual Xcode completion marker and failure evidence,
            # and use each worker's audit as the sole preference event source.
            for line in log_path.read_text(encoding='utf-8').splitlines(keepends=True):
                if 'TEST_PREFERENCE_CREATED' not in line and 'TEST_PREFERENCE_CLEANED' not in line:
                    log.write(line)
            log.writelines(events)
        receipt['preference_audits'] = audit_paths
        receipt['preference_verification_log'] = str(verification_log)
    except (ValueError, OSError):
        receipt['preference_audit_error'] = 'could not verify this invocation preference audit streams'
        (OUT / (args.name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
        print(receipt['preference_audit_error'])
        return 1
    guards = []
    for script in ('check_build_warnings.py', 'check_test_preferences.py'):
        if script == 'check_test_preferences.py':
            checked_log = verification_log
            # A focused run may create no suite; a full run must still have events.
            options = ['--allow-no-events'] if args.only else []
        else:
            checked_log = log_path
            options = ['--require-compiled-targets', *COMPILED_TARGETS]
        checked = subprocess.run([sys.executable,
                                  str(REPO / 'Scripts' / script), str(checked_log), *options],
                                 cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, errors='replace')
        output = ''.join(redact.filtered(checked.stdout.splitlines(keepends=True)))
        (OUT / (args.name + '-' + script.removesuffix('.py') + '.txt')).write_text(output)
        guards.append({'guard': script, 'exit_code': checked.returncode})
        print(output.rstrip())
    receipt['guards'] = guards
    passed = all(item['exit_code'] == 0 for item in guards)
    # Keep worker directories (fixtures, screenshots) as evidence after a
    # failure; after a pass their events are already in the verification log.
    if passed and not args.keep_workers:
        try:
            receipt['removed_workers'] = retire_workers(DD / 'tmp', set(observed_hosts), previous_workers)
        except (ValueError, OSError):
            receipt['worker_cleanup_error'] = 'could not remove this invocation worker directories'
            print(receipt['worker_cleanup_error'])
    (OUT / (args.name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
