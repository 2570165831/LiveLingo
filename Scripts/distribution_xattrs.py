"""Inspect distribution-copy attributes without following links or invoking a UI."""
import argparse
from collections import Counter
import ctypes
import codecs
import json
import hashlib
import os
import re
import stat
from pathlib import Path
try:
    from .dmg_metadata import inspect as inspect_container
except ImportError:
    from dmg_metadata import inspect as inspect_container

TRACKING = frozenset({'com.apple.metadata:kMDItemWhereFroms',
                      'com.apple.metadata:kMDItemFinderComment', 'com.apple.lastuseddate#PS'})
# Empty records and the automatic-position sentinel emitted by makehybrid,
# with or without its symlink flag. No window geometry, timestamps or IDs.
PUBLIC_FINDER_INFO = frozenset(
    bytes(8) + flags + position + bytes(18)
    for flags in (bytes(2), b'\x80\x00')
    for position in (bytes(4), b'\xff' * 4))
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
    device = root.lstat().st_dev
    if root.is_dir():
        for directory, dirs, files in os.walk(root, followlinks=False):
            children = [Path(directory) / name for name in sorted(dirs + files)]
            if any(path.lstat().st_dev != device for path in children):
                raise ValueError('nested mount in distribution content')
            entries.extend(children)
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
            elif name == 'com.apple.FinderInfo' and data in PUBLIC_FINDER_INFO:
                pass
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
            'preserved': 'Exact empty/automatic-position FinderInfo records and bounded text-encoding labels only; quarantine is never stripped.'}


def inspect_mounted_image(image, mounted_root):
    """Gate image contents, while separately recording host-file attributes."""
    image, mounted_root = Path(image), Path(mounted_root)
    if (image.is_symlink() or image.resolve() != image or not image.is_file()
            or mounted_root.is_symlink() or mounted_root.resolve() != mounted_root
            or not mounted_root.is_dir() or not os.path.ismount(mounted_root)
            or not os.statvfs(mounted_root).f_flag & os.ST_RDONLY):
        raise ValueError('use an exact image and its read-only mounted root')
    contents = inspect(mounted_root)
    host = inspect(image)
    container = inspect_container(image)
    digest = hashlib.sha256()
    with os.fdopen(os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC), 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('image must be regular')
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
        after = os.fstat(stream.fileno())
    if any(getattr(before, name) != getattr(after, name)
           for name in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')):
        raise ValueError('image changed during metadata audit')
    return {'passed': contents['passed'], 'scope': 'actual-readonly-mounted-image-contents',
            'image': str(image), 'imageSHA256': digest.hexdigest(), 'imageBytes': before.st_size,
            'contents': contents, 'hostFile': host,
            'containerMetadata': container,
            'hostMetadataRequiresTransportReview': not host['passed'],
            'hostMetadataNote': 'Host-file attributes are outside the image data stream. '
                                'Their preservation depends on the later transfer; no external transfer is tested here.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--root', type=Path)
    target.add_argument('--image', type=Path, help='image already attached by the verifier')
    parser.add_argument('--mounted-root', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--strip-tracking', action='store_true',
                        help='only on a new distribution copy before final signing')
    args = parser.parse_args()
    if args.image:
        if args.mounted_root is None or args.strip_tracking:
            parser.error('image audit requires --mounted-root and never strips attributes')
        report = inspect_mounted_image(args.image, args.mounted_root)
    else:
        if args.mounted_root is not None:
            parser.error('--mounted-root requires --image')
        report = inspect(args.root, strip_tracking=args.strip_tracking)
    with args.report.open('x') as stream:
        json.dump(report, stream, indent=2); stream.write('\n')
    contents = report.get('contents', report)
    print(json.dumps({'passed': report['passed'], 'scope': report.get('scope', 'selected-tree'),
                      'entries': contents['entries'], 'attributes': contents['attributes'],
                      'removedTracking': contents['removedTracking'], 'rejected': len(contents['rejected']),
                      'hostMetadataRequiresTransportReview': report.get('hostMetadataRequiresTransportReview', False)}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
