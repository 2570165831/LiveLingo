"""Inspect distribution-copy attributes without following links or invoking a UI."""
import argparse
from collections import Counter
import ctypes
import codecs
import json
import os
import re
from pathlib import Path

TRACKING = frozenset({'com.apple.metadata:kMDItemWhereFroms',
                      'com.apple.metadata:kMDItemFinderComment', 'com.apple.lastuseddate#PS'})
# Quarantine is a security attribute, not a tracking field to silently remove.
LIB = ctypes.CDLL(None, use_errno=True)
LIB.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
LIB.listxattr.restype = ctypes.c_ssize_t
LIB.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
LIB.getxattr.restype = ctypes.c_ssize_t
LIB.removexattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
LIB.removexattr.restype = ctypes.c_int


def names(path):
    raw = os.fsencode(path)
    length = LIB.listxattr(raw, None, 0, 1)
    if length < 0:
        raise OSError(ctypes.get_errno(), 'attribute enumeration failed')
    if not length:
        return []
    buffer = ctypes.create_string_buffer(length)
    actual = LIB.listxattr(raw, buffer, length, 1)
    if actual < 0:
        raise OSError(ctypes.get_errno(), 'attribute enumeration changed')
    return [value.decode('utf-8', errors='strict') for value in buffer.raw[:actual].split(b'\0') if value]


def value(path, name):
    raw, key = os.fsencode(path), name.encode()
    size = LIB.getxattr(raw, key, None, 0, 0, 1)
    if size < 0 or size > 1024 * 1024:
        raise ValueError('unreadable or oversized attribute')
    buffer = ctypes.create_string_buffer(size)
    actual = LIB.getxattr(raw, key, buffer, size, 0, 1)
    if actual != size:
        raise ValueError('attribute changed while reading')
    return buffer.raw[:size]


def inspect(root, *, strip_tracking=False):
    root = Path(root)
    if root.is_symlink() or not root.exists() or root.resolve() != root:
        raise ValueError('use an exact real distribution-copy path')
    entries = [root]
    if root.is_dir():
        for directory, dirs, files in os.walk(root, followlinks=False):
            entries.extend(Path(directory) / name for name in sorted(dirs + files))
    found, removed, rejected = Counter(), Counter(), []
    for path in entries:
        for name in names(path):
            data = value(path, name)
            found[name] += 1
            if name in TRACKING and strip_tracking:
                if LIB.removexattr(os.fsencode(path), name.encode(), 1):
                    raise OSError(ctypes.get_errno(), 'tracking attribute removal failed')
                if name in names(path):
                    raise ValueError('tracking attribute removal not verified')
                removed[name] += 1
            elif name == 'com.apple.FinderInfo' and len(data) == 32:
                try:
                    from .resource_metadata import readable
                except ImportError:
                    from resource_metadata import readable
                readable(data)  # Needed Finder flags still cannot hide paths.
            elif name == 'com.apple.TextEncoding' and re.fullmatch(rb'[A-Za-z0-9._-]{1,32};[0-9]{1,12}', data):
                try:
                    codecs.lookup(data.split(b';')[0].decode('ascii'))
                except LookupError:
                    rejected.append({'file': '.' if path == root else path.relative_to(root).as_posix(),
                                     'attribute': name, 'bytes': len(data), 'reason': 'unknown-text-encoding'})
            else:
                rejected.append({'file': '.' if path == root else path.relative_to(root).as_posix(),
                                 'attribute': name, 'bytes': len(data),
                                 'reason': 'system-security-provenance-not-decoded' if name == 'com.apple.provenance'
                                           else 'unreviewed-attribute'})
    return {'entries': len(entries), 'attributes': dict(found), 'removedTracking': dict(removed),
            'rejected': rejected, 'passed': not rejected,
            'preserved': 'Finder display flags and bounded text-encoding labels only; quarantine is never stripped.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--strip-tracking', action='store_true',
                        help='only on a new distribution copy before final signing')
    args = parser.parse_args()
    report = inspect(args.root, strip_tracking=args.strip_tracking)
    with args.report.open('x') as stream:
        json.dump(report, stream, indent=2); stream.write('\n')
    print(json.dumps({'passed': report['passed'], 'entries': report['entries'],
                      'attributes': report['attributes'], 'removedTracking': report['removedTracking'],
                      'rejected': len(report['rejected'])}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
