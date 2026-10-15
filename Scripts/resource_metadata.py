"""Static inspection of non-native distribution resources; never render or execute."""
from pathlib import Path
import mmap
import struct
import zlib

try:
    from .privacy_package import PrivacyError, validate_metadata
    from .macho_paths import scan_binary_paths_bytes
except ImportError:
    from privacy_package import PrivacyError, validate_metadata
    from macho_paths import scan_binary_paths_bytes

LIMIT = 64 * 1024 * 1024
TEXT_LIMIT = 1024 * 1024
PNG = b'\x89PNG\r\n\x1a\n'


def readable(data):
    if scan_binary_paths_bytes(data)['matches']:
        raise PrivacyError('local-path-binary-resource')


def inflate(data):
    try:
        decoder = zlib.decompressobj()
        value = decoder.decompress(data, TEXT_LIMIT + 1)
        if len(value) > TEXT_LIMIT or not decoder.eof or decoder.unused_data:
            raise PrivacyError('invalid-resource-compressed-metadata')
        return value
    except zlib.error:
        raise PrivacyError('invalid-resource-compressed-metadata') from None


def exif_metadata(data, counts):
    """Accept only numeric display/color fields, with every nonzero byte owned.

    Author, GPS, dates, serial numbers, maker notes, thumbnails and unknown
    tags remain rejected, including metadata hidden in unused TIFF space.
    """
    if len(data) < 8 or len(data) > TEXT_LIMIT or data[:4] not in (b'II*\0', b'MM\0*'):
        raise PrivacyError('invalid-resource-exif')
    order = '<' if data[:2] == b'II' else '>'
    used = bytearray(len(data))
    visited = set()
    def mark(offset, length):
        if offset < 0 or offset + length > len(data) or any(used[offset:offset + length]):
            raise PrivacyError('invalid-resource-exif')
        used[offset:offset + length] = b'\1' * length
    def u32(offset):
        if offset < 0 or offset + 4 > len(data):
            raise PrivacyError('invalid-resource-exif')
        return struct.unpack_from(order + 'I', data, offset)[0]
    def ifd(offset):
        if offset in visited or len(visited) >= 16 or offset + 2 > len(data):
            raise PrivacyError('invalid-resource-exif')
        visited.add(offset)
        number = struct.unpack_from(order + 'H', data, offset)[0]
        if number > 64:
            raise PrivacyError('invalid-resource-exif')
        mark(offset, 2 + 12 * number + 4)
        tags = set()
        for index in range(number):
            at = offset + 2 + 12 * index
            tag, kind, count = struct.unpack_from(order + 'HHI', data, at)
            if tag in tags:
                raise PrivacyError('invalid-resource-exif')
            tags.add(tag)
            if tag in (0x8769, 0xA005):
                if kind != 4 or count != 1:
                    raise PrivacyError('invalid-resource-exif')
                ifd(u32(at + 8))
            elif tag in (0x100, 0x101, 0x112, 0x128, 0xA001, 0xA002, 0xA003):
                if kind not in (3, 4) or count != 1 or (kind == 3 and any(data[at + 10:at + 12])):
                    raise PrivacyError('invalid-resource-exif')
            elif tag in (0x9000, 0xA000):
                if kind != 7 or count != 4 or not all(48 <= b <= 57 for b in data[at + 8:at + 12]):
                    raise PrivacyError('invalid-resource-exif')
            else:
                raise PrivacyError('unreviewed-resource-exif-tag')
            counts['resource_metadata_fields'] = counts.get('resource_metadata_fields', 0) + 1
        following = u32(offset + 2 + 12 * number)
        if following:
            ifd(following)
    mark(0, 8)
    ifd(u32(4))
    if any(byte for byte, claimed in zip(data, used) if not claimed):
        raise PrivacyError('unreviewed-resource-exif-padding')


def png_metadata(data, counts):
    """Check all PNG chunk CRCs, decode compressed text and reject unknown metadata."""
    if not data.startswith(PNG):
        raise PrivacyError('invalid-resource-png')
    offset, first, ended = len(PNG), True, False
    while offset < len(data):
        if len(data) - offset < 12:
            raise PrivacyError('invalid-resource-png')
        size, kind = struct.unpack_from('>I4s', data, offset)
        end = offset + 12 + size
        if end > len(data):
            raise PrivacyError('invalid-resource-png')
        body = data[offset + 8:end - 4]
        crc = int.from_bytes(data[end - 4:end], 'big')
        if zlib.crc32(kind + body) != crc or (first and (kind != b'IHDR' or size != 13)):
            raise PrivacyError('invalid-resource-png')
        first = False
        try:
            if kind in (b'tEXt', b'zTXt', b'iTXt'):
                key, payload = body.split(b'\0', 1)
                if not 1 <= len(key) <= 79:
                    raise ValueError()
                if kind == b'zTXt':
                    if payload[:1] != b'\0':
                        raise ValueError()
                    payload = inflate(payload[1:])
                elif kind == b'iTXt':
                    flag, method = payload[:2]
                    language, translated, payload = payload[2:].split(b'\0', 2)
                    if flag not in (0, 1) or method != 0:
                        raise ValueError()
                    validate_metadata(language.decode('ascii'))
                    validate_metadata(translated.decode('utf-8'))
                    if flag:
                        payload = inflate(payload)
                value = payload.decode('utf-8' if kind == b'iTXt' else 'latin-1')
                validate_metadata({key.decode('latin-1'): value})
                readable(payload)
                counts['resource_metadata_fields'] = counts.get('resource_metadata_fields', 0) + 1
            elif kind == b'eXIf':
                exif_metadata(body, counts)
            elif kind == b'iCCP':
                # Color profiles are necessary for faithful display. Inspect
                # their uncompressed strings without rewriting profile bytes.
                key, payload = body.split(b'\0', 1)
                if payload[:1] != b'\0':
                    raise ValueError()
                validate_metadata(key.decode('latin-1'))
                readable(inflate(payload[1:]))
            elif kind not in (b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'cHRM',
                              b'gAMA', b'sBIT', b'sRGB', b'bKGD', b'hIST', b'pHYs',
                              b'sPLT', b'acTL', b'fcTL', b'fdAT'):
                raise PrivacyError('unreviewed-resource-png-chunk')
        except PrivacyError:
            raise
        except (ValueError, UnicodeError):
            raise PrivacyError('invalid-resource-png-metadata') from None
        counts['png_chunks'] = counts.get('png_chunks', 0) + 1
        offset = end
        if kind == b'IEND':
            if size or offset != len(data):
                raise PrivacyError('invalid-resource-png')
            ended = True
            break
    if not ended:
        raise PrivacyError('invalid-resource-png')


def inspect_resource(path, counts):
    path = Path(path)
    if path.stat().st_size > LIMIT:
        if path.suffix.lower() != '.metallib' and path.name != 'Assets.car':
            raise PrivacyError('unreviewed-large-binary-resource')
        if path.stat().st_size > 1024 * 1024 * 1024:
            raise PrivacyError('unreviewed-large-binary-resource')
        # Compiled shader/catalog resources need no decompression. Scan the
        # complete mapping without copying the large object into Python RAM.
        with path.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            readable(data)
        counts['binary_resource_path_files'] = counts.get('binary_resource_path_files', 0) + 1
        return
    data = path.read_bytes()
    readable(data)
    if data.startswith(PNG):
        png_metadata(data, counts)
    elif data.startswith(b'icns'):
        offset = 8
        if int.from_bytes(data[4:8], 'big') != len(data):
            raise PrivacyError('invalid-resource-icns')
        while offset < len(data):
            if len(data) - offset < 8:
                raise PrivacyError('invalid-resource-icns')
            size = int.from_bytes(data[offset + 4:offset + 8], 'big')
            if size < 8 or offset + size > len(data):
                raise PrivacyError('invalid-resource-icns')
            payload = data[offset + 8:offset + size]
            if payload.startswith(PNG):
                png_metadata(payload, counts)
            counts['icns_chunks'] = counts.get('icns_chunks', 0) + 1
            offset += size
    elif data.startswith(b'!<arch>\n'):
        offset = 8
        while offset < len(data):
            header = data[offset:offset + 60]
            if len(header) != 60 or header[58:] != b'`\n':
                raise PrivacyError('invalid-resource-ar')
            try:
                size = int(header[48:58].strip())
                timestamp = int(header[16:28].strip() or b'0')
                owner = int(header[28:34].strip() or b'0')
                group = int(header[34:40].strip() or b'0')
            except ValueError:
                raise PrivacyError('invalid-resource-ar') from None
            if size < 0 or offset + 60 + size > len(data) or timestamp or owner or group:
                raise PrivacyError('nonpublic-resource-ar-header')
            offset += 60 + size
            if offset % 2:
                if data[offset:offset + 1] != b'\n':
                    raise PrivacyError('invalid-resource-ar')
                offset += 1
            counts['ar_member_headers'] = counts.get('ar_member_headers', 0) + 1
    # Compiled Metal, CAR, ar and legacy image data retain opaque sections.
    # Count the raw scan separately; it does not claim full format decoding.
    counts['binary_resource_path_files'] = counts.get('binary_resource_path_files', 0) + 1
