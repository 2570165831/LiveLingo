"""Check UDIF container metadata without mounting or executing image content."""
import hashlib
from pathlib import Path
import struct

try:
    from .privacy_package import PrivacyError, metadata_kind, parse_metadata, validate_metadata
    from .resource_metadata import readable
except ImportError:
    from privacy_package import PrivacyError, metadata_kind, parse_metadata, validate_metadata
    from resource_metadata import readable

# Public fixed plst resource in libdmg-hfsplus/dmg/resources.c (plstData).
# This exact field/value exemption does not approve arbitrary binary payloads.
PUBLIC_PLST = bytes(517) + b'\x01\x00\x01' + bytes(512)
REFERENCE = 'https://github.com/planetbeing/libdmg-hfsplus/blob/master/dmg/resources.c'


def block_map_runs(data, data_fork_bytes, image_sectors):
    """Validate the supported fixed-width numeric mish header and run table.

    Integer offsets and CRC words may spell short path-like byte sequences.
    They are not text. Unknown records, padding, gaps and out-of-image ranges
    remain rejected; mounted files and image checksums are checked separately.
    """
    if len(data) < 204 or data[:4] != b'mish':
        raise PrivacyError('unreviewed-udif-block-map')
    version, first_sector, sectors, base, buffers, _descriptor = struct.unpack_from('>IQQQII', data, 4)
    count = struct.unpack_from('>I', data, 200)[0]
    checksum_type, checksum_bits = struct.unpack_from('>II', data, 64)
    if (version != 1 or len(data) != 204 + count * 40 or any(data[40:64])
            or first_sector > image_sectors or sectors > image_sectors - first_sector
            or base > data_fork_bytes or buffers > 1024 * 1024):
        raise PrivacyError('unreviewed-udif-block-map')
    if (checksum_type, checksum_bits) == (0, 0):
        padding = data[72:200]
    elif (checksum_type, checksum_bits) == (2, 32):
        padding = data[76:200]
    else:
        raise PrivacyError('unreviewed-udif-block-map-checksum')
    if any(padding):
        raise PrivacyError('unreviewed-udif-block-map-checksum')
    cursor = 0
    for index in range(count):
        kind, reserved, start, length, offset, size = struct.unpack_from('>IIQQQQ', data, 204 + index * 40)
        if (reserved or start != cursor or length > sectors - cursor
                or offset > data_fork_bytes - base or size > data_fork_bytes - base - offset):
            raise PrivacyError('unreviewed-udif-block-map-range')
        if kind == 0xffffffff:
            if index != count - 1 or length or size or cursor != sectors:
                raise PrivacyError('unreviewed-udif-block-map-terminator')
        elif kind in (1, 2, 0x80000005):
            if (not length or index == count - 1 or (kind == 1 and size != length * 512)
                    or (kind == 2 and size) or (kind == 0x80000005 and not size)):
                raise PrivacyError('unreviewed-udif-block-map-run')
            cursor += length
        else:
            raise PrivacyError('unreviewed-udif-block-map-run')
    if cursor != sectors:
        raise PrivacyError('unreviewed-udif-block-map-coverage')
    return count


def inspect(image):
    image = Path(image)
    size = image.stat().st_size
    with image.open('rb') as stream:
        if size < 512:
            raise PrivacyError('invalid-udif-container')
        stream.seek(-512, 2)
        footer = stream.read(512)
        if footer[:4] != b'koly' or struct.unpack_from('>II', footer, 4) != (4, 512):
            raise PrivacyError('unsupported-udif-footer')
        offset, length = struct.unpack_from('>QQ', footer, 216)
        data_offset, data_length = struct.unpack_from('>QQ', footer, 24)
        image_sectors = struct.unpack_from('>Q', footer, 492)[0]
        if not 0 < length <= 64 * 1024 * 1024 or offset + length > size - 512:
            raise PrivacyError('invalid-udif-metadata-range')
        if data_offset > offset or data_length > offset - data_offset:
            raise PrivacyError('invalid-udif-data-range')
        stream.seek(offset)
        raw = stream.read(length)
    readable(footer)
    root = parse_metadata(raw, 'plist')
    if not isinstance(root, dict):
        raise PrivacyError('invalid-udif-metadata-root')
    blobs = []; text_fields = 0

    def walk(item, trail=()):
        nonlocal text_fields
        if isinstance(item, dict):
            for key, value in item.items():
                validate_metadata({key: None})  # Apply sensitive field-name rules too.
                walk(key, trail + ('<key>',))
                walk(value, trail + (str(key),))
        elif isinstance(item, list):
            for index, value in enumerate(item):
                walk(value, trail + (str(index),))
        elif isinstance(item, bytes):
            if (len(trail) == 4 and trail[:2] == ('resource-fork', 'blkx')
                    and trail[2].isdigit() and trail[3] == 'Data'
                    and item.startswith(b'mish')):
                count = block_map_runs(item, data_length, image_sectors)
                blobs.append({'field': '/'.join(trail), 'bytes': len(item),
                              'sha256': hashlib.sha256(item).hexdigest(),
                              'kind': 'mish-block-map', 'runs': count,
                              'reservedHeaderBytesZero': True, 'numericRunRangesChecked': True})
                return
            readable(item)
            kind = metadata_kind(item)
            if kind:
                walk(parse_metadata(item, kind), trail + ('<embedded>',))
                return
            row = {'field': '/'.join(trail), 'bytes': len(item),
                   'sha256': hashlib.sha256(item).hexdigest()}
            if trail == ('resource-fork', 'plst', '0', 'Data') and item == PUBLIC_PLST:
                row['kind'] = 'exact-public-plst-constant'
            else:
                raise PrivacyError('unreviewed-udif-binary-metadata')
            blobs.append(row)
        else:
            validate_metadata(item)
            text_fields += isinstance(item, str)

    walk(root)
    return {'passed': True, 'footerVersion': 4, 'xmlBytes': length,
            'xmlSHA256': hashlib.sha256(raw).hexdigest(),
            'structuredTextFieldsChecked': text_fields, 'binaryResources': blobs,
            'publicConstantReference': REFERENCE,
            'scope': 'UDIF XML scalar/embedded metadata, exact public plst constant, '
                     'typed numeric block-map ranges/coverage/reserved bytes and readable paths '
                     'in other binary resources/footer. '
                     'Filesystem data and standard numeric/checksum fields remain necessary image data; '
                     'hdiutil verify and the mounted-content gate validate them separately.'}
