#!/usr/bin/env python3
"""Save tool output only after filtering environment diagnostics, without echoing it."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


ASSIGNMENT = re.compile(r'^\s*(?:(?:export|setenv)\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=')
ENVIRONMENT = re.compile(r'\b(?:environment(?:\s+variables)?|EnvironmentVariables|SetEnv)\b', re.I)


def filtered(lines):
    braces = 0
    environment_indent = None
    for line in lines:
        if braces:
            braces += line.count('{') - line.count('}')
            continue
        if environment_indent is not None:
            if not line.strip():
                environment_indent = None
                continue
            if len(line) - len(line.lstrip()) > environment_indent:
                continue
            environment_indent = None
        if ENVIRONMENT.search(line):
            braces = max(0, line.count('{') - line.count('}'))
            if not braces and line.rstrip().endswith(':'):
                environment_indent = len(line) - len(line.lstrip())
            if re.search(r'\bwarning:', line, re.I):
                yield 'warning: [environment diagnostic omitted]\n'
            continue
        if ASSIGNMENT.match(line):
            continue
        yield line


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', required=True, type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required')
    # Exclusive creation prevents truncating a previous diagnostic/evidence file.
    with args.log.open('x', encoding='utf-8') as log:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors='replace') as process:
            for line in filtered(process.stdout):
                log.write(line)
                log.flush()
            return process.wait()


if __name__ == '__main__':
    sys.exit(main())
