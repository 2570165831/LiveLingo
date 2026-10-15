"""Clear exact generated Finder display fields in a new, unmounted HFS+ copy.

On-disk layout reference (schema facts, not implementation code):
https://github.com/apple-oss-distributions/hfs/blob/main/core/hfs_format.h
Only raw makehybrid images with a complete non-journaled catalog are supported.
File forks, permissions and symlink type/creator markers remain unchanged.
"""
import argparse
from collections import Counter
import hashlib
import json
import mmap
import os
from pathlib import Path
import stat
import struct
import subprocess


def plan(data):
    size = len(data)
    def read(offset, length):
        if offset < 0 or length < 0 or offset + length > size:
            raise ValueError('HFS image range outside file')
        return data[offset:offset + length]
    def u16(offset):
        return struct.unpack('>H', read(offset, 2))[0]
    def u32(offset):
        return struct.unpack('>I', read(offset, 4))[0]
    if read(0, 2) != b'ER' or u16(2) not in (512, 2048) or read(512, 2) != b'PM':
        raise ValueError('expected raw makehybrid partition map with 512-byte map entries')
    count = u32(516)
    if not 1 <= count <= 256:
        raise ValueError('invalid partition map count')
    volumes = []
    for index in range(1, count + 1):
        offset = index * 512
        if read(offset, 2) != b'PM' or u32(offset + 4) != count:
            raise ValueError('inconsistent partition map')
        start, length = u32(offset + 8) * 512, u32(offset + 12) * 512
        read(start, 0)
        if start + length > size:
            raise ValueError('partition outside image')
        if read(offset + 48, 32).split(b'\0')[0] == b'Apple_HFS':
            volumes.append((start, length))
    if len(volumes) != 1:
        raise ValueError('expected exactly one HFS+ partition')
    start, length = volumes[0]; header = start + 1024
    if read(header, 4) != b'H+\x00\x04' or u32(header + 12) or u32(header + 4) & 0x2000:
        raise ValueError('expected non-journaled HFS+ version 4')
    block = u32(header + 40)
    if block < 512 or block > 1024 * 1024 or block & (block - 1) or u32(header + 44) * block > length:
        raise ValueError('invalid HFS allocation geometry')
    fork = header + 272
    logical = struct.unpack('>Q', read(fork, 8))[0]
    if not 512 <= logical <= 256 * 1024 * 1024:
        raise ValueError('unsupported catalog size')
    extents = []; cursor = 0; empty = False
    for index in range(8):
        first, blocks = u32(fork + 16 + index * 8), u32(fork + 20 + index * 8)
        if not blocks:
            if first:
                raise ValueError('invalid empty catalog extent')
            empty = True; continue
        if empty or not first or (first + blocks) * block > length:
            raise ValueError('invalid or overflowed catalog extents')
        physical = start + first * block; capacity = blocks * block
        if any(physical < prior + span and prior < physical + capacity for _, prior, span in extents):
            raise ValueError('overlapping catalog extents')
        extents.append((cursor, physical, capacity)); cursor += capacity
    if cursor != u32(fork + 12) * block or logical > cursor:
        raise ValueError('catalog overflow extents are not supported')
    def spans(offset, length):
        if offset < 0 or offset + length > logical:
            raise ValueError('catalog range outside logical fork')
        result = []
        for beginning, physical, capacity in extents:
            left = max(offset, beginning); right = min(offset + length, beginning + capacity)
            if left < right:
                result.append((physical + left - beginning, left - offset, right - left))
        if sum(row[2] for row in result) != length:
            raise ValueError('incomplete catalog mapping')
        return result
    def catalog(offset, length):
        return b''.join(read(physical, count) for physical, _, count in spans(offset, length))
    head = catalog(0, 128)
    if head[8:10] != b'\x01\x00':
        raise ValueError('invalid catalog header node')
    leaf_records, first_leaf, last_leaf = struct.unpack_from('>III', head, 20)
    node_size = struct.unpack_from('>H', head, 32)[0]
    nodes = struct.unpack_from('>I', head, 36)[0]
    if (not 512 <= node_size <= 32768 or node_size & (node_size - 1)
            or not nodes or nodes * node_size > logical):
        raise ValueError('invalid catalog B-tree geometry')
    public = {bytes(8) + flags + position + bytes(18)
              for flags in (bytes(2), b'\x80\x00') for position in (bytes(4), b'\xff' * 4)}
    patches = []; kinds = Counter(); visited = set(); previous = 0; current = first_leaf
    while current:
        if current in visited or current >= nodes:
            raise ValueError('cyclic or invalid catalog leaf chain')
        visited.add(current); node = catalog(current * node_size, node_size)
        forward, backward, kind, height, records, reserved = struct.unpack_from('>IIbBHH', node)
        if backward != previous or kind != -1 or height != 1 or reserved or not records:
            raise ValueError('invalid catalog leaf descriptor')
        table = node_size - 2 * (records + 1)
        if table < 14:
            raise ValueError('oversized catalog offset table')
        offsets = [struct.unpack_from('>H', node, node_size - 2 * (index + 1))[0]
                   for index in range(records + 1)]
        if offsets[0] < 14 or offsets[-1] > table or any(a >= b for a, b in zip(offsets, offsets[1:])):
            raise ValueError('invalid catalog record ranges')
        for begin, end in zip(offsets, offsets[1:]):
            key_length = struct.unpack_from('>H', node, begin)[0]
            if key_length < 6 or key_length > 516 or key_length & 1 or begin + 2 + key_length + 2 > end:
                raise ValueError('invalid catalog key')
            name_length = struct.unpack_from('>H', node, begin + 6)[0]
            if key_length != 6 + 2 * name_length:
                raise ValueError('invalid catalog name length')
            node[begin + 8:begin + 8 + 2 * name_length].decode('utf-16-be', errors='strict')
            record = begin + 2 + key_length
            record_kind = struct.unpack_from('>H', node, record)[0]; kinds[record_kind] += 1
            if record_kind in (3, 4):
                continue
            expected = {1: 88, 2: 248}.get(record_kind)
            if expected is None or end - record != expected:
                raise ValueError('unknown or malformed catalog data record')
            mode = struct.unpack_from('>H', node, record + 42)[0]
            link = stat.S_ISLNK(mode)
            if (record_kind == 1 and not stat.S_ISDIR(mode)) or (record_kind == 2 and not (link or stat.S_ISREG(mode))):
                raise ValueError('unsupported HFS file type')
            before = node[record + 48:record + 80]
            normalized = bytes(8) + before[8:] if link and before[:8] == b'slnkrhap' else before
            if normalized not in public or link and before[:8] != b'slnkrhap':
                raise ValueError('unreviewed Finder metadata; not cleared')
            after = before[:8] + bytes(24) if link else bytes(32)
            relative = current * node_size + record + 48
            for physical, within, count in spans(relative, 32):
                patches.append((physical, before[within:within + count], after[within:within + count]))
        previous, current = current, forward
    if (previous != last_leaf or sum(kinds.values()) != leaf_records
            or kinds[2] != u32(header + 32) or kinds[1] != u32(header + 36) + 1):
        raise ValueError('catalog record counts do not match headers')
    patches.sort()
    if any(a[0] + len(a[1]) > b[0] for a, b in zip(patches, patches[1:])):
        raise ValueError('overlapping metadata patches')
    return patches, {'catalogDataRecords': kinds[1] + kinds[2], 'catalogLeafNodes': len(visited),
                     'catalogRecords': leaf_records, 'allocationBlockBytes': block,
                     'symlinkMarkersPreserved': True}


def clean(source, destination, report):
    source, destination, report = map(Path, (source, destination, report))
    for path in (source, destination, report):
        if not path.is_absolute() or path.resolve() != path or path.is_symlink():
            raise ValueError('use exact absolute paths without symlink ancestors')
    if not source.is_file() or destination.exists() or report.exists():
        raise ValueError('require source file and new output/report paths')
    if source.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError('APFS clone source and destination must be on the same volume')
    original_stat = source.stat()
    holders = subprocess.run(['/usr/sbin/lsof', '-t', str(source)], capture_output=True, text=True)
    if holders.returncode not in (0, 1) or holders.stdout.strip() or holders.stderr.strip():
        raise ValueError('source image is active or cannot be inspected')
    with source.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        patches, details = plan(data)
    subprocess.run(['/bin/cp', '-c', str(source), str(destination)], check=True)
    with destination.open('r+b') as stream:
        for offset, before, after in patches:
            stream.seek(offset)
            if stream.read(len(before)) != before:
                raise ValueError('cloned metadata changed before edit')
            stream.seek(offset); stream.write(after)
        stream.flush(); os.fsync(stream.fileno())
    original_sha, clean_sha = hashlib.sha256(), hashlib.sha256(); position = 0
    with source.open('rb') as original, destination.open('rb') as changed:
        while True:
            left = original.read(8 * 1024 * 1024); right = changed.read(8 * 1024 * 1024)
            if not left and not right:
                break
            expected = bytearray(left)
            for offset, before, after in patches:
                start = max(offset, position); end = min(offset + len(after), position + len(left))
                if start < end:
                    expected[start - position:end - position] = after[start - offset:end - offset]
            if right != expected:
                raise ValueError('non-metadata image bytes changed')
            original_sha.update(left); clean_sha.update(right); position += len(left)
    final_stat = source.stat()
    if any(getattr(original_stat, name) != getattr(final_stat, name)
           for name in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')):
        raise ValueError('source image changed during metadata preparation')
    result = {'passed': True, **details, 'source': str(source), 'output': str(destination),
              'sourceSHA256': original_sha.hexdigest(), 'outputSHA256': clean_sha.hexdigest(),
              'bytes': position, 'changedByteRanges': len(patches), 'onlyKnownFinderFieldsChanged': True,
              'layoutReference': 'https://github.com/apple-oss-distributions/hfs/blob/main/core/hfs_format.h'}
    with report.open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'output', 'report'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(clean(args.source, args.output, args.report)))
