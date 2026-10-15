"""Static synthetic sign/re-sign fixtures; no native execution or codesign.

Fixtures persist in unique task evidence directories, including failed cases.
Builders use independent struct layouts, not the production normalization.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch
import uuid

from Scripts import signed_resource_review as review
from Scripts import privacy_package as privacy
from Scripts.privacy_package import PrivacyError, inspect_tree

EVIDENCE_ROOT = Path(__file__).resolve().parents[1] / "work/relpipe/relpipe6/f4-signed-stage"
PUBLIC = "/" + "Users/runner/work/public/source.c"
PRIVATE = "/" + "Users/reviewprobe/private/source.c"
RELATIVE = "Contents/Resources/LanguageRuntime/probe.dylib"


def thin(*, endian="<", wide=True, text=PUBLIC, linkedit=b"original string table\0"):
    number = "Q" if wide else "I"
    segment = 0x19 if wide else 1
    fixed = 72 if wide else 56
    def seg(name, fileoff, size):
        return struct.pack(endian + "II16s" + number * 4 + "4I", segment, fixed,
                           name.encode().ljust(16, b"\0"), fileoff, 4096, fileoff, size,
                           7, 5, 0, 0)
    identity = b"@rpath/probe.dylib\0"
    width = (24 + len(identity) + (7 if wide else 3)) // (8 if wide else 4) * (8 if wide else 4)
    commands = (seg("__TEXT", 0, 4096) + seg("__LINKEDIT", 4096, 128)
                + struct.pack(endian + "6I", 0xD, width, 24, 0, 0, 0)
                + identity.ljust(width - 24, b"\0"))
    header = struct.pack(endian + ("8I" if wide else "7I"),
                         *([0xfeedfacf if wide else 0xfeedface,
                            0x100000c if wide else 7, 0, 6, 3, len(commands), 0]
                           + ([0] if wide else [])))
    body = bytearray(4096)
    body[:len(header + commands)] = header + commands
    raw = text.encode() + b"\0"
    body[512:512 + len(raw)] = raw
    return bytes(body) + linkedit.ljust(128, b"\0")


def simulated_sign(data, *, cms=b"SIMULATED_CMS", auxiliary=None,
                   version=0x20400, runtime=0, preencrypt=0):
    """Change only signature command, derived size, valid page hashes and CMS."""
    formats = {b"\xcf\xfa\xed\xfe": ("<", True), b"\xfe\xed\xfa\xcf": (">", True),
               b"\xce\xfa\xed\xfe": ("<", False), b"\xfe\xed\xfa\xce": (">", False)}
    endian, wide = formats[data[:4]]
    header = 32 if wide else 28
    count, size = struct.unpack_from(endian + "II", data, 16)
    position, signature_at, linkedit_at = header, None, None
    for _ in range(count):
        cmd, width = struct.unpack_from(endian + "II", data, position)
        if cmd == 0x1d:
            signature_at = position
            prefix = struct.unpack_from(endian + "I", data, position + 8)[0]
        if cmd in (1, 0x19) and data[position + 8:position + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit_at = position
        position += width
    if signature_at is None:
        prefix = len(data)
        signature_at = header + size
        count += 1
        size += 16
    prefix = (prefix + 15) // 16 * 16
    image = bytearray(data[:prefix].ljust(prefix, b"\0"))
    ident = b"synthetic.probe\0"
    team = b"TESTTEAM\0"
    strings = ident + team
    special = auxiliary[0] if auxiliary else 0
    cd_header = 96 if version == 0x20500 else 88
    cd_size = cd_header + len(strings) + special * 32 + ((prefix + 4095) // 4096) * 32
    slots = [(0, None), (0x10000, struct.pack(">II", 0xfade0b01, 8 + len(cms)) + cms)]
    if auxiliary:
        slots.insert(1, auxiliary)
    total = 12 + 8 * len(slots) + cd_size + sum(len(blob) for _, blob in slots if blob is not None)
    struct.pack_into(endian + "II", image, 16, count, size)
    struct.pack_into(endian + "4I", image, signature_at, 0x1d, 16, prefix, total)
    struct.pack_into(endian + ("Q" if wide else "I"), image, linkedit_at + (48 if wide else 36),
                     prefix + total - 4096)
    cd = bytearray(cd_size)
    hash_offset = cd_header + len(strings) + special * 32
    struct.pack_into(">9I", cd, 0, 0xfade0c02, cd_size, version, 0,
                     hash_offset, cd_header, special, (prefix + 4095) // 4096, prefix)
    cd[36:40] = bytes([32, 2, 0, 12])
    struct.pack_into(">I", cd, 48, cd_header + len(ident))
    if version == 0x20500:
        struct.pack_into(">II", cd, 88, runtime, preencrypt)
    cd[cd_header:cd_header + len(strings)] = strings
    if auxiliary:
        at = hash_offset - special * 32
        cd[at:at + 32] = hashlib.sha256(auxiliary[1]).digest()
    for index in range((prefix + 4095) // 4096):
        at = hash_offset + index * 32
        cd[at:at + 32] = hashlib.sha256(image[index * 4096:min(prefix, (index + 1) * 4096)]).digest()
    slots[0] = (0, bytes(cd))
    output = bytearray(struct.pack(">3I", 0xfade0cc0, total, len(slots)))
    cursor = 12 + 8 * len(slots)
    for slot, blob in slots:
        output += struct.pack(">II", slot, cursor)
        cursor += len(blob)
    return bytes(image + output + b"".join(blob for _, blob in slots))


def fat(images, *, wide=False):
    width = 32 if wide else 20
    output = bytearray(8 + len(images) * width)
    struct.pack_into(">II", output, 0, 0xcafebabf if wide else 0xcafebabe, len(images))
    for index, image in enumerate(images):
        padding = -len(output) % 4096
        output += b"\0" * padding
        start = len(output)
        endian = "<" if image[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") else ">"
        cpu, sub = struct.unpack_from(endian + "II", image, 4)
        form = ">IIQQII" if wide else ">IIIII"
        values = [cpu, sub, start, len(image), 12] + ([0] if wide else [])
        struct.pack_into(form, output, 8 + index * width, *values)
        output += image
    return bytes(output)


class SignedResourceTests(unittest.TestCase):
    def setUp(self):
        self.root = EVIDENCE_ROOT / (self._testMethodName + "-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.app = self.root / "Synthetic.app"
        self.path = self.app / RELATIVE
        self.path.parent.mkdir(parents=True)
        self.source = thin()
        self.path.write_bytes(self.source)
        self.item = {"path": RELATIVE, "sha256": hashlib.sha256(self.source).hexdigest(),
                     "format": "macho-public-build-strings", "package": "synthetic",
                     "version": "1", "reason": "Public upstream fixture, no code execution",
                     "publicBuildPathsHex": [PUBLIC.encode().hex()]}
        self.approvals = {RELATIVE: self.item,
                          "Contents/Resources/other.txt": {"format": "notice-text", "sha256": "b" * 64}}
        self.index = review.document_hash(self.approvals)
        self.repo = patch.object(review, "_repository", side_effect=lambda: (json.loads(json.dumps(self.approvals)), self.index))
        self.repo.start()
        self.addCleanup(self.repo.stop)

    def complete(self):
        captured = review.capture_before_signing(self.app)
        review.write_capture_receipt(self.app, (self.root / "before-sign.json").absolute(), captured)
        self.path.write_bytes(simulated_sign(self.source))
        return review.finalize_signed_review(self.app, captured)

    def rewrite_receipt(self, mutate):
        path = self.app / review.RECEIPT_PATH
        value = json.loads(path.read_bytes())
        mutate(value)
        path.write_text(json.dumps(value))

    def test_sign_and_resign_roundtrip_source_is_authenticated(self):
        for source in (thin(), simulated_sign(thin(), cms=b"OLD_SOURCE_CMS")):
            signed = simulated_sign(source, cms=b"NEW_SIMULATED_CMS_CONTENT")
            saved = review.capture_source(source)
            self.assertEqual(review.reconstruct_source(signed, saved), source)
            self.assertEqual(review.compare_signed(source, signed)["policy"], review.POLICY)

    def test_thin_32_64_both_endians(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                source = thin(endian=endian, wide=wide)
                signed = simulated_sign(source)
                self.assertEqual(review.reconstruct_source(signed, review.capture_source(source)), source)
                review.compare_signed(source, signed)

    def test_fat32_fat64_roundtrip_with_slice_growth(self):
        for wide in (False, True):
            originals = [thin(), thin(wide=False, endian=">")]
            source, signed = fat(originals, wide=wide), fat([simulated_sign(i) for i in originals], wide=wide)
            self.assertEqual(review.reconstruct_source(signed, review.capture_source(source)), source)
            review.compare_signed(source, signed)

    def test_approvals_only_replace_signed_native_hash(self):
        receipt = self.complete()
        result = review.approvals_for_app(self.app)
        self.assertEqual(result[RELATIVE]["sha256"], receipt["resources"][0]["sha256"])
        self.assertEqual(result["Contents/Resources/other.txt"], self.approvals["Contents/Resources/other.txt"])
        self.assertEqual(self.item["sha256"], hashlib.sha256(self.source).hexdigest())

    def test_parent_signed_phase_gate_and_preparation_index_stay_separate(self):
        self.complete()
        with patch("Scripts.reviewed_resources.entries", return_value=self.approvals):
            counts = inspect_tree(self.app, phase="signed")
            self.assertEqual(counts["reviewed_resource_files"], 1)
            for phase in ("prepare", "final"):
                with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
                    inspect_tree(self.app, phase=phase)

    def test_signed_stage_requires_signed_candidate_audio_provenance(self):
        self.complete()
        (self.app / "Contents/Resources/ASRRuntime").mkdir()
        with patch("Scripts.binary_provenance.verify_app_provenance", return_value={"finalStage": "assembled-candidate"}):
            with self.assertRaisesRegex(PrivacyError, "provenance-stage-mismatch"):
                review.approvals_for_app(self.app)
        with patch("Scripts.binary_provenance.verify_app_provenance", return_value={"finalStage": "signed-candidate"}):
            self.assertIn(RELATIVE, review.approvals_for_app(self.app))

    def test_linkedit_data_is_never_excluded(self):
        bad = bytearray(self.source); bad[4100] ^= 1
        with self.assertRaisesRegex(PrivacyError, "nonsignature-changed"):
            review.compare_signed(self.source, simulated_sign(bytes(bad)))

    def test_text_instruction_data_change_rejected_with_valid_new_page_hashes(self):
        bad = bytearray(self.source); bad[1024] = 0x41
        with self.assertRaisesRegex(PrivacyError, "nonsignature-changed"):
            review.compare_signed(self.source, simulated_sign(bytes(bad)))

    def test_changed_load_command_rejected(self):
        bad = bytearray(self.source); bad[200:204] = b"evil"
        with self.assertRaises(PrivacyError):
            review.compare_signed(self.source, simulated_sign(bytes(bad)))

    def test_stale_code_page_hash_rejected(self):
        bad = bytearray(simulated_sign(self.source)); bad[1024] ^= 1
        with self.assertRaisesRegex(PrivacyError, "code-page-hash-mismatch"):
            review.compare_signed(self.source, bad)

    def test_signature_not_eof_rejected(self):
        with self.assertRaisesRegex(PrivacyError, "linkedit-boundary"):
            review.compare_signed(self.source, simulated_sign(self.source) + b"hidden trailer")

    def test_signature_offset_overlaps_code_rejected(self):
        bad = bytearray(simulated_sign(self.source))
        struct.pack_into("<I", bad, 32 + 72 + 72 + 48 + 8, 512)
        with self.assertRaises(PrivacyError):
            review.compare_signed(self.source, bad)

    def test_unchecked_superblob_shape_rejected(self):
        signed = bytearray(simulated_sign(self.source))
        struct.pack_into(">I", signed, 4224, 0xfade0b01)
        with self.assertRaisesRegex(PrivacyError, "superblob"):
            review.compare_signed(self.source, signed)

    def test_overlapping_slots_rejected(self):
        signed = bytearray(simulated_sign(self.source))
        first = struct.unpack_from(">I", signed, 4224 + 16)[0]
        struct.pack_into(">I", signed, 4224 + 24, first)
        with self.assertRaises(PrivacyError):
            review.compare_signed(self.source, signed)

    def test_unknown_signature_slot_rejected(self):
        signed = bytearray(simulated_sign(self.source))
        struct.pack_into(">I", signed, 4224 + 20, 0xDEAD)
        with self.assertRaisesRegex(PrivacyError, "superblob-slot"):
            review.compare_signed(self.source, signed)

    def test_code_limit_cannot_exclude_arbitrary_tail(self):
        signed = bytearray(simulated_sign(self.source))
        struct.pack_into(">I", signed, 4224 + 28 + 32, 4096)
        with self.assertRaisesRegex(PrivacyError, "page-coverage"):
            review.compare_signed(self.source, signed)

    def test_scatter_cannot_exclude_code(self):
        signed = bytearray(simulated_sign(self.source))
        struct.pack_into(">I", signed, 4224 + 28 + 44, 8)
        with self.assertRaisesRegex(PrivacyError, "scatter"):
            review.compare_signed(self.source, signed)

    def test_runtime_version_field_supported_but_preencrypt_offset_rejected(self):
        signed = simulated_sign(self.source, version=0x20500, runtime=0x001A0100)
        review.compare_signed(self.source, signed)
        with self.assertRaisesRegex(PrivacyError, "preencrypt"):
            review.compare_signed(self.source, simulated_sign(self.source, version=0x20500,
                                                             runtime=0x001A0100, preencrypt=128))

    def test_auxiliary_slot_hashes_are_checked(self):
        requirement = struct.pack(">II", 0xfade0c01, 12) + b"TEST"
        signed = simulated_sign(self.source, auxiliary=(2, requirement))
        review.compare_signed(self.source, signed)
        bad = bytearray(signed); bad[-len(b"SIMULATED_CMS") - 12] ^= 1
        with self.assertRaises(PrivacyError):
            review.compare_signed(self.source, bad)

    def test_unbounded_linkedit_vmsize_rejected(self):
        altered = bytearray(self.source)
        struct.pack_into("<Q", altered, 32 + 72 + 32, 0x100000)
        with self.assertRaisesRegex(PrivacyError, "vmsize-changed"):
            review.compare_signed(self.source, simulated_sign(bytes(altered)))

    def test_unsigned_final_is_rejected(self):
        with self.assertRaisesRegex(PrivacyError, "missing-signed-signature"):
            review.compare_signed(self.source, self.source)

    def test_preparation_hash_mismatch_rejected_before_capture(self):
        self.path.write_bytes(self.source + b"mutation")
        with self.assertRaisesRegex(PrivacyError, "reviewed-resource-hash-mismatch"):
            review.capture_before_signing(self.app)

    def test_changed_index_rejected(self):
        captured = review.capture_before_signing(self.app)
        self.index = "a" * 64
        with self.assertRaisesRegex(PrivacyError, "preparation-index-changed"):
            review.finalize_signed_review(self.app, captured)

    def test_changed_public_string_approval_rejected(self):
        self.complete()
        self.approvals[RELATIVE]["publicBuildPathsHex"] = [b"/tmp/different-public-source".hex()]
        with self.assertRaisesRegex(PrivacyError, "source-approval-mismatch"):
            review.approvals_for_app(self.app)

    def test_private_load_path_cannot_reuse_public_string_approval(self):
        source = bytearray(self.source)
        source[32 + 144 + 24:32 + 144 + 48] = b"/tmp/private.dylib\0".ljust(24, b"\0")
        self.path.write_bytes(source)
        self.item["sha256"] = hashlib.sha256(source).hexdigest()
        self.item["publicBuildPathsHex"].append(b"/tmp/private.dylib".hex())
        with self.assertRaisesRegex(PrivacyError, "load-command"):
            review.capture_before_signing(self.app)

    def test_private_signature_string_is_not_exempt(self):
        captured = review.capture_before_signing(self.app)
        self.path.write_bytes(simulated_sign(self.source, cms=PRIVATE.encode()))
        with self.assertRaisesRegex(PrivacyError, "build-string"):
            review.finalize_signed_review(self.app, captured)

    def test_stale_signed_receipt_rejected(self):
        self.complete()
        self.path.write_bytes(simulated_sign(self.source, cms=b"ANOTHER_VALID_SIGNATURE"))
        with self.assertRaisesRegex(PrivacyError, "signed-resource-hash-mismatch"):
            review.approvals_for_app(self.app)

    def test_rehashed_forged_receipt_cannot_authorize_code(self):
        self.complete()
        changed = bytearray(self.source); changed[1024] ^= 1
        signed = simulated_sign(bytes(changed))
        self.path.write_bytes(signed)
        def forge(value):
            value["resources"][0]["sha256"] = hashlib.sha256(signed).hexdigest()
            value["resources"][0]["nonSignatureSHA256"] = review.compare_signed(bytes(changed), signed)["nonSignatureSHA256"]
        self.rewrite_receipt(forge)
        with self.assertRaisesRegex(PrivacyError, "source-reconstruction-hash-mismatch"):
            review.approvals_for_app(self.app)

    def test_forged_original_header_cannot_authorize_header_load_or_linkedit(self):
        self.complete()
        receipt_path = self.app / review.RECEIPT_PATH
        saved = receipt_path.read_bytes()
        for offset in (24, 32 + 144 + 24, 1024, 4100):
            changed = bytearray(self.source); changed[offset] ^= 1
            signed = simulated_sign(bytes(changed))
            self.path.write_bytes(signed)
            receipt_path.write_bytes(saved)
            def forge(value):
                row = value["resources"][0]
                row["sha256"] = hashlib.sha256(signed).hexdigest()
                # Reinsert the genuine source header into the forged receipt.
                # Header normalization still compares every non-signature field.
                row["sourceLayout"] = review.capture_source(self.source)
            self.rewrite_receipt(forge)
            with self.assertRaises(PrivacyError):
                review.approvals_for_app(self.app)

    def test_forged_source_header_itself_does_not_match_fixed_full_hash(self):
        self.complete()
        def forge(value):
            layout = value["resources"][0]["sourceLayout"]["slices"][0]
            header = bytearray.fromhex(layout["headerHex"]); header[24] ^= 1
            layout["headerHex"] = header.hex()
        self.rewrite_receipt(forge)
        with self.assertRaisesRegex(PrivacyError, "source-reconstruction-hash-mismatch"):
            review.approvals_for_app(self.app)

    def test_source_layout_fields_fail_closed(self):
        self.complete()
        receipt_path = self.app / review.RECEIPT_PATH
        saved = receipt_path.read_bytes()
        mutations = (lambda v: v["resources"][0]["sourceLayout"].update(extra="ignored?"),
                     lambda v: v["resources"][0]["sourceLayout"].update(size=-1),
                     lambda v: v["resources"][0]["sourceLayout"]["slices"][0].update(offset=1),
                     lambda v: v["resources"][0]["sourceLayout"]["slices"][0].update(prefixSize=1),
                     lambda v: v["resources"][0]["sourceLayout"]["slices"][0].update(headerHex="not-hex"),
                     lambda v: v.update(schemaVersion=True))
        for mutate in mutations:
            receipt_path.write_bytes(saved); self.rewrite_receipt(mutate)
            with self.assertRaises(PrivacyError):
                review.approvals_for_app(self.app)

    def test_prepared_stale_signature_and_old_reservation_bytes_are_preserved(self):
        source = bytearray(simulated_sign(self.source))
        source[1024] ^= 1  # simulate reviewed privacy edits, old page hashes stale
        source += b"OLD_RESERVED_BYTES"
        sig_at = 32 + 72 + 72 + 48
        struct.pack_into("<I", source, sig_at + 12, len(source) - 4224)
        struct.pack_into("<Q", source, 32 + 72 + 48, len(source) - 4096)
        signed = simulated_sign(bytes(source))
        layout = review.capture_source(source)
        self.assertEqual(review.reconstruct_source(signed, layout), bytes(source))
        review.compare_signed(source, signed)
        with self.assertRaises(PrivacyError):
            review.compare_signed(source, source)

    def test_final_signature_nonzero_reservation_padding_rejected(self):
        signed = bytearray(simulated_sign(self.source))
        signed += b"NEW_UNCHECKED_RESERVED_DATA"
        sig_at = 32 + 72 + 72 + 48
        struct.pack_into("<I", signed, sig_at + 12, len(signed) - 4224)
        struct.pack_into("<Q", signed, 32 + 72 + 48, len(signed) - 4096)
        with self.assertRaisesRegex(PrivacyError, "superblob"):
            review.compare_signed(self.source, signed)

    def test_symbol_table_cannot_overlap_signature(self):
        # Add a valid SYMTAB before signing; its referenced string range must
        # remain entirely before the signature even if all page hashes match.
        source = bytearray(self.source)
        at = 32 + 72 + 72 + 48
        struct.pack_into("<6I", source, at, 2, 24, 4096, 1, 4210, 40)
        struct.pack_into("<II", source, 16, 4, 72 + 72 + 48 + 24)
        signed = simulated_sign(bytes(source))
        with self.assertRaisesRegex(PrivacyError, "overlaps-signed-content"):
            review.compare_signed(self.source, signed)

    def test_missing_duplicate_extra_receipt_entries_rejected(self):
        self.complete()
        saved = (self.app / review.RECEIPT_PATH).read_bytes()
        for mutate in (lambda v: v.update(resources=[]),
                       lambda v: v["resources"].append(v["resources"][0]),
                       lambda v: v["resources"][0].update(path="Contents/Resources/unknown.dylib")):
            (self.app / review.RECEIPT_PATH).write_bytes(saved)
            self.rewrite_receipt(mutate)
            with self.assertRaisesRegex(PrivacyError, "resource-set"):
                review.approvals_for_app(self.app)

    def test_receipt_symlink_rejected(self):
        self.complete()
        other = self.root / "Linked.app"
        (other / "Contents/Resources/LanguageRuntime").mkdir(parents=True)
        (other / review.RECEIPT_PATH).symlink_to((self.app / review.RECEIPT_PATH).absolute())
        with self.assertRaises(PrivacyError):
            review.approvals_for_app(other)

    def test_native_symlink_rejected(self):
        other = self.root / "Linked.app"
        (other / "Contents/Resources/LanguageRuntime").mkdir(parents=True)
        (other / RELATIVE).symlink_to(self.path.absolute())
        with self.assertRaises(PrivacyError):
            review.capture_before_signing(other)

    def test_external_capture_is_exclusive_and_outside_app(self):
        captured = review.capture_before_signing(self.app)
        destination = (self.root / "capture.json").absolute()
        review.write_capture_receipt(self.app, destination, captured)
        with self.assertRaises(FileExistsError):
            review.write_capture_receipt(self.app, destination, captured)
        with self.assertRaisesRegex(PrivacyError, "outside-app"):
            review.write_capture_receipt(self.app, (self.path.parent / "capture.json").absolute(), captured)

    def test_existing_receipt_rejected_before_resigning(self):
        self.complete()
        with self.assertRaisesRegex(PrivacyError, "already-exists"):
            review.capture_before_signing(self.app)

    def test_fat_alignment_change_rejected(self):
        originals = [thin(), thin(wide=False)]
        source = fat(originals)
        signed = bytearray(fat([simulated_sign(i) for i in originals]))
        struct.pack_into(">I", signed, 24, 11)
        with self.assertRaisesRegex(PrivacyError, "fat-header-changed"):
            review.compare_signed(source, signed)

    def test_signing_order_is_static_and_dmg_selects_stage(self):
        scripts = Path(__file__).resolve().parent
        source = (scripts / "sign-offline-app.py").read_text()
        positions = [source.index(s) for s in ("captured = capture_before_signing", "write_capture_receipt(app_root",
            "for _depth, kind, path", "finalize_app_provenance(app_root", "finalize_signed_review(app_root",
            'inspect_tree(app_root, phase="signed")', '"--remove-signature"')]
        self.assertEqual(positions, sorted(positions))
        dmg = (scripts / "build-offline-dmg.sh").read_text()
        self.assertIn("--phase signed", dmg)
        self.assertIn("--privacy-phase signed", dmg)

    def test_sign_api_requires_capture_and_runs_signed_gate_before_outer_seal(self):
        script = Path(__file__).resolve().parent / "sign-offline-app.py"
        spec = importlib.util.spec_from_file_location("f4_sign_mock", script)
        signing = importlib.util.module_from_spec(spec); spec.loader.exec_module(signing)
        with self.assertRaisesRegex(SystemExit, "review-capture"):
            signing.sign(self.app, "mock", "mock", self.root / "app.plist", self.root / "inherit.plist", [])
        events = []
        def command(arguments):
            target = Path(arguments[-1])
            if target == self.path:
                self.path.write_bytes(simulated_sign(self.source))
                events.append("inner-mock")
            else:
                self.assertEqual(events[-1], "signed-gate")
                review.approvals_for_app(self.app)
                events.append("outer-mock")
        def gate(app, *, phase):
            self.assertEqual(phase, "signed")
            review.approvals_for_app(app)
            events.append("signed-gate")
        with patch.dict(sys.modules, signed_resource_review=review, privacy_package=privacy), \
             patch.object(signing, "main_executable_path", return_value=self.root / "main"), \
             patch.object(signing, "nested_bundles", return_value=[]), \
             patch.object(signing, "run", side_effect=command), \
             patch.object(signing.subprocess, "run") as remove, \
             patch("Scripts.privacy_package.inspect_tree", side_effect=gate):
            remove.return_value.returncode = 0
            signing.sign(self.app, "mock", "mock", self.root / "app.plist", self.root / "inherit.plist",
                         [(self.path, [{"filetype": signing.MH_EXECUTE}])], (self.root / "capture-mock.json").absolute())
        self.assertEqual(events, ["inner-mock", "signed-gate", "outer-mock"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
