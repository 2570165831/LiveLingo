#!/usr/bin/env python3
"""Read-only preview receipt: metadata, sizes, architectures and Mach-O signing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess


def signature_commands(path):
    """Detect LC_CODE_SIGNATURE in every slice without executing the binary."""
    with path.open('rb') as stream:
        magic = stream.read(4)
        if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            count = struct.unpack('>I', stream.read(4))[0]
            offsets = []
            for _ in range(count):
                if magic == b'\xca\xfe\xba\xbe':
                    entry = struct.unpack('>5I', stream.read(20))
                else:
                    entry = struct.unpack('>IIQQII', stream.read(32))
                offsets.append(entry[2])
        elif magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce'):
            offsets = [0]
        else:
            return None
        signed = 0
        for offset in offsets:
            stream.seek(offset)
            magic = stream.read(4)
            endian = '<' if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe') else '>'
            header = struct.unpack(endian + '6I', stream.read(24))
            if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'):
                stream.read(4)
            for _ in range(header[3]):
                command, size = struct.unpack(endian + 'II', stream.read(8))
                if size < 8:
                    raise ValueError('Invalid Mach-O load command')
                signed += command == 0x1D
                stream.seek(size - 8, 1)
        return signed


def inspect(app, unsigned=False):
    app = app.resolve(strict=True)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'com.jianhongli.LiveLingo.preview':
        raise ValueError('Not a preview bundle')
    if info.get('CFBundleDisplayName') != 'LiveLingo 预览版':
        raise ValueError('Preview display name is missing')
    if info['LiveLingoPreviewCommit'][:8] not in info['CFBundleVersion']:
        raise ValueError('Build number does not contain the source commit')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    logical_bytes = allocated_bytes = 0
    binaries = {}
    links = {}
    for directory, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path.is_symlink():
                links[str(path.relative_to(app))] = os.readlink(path)
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            stat = path.stat()
            logical_bytes += stat.st_size
            allocated_bytes += stat.st_blocks * 512
            commands = signature_commands(path)
            if commands is not None:
                binaries[str(path.relative_to(app))] = commands
    if not binaries or str(executable.relative_to(app)) not in binaries:
        raise ValueError('Missing Mach-O executable')
    if unsigned and (any(binaries.values()) or (app / 'Contents/_CodeSignature').exists()):
        raise ValueError('Unexpected signature, including linker ad-hoc signing')
    resources = app / 'Contents/Resources'
    if (resources / 'Models').exists() and not (resources / 'Models').is_symlink():
        raise ValueError('Unexpected copied models')
    if any((resources / name).exists() for name in ('LanguageRuntime', 'ASRRuntime')):
        raise ValueError('UI preview must not contain ML runtimes')
    return {
        'app': str(app),
        'info': {key: info.get(key) for key in (
            'CFBundleIdentifier', 'CFBundleDisplayName', 'CFBundleName', 'CFBundleExecutable',
            'CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion',
            'LiveLingoPreviewCommit', 'LiveLingoPreviewDirty', 'LiveLingoPreviewMode')},
        'architectures': subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).strip().split(),
        'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'logical_file_bytes_excluding_model_reference': logical_bytes,
        'allocated_file_bytes_excluding_model_reference': allocated_bytes,
        'code_signature_commands': binaries,
        'sandbox': 'not enforced without signed entitlements' if not any(binaries.values()) else 'signed; requires entitlement verification',
        'symlinks': links,
        'runtimes_bundled': False,
        'models_copied': False,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--unsigned', action='store_true')
    args = parser.parse_args()
    print(json.dumps(inspect(args.app, args.unsigned), ensure_ascii=False, indent=2))
