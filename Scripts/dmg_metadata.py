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
        if not 0 < length <= 64 * 1024 * 1024 or offset + length > size - 512:
            raise PrivacyError('invalid-udif-metadata-range')
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
            readable(item)
            kind = metadata_kind(item)
            if kind:
                walk(parse_metadata(item, kind), trail + ('<embedded>',))
                return
            row = {'field': '/'.join(trail), 'bytes': len(item),
                   'sha256': hashlib.sha256(item).hexdigest()}
            if trail == ('resource-fork', 'plst', '0', 'Data') and item == PUBLIC_PLST:
                row['kind'] = 'exact-public-plst-constant'
            elif (len(trail) == 4 and trail[:2] == ('resource-fork', 'blkx')
                  and trail[2].isdigit() and trail[3] == 'Data'
                  and item.startswith(b'mish') and len(item) >= 204):
                count = struct.unpack_from('>I', item, 200)[0]
                if len(item) != 204 + count * 40 or any(item[40:64]):
                    raise PrivacyError('unreviewed-udif-block-map')
                row.update(kind='mish-block-map', runs=count, reservedHeaderBytesZero=True)
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
                     'block-map sizes/reserved bytes and readable paths in binary resources/footer. '
                     'Filesystem data and standard numeric/checksum fields remain necessary image data; '
                     'hdiutil verify and the mounted-content gate validate them separately.'}
