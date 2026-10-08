#!/usr/bin/env python3
"""Sign preview code from the inside out; ad-hoc is the identity-free default."""

import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


spec = importlib.util.spec_from_file_location('preview_metadata', Path(__file__).with_name('preview-app-metadata.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def code_targets(app, receipt):
    app = app.resolve(strict=True)
    for link in receipt['symlinks']:
        resolved = (app / link).resolve(strict=True)
        if not resolved.is_relative_to(app):
            raise ValueError('Signed preview links must stay inside the app')
    main = app / 'Contents/MacOS' / receipt['info']['CFBundleExecutable']
    targets = {app / name for name in receipt['code_signature_commands']}
    targets.discard(main)
    for directory, directories, _ in os.walk(app, followlinks=False):
        for name in directories:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            if path.suffix == '.framework' or (path.suffix in ('.app', '.xpc', '.appex', '.bundle')
                    and any(path in binary.parents for binary in targets)):
                targets.add(path)
    return sorted(targets, key=lambda p: (len(p.parts), p.is_file()), reverse=True) + [app]


def sign(app, entitlements, identity='-', keychain=None):
    if identity == '-' and keychain is not None:
        raise ValueError('Ad-hoc signing must not access a keychain')
    if identity != '-' and (not identity.startswith('Developer ID Application: ') or keychain is None):
        raise ValueError('Developer signing requires an explicit identity and keychain')
    with entitlements.open('rb') as stream:
        rights = plistlib.load(stream)
    if rights.get('com.apple.security.app-sandbox') is not True:
        raise ValueError('Signed previews require App Sandbox entitlements')
    if rights.get('com.apple.security.application-groups'):
        raise ValueError('Preview signing must not grant shared application groups')
    receipt = metadata.inspect(app, unsigned=True)
    app = app.resolve(strict=True)
    targets = code_targets(app, receipt)
    base = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none',
            '--options', 'runtime', '--generate-entitlement-der']
    if keychain is not None:
        base += ['--keychain', str(keychain)]
    with tempfile.TemporaryDirectory(prefix='preview-sign-', dir=app.parent) as temporary:
        inherited = Path(temporary) / 'inherit.entitlements'
        inherited.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
                                             'com.apple.security.inherit': True}))
        for target in targets:
            command = list(base)
            if target == app:
                command += ['--identifier', 'com.jianhongli.LiveLingo.preview',
                            '--entitlements', str(entitlements)]
            elif target.is_file() and 2 in metadata.macho_info(target)['file_types']:
                command += ['--entitlements', str(inherited)]
            subprocess.run(command + [str(target)], check=True)
        for target in targets:
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(target)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    metadata.inspect(app, adhoc=identity == '-')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--entitlements', required=True, type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--keychain', type=Path)
    args = parser.parse_args()
    sign(args.app, args.entitlements, args.identity, args.keychain)
