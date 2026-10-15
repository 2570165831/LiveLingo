"""Copy legal material, excluding pinned Windows API import-library false positives."""
import hashlib
import json
import os
from pathlib import Path
import shutil

try:
    from .privacy_package import PrivacyError, excluded, read_json, license_filename
except ImportError:
    from privacy_package import PrivacyError, excluded, read_json, license_filename

FAMILIES = ('native-cargo-notices', 'outlines-core-0.2.14-cargo')
IMPORT_LIBRARIES = {
    'winapi-i686-pc-windows-gnu-0.4.0/lib/libwinapi_oemlicense.a':
        '0b7a4c869927a60159e6fb52e0a770edcc762d78a8527d7c13d97b315caab8e3',
    'winapi-x86_64-pc-windows-gnu-0.4.0/lib/libwinapi_oemlicense.a':
        'bc88d3b4bb4a91945e8c288539e415d2a1ce5db6d3c342f3ec5860ba1e300df1',
}
REASON = ('Windows OEMLicense API import library, not a copyright notice. '
          'Not used by the macOS inference runtime; original Cargo license declarations and authors remain.')


def prepared_inventory(value):
    """Correct texts without inventing replacement license or publisher claims."""
    # read_json has already rejected duplicate keys. Build a separate mutable
    # ordinary dictionary; its validated mapping deliberately forbids overwrites.
    value = json.loads(json.dumps(value, ensure_ascii=False))
    changed = []
    for component in value.get('components', []):
        kept = []
        for item in component.get('texts', []):
            expected = IMPORT_LIBRARIES.get(item.get('path'))
            if expected is None:
                kept.append(item)
            else:
                if item.get('sha256') != expected:
                    raise PrivacyError('changed-nonnotice-inventory-input')
                changed.append(item['path'])
                component.setdefault('omittedNonNoticeBuildInputs', []).append({**item, 'reason': REASON})
        if 'texts' in component:
            component['texts'] = kept
    if set(changed) != set(IMPORT_LIBRARIES):
        raise PrivacyError('incomplete-nonnotice-inventory-input')
    value['distributionNote'] = REASON
    return value


def copy_notice_tree(source, target, *, dirs_exist_ok=False):
    """Keep sources read-only; fail if known omitted bytes or inventory change."""
    source, target = Path(source), Path(target)
    if source.is_symlink() or not source.is_dir():
        raise PrivacyError('notice-source-not-real-directory')
    for directory, dirs, files in os.walk(source, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise PrivacyError('notice-material-symlink')
            if path.is_file() and license_filename(path) and any(excluded(part) for part in path.relative_to(source).parts):
                raise PrivacyError('supplement-license-needs-safe-relative-name')
    removed = []
    if source.name in FAMILIES:
        for relative, expected in IMPORT_LIBRARIES.items():
            path = source / relative
            if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise PrivacyError('changed-nonnotice-build-input')
            if (target / relative).exists() or (target / relative).is_symlink():
                raise PrivacyError('obsolete-nonnotice-in-destination')
            removed.append({'file': source.name + '/' + relative, 'sha256': expected,
                            'bytes': path.stat().st_size, 'reason': REASON})
    changes = []
    def ignore(directory, names):
        directory = Path(directory)
        return [name for name in names if excluded(name) or source.name in FAMILIES
                and (directory / name).relative_to(source).as_posix() in IMPORT_LIBRARIES]
    def copy(path, destination):
        path, destination = Path(path), Path(destination)
        if path == source / 'inventory.json' and source.name in FAMILIES:
            original = path.read_bytes()
            value = prepared_inventory(read_json(path))
            prepared = (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()
            destination.write_bytes(prepared)
            changes.append({'file': source.name + '/inventory.json',
                            'originalSHA256': hashlib.sha256(original).hexdigest(),
                            'preparedSHA256': hashlib.sha256(prepared).hexdigest(), 'reason': REASON})
        else:
            shutil.copy2(path, destination, follow_symlinks=False)
        return str(destination)
    shutil.copytree(source, target, dirs_exist_ok=dirs_exist_ok, symlinks=True, ignore=ignore, copy_function=copy)
    return {'removedFiles': removed, 'changedInventories': changes}
