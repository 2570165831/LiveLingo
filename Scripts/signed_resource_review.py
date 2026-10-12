"""Static signed-stage approval, anchored to the unchanged preparation index.

No subprocesses, signature creation, native loading or publisher-trust claim.
Final exclusion accepts only an end-of-file LC_CODE_SIGNATURE SuperBlob with
validated CodeDirectory page hashes. Original signatures are captured as exact,
untrusted source bytes, bound by the preparation full-file hash. Every other
byte (including LINKEDIT data) stays in the comparison. The final reader
reconstructs the original approved file;
editing an unsigned receipt cannot authorize new code by inventing new hashes.
"""
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import struct

if __package__:
    from .privacy_package import PrivacyError, JSON_LIMIT, parse_metadata
    from . import macho_paths
    from .private_files import open_directory
else:
    from privacy_package import PrivacyError, JSON_LIMIT, parse_metadata
    import macho_paths
    from private_files import open_directory

RECEIPT_PATH = "Contents/Resources/LanguageRuntime/signed-resource-review.json"
FORMAT = "macho-public-build-strings"
POLICY = "exact-nonsignature-reconstruction-v1"
SIGNATURE = 0x1D
SEGMENTS = {1: (32, 36, 48, 56, 68), 0x19: (40, 48, 64, 72, 80)}


def reject(code="invalid-signed-resource"):
    raise PrivacyError(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def document_hash(value):
    return digest(json.dumps(value, sort_keys=True, separators=(",", ":"),
                             ensure_ascii=True).encode())


def _range(data, offset, size):
    if (not isinstance(offset, int) or not isinstance(size, int)
            or offset < 0 or size < 0 or offset + size > len(data)):
        reject("invalid-signed-resource-range")
    return data[offset:offset + size]


def _u32(data, offset, endian=">"):
    return struct.unpack(endian + "I", _range(data, offset, 4))[0]


def _code_directory(blob, image, signature_offset, *, verify_pages=True):
    """Validate contiguous page coverage; scatter/unknown versions fail closed."""
    if len(blob) < 44:
        reject("invalid-signed-code-directory")
    version = _u32(blob, 8)
    minimums = {0x20001: 44, 0x20100: 48, 0x20200: 52, 0x20300: 64,
                0x20400: 88, 0x20500: 96, 0x20600: 108}
    if version not in minimums or len(blob) < minimums[version]:
        reject("unsupported-signed-code-directory")
    hash_offset, ident, special, slots, limit = struct.unpack_from(
        ">5I", blob, 16)
    hash_size, hash_type, platform, power = blob[36:40]
    algorithms = {1: ("sha1", 20), 2: ("sha256", 32),
                  3: ("sha256", 20), 4: ("sha384", 48)}
    if (hash_type not in algorithms or algorithms[hash_type][1] != hash_size
            or platform not in (0, 1) or not 0 <= power <= 16 or special > 32
            or _u32(blob, 40) != 0):
        reject("invalid-signed-code-directory")
    if version >= 0x20100 and _u32(blob, 44) != 0:
        reject("unsupported-signed-scatter")
    if version >= 0x20300:
        if _u32(blob, 52) != 0:
            reject("invalid-signed-code-directory")
        limit64 = struct.unpack_from(">Q", blob, 56)[0]
        if limit64:
            if limit != 0xFFFFFFFF:
                reject("invalid-signed-code-directory")
            limit = limit64
    # offset 88 is the packed runtime version, not preEncryptOffset.
    if version >= 0x20500 and _u32(blob, 92):
        reject("unsupported-signed-preencrypt")
    if version >= 0x20600 and any(blob[96:108]):
        reject("unsupported-signed-linkage")
    page = (1 << power) if power else limit
    if (limit != signature_offset or not page or slots != math.ceil(limit / page)
            or hash_offset - special * hash_size < minimums[version]
            or hash_offset + slots * hash_size != len(blob)):
        reject("invalid-signed-page-coverage")
    strings_end = hash_offset - special * hash_size
    for start in (ident, _u32(blob, 48) if version >= 0x20200 else 0):
        if start == 0:
            if start == ident:
                reject("invalid-signed-code-directory")
            continue
        if not minimums[version] <= start < strings_end:
            reject("invalid-signed-code-directory")
        end = blob.find(b"\0", start, strings_end)
        if end == -1 or not blob[start:end] or any(c < 32 or c > 126 for c in blob[start:end]):
            reject("invalid-signed-code-directory")
    algorithm = algorithms[hash_type][0]
    for index in range(slots):
        expected = hashlib.new(algorithm, image[index * page:min(limit, (index + 1) * page)]).digest()[:hash_size]
        if verify_pages and blob[hash_offset + index * hash_size:hash_offset + (index + 1) * hash_size] != expected:
            reject("signed-code-page-hash-mismatch")
    return {"algorithm": algorithm, "pages": slots, "codeLimit": limit}


def _signature(image, offset, size, *, source=False):
    blob = _range(image, offset, size)
    if size < 20 or _u32(blob, 0) != 0xFADE0CC0:
        reject("invalid-signed-superblob")
    length, count = struct.unpack_from(">II", blob, 4)
    if (not 1 <= count <= 32 or not 12 + count * 8 <= length <= size
            or (not source and any(blob[length:]))):
        reject("invalid-signed-superblob")
    slots, spans, directories = {}, [], []
    # Every slot has an exact expected magic. Unknown slots are not opaque gaps.
    magics = {0: 0xFADE0C02, 2: 0xFADE0C01, 5: 0xFADE7171,
              7: 0xFADE7172, 0x10000: 0xFADE0B01}
    for index in range(count):
        slot, start = struct.unpack_from(">II", blob, 12 + index * 8)
        expected = 0xFADE0C02 if 0x1000 <= slot <= 0x1005 else magics.get(slot)
        if expected is None or slot in slots or start < 12 + count * 8 or start + 8 > length:
            reject("invalid-signed-superblob-slot")
        magic, width = struct.unpack_from(">II", blob, start)
        if magic != expected or width < 8 or start + width > length:
            reject("invalid-signed-superblob-slot")
        if any(start < end and begin < start + width for begin, end in spans):
            reject("overlapping-signed-superblob-slots")
        spans.append((start, start + width))
        child = blob[start:start + width]
        slots[slot] = child
        if expected == 0xFADE0C02:
            directories.append(_code_directory(child, image, offset, verify_pages=not source))
    if 0 not in slots:
        reject("missing-signed-code-directory")
    end = 12 + count * 8
    for begin, finish in sorted(spans):
        if any(blob[end:begin]):
            reject("nonzero-signed-superblob-gap")
        end = finish
    if any(blob[end:length]):
        reject("nonzero-signed-superblob-gap")
    # Auxiliary slots must be hashed by each CodeDirectory if present.
    for slot, child in slots.items():
        if slot not in (2, 5, 7):
            continue
        for cd_slot, directory in slots.items():
            if cd_slot != 0 and not 0x1000 <= cd_slot <= 0x1005:
                continue
            hash_offset, special = _u32(directory, 16), _u32(directory, 24)
            hash_size, hash_type = directory[36:38]
            if special < slot:
                reject("unbound-signed-special-slot")
            algorithm = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}[hash_type]
            expected = hashlib.new(algorithm, child).digest()[:hash_size]
            if directory[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size] != expected:
                reject("signed-special-slot-hash-mismatch")
    return directories


def _thin(image, *, require_signed=False):
    if image[:4] not in macho_paths.THIN:
        reject("invalid-signed-macho")
    endian, header = macho_paths.THIN[image[:4]]
    _range(image, 0, header)
    count, size = struct.unpack_from(endian + "II", image, 16)
    end = header + size
    if size > 16 * 1024 * 1024 or count > size // 8:
        reject("invalid-signed-load-commands")
    _range(image, header, size)
    signature, linkedit, ranges, referenced = None, None, [], []
    position = header
    for _ in range(count):
        command, width = struct.unpack(endian + "II", _range(image, position, 8))
        if width < 8 or width % (8 if header == 32 else 4) or position + width > end:
            reject("invalid-signed-load-commands")
        body = _range(image, position, width)
        if command == SIGNATURE:
            if signature is not None or width != 16 or position + width != end:
                reject("invalid-signed-signature-command")
            signature = (position, *_range_signature_fields(body, endian))
        def reference(offset, length):
            if length:
                _range(image, offset, length)
                referenced.append((offset, offset + length))
        if command in (0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034):
            if width != 16:
                reject("invalid-signed-linkedit-command")
            reference(*struct.unpack_from(endian + "II", body, 8))
        elif command == 2:  # LC_SYMTAB
            if width != 24:
                reject("invalid-signed-linkedit-command")
            symoff, nsyms, stroff, strsize = struct.unpack_from(endian + "4I", body, 8)
            reference(symoff, nsyms * (16 if header == 32 else 12))
            reference(stroff, strsize)
        elif command in (0x22, 0x80000022):  # LC_DYLD_INFO[_ONLY]
            if width != 48:
                reject("invalid-signed-linkedit-command")
            for field in range(8, 48, 8):
                reference(*struct.unpack_from(endian + "II", body, field))
        elif command == 0xB:  # LC_DYSYMTAB
            if width != 80:
                reject("invalid-signed-linkedit-command")
            for field, unit in zip(range(32, 80, 8), (8, 56 if header == 32 else 52, 4, 4, 8, 8)):
                offset, entries = struct.unpack_from(endian + "II", body, field)
                reference(offset, entries * unit)
        elif command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO[_64]
            if width != (24 if command == 0x2C else 20):
                reject("invalid-signed-encryption-command")
            reference(*struct.unpack_from(endian + "II", body, 8))
        if command in SEGMENTS:
            off_at, size_at, nsects_at, fixed, section = SEGMENTS[command]
            number = "Q" if command == 0x19 else "I"
            if width < fixed:
                reject("invalid-signed-segment")
            fileoff = struct.unpack_from(endian + number, body, off_at)[0]
            filesize = struct.unpack_from(endian + number, body, size_at)[0]
            vm_at = 32 if command == 0x19 else 28
            vmsize = struct.unpack_from(endian + number, body, vm_at)[0]
            nsects = _u32(body, nsects_at, endian)
            if width != fixed + nsects * section:
                reject("invalid-signed-segment")
            _range(image, fileoff, filesize)
            name = body[8:24].split(b"\0", 1)[0]
            if name == b"__LINKEDIT":
                if linkedit is not None or nsects or fileoff < end or fileoff + filesize != len(image):
                    reject("invalid-signed-linkedit-boundary")
                linkedit = {"commandOffset": position, "fileoff": fileoff,
                            "filesize": filesize, "vmsize": vmsize,
                            "sizeAt": position + size_at, "vmAt": position + vm_at,
                            "number": number, "endian": endian}
            elif filesize:
                ranges.append((fileoff, fileoff + filesize))
            for index in range(nsects):
                entry = body[fixed + index * section:fixed + (index + 1) * section]
                section_size = struct.unpack_from(endian + number, entry, 40 if command == 0x19 else 36)[0]
                section_off = _u32(entry, 48 if command == 0x19 else 40, endian)
                flags = _u32(entry, 64 if command == 0x19 else 56, endian)
                if flags & 0xFF not in (1, 0xC, 0x12):  # zerofill has no file bytes
                    if section_size and not fileoff <= section_off <= section_off + section_size <= fileoff + filesize:
                        reject("invalid-signed-section")
                    if section_size:
                        ranges.append((section_off, section_off + section_size))
        position += width
    if position != end or linkedit is None:
        reject("invalid-signed-load-commands")
    prefix_size = len(image)
    pages = []
    if signature:
        _, offset, span = signature
        if offset % 16 or offset < end or offset < linkedit["fileoff"] or offset + span != len(image):
            reject("invalid-signed-signature-boundary")
        if any(finish > offset for _, finish in ranges + referenced):
            reject("signature-overlaps-signed-content")
        # Prepared binaries may carry stale vendor signatures after reviewed
        # privacy edits, including old reserved signature bytes. Source bytes
        # are authenticated by the fixed *full-file* approval and preserved
        # exactly in reconstruction. Final exclusion always requires valid
        # page hashes and zero reservation padding; no source trust is inferred.
        pages = _signature(image, offset, span, source=not require_signed)
        prefix_size = offset
    elif require_signed:
        reject("missing-signed-signature-command")
    # A signature can only occupy terminal LINKEDIT bytes, never another segment.
    if any(begin < len(image) and linkedit["fileoff"] < finish
           for begin, finish in ranges):
        reject("overlapping-signed-linkedit")
    if linkedit["vmsize"] < prefix_size - linkedit["fileoff"] or linkedit["vmsize"] % 4096:
        reject("invalid-signed-linkedit-vmsize")
    normalized = bytearray(image[:prefix_size])
    if signature:
        at = signature[0]
        normalized[at:at + 16] = b"\0" * 16
        struct.pack_into(endian + "II", normalized, 16, count - 1, size - 16)
    else:
        # A newly added signature command may use only existing zero header pad.
        if len(image) < end + 16 or any(image[end:end + 16]):
            reject("missing-zero-signature-header-pad")
    for at in (linkedit["sizeAt"], linkedit["vmAt"]):
        struct.pack_into(endian + linkedit["number"], normalized, at, 0)
    normalized += b"\0" * (-len(normalized) % 16)
    return {"normalized": bytes(normalized), "prefixSize": prefix_size,
            "headerEnd": end if signature else end + 16,
            "linkedit": linkedit, "signature": signature, "pages": pages,
            "architecture": list(struct.unpack_from(endian + "II", image, 4))}


def _range_signature_fields(body, endian):
    return struct.unpack_from(endian + "II", body, 8)


def _container(data, *, require_signed=False):
    data = bytes(data)
    if data[:4] in macho_paths.THIN:
        return {"header": b"", "slices": [(0, len(data), _thin(data, require_signed=require_signed))]}
    if data[:4] not in macho_paths.FAT:
        reject("invalid-signed-macho")
    endian, wide = macho_paths.FAT[data[:4]]
    count = _u32(data, 4, endian)
    width = 32 if wide else 20
    if not 1 <= count <= 64:
        reject("invalid-signed-fat")
    header_end = 8 + count * width
    header = _range(data, 0, header_end)
    slices, identities = [], set()
    for index in range(count):
        entry = _range(data, 8 + index * width, width)
        cpu = list(struct.unpack_from(endian + "II", entry))
        offset, span = struct.unpack_from(endian + ("QQ" if wide else "II"), entry, 8)
        alignment = _u32(entry, 24 if wide else 16, endian)
        if (alignment > 30 or offset % (1 << alignment) or offset < header_end
                or span < 28 or (wide and _u32(entry, 28, endian))
                or tuple(cpu) in identities):
            reject("invalid-signed-fat")
        info = _thin(_range(data, offset, span), require_signed=require_signed)
        if info["architecture"] != cpu or any(offset < at + size and at < offset + span for at, size, _ in slices):
            reject("invalid-signed-fat")
        identities.add(tuple(cpu))
        slices.append((offset, span, info))
    cursor = header_end
    for offset, span, _ in sorted(slices):
        if any(data[cursor:offset]):
            reject("nonzero-signed-fat-gap")
        cursor = offset + span
    if cursor != len(data):
        reject("unexpected-signed-fat-trailer")
    return {"header": header, "slices": slices}


def capture_source(data):
    """Minimal reversible representation of the excluded source fields only."""
    view = _container(data)
    slices = []
    for offset, span, info in view["slices"]:
        image = data[offset:offset + span]
        slices.append({"offset": offset, "size": span,
                       "prefixSize": info["prefixSize"],
                       "headerHex": image[:info["headerEnd"]].hex(),
                       "signatureHex": image[info["prefixSize"]:].hex()})
    return {"size": len(data), "fatHeaderHex": view["header"].hex(), "slices": slices}


def reconstruct_source(signed, source):
    """Recreate exact source, then let its fixed full-file SHA authenticate it."""
    view = _container(signed, require_signed=True)
    try:
        if (not isinstance(source, dict) or set(source) != {"size", "fatHeaderHex", "slices"}
                or not isinstance(source["slices"], list)):
            reject("invalid-signed-source-reconstruction")
        size = source["size"]
        slices = source["slices"]
        header = bytes.fromhex(source["fatHeaderHex"])
        if type(size) is not int or not 28 <= size <= len(signed) + JSON_LIMIT:
            reject()
        if len(slices) != len(view["slices"]) or bool(header) != bool(view["header"]):
            reject()
        output = bytearray(size)
        output[:len(header)] = header
        spans = []
        for entry, (_, _, info) in zip(slices, view["slices"]):
            if not isinstance(entry, dict) or set(entry) != {"offset", "size", "prefixSize", "headerHex", "signatureHex"}:
                reject("invalid-signed-source-reconstruction")
            offset, span, prefix = entry["offset"], entry["size"], entry["prefixSize"]
            saved_header = bytes.fromhex(entry["headerHex"])
            saved_signature = bytes.fromhex(entry["signatureHex"])
            if (not all(type(n) is int for n in (offset, span, prefix))
                    or offset < len(header) or span < 28 or offset + span > size
                    or prefix < len(saved_header) or prefix > len(info["normalized"])
                    or prefix + len(saved_signature) != span
                    or len(saved_header) > 16 * 1024 * 1024 + 48
                    or any(offset < end and begin < offset + span for begin, end in spans)):
                reject()
            image = bytearray(info["normalized"][:prefix])
            image[:len(saved_header)] = saved_header
            image += saved_signature
            output[offset:offset + span] = image
            spans.append((offset, offset + span))
        return bytes(output)
    except (KeyError, TypeError, ValueError, OverflowError):
        reject("invalid-signed-source-reconstruction")


def compare_signed(source, signed):
    before, after = _container(source), _container(signed, require_signed=True)
    if len(before["slices"]) != len(after["slices"]) or bool(before["header"]) != bool(after["header"]):
        reject("signed-resource-architecture-changed")
    if before["header"]:
        def stable_header(value):
            result = bytearray(value)
            endian, wide = macho_paths.FAT[value[:4]]
            count = _u32(value, 4, endian)
            width = 32 if wide else 20
            for index in range(count):
                start = 8 + index * width + 8
                result[start:start + (16 if wide else 8)] = b"\0" * (16 if wide else 8)
            return result
        if stable_header(before["header"]) != stable_header(after["header"]):
            reject("signed-resource-fat-header-changed")
    for (_, _, base), (_, _, final) in zip(before["slices"], after["slices"]):
        if base["architecture"] != final["architecture"] or base["normalized"] != final["normalized"]:
            reject("signed-resource-nonsignature-changed")
        old, new = base["linkedit"], final["linkedit"]
        permitted_vm = {old["vmsize"], *(math.ceil(new["filesize"] / page) * page for page in (4096, 16384))}
        if new["vmsize"] not in permitted_vm:
            reject("signed-resource-linkedit-vmsize-changed")
    return {"policy": POLICY, "architectures": [i[2]["architecture"] for i in after["slices"]],
            "nonSignatureSHA256": [digest(i[2]["normalized"]) for i in after["slices"]]}


def _read(root, relative, *, limit=None):
    parts = PurePosixPath(relative).parts
    if (not parts or PurePosixPath(relative).is_absolute() or any(p in (".", "..") for p in parts)
            or str(PurePosixPath(relative)) != relative or "\\" in relative):
        reject("invalid-signed-resource-path")
    try:
        with open_directory(Path(root).joinpath(*parts[:-1])) as directory:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                         dir_fd=directory.fd)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                if not stat.S_ISREG(before.st_mode) or (limit is not None and before.st_size > limit):
                    reject("invalid-signed-resource-file")
                data = stream.read() if limit is None else stream.read(limit + 1)
                after = os.fstat(stream.fileno())
                fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
                if len(data) != before.st_size or any(getattr(before, k) != getattr(after, k) for k in fields):
                    reject("signed-resource-changed-during-read")
            directory.require_bound()
            return data
    except (OSError, ValueError):
        reject("invalid-signed-resource-file")


def _repository():
    if __package__:
        from .reviewed_resources import entries, MANIFEST
    else:
        from reviewed_resources import entries, MANIFEST
    first = _read(MANIFEST.parent, MANIFEST.name, limit=JSON_LIMIT)
    approvals = entries()
    if first != _read(MANIFEST.parent, MANIFEST.name, limit=JSON_LIMIT):
        reject("preparation-index-changed")
    return approvals, digest(first)


def _allowed(item):
    try:
        return [bytes.fromhex(value) for value in item["publicBuildPathsHex"]]
    except (KeyError, ValueError, TypeError):
        reject("invalid-macho-build-path-approval")


def _inspect(app, relative, item, expected):
    # Strict whole-file/load-command scanner; it also checks signature strings.
    path = Path(app) / relative
    if not macho_paths.inspect_macho_paths(path, {}, allowed=_allowed(item)):
        reject("reviewed-resource-format-mismatch")
    if _read(app, relative) != expected:
        reject("signed-resource-changed-during-review")


def capture_before_signing(app_root):
    receipt = Path(app_root) / RECEIPT_PATH
    if receipt.exists() or receipt.is_symlink():
        reject("signed-review-already-exists-rebuild-prepared-copy")
    approvals, index_hash = _repository()
    captured = {}
    for relative, item in approvals.items():
        if item["format"] != FORMAT:
            continue
        data = _read(app_root, relative)
        if digest(data) != item["sha256"]:
            reject("reviewed-resource-hash-mismatch")
        _inspect(app_root, relative, item, data)
        captured[relative] = {"sourceSHA256": item["sha256"],
                              "sourceApprovalSHA256": document_hash(item),
                              "sourceLayout": capture_source(data)}
    return {"preparationIndexSHA256": index_hash, "resources": captured}


def write_capture_receipt(app_root, destination, captured):
    """Exclusive host receipt before signing; never write this capture into App."""
    destination = Path(destination)
    if (not destination.is_absolute() or ".." in destination.parts
            or destination.resolve().is_relative_to(Path(app_root).resolve())):
        reject("signed-review-capture-must-be-outside-app")
    data = (json.dumps({"schemaVersion": 1, "phase": "before-signing", **captured},
                       sort_keys=True, indent=2) + "\n").encode()
    if len(data) > JSON_LIMIT:
        reject("signed-review-receipt-too-large")
    with open_directory(destination.parent) as directory:
        with os.fdopen(directory.create_file(destination.name), "wb") as stream:
            stream.write(data)
        directory.require_bound()


def finalize_signed_review(app_root, captured):
    approvals, index_hash = _repository()
    if captured["preparationIndexSHA256"] != index_hash:
        reject("preparation-index-changed")
    expected = {key for key, item in approvals.items() if item["format"] == FORMAT}
    if set(captured["resources"]) != expected:
        reject("invalid-signed-review-resource-set")
    resources = []
    for relative, saved in captured["resources"].items():
        item = approvals.get(relative)
        if (item is None or saved["sourceApprovalSHA256"] != document_hash(item)
                or saved["sourceSHA256"] != item["sha256"]):
            reject("signed-source-approval-mismatch")
        data = _read(app_root, relative)
        source = reconstruct_source(data, saved["sourceLayout"])
        if digest(source) != item["sha256"]:
            reject("signed-source-reconstruction-hash-mismatch")
        result = compare_signed(source, data)
        _inspect(app_root, relative, item, data)
        resources.append({"path": relative, "sha256": digest(data),
                          "sourceSHA256": item["sha256"], **saved, **result})
    value = {"schemaVersion": 1, "phase": "signed", "policy": POLICY,
             "preparationIndexSHA256": index_hash, "resources": resources}
    raw = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
    if len(raw) > JSON_LIMIT:
        reject("signed-review-receipt-too-large")
    with open_directory(Path(app_root) / Path(RECEIPT_PATH).parent) as directory:
        with os.fdopen(directory.create_file(Path(RECEIPT_PATH).name), "wb") as stream:
            stream.write(raw)
        directory.require_bound()
    approvals_for_app(app_root)
    return value


def approvals_for_app(app_root):
    """Parent integration point: validated overrides, never a replacement index."""
    approvals, index_hash = _repository()
    value = parse_metadata(_read(app_root, RECEIPT_PATH, limit=JSON_LIMIT), "json")
    if (not isinstance(value, dict) or set(value) != {"schemaVersion", "phase", "policy", "preparationIndexSHA256", "resources"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["phase"] != "signed" or value["policy"] != POLICY
            or value["preparationIndexSHA256"] != index_hash or not isinstance(value["resources"], list)):
        reject("invalid-signed-review-receipt")
    expected = {key for key, item in approvals.items() if item["format"] == FORMAT}
    seen = set()
    for record in value["resources"]:
        if (not isinstance(record, dict) or set(record) != {"path", "sha256", "sourceSHA256", "sourceApprovalSHA256",
                "sourceLayout", "policy", "architectures", "nonSignatureSHA256"}
                or not isinstance(record["path"], str) or record["path"] not in expected or record["path"] in seen):
            reject("invalid-signed-review-resource-set")
        relative = record["path"]
        item = approvals[relative]
        if (record["sourceSHA256"] != item["sha256"]
                or record["sourceApprovalSHA256"] != document_hash(item) or record["policy"] != POLICY):
            reject("signed-source-approval-mismatch")
        data = _read(app_root, relative)
        if digest(data) != record["sha256"]:
            reject("signed-resource-hash-mismatch")
        source = reconstruct_source(data, record["sourceLayout"])
        if digest(source) != item["sha256"]:
            reject("signed-source-reconstruction-hash-mismatch")
        result = compare_signed(source, data)
        if any(record[key] != result[key] for key in result):
            reject("signed-resource-comparison-mismatch")
        _inspect(app_root, relative, item, data)
        approvals[relative] = {**item, "sha256": record["sha256"]}
        seen.add(relative)
    if seen != expected:
        reject("invalid-signed-review-resource-set")
    # Existing final provenance binds the actually shipped libsndfile as well.
    if (Path(app_root) / "Contents/Resources/ASRRuntime").exists():
        if __package__:
            from .binary_provenance import verify_app_provenance
        else:
            from binary_provenance import verify_app_provenance
        if verify_app_provenance(app_root).get("finalStage") != "signed-candidate":
            reject("signed-review-provenance-stage-mismatch")
    return approvals
