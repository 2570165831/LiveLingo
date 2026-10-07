#!/usr/bin/env python3
"""Submit once, then poll Apple's notarization service by submission ID.

Credentials stay in a local keychain profile. Never use notarytool --wait:
the 0.2.0 release saw exit 138 with --wait and a submission pending for nine
hours. Bound both individual commands and the complete submit/poll operation;
never automatically resubmit an upload with an uncertain outcome.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

PROFILE_PLACEHOLDER = "<你的 profile>"


class NotarizationError(Exception):
    pass


def positive_number(value):
    number = float(value)
    if not 0 < number < float("inf"):
        raise argparse.ArgumentTypeError("must be a finite positive number")
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
        self.deadline = time.monotonic() + args.timeout
        self.command_count = 0
        self.receipt = {"artifact": str(args.artifact.resolve()) if args.artifact else None,
                        "submissionId": None, "status": "Not submitted"}

    def save_receipt(self):
        (self.args.receipt_dir / "receipt.json").write_text(
            json.dumps(self.receipt, indent=2) + "\n", encoding="utf-8")

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise NotarizationError("notarization timed out (overall deadline)")
        return remaining

    def command(self, action, *arguments):
        timeout = min(self.args.command_timeout, self.remaining())
        command = ["xcrun", "notarytool", action, *map(str, arguments),
                   "--keychain-profile", self.args.profile]
        if self.args.keychain:
            command += ["--keychain", str(self.args.keychain)]
        if action != "log":
            command += ["--output-format", "json"]
        self.command_count += 1
        prefix = self.args.receipt_dir / ("%03d-%s" % (self.command_count, action))
        # A separate process group lets a timeout stop only this tool and its
        # children, including any child that still owns a captured output pipe.
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", errors="replace",
                                   start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            if isinstance(error, KeyboardInterrupt):
                prefix.with_suffix(".stdout.json").write_text(stdout, encoding="utf-8")
                prefix.with_suffix(".stderr.txt").write_text(stderr, encoding="utf-8")
                raise
            timed_out = True
        prefix.with_suffix(".stdout.json").write_text(stdout, encoding="utf-8")
        prefix.with_suffix(".stderr.txt").write_text(stderr, encoding="utf-8")
        return process.returncode, stdout, timed_out

    def pause(self):
        time.sleep(min(self.args.poll_interval, self.remaining()))

    def run(self):
        self.save_receipt()
        if self.args.submission_id:
            known_id = submission_id(self.args.submission_id)
        else:
            code, stdout, timed_out = self.command("submit", self.args.artifact)
            try:
                known_id = submission_id(json.loads(stdout).get("id"))
            except (ValueError, AttributeError, NotarizationError):
                self.receipt["status"] = "Submission outcome unknown"
                self.save_receipt()
                raise NotarizationError(
                    "submission outcome unknown (exit %s%s); NOT resubmitting. "
                    "Check notarytool history with the same keychain profile, then resume "
                    "with --submission-id. See saved submit output." %
                    (code, ", command timed out" if timed_out else ""))
            if code != 0 or timed_out:
                print("Submit returned an error, but an ID was recovered; polling only that ID.",
                      file=sys.stderr, flush=True)
        self.receipt.update(submissionId=known_id, status="Submitted")
        self.save_receipt()
        print("Submission ID: " + known_id, flush=True)
        consecutive_failures = 0
        for attempt in range(1, self.args.max_polls + 1):
            self.receipt["pollAttempts"] = attempt
            code, stdout, timed_out = self.command("info", known_id)
            try:
                if code != 0 or timed_out:
                    raise ValueError("info exit %s%s" %
                                     (code, ", command timed out" if timed_out else ""))
                response = json.loads(stdout)
                if not isinstance(response, dict) or not isinstance(response.get("status"), str):
                    raise ValueError("info did not return a JSON status")
            except ValueError as error:
                consecutive_failures += 1
                self.save_receipt()
                if consecutive_failures > self.args.max_retries:
                    raise NotarizationError("info retry limit exceeded: " + str(error))
                print("Retrying info (%s/%s): %s" %
                      (consecutive_failures, self.args.max_retries, error),
                      file=sys.stderr, flush=True)
            else:
                if submission_id(response.get("id")) != known_id:
                    raise NotarizationError("info returned a different submission ID")
                consecutive_failures = 0
                state = response["status"]
                self.receipt["status"] = state
                self.save_receipt()
                print("Poll %s/%s: %s" % (attempt, self.args.max_polls, state), flush=True)
                if state == "Accepted":
                    return
                if state in ("Invalid", "Rejected"):
                    try:
                        self.command("log", known_id)
                    except (OSError, NotarizationError) as error:
                        print("Could not fetch rejection log: " + str(error), file=sys.stderr)
                    raise NotarizationError("notarization " + state + "; inspect saved log")
                if state != "In Progress":
                    raise NotarizationError("unexpected notarization status: " + state)
            if attempt < self.args.max_polls:
                self.pause()
        raise NotarizationError("notarization poll limit reached")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--artifact", type=Path, help="signed App ZIP or signed DMG to submit once")
    parser.add_argument("--submission-id", help="resume polling an existing submission; do not upload")
    parser.add_argument("--profile", default=os.environ.get("LIVELINGO_NOTARY_PROFILE", PROFILE_PLACEHOLDER),
                        help="existing local keychain profile (or LIVELINGO_NOTARY_PROFILE)")
    parser.add_argument("--keychain", type=Path, help="keychain containing that profile")
    parser.add_argument("--receipt-dir", type=Path, required=True,
                        help="new private directory for submission ID and tool output; never put in DMG")
    parser.add_argument("--timeout", type=positive_number, default=3600,
                        help="overall submit/poll deadline in seconds (default: 3600)")
    parser.add_argument("--command-timeout", type=positive_number, default=600,
                        help="per-command deadline in seconds, capped by remaining time (default: 600)")
    parser.add_argument("--poll-interval", type=positive_number, default=30,
                        help="seconds between info attempts (default: 30)")
    parser.add_argument("--max-polls", type=positive_integer, default=120,
                        help="maximum info attempts, including failures (default: 120)")
    parser.add_argument("--max-retries", type=nonnegative_integer, default=3,
                        help="retries after consecutive info failures (default: 3; submit never retried)")
    args = parser.parse_args()
    if not args.profile.strip() or args.profile == PROFILE_PLACEHOLDER:
        parser.error("specify an existing keychain profile; the documentation placeholder is not a profile")
    if args.submission_id:
        try:
            submission_id(args.submission_id)
        except NotarizationError as error:
            parser.error(str(error))
    elif not args.artifact or not args.artifact.is_file():
        parser.error("--artifact must be an existing file unless --submission-id is supplied")
    try:
        # Refuse existing directories, including dangling symlinks. Each run's
        # outputs belong to this run and are outside the distributable payload.
        args.receipt_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError as error:
        parser.error("cannot create new receipt directory: " + str(error))
    worker = Notarizer(args)
    try:
        worker.run()
    except (NotarizationError, OSError, KeyboardInterrupt) as error:
        print("Notarization failed: %s\nReceipts: %s" % (error or "interrupted", args.receipt_dir),
              file=sys.stderr)
        if worker.receipt.get("submissionId"):
            print("Resume with --submission-id " + worker.receipt["submissionId"], file=sys.stderr)
        return 1
    print("Notarization Accepted; receipts: " + str(args.receipt_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
