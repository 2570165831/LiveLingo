#!/usr/bin/env python3
"""Sign or verify the self-contained LiveLingo candidate for the offline drag-install DMG.

Reusable for any app with nested tools: it signs every Mach-O file inside the
bundle (deepest first), gives helper executables the App Sandbox inherit
entitlement, and signs the outer app with the existing project entitlements.

Guarantees and boundaries:
  * The Developer ID certificate file, the signing identity and the matching
    private key are verified before anything is signed. Only Developer ID
    Application identities are accepted.
  * The keychain is never modified: this script only runs read-only
    `security find-identity`/`find-certificate` queries. It never imports,
    unlocks, or edits keychain items.
  * Mach-O minimum macOS versions are parsed from LC_BUILD_VERSION /
    LC_VERSION_MIN_MACOSX. A dependency requiring later than --max-minos
    (default 14.0) is rejected instead of being shipped.
  * Absolute install names that point outside the app and outside system
    library locations, and symlinks escaping the bundle, are rejected: the
    candidate must be self-contained.
  * No notarization credentials are embedded. Notarize and staple outside this
    script (xcrun notarytool submit ... --keychain-profile ... ; xcrun stapler
    staple ...). This script never downloads anything.

Modes:
  default        sign the app inside-out, then verify it
  --verify-only  run every structural/signature/entitlement check, sign nothing
  --scan PATH    read-only Mach-O inventory (minimum version + dependencies)
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENTITLEMENTS = REPO_ROOT / "LiveLingo/Resources/LiveLingo.entitlements"
REQUIRED_APP_ENTITLEMENTS = (
    "com.apple.security.app-sandbox",
    "com.apple.security.device.audio-input",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
)
INHERIT_ENTITLEMENT = "com.apple.security.inherit"
FORBIDDEN_APP_ENTITLEMENT = "com.apple.security.get-task-allow"
DEVELOPER_ID_PREFIX = "Developer ID Application: "
SYSTEM_LIBRARY_PREFIXES = (
    "/usr/lib/",
    "/System/Library/",
    "/System/iOSSupport/",
    "/System/Volumes/Preboot/Cryptexes/",
    "/Library/Apple/",
)
SYSTEM_SYMLINK_PREFIXES = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")

MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MACHO_MAGICS = frozenset((MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64,
                          FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64))
FAT_MAGICS = frozenset((FAT_MAGIC, FAT_MAGIC_64))

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
DYLIB_LOAD_COMMANDS = frozenset((LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
                                 LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB, LC_LAZY_LOAD_DYLIB))

MH_EXECUTE = 0x2
FILE_TYPES = {0x1: "object", 0x2: "execute", 0x3: "fvmlib", 0x4: "core", 0x5: "preload",
              0x6: "dylib", 0x7: "dylinker", 0x8: "bundle", 0x9: "dylib_stub", 0xB: "fileset"}
CPU_TYPES = {7: "i386", 12: "arm", 0x01000007: "x86_64", 0x0100000C: "arm64", 0x0200000C: "arm64_32"}


def fail(message):
    raise SystemExit("sign-offline-app: " + message)


def note(message):
    print(message, file=sys.stderr)


def run(command, check=True):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    if check and result.returncode != 0:
        fail("command failed (%s): %s\n%s" % (result.returncode, " ".join(str(part) for part in command),
                                              (result.stderr or result.stdout).strip()))
    return result


def decode_version(value):
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def format_version(version):
    parts = list(version)
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return ".".join(str(part) for part in parts)


def parse_version(text):
    parts = [int(part) for part in str(text).split(".")]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def cstring(body, offset):
    if offset <= 0 or offset >= len(body):
        return ""
    end = body.find(b"\x00", offset)
    if end < 0:
        end = len(body)
    return body[offset:end].decode("utf-8", "replace")


def parse_thin(data):
    """Parse one thin Mach-O image into a dict, or None when it is not Mach-O."""
    if len(data) < 28:
        return None
    magic = struct.unpack(">I", data[:4])[0]
    if magic == MH_MAGIC_64:
        endian, is64 = ">", True
    elif magic == MH_CIGAM_64:
        endian, is64 = "<", True
    elif magic == MH_MAGIC:
        endian, is64 = ">", False
    elif magic == MH_CIGAM:
        endian, is64 = "<", False
    else:
        return None
    header_size = 32 if is64 else 28
    if len(data) < header_size:
        return None
    cputype, _cpusubtype, filetype, ncmds, sizeofcmds, _flags = struct.unpack(endian + "iiIIII", data[4:28])
    image = {"cputype": CPU_TYPES.get(cputype & 0xFFFFFFFF, str(cputype)), "filetype": filetype,
             "fileTypeName": FILE_TYPES.get(filetype, str(filetype)), "minos": None,
             "dependencies": [], "rpaths": [], "installName": None}
    offset = header_size
    limit = min(len(data), header_size + sizeofcmds)
    for _ in range(ncmds):
        if offset + 8 > limit:
            break
        command, command_size = struct.unpack(endian + "II", data[offset:offset + 8])
        if command_size < 8 or offset + command_size > limit:
            break
        body = data[offset:offset + command_size]
        if command == LC_BUILD_VERSION and len(body) >= 24:
            _platform, min_version, _sdk = struct.unpack(endian + "III", body[8:20])
            image["minos"] = decode_version(min_version)
        elif command == LC_VERSION_MIN_MACOSX and len(body) >= 16:
            image["minos"] = decode_version(struct.unpack(endian + "I", body[8:12])[0])
        elif command == LC_ID_DYLIB and len(body) >= 12:
            image["installName"] = cstring(body, struct.unpack(endian + "I", body[8:12])[0])
        elif command in DYLIB_LOAD_COMMANDS and len(body) >= 12:
            name = cstring(body, struct.unpack(endian + "I", body[8:12])[0])
            if name:
                image["dependencies"].append(name)
        elif command == LC_RPATH and len(body) >= 12:
            name = cstring(body, struct.unpack(endian + "I", body[8:12])[0])
            if name:
                image["rpaths"].append(name)
        offset += command_size
    return image


def macho_images(path):
    """Return the list of Mach-O images in a file, or None when it is not Mach-O."""
    try:
        with open(path, "rb") as handle:
            header = handle.read(8)
            if len(header) < 4:
                return None
            magic = struct.unpack(">I", header[:4])[0]
            if magic not in MACHO_MAGICS:
                return None
            if magic not in FAT_MAGICS:
                image = parse_thin(header + handle.read(1 << 20))
                return [image] if image is not None else None
            fat64 = magic == FAT_MAGIC_64
            count = struct.unpack(">I", header[4:8])[0]
            if count == 0 or count > 64:
                return None
            entries = []
            for _ in range(count):
                raw = handle.read(32 if fat64 else 20)
                if len(raw) < (32 if fat64 else 20):
                    break
                if fat64:
                    _cputype, _cpusubtype, offset, size, _align, _reserved = struct.unpack(">iiQQII", raw)
                else:
                    _cputype, _cpusubtype, offset, size, _align = struct.unpack(">iiIII", raw)
                entries.append((offset, size))
            images = []
            for offset, size in entries:
                handle.seek(offset)
                image = parse_thin(handle.read(min(size, 1 << 20)))
                if image is not None:
                    images.append(image)
            return images or None
    except (OSError, struct.error, ValueError):
        return None


def worst_minos(images):
    versions = [image["minos"] for image in images if image["minos"]]
    return max(versions) if versions else None


def collect_macho(root):
    root = Path(root)
    found = []
    if root.is_file() and not root.is_symlink():
        images = macho_images(root)
        return [(root, images)] if images else []
    for directory, _directories, files in os.walk(root, followlinks=False):
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            images = macho_images(path)
            if images:
                found.append((path, images))
    return found


def main_executable_path(app_root):
    info = plistlib.loads((app_root / "Contents/Info.plist").read_bytes())
    name = info.get("CFBundleExecutable")
    if not name:
        fail("Contents/Info.plist has no CFBundleExecutable: %s" % app_root)
    return app_root / "Contents/MacOS" / name


def inside_app(candidate, app_root):
    candidate = os.path.normpath(os.path.realpath(candidate))
    root = os.path.normpath(os.path.realpath(str(app_root)))
    return candidate == root or candidate.startswith(root + os.sep)


def expand_loader_path(entry, owner, app_root):
    if entry.startswith("@loader_path"):
        base = str(Path(owner).parent)
        return os.path.normpath(os.path.join(base, entry[len("@loader_path"):].lstrip("/")))
    if entry.startswith("@executable_path"):
        base = str(app_root / "Contents/MacOS")
        return os.path.normpath(os.path.join(base, entry[len("@executable_path"):].lstrip("/")))
    return os.path.normpath(entry)


def dependency_violations(path, images, app_root, extra_rpaths=()):
    violations = []
    for image in images:
        rpaths = list(image["rpaths"]) + list(extra_rpaths)
        for dependency in image["dependencies"]:
            if dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
                resolved = False
                if dependency.startswith("@rpath/"):
                    suffix = dependency[len("@rpath/"):]
                    for rpath in rpaths:
                        if inside_app(os.path.join(expand_loader_path(rpath, path, app_root), suffix), app_root):
                            resolved = True
                            break
                else:
                    resolved = inside_app(expand_loader_path(dependency, path, app_root), app_root)
                if not resolved:
                    violations.append("%s: %s cannot be resolved inside the app" % (path, dependency))
            elif dependency.startswith("/"):
                if inside_app(dependency, app_root) or dependency.startswith(SYSTEM_LIBRARY_PREFIXES):
                    continue
                violations.append("%s: absolute dependency outside the app: %s" % (path, dependency))
            elif not inside_app(os.path.join(str(Path(path).parent), dependency), app_root):
                violations.append("%s: relative dependency outside the app: %s" % (path, dependency))
    return violations


def symlink_violations(app_root):
    root_text = os.path.realpath(str(app_root))
    violations = []
    for directory, directories, files in os.walk(app_root, followlinks=False):
        for name in list(directories) + list(files):
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            target = os.readlink(str(path))
            resolved = os.path.realpath(target if os.path.isabs(target)
                                        else os.path.join(directory, target))
            if resolved == root_text or resolved.startswith(root_text + os.sep):
                continue
            if resolved.startswith(SYSTEM_SYMLINK_PREFIXES):
                continue
            violations.append("%s -> %s" % (path.relative_to(app_root), target))
    return sorted(violations)


def check_min_version(app_root, found, max_minos):
    violations = []
    for path, images in found:
        version = worst_minos(images)
        if version is not None and version > max_minos:
            violations.append("%s requires macOS %s" % (path.relative_to(app_root) if inside_app(path, app_root)
                                                        else path, format_version(version)))
    return violations


def certificate_facts(certificate, checkend="0"):
    certificate = Path(certificate)
    if not certificate.is_file():
        fail("certificate file not found: %s" % certificate)
    prefix = ["/usr/bin/openssl", "x509"]
    if b"-----BEGIN CERTIFICATE-----" not in certificate.read_bytes():
        prefix += ["-inform", "DER"]
    if checkend is not None:
        result = run(prefix + ["-in", certificate, "-noout", "-checkend", checkend], check=False)
        if result.returncode != 0:
            fail("certificate is expired or not yet valid: %s" % certificate)
    subject = run(prefix + ["-in", certificate, "-noout", "-subject", "-nameopt", "RFC2253"]).stdout.strip()
    fingerprint = run(prefix + ["-in", certificate, "-noout", "-fingerprint", "-sha1"]).stdout.strip()
    sha1 = fingerprint.split("=", 1)[-1].replace(":", "").strip().upper()
    if "Developer ID Application" not in subject:
        fail("certificate is not a Developer ID Application certificate: %s" % subject)
    return subject, sha1


def verify_identity(identity, certificate, keychain):
    if not identity:
        fail("no signing identity: pass --identity or set LIVELINGO_SIGN_IDENTITY")
    if not identity.startswith(DEVELOPER_ID_PREFIX):
        fail("identity is not a Developer ID Application identity: %s" % identity)
    if not keychain:
        fail("no keychain: pass --keychain or set LIVELINGO_KEYCHAIN_PATH")
    keychain = Path(keychain)
    try:
        keychain_exists = keychain.exists()
    except OSError as error:
        fail("cannot access keychain %s: %s" % (keychain, error))
    if not keychain_exists:
        fail("keychain not found: %s" % keychain)
    subject, sha1 = certificate_facts(certificate)
    # Read-only queries only. The keychain is never imported into or modified.
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain]).stdout
    if '%s "%s"' % (sha1, identity) not in identities:
        fail("the certificate does not match an identity with a usable private key in %s.\n"
             "Certificate: %s\nAvailable identities:\n%s" % (keychain, subject, identities.strip()))
    return sha1


def entitlements_of(path):
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)],
                            capture_output=True)
    combined = result.stdout + result.stderr
    if b"invalid entitlements blob" in combined:
        fail("macOS reports an invalid entitlement blob for %s" % path)
    start = result.stdout.find(b"<?xml")
    if start < 0:
        return None
    try:
        return plistlib.loads(result.stdout[start:])
    except Exception:
        return None


def validate_app_entitlements(plist, source):
    if not isinstance(plist, dict):
        fail("entitlements plist could not be read: %s" % source)
    for key in REQUIRED_APP_ENTITLEMENTS:
        if plist.get(key) is not True:
            fail("required entitlement is missing or false in %s: %s" % (source, key))
    if FORBIDDEN_APP_ENTITLEMENT in plist:
        fail("%s must not contain %s" % (source, FORBIDDEN_APP_ENTITLEMENT))


NESTED_BUNDLE_SUFFIXES = (".app", ".framework", ".xpc", ".bundle", ".plugin", ".kext")


def is_code_bundle(path):
    """True for a nested directory that codesign must seal as a code bundle."""
    if path.is_symlink():
        return False
    if path.name.endswith((".app", ".framework", ".xpc")):
        return True
    if not path.name.endswith(NESTED_BUNDLE_SUFFIXES):
        return False
    # Loose .bundle/.plugin/.kext directories only count when they really are bundles.
    return any(path.glob("Contents/Info.plist")) or any(path.glob("Contents/Resources/Info.plist"))


def nested_bundles(app_root):
    """Bundles nested inside the app (frameworks, helper apps) that codesign must seal."""
    bundles = []
    for directory, directories, _files in os.walk(app_root, followlinks=False):
        for name in directories:
            path = Path(directory) / name
            if is_code_bundle(path):
                bundles.append(path)
    return bundles


def sign(app_root, identity, keychain, entitlements, inherit_plist, found):
    """Sign inside-out: nested Mach-O files and bundles first, the outer app last."""
    main_executable = main_executable_path(app_root)
    entries = [(len(path.parts), 0, path, images, False)
               for path, images in found if path.resolve() != main_executable.resolve()]
    for bundle in nested_bundles(app_root):
        entries.append((len(bundle.parts), 1, bundle, None, bundle.name.endswith((".app", ".xpc"))))
    entries.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
    helpers = 0
    for _depth, kind, path, images, launchable in entries:
        command = ["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", keychain,
                   "--options", "runtime", "--timestamp"]
        if kind == 0:
            helper = any(image["filetype"] == MH_EXECUTE for image in images)
            if helper:
                command += ["--entitlements", str(inherit_plist), "--generate-entitlement-der"]
                helpers += 1
        elif launchable:
            command += ["--entitlements", str(inherit_plist), "--generate-entitlement-der"]
            helpers += 1
        command.append(str(path))
        run(command)
    result = subprocess.run(["/usr/bin/codesign", "--remove-signature", str(app_root)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        note("note: no removable outer signature (%s)" %
             (result.stderr or result.stdout).strip().splitlines()[0])
    run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", keychain,
         "--options", "runtime", "--timestamp", "--generate-entitlement-der",
         "--entitlements", str(entitlements), str(app_root)])
    return helpers


def verify(app_root, identity, max_minos, found, main_rpaths):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app_root])
    signature = run(["/usr/bin/codesign", "-d", "--verbose=4", app_root], check=False)
    details = (signature.stdout or "") + (signature.stderr or "")
    if identity and "Authority=" + identity not in details:
        fail("app is not signed by the expected identity %s" % identity)

    violations = []
    violations += ["minimum macOS: " + item for item in check_min_version(app_root, found, max_minos)]
    violations += ["symlink: " + item for item in symlink_violations(app_root)]
    for path, images in found:
        violations += ["dependency: " + item for item in
                       dependency_violations(path, images, app_root, main_rpaths)]
    if violations:
        fail("candidate is not self-contained for macOS 14:\n  " + "\n  ".join(violations))

    app_entitlements = entitlements_of(app_root)
    validate_app_entitlements(app_entitlements, app_root)
    main_executable = main_executable_path(app_root)
    helpers = []
    for path, images in found:
        if path.resolve() == main_executable.resolve():
            continue
        if any(image["filetype"] == MH_EXECUTE for image in images):
            helper_entitlements = entitlements_of(path) or {}
            if helper_entitlements.get(INHERIT_ENTITLEMENT) is not True or helper_entitlements.get("com.apple.security.app-sandbox") is not True:
                fail("helper executable misses the sandbox inherit entitlement: %s" % path)
            helpers.append(str(path.relative_to(app_root)))
    return {"helpers": helpers, "entitlements": sorted(app_entitlements.keys())}


def scan_mode(target, max_minos):
    target = Path(target)
    if not target.exists():
        fail("scan target does not exist: %s" % target)
    found = collect_macho(target)
    root = target if target.is_dir() else target.parent
    inventory = []
    violations = []
    for path, images in found:
        version = worst_minos(images)
        entry = {
            "path": str(path),
            "fileType": sorted({image["fileTypeName"] for image in images}),
            "architectures": sorted({image["cputype"] for image in images}),
            "minMacOS": format_version(version) if version else None,
            "installName": next((image["installName"] for image in images if image["installName"]), None),
            "dependencies": sorted({dependency for image in images for dependency in image["dependencies"]}),
            "rpaths": sorted({rpath for image in images for rpath in image["rpaths"]}),
        }
        inventory.append(entry)
        if version is not None and version > max_minos:
            violations.append("%s requires macOS %s" % (path, entry["minMacOS"]))
    print(json.dumps({
        "target": str(target),
        "maxAllowedMinMacOS": format_version(max_minos),
        "machOFiles": len(inventory),
        "inventory": inventory,
        "violations": violations,
    }, ensure_ascii=False, indent=2))
    if violations:
        fail("minimum macOS violation(s):\n  " + "\n  ".join(violations))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n"
               "  Scripts/sign-offline-app.py --app work/OfflineCandidate/LiveLingo.app \\\n"
               "      --identity \"Developer ID Application: ... (TEAMID)\" \\\n"
               "      --certificate /abs/developer-id.cer --keychain /abs/login.keychain-db\n"
               "  Scripts/sign-offline-app.py --verify-only --app work/OfflineCandidate/LiveLingo.app\n"
               "  Scripts/sign-offline-app.py --scan work/OfflineCandidate/LiveLingo.app/Contents/Resources/ASRRuntime\n",
    )
    parser.add_argument("--app", type=Path, help="LiveLingo.app candidate to sign or verify")
    parser.add_argument("--identity", default=os.environ.get("LIVELINGO_SIGN_IDENTITY"),
                        help="Developer ID Application identity (or LIVELINGO_SIGN_IDENTITY)")
    parser.add_argument("--certificate", type=Path, default=os.environ.get("LIVELINGO_CERTIFICATE_PATH"),
                        help="public .cer/.pem matching the identity (or LIVELINGO_CERTIFICATE_PATH)")
    parser.add_argument("--keychain", type=Path, default=os.environ.get("LIVELINGO_KEYCHAIN_PATH"),
                        help="keychain holding the matching private key (or LIVELINGO_KEYCHAIN_PATH)")
    parser.add_argument("--entitlements", type=Path, default=DEFAULT_ENTITLEMENTS,
                        help="app entitlements plist (default: LiveLingo/Resources/LiveLingo.entitlements)")
    parser.add_argument("--max-minos", default="14.0",
                        help="reject Mach-O files requiring a later macOS than this (default: 14.0)")
    parser.add_argument("--verify-only", action="store_true",
                        help="run every check without signing anything")
    parser.add_argument("--scan", type=Path, metavar="PATH",
                        help="read-only Mach-O inventory of a file or directory; exits non-zero on a "
                             "minimum-version violation")
    args = parser.parse_args()

    try:
        max_minos = parse_version(args.max_minos)
    except ValueError:
        fail("--max-minos must look like 14.0, got: %s" % args.max_minos)
    if args.scan is not None:
        scan_mode(args.scan, max_minos)
        return

    if not args.app:
        fail("--app is required unless --scan is used")
    app_root = args.app
    if not (app_root / "Contents/Info.plist").is_file():
        fail("not a macOS application bundle: %s" % app_root)
    if not args.entitlements.is_file():
        fail("entitlements plist not found: %s" % args.entitlements)
    try:
        validate_app_entitlements(plistlib.loads(args.entitlements.read_bytes()), args.entitlements)
    except plistlib.InvalidFileException:
        fail("entitlements plist is not a valid property list: %s" % args.entitlements)

    found = collect_macho(app_root)
    if not found:
        fail("no Mach-O content found inside %s" % app_root)
    main_executable = main_executable_path(app_root)
    main_rpaths = []
    for path, images in found:
        if path.resolve() == main_executable.resolve():
            main_rpaths = sorted({rpath for image in images for rpath in image["rpaths"]})
    versions = [worst_minos(images) for _path, images in found]
    worst = max((version for version in versions if version), default=None)
    summary = {
        "app": str(app_root.resolve()),
        "mode": "verify-only" if args.verify_only else "sign",
        "machOFiles": len(found),
        "worstMinMacOS": format_version(worst) if worst else "unknown",
        "maxAllowedMinMacOS": format_version(max_minos),
    }

    if args.verify_only:
        result = verify(app_root, args.identity, max_minos, found, main_rpaths)
        summary.update({"signed": True, "verified": True, "helperExecutables": result["helpers"],
                        "appEntitlements": result["entitlements"]})
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return

    preflight = check_min_version(app_root, found, max_minos) + symlink_violations(app_root)
    for path, images in found:
        preflight += dependency_violations(path, images, app_root, main_rpaths)
    if preflight:
        fail("pre-sign dependency audit failed:\n  " + "\n  ".join(preflight))

    summary["certificateSHA1"] = verify_identity(args.identity, args.certificate, args.keychain)
    note("signing with %s" % args.identity)
    temporary = Path(tempfile.mkdtemp(prefix="livelingo-inherit-"))
    try:
        inherit_plist = temporary / "inherit.entitlements"
        inherit_plist.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, INHERIT_ENTITLEMENT: True}))
        summary["helperExecutablesSigned"] = sign(app_root, args.identity, args.keychain, args.entitlements,
                                                  inherit_plist, found)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)

    result = verify(app_root, args.identity, max_minos, found, main_rpaths)
    summary.update({"signed": True, "verified": True, "helperExecutables": result["helpers"],
                    "appEntitlements": result["entitlements"],
                    "notarization": "external: xcrun notarytool submit <dmg> --keychain-profile <profile> "
                                    "--wait && xcrun stapler staple <dmg>; no credentials are stored by "
                                    "this script"})
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
