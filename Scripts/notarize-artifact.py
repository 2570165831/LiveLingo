#!/usr/bin/env python3
"""Submit once, confirm the upload, then poll by submission ID.

Upload time is separate from the processing deadline. Save an ID immediately,
but never poll or recommend resuming an upload that has not been confirmed
complete. Credentials stay in an existing keychain profile; no --wait is used.
"""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PROFILE_PLACEHOLDER = "<你的 profile>"
INTERRUPT_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
SUBMIT_ID = re.compile(
    r"^\s*id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$",
    re.IGNORECASE)
SUBMIT_STATUS = re.compile(r"^\s*status:\s*(In Progress|Accepted|Invalid|Rejected)\s*$")
UPLOAD_COMPLETED = re.compile(
    r"^\s*(?:Successfully uploaded file|Upload completed)(?:[\s.:].*)?$", re.IGNORECASE)
AUTH_FAILURE = re.compile(
    r"authentication (?:failed|failure|error)|(?:unable|failed|could not) to authenticate|"
    r"unauthorized|invalid (?:credentials|(?:app[- ]specific )?password)|"
    r"(?:http|status(?: code)?)[^\n]*\b(?:401|403)\b|"
    r"(?:no|cannot find|could not find|unable to find)[^\n]*keychain[^\n]*(?:item|profile)|"
    r"profile[^\n]*(?:not found|does not exist|could not be found)", re.IGNORECASE)


class NotarizationError(Exception):
    pass


class NotarizationInterrupted(NotarizationError):
    def __init__(self, signum):
        self.signum = signum
        super().__init__("interrupted by " + signal.Signals(signum).name)


def positive_number(value):
    number = float(value)
    if not 0 < number < float("inf"):
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return number


def nonnegative_number(value):
    number = float(value)
    if not 0 <= number < float("inf"):
        raise argparse.ArgumentTypeError("must be a finite nonnegative number")
    return number


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def nonnegative_integer(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be a nonnegative integer")
    return number


def submission_id(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise NotarizationError("notarytool did not return a valid submission ID")


class Notarizer:
    def __init__(self, args):
        self.args = args
        self.deadline = None
        self.command_count = 0
        self.active_process = None
        self.interrupted_signal = None
        self.last_stderr = ""
        self.phase = "initializing"
        self.notarytool = None
        self.submit_status = None
        self.completion_evidence = []
        self.receipt = {
            "artifact": str(args.artifact.resolve()) if args.artifact else None,
            "artifactBytes": args.artifact.stat().st_size if args.artifact else None,
            "submissionId": submission_id(args.submission_id) if args.submission_id else None,
            "status": "Existing submission" if args.submission_id else "Not submitted",
            "uploadComplete": False,
            "submissionMode": "explicit-resume" if args.submission_id else "upload",
        }

    def handle_signal(self, signum, _frame):
        # Do not raise inside Popen or an atomic receipt write. The command/pause
        # loops observe this flag, including a signal received during Popen.
        if self.interrupted_signal is None:
            self.interrupted_signal = signum
        if self.active_process is not None:
            try:
                os.killpg(self.active_process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def check_interrupted(self):
        if self.interrupted_signal is not None:
            raise NotarizationInterrupted(self.interrupted_signal)

    def save_receipt(self):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".receipt-",
                                             suffix=".tmp", dir=self.args.receipt_dir,
                                             delete=False) as output:
                temporary = Path(output.name)
                json.dump(self.receipt, output, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.args.receipt_dir / "receipt.json")
            temporary = None
            directory_fd = os.open(self.args.receipt_dir, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def remaining(self):
        self.check_interrupted()
        if self.deadline is None:
            raise NotarizationError("processing deadline has not started")
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise NotarizationError("notarization timed out (processing deadline)")
        return remaining

    @staticmethod
    def stop_process_group(process):
        # Kill the group even if its leader has already exited: a child may
        # still be running or holding a captured output pipe open.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)

    def observe_submit_line(self, line):
        match = SUBMIT_ID.fullmatch(line)
        if match:
            known_id = submission_id(match.group(1))
            if self.receipt["submissionId"] not in (None, known_id):
                raise NotarizationError("submit returned conflicting submission IDs; upload outcome unknown")
            if self.receipt["submissionId"] is None:
                self.receipt.update(submissionId=known_id, status="Uploading")
                self.save_receipt()
        status = SUBMIT_STATUS.fullmatch(line)
        if status:
            self.submit_status = status.group(1)
            self.completion_evidence.append("status: " + self.submit_status)
        elif UPLOAD_COMPLETED.fullmatch(line):
            self.completion_evidence.append(line.strip())

    def execute(self, action, command, timeout):
        self.check_interrupted()
        self.phase = action
        self.last_stderr = ""
        self.command_count += 1
        prefix = self.args.receipt_dir / ("%03d-%s" % (self.command_count, action))
        stdout_path = prefix.with_suffix(".stdout.txt" if action == "submit" else ".stdout.json")
        stderr_path = prefix.with_suffix(".stderr.txt")
        if action == "submit":
            self.receipt.update(submitStdout=stdout_path.name, submitStderr=stderr_path.name,
                                status="Uploading")
            self.save_receipt()
        output = {"stdout": bytearray(), "stderr": bytearray()}
        pending_line = bytearray()
        process = None
        stopped = False
        timed_out = False
        finished = False
        deadline = time.monotonic() + timeout if timeout is not None else None
        drain_deadline = None
        with stdout_path.open("wb") as stdout_log, stderr_path.open("wb") as stderr_log:
            selector = selectors.DefaultSelector()
            try:
                try:
                    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                               start_new_session=True)
                except OSError as error:
                    self.check_interrupted()
                    stderr_log.write(str(error).encode("utf-8"))
                    stderr_log.flush()
                    self.last_stderr = str(error)
                    return None, "", str(error), False
                self.active_process = process
                for name, pipe in (("stdout", process.stdout), ("stderr", process.stderr)):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ, name)
                while selector.get_map() or process.poll() is None:
                    now = time.monotonic()
                    if not stopped and (self.interrupted_signal is not None or
                                        (deadline is not None and now >= deadline)):
                        timed_out = self.interrupted_signal is None
                        self.stop_process_group(process)
                        stopped = True
                        drain_deadline = time.monotonic() + 1
                    if drain_deadline is not None and time.monotonic() >= drain_deadline:
                        break
                    for key, _events in selector.select(timeout=0.1):
                        try:
                            chunk = os.read(key.fd, 65536)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        output[key.data].extend(chunk)
                        log = stdout_log if key.data == "stdout" else stderr_log
                        log.write(chunk)
                        log.flush()
                        if action == "submit" and key.data == "stdout":
                            pending_line.extend(chunk)
                            while b"\n" in pending_line:
                                line, _, remainder = pending_line.partition(b"\n")
                                pending_line[:] = remainder
                                decoded = line.decode("utf-8", errors="replace")
                                self.observe_submit_line(decoded)
                                print(decoded, flush=True)
                        elif action == "submit":
                            # Surface credential/unlock diagnostics while uploading.
                            sys.stderr.write(chunk.decode("utf-8", errors="replace"))
                            sys.stderr.flush()
                if action == "submit" and pending_line:
                    decoded = pending_line.decode("utf-8", errors="replace")
                    self.observe_submit_line(decoded)
                    print(decoded, flush=True)
                self.check_interrupted()
                process.wait(timeout=5)
                finished = True
            finally:
                try:
                    if (process is not None and not stopped and
                            (not finished or self.interrupted_signal is not None)):
                        self.stop_process_group(process)
                finally:
                    if process is not None:
                        self.last_stderr = output["stderr"].decode("utf-8", errors="replace")
                    selector.close()
                    if process is not None:
                        process.stdout.close()
                        process.stderr.close()
                    self.active_process = None
        return (process.returncode, output["stdout"].decode("utf-8", errors="replace"),
                output["stderr"].decode("utf-8", errors="replace"), timed_out)

    def resolve_notarytool(self):
        if "LIVELINGO_TEST_TOOL_DIR" in os.environ:
            test_dir = Path(os.environ["LIVELINGO_TEST_TOOL_DIR"])
            if not test_dir.is_absolute() or not test_dir.is_dir():
                raise NotarizationError("LIVELINGO_TEST_TOOL_DIR must be an absolute test-tool directory")
            path = (test_dir / "notarytool").resolve()
            if not path.is_relative_to(test_dir.resolve()):
                raise NotarizationError("test notarytool must resolve inside LIVELINGO_TEST_TOOL_DIR")
            source = "LIVELINGO_TEST_TOOL_DIR"
        else:
            code, stdout, stderr, timed_out = self.execute(
                "resolve", ["/usr/bin/xcrun", "-f", "notarytool"], 30)
            if code != 0 or timed_out:
                raise NotarizationError("cannot resolve notarytool: " +
                                        self.command_failure("xcrun", code, stderr, timed_out))
            path = Path(stdout.strip())
            if not path.is_absolute():
                raise NotarizationError("xcrun did not resolve an absolute notarytool path")
            path = path.resolve()
            source = "/usr/bin/xcrun -f notarytool"
        if not path.is_file() or not os.access(path, os.X_OK):
            raise NotarizationError("resolved notarytool is not an executable file: " + str(path))
        self.notarytool = str(path)
        self.receipt.update(notarytool=self.notarytool, notarytoolSource=source)
        self.save_receipt()
        print("Notarytool: " + self.notarytool, flush=True)

    def command(self, action, *arguments):
        if action == "submit":
            timeout = self.args.submit_timeout or None
        else:
            timeout = min(self.args.command_timeout, self.remaining())
        command = [self.notarytool, action, *map(str, arguments),
                   "--keychain-profile", self.args.profile]
        if self.args.notary_keychain:
            command += ["--keychain", str(self.args.notary_keychain)]
        if action == "submit":
            command += ["--no-progress"]
        elif action == "info":
            command += ["--output-format", "json"]
        return self.execute(action, command, timeout)

    @staticmethod
    def command_failure(action, code, stderr, timed_out):
        detail = "%s exit %s%s" % (action, code, ", command timed out" if timed_out else "")
        summary = stderr.strip()
        if summary:
            detail += "; stderr: " + summary[-2000:]
        else:
            detail += "; stderr: (empty)"
        return detail

    def pause(self):
        end = time.monotonic() + min(self.args.poll_interval, self.remaining())
        while time.monotonic() < end:
            self.check_interrupted()
            time.sleep(min(0.1, max(0, end - time.monotonic())))
        self.remaining()

    def submit(self):
        print("Uploading artifact: %s (%s bytes); submit timeout: %s" %
              (self.receipt["artifact"], self.receipt["artifactBytes"],
               "%s seconds" % self.args.submit_timeout if self.args.submit_timeout else "unlimited"),
              flush=True)
        code, stdout, stderr, timed_out = self.command("submit", self.receipt["artifact"])
        # The processing budget starts when submit finishes, never before upload.
        self.deadline = time.monotonic() + self.args.timeout
        self.receipt.update(submitExitCode=code, submitTimedOut=timed_out,
                            uploadCompletionEvidence=self.completion_evidence)
        if (code != 0 or timed_out or not self.receipt["submissionId"] or
                not self.completion_evidence):
            detail = self.command_failure("submit", code, stderr, timed_out)
            if not self.receipt["submissionId"] and AUTH_FAILURE.search(stderr + "\n" + stdout):
                self.receipt["status"] = "Authentication/profile failed"
                self.save_receipt()
                raise NotarizationError("notarytool authentication/profile failed before receiving an ID; "
                                        "NOT resubmitting. " + detail)
            self.receipt["status"] = "Submission outcome unknown"
            self.save_receipt()
            raise NotarizationError("submission outcome unknown: " + detail +
                                    "; upload completion not confirmed. NOT resubmitting or polling. "
                                    "Any captured ID is not safe to resume; inspect saved submit output.")
        self.receipt.update(uploadComplete=True, status=self.submit_status or "Submitted")
        self.save_receipt()

    def fetch_rejection_log(self, known_id):
        self.receipt["logFetched"] = False
        for attempt in range(1, self.args.max_retries + 2):
            self.receipt["logAttempts"] = attempt
            try:
                code, _stdout, stderr, timed_out = self.command("log", known_id)
                if code != 0 or timed_out:
                    raise NotarizationError(self.command_failure("log", code, stderr, timed_out))
            except NotarizationInterrupted:
                raise
            except (OSError, NotarizationError) as error:
                self.receipt["logError"] = str(error)
                self.save_receipt()
                print("Could not fetch rejection log (attempt %s/%s): %s" %
                      (attempt, self.args.max_retries + 1, error), file=sys.stderr, flush=True)
                if attempt <= self.args.max_retries:
                    print("Retrying log; upload is not retried.", file=sys.stderr, flush=True)
                    try:
                        self.pause()
                    except NotarizationInterrupted:
                        raise
                    except NotarizationError as error:
                        self.receipt["logError"] = str(error)
                        self.save_receipt()
                        print("Log retry stopped: " + str(error), file=sys.stderr, flush=True)
                        break
            else:
                self.receipt["logFetched"] = True
                self.receipt.pop("logError", None)
                self.save_receipt()
                return True
        return False

    def run(self):
        self.save_receipt()
        self.resolve_notarytool()
        if self.args.submission_id:
            # An explicit ID is a caller-requested query, not evidence that this
            # helper completed its upload. Do not invent uploadComplete=True.
            self.deadline = time.monotonic() + self.args.timeout
            print("Explicitly polling an existing ID; this run has not verified its upload completion.",
                  flush=True)
        else:
            self.submit()
        known_id = self.receipt["submissionId"]
        print("Submission ID: " + known_id, flush=True)
        consecutive_failures = 0
        for attempt in range(1, self.args.max_polls + 1):
            self.receipt["pollAttempts"] = attempt
            code, stdout, stderr, timed_out = self.command("info", known_id)
            try:
                if code != 0 or timed_out:
                    raise ValueError(self.command_failure("info", code, stderr, timed_out))
                response = json.loads(stdout)
                if not isinstance(response, dict) or not isinstance(response.get("status"), str):
                    raise ValueError("info did not return a JSON status")
                try:
                    response_id = submission_id(response.get("id"))
                except NotarizationError as error:
                    raise ValueError(str(error))
            except ValueError as error:
                consecutive_failures += 1
                detail = str(error)
                if "; stderr:" not in detail:
                    detail += "; stderr: " + (stderr.strip()[-2000:] or "(empty)")
                self.receipt.update(infoFailures=consecutive_failures, lastInfoError=detail)
                self.save_receipt()
                if consecutive_failures > self.args.max_retries:
                    raise NotarizationError("info retry limit exceeded: " + detail)
                print("Retrying info (%s/%s): %s" %
                      (consecutive_failures, self.args.max_retries, detail),
                      file=sys.stderr, flush=True)
            else:
                if response_id != known_id:
                    raise NotarizationError("info returned a different submission ID; stderr: " +
                                            (stderr.strip()[-2000:] or "(empty)"))
                consecutive_failures = 0
                state = response["status"]
                self.receipt.update(status=state, infoFailures=0)
                self.receipt.pop("lastInfoError", None)
                self.save_receipt()
                print("Poll %s/%s: %s" % (attempt, self.args.max_polls, state), flush=True)
                if state == "Accepted":
                    return
                if state in ("Invalid", "Rejected"):
                    fetched = self.fetch_rejection_log(known_id)
                    raise NotarizationError("notarization " + state +
                                            ("; inspect saved log" if fetched else
                                             "; rejection log unavailable; inspect saved stderr"))
                if state != "In Progress":
                    raise NotarizationError("unexpected notarization status: " + state)
            if attempt < self.args.max_polls:
                self.pause()
        raise NotarizationError("notarization poll limit reached")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--artifact", type=Path, help="App-only DMG or signed release DMG to submit once")
    parser.add_argument("--submission-id",
                        help="explicitly query an existing ID with a known completed upload; do not upload")
    parser.add_argument("--profile", default=os.environ.get("LIVELINGO_NOTARY_PROFILE", PROFILE_PLACEHOLDER),
                        help="existing local keychain profile (or LIVELINGO_NOTARY_PROFILE)")
    parser.add_argument("--notary-keychain", "--keychain", dest="notary_keychain", type=Path,
                        help="optional keychain containing the notary profile; independent of signing "
                             "keychain; omitted by default (--keychain is a compatibility alias)")
    parser.add_argument("--receipt-dir", type=Path, required=True,
                        help="new private directory for submission ID and tool output; never put in DMG")
    parser.add_argument("--submit-timeout", type=nonnegative_number, default=0,
                        help="upload-only deadline in seconds; 0 is unlimited (default: 0)")
    parser.add_argument("--timeout", type=positive_number, default=3600,
                        help="processing deadline after upload or at explicit resume, in seconds "
                             "(default: 3600)")
    parser.add_argument("--command-timeout", type=positive_number, default=60,
                        help="info/log deadline in seconds, capped by remaining processing time "
                             "(default: 60); never limits submit")
    parser.add_argument("--poll-interval", type=positive_number, default=30,
                        help="seconds between info attempts (default: 30)")
    parser.add_argument("--max-polls", type=positive_integer, default=120,
                        help="maximum info attempts, including failures (default: 120)")
    parser.add_argument("--max-retries", type=nonnegative_integer, default=3,
                        help="retries after consecutive info failures or failed log requests "
                             "(default: 3; submit never retried)")
    args = parser.parse_args()
    if not args.profile.strip() or args.profile == PROFILE_PLACEHOLDER:
        parser.error("specify an existing keychain profile; the documentation placeholder is not a profile")
    if args.submission_id:
        try:
            submission_id(args.submission_id)
        except NotarizationError as error:
            parser.error(str(error))
    if args.artifact is not None and not args.artifact.is_file():
        parser.error("--artifact must be an existing file")
    if not args.submission_id and not args.artifact:
        parser.error("--artifact must be an existing file unless --submission-id is supplied")
    if not args.submission_id and args.artifact.suffix.lower() != ".dmg":
        parser.error("new uploads require a .dmg; ZIP uploads are not supported")
    try:
        # Refuse existing directories, including dangling symlinks. Each run's
        # outputs belong to this run and are outside the distributable payload.
        args.receipt_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        args.receipt_dir.chmod(0o700)
        args.receipt_dir = args.receipt_dir.resolve()
    except OSError as error:
        parser.error("cannot create new receipt directory: " + str(error))
    worker = None
    previous_handlers = {}
    result = 0
    try:
        worker = Notarizer(args)
        for signum in INTERRUPT_SIGNALS:
            previous_handlers[signum] = signal.signal(signum, worker.handle_signal)
        worker.run()
        worker.check_interrupted()
    except (NotarizationError, OSError, KeyboardInterrupt, subprocess.TimeoutExpired) as error:
        result = 1
        detail = str(error) or "interrupted"
        if worker is not None:
            if (worker.interrupted_signal is not None or
                    isinstance(error, (NotarizationInterrupted, KeyboardInterrupt))):
                signum = worker.interrupted_signal or signal.SIGINT
                worker.receipt.update(lastKnownStatus=worker.receipt["status"], status="Interrupted",
                                      interruptedSignal=signal.Signals(signum).name,
                                      interruptedDuring=worker.phase)
                result = 128 + signum
            summary = worker.last_stderr.strip()[-2000:]
            if summary and summary not in detail:
                detail += "; stderr: " + summary
            worker.receipt["error"] = detail
            try:
                worker.save_receipt()
            except OSError as receipt_error:
                print("Could not save final receipt: " + str(receipt_error), file=sys.stderr)
        print("Notarization failed: %s\nReceipts: %s" % (detail, args.receipt_dir),
              file=sys.stderr)
        if (worker is not None and worker.receipt["uploadComplete"] and
                worker.receipt.get("lastKnownStatus", worker.receipt["status"]) not in
                ("Accepted", "Invalid", "Rejected")):
            print("Resume with --submission-id " + worker.receipt["submissionId"] +
                  " using a new --receipt-dir.", file=sys.stderr)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if result:
        return result
    print("Notarization Accepted; receipts: " + str(args.receipt_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
