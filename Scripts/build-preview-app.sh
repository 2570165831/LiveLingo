#!/bin/bash
# A local UI preview. No installation, launch, download or signing by default.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_root="${project_root}/../work/preview"
architecture=x86_64
reference_models=0
installed_app=/Applications/LiveLingo.app
identity=""
certificate=""
keychain=""

usage() {
  cat <<'EOF'
Usage: Scripts/build-preview-app.sh [options]
  --output-root PATH          Dedicated output/cache root (default: ../work/preview)
  --arch x86_64|arm64          Default x86_64: unsigned UI preview, Rosetta on Apple Silicon
  --reference-installed-models Reference only the installed app's Models directory
  --installed-app PATH        Model source (default: /Applications/LiveLingo.app)
  --sign IDENTITY             OPTIONAL; requires separate user authorization
  --certificate PATH         Public DER certificate matching --sign
  --keychain PATH            Keychain with the matching signing identity/private key
  --help                     Show this help

No models or Python runtimes are copied. A model reference is a symlink used
only for reads by this UI-only app; it is NOT a filesystem read-only mount.
Signing is skipped unless --sign is explicit; ad-hoc identities are refused.
Signed sandbox builds refuse external model references (no automatic grants).
Unsigned arm64 cannot run on Apple Silicon until separately authorized signing.
EOF
}
fail() { echo "Error: $*" >&2; exit 1; }
argument() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root) argument "$@"; output_root="$2"; shift 2 ;;
    --arch) argument "$@"; architecture="$2"; shift 2 ;;
    --reference-installed-models) reference_models=1; shift ;;
    --installed-app) argument "$@"; installed_app="$2"; shift 2 ;;
    --sign) argument "$@"; identity="$2"; shift 2 ;;
    --certificate) argument "$@"; certificate="$2"; shift 2 ;;
    --keychain) argument "$@"; keychain="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$architecture" == x86_64 || "$architecture" == arm64 ]] || fail "Unsupported architecture"
[[ "$output_root" == /* ]] || fail "--output-root must be an absolute path"
[[ -z "$identity" || "$identity" != - ]] || fail "Ad-hoc signing is not supported"
if [[ -z "$identity" ]]; then
  [[ -z "$certificate" && -z "$keychain" ]] || fail "Signing material requires explicit --sign"
else
  [[ "$reference_models" == 0 ]] || fail "Sandbox signing cannot grant access through a model symlink; external model references are refused"
  [[ -f "$certificate" && -f "$keychain" ]] || fail "--sign needs --certificate and --keychain"
  [[ "$identity" == "Developer ID Application: "* ]] || fail "Use an explicit Developer ID Application identity"
fi

# Validate before mkdir, and reuse only this dedicated architecture's cache.
output_root="$(python3 - "$output_root" "$project_root" <<'PY'
from pathlib import Path
import os
import sys
p = Path(sys.argv[1])
root = p.resolve()
repo = Path(sys.argv[2]).resolve()
protected = {Path('/'), Path.home(), Path('/Users'), Path('/Volumes'), repo}
for base in ('/Applications', '/System', '/Library'):
    if root == Path(base) or Path(base) in root.parents:
        raise SystemExit('Refusing a system/application output directory')
if root in protected or root in repo.parents or repo in root.parents:
    raise SystemExit('Use a dedicated output root outside the source tree')
if any(item.is_symlink() for item in (p, *p.parents)):
    raise SystemExit('Output paths must not contain symbolic links')
if root.exists() and not root.is_dir():
    raise SystemExit('Output root is not a directory')
print(root)
PY
)"
derived_data="${output_root}/dd-build-${architecture}"
[[ ! -L "$derived_data" && ( ! -e "$derived_data" || -d "$derived_data" ) ]] || fail "DerivedData must be an ordinary directory"

models=""
if [[ "$reference_models" == 1 ]]; then
  [[ "$installed_app" == /* ]] || fail "--installed-app must be an absolute path"
  models="$(python3 - "$installed_app" <<'PY'
from pathlib import Path
import plistlib
import sys
app = Path(sys.argv[1]).resolve(strict=True)
with (app / 'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
if info.get('CFBundleIdentifier') != 'com.jianhongli.LiveLingo':
    raise SystemExit('Model source is not the production LiveLingo bundle')
models = app / 'Contents/Resources/Models'
if not models.is_dir() or models.is_symlink():
    raise SystemExit('Installed Models must be an ordinary readable directory')
# Check directory access only. Do not open or load weights.
next(iter(models.iterdir()), None)
print(models)
PY
)"
fi

if [[ -n "$identity" ]]; then
  # Optional offline signing: validate certificate dates and the exact private
  # key identity. Never import/export/unlock a keychain or auto-select an identity.
  python3 - "$certificate" <<'PY'
from datetime import datetime, timezone
import subprocess
import sys
text = subprocess.check_output(['/usr/bin/openssl', 'x509', '-inform', 'DER',
    '-in', sys.argv[1], '-noout', '-startdate', '-enddate'], text=True)
dates = dict(line.split('=', 1) for line in text.splitlines())
parse = lambda value: datetime.strptime(value, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
if not parse(dates['notBefore']) <= datetime.now(timezone.utc) < parse(dates['notAfter']):
    raise SystemExit('Signing certificate is not currently valid')
PY
  certificate_sha1="$(/usr/bin/openssl x509 -inform DER -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/awk -F= '{gsub(":", "", $2); print toupper($2)}')"
  identities="$(/usr/bin/security find-identity -v -p codesigning "$keychain")"
  /usr/bin/grep -Fq "${certificate_sha1} \"${identity}\"" <<<"$identities" || fail "Certificate and available private-key identity do not match"
fi

commit="$(git -C "$project_root" rev-parse HEAD)"
short_commit="$(git -C "$project_root" rev-parse --short=8 HEAD)"
dirty=0
[[ -z "$(git -C "$project_root" status --porcelain)" ]] || dirty=1
mkdir -p "$output_root"
run_directory="$(/usr/bin/mktemp -d "${output_root}/package-${short_commit}-XXXXXX")"
info_plist="${run_directory}/PreviewInfo.plist"
python3 - "$project_root/LiveLingo/Resources/Info.plist" "$info_plist" "$commit" "$short_commit" "$dirty" <<'PY'
from pathlib import Path
import plistlib
import sys
with Path(sys.argv[1]).open('rb') as f:
    info = plistlib.load(f)
info['CFBundleIdentifier'] = 'com.jianhongli.LiveLingo.preview'
info['CFBundleDisplayName'] = info['CFBundleName'] = 'LiveLingo 预览版'
info['LSApplicationCategoryType'] = 'public.app-category.education'
info['CFBundleVersion'] += '-preview.' + sys.argv[4] + ('.dirty' if sys.argv[5] == '1' else '')
info['LiveLingoPreviewCommit'] = sys.argv[3]
info['LiveLingoPreviewDirty'] = sys.argv[5] == '1'
info['LiveLingoPreviewMode'] = 'UI-only; no bundled ML runtimes'
with Path(sys.argv[2]).open('xb') as f:
    plistlib.dump(info, f)
PY

echo "Building unsigned ${architecture} preview; log: ${run_directory}/build.log"
# CODE_SIGNING_ALLOWED alone does not stop the linker's implicit ad-hoc signing.
# Do not use build-release.sh: its signing environment is intentionally separate.
/usr/bin/xcodebuild \
  -project "${project_root}/LiveLingo.xcodeproj" -scheme LiveLingo \
  -configuration Release -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "$derived_data" -disableAutomaticPackageResolution -skipPackageUpdates \
  ARCHS="$architecture" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  'OTHER_LDFLAGS=$(inherited) -Wl,-no_adhoc_codesign' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LIVELINGO_PREVIEW' \
  PRODUCT_BUNDLE_IDENTIFIER=com.jianhongli.LiveLingo.preview \
  INFOPLIST_FILE="$info_plist" \
  CLANG_MODULE_CACHE_PATH="${derived_data}/ModuleCache.noindex" \
  CLANG_COVERAGE_MAPPING=NO CLANG_ENABLE_CODE_COVERAGE=NO ENABLE_CODE_COVERAGE=NO \
  build >"${run_directory}/build.log" 2>&1 || {
    tail -50 "${run_directory}/build.log" >&2
    fail "xcodebuild failed; full log retained"
  }
python3 "${project_root}/Scripts/check_build_warnings.py" "${run_directory}/build.log"

app="${run_directory}/LiveLingo 预览版.app"
# Move this build product instead of duplicating the bundle. Never touch the
# installed application or replace a previous preview.
mv "${derived_data}/Build/Products/Release/LiveLingo.app" "$app"
cp "${project_root}/LICENSE" "${app}/Contents/Resources/LICENSE"
if [[ -n "$models" ]]; then
  [[ ! -e "${app}/Contents/Resources/Models" && ! -L "${app}/Contents/Resources/Models" ]] || fail "Unexpected bundled models"
  ln -s "$models" "${app}/Contents/Resources/Models"
fi
cat >"${app}/Contents/Resources/Preview-README.txt" <<'EOF'
LiveLingo 预览版：界面与窗口试用包。
没有内置模型或 Python 运行库；不支持录音转写、MLX 翻译、摘要或复查。
模型引用只供只读定位，不会补上运行库；软链接不是只读挂载。
未签名包没有生效的 App Sandbox：偏好使用独立 preview bundle ID，
数据放在用户 Library/Application Support/LiveLingoPreview。
所有课程打开、保存、导出及迁移限制在该目录的 Courses 子目录；
导入媒体也须先放入此目录。不会继承正式版课程书签或 CLI 数据路径。
Intel 预览包在 Apple Silicon 上需要已安装的 Rosetta。
本包不会自行安装、下载、签名或修改系统设置。
EOF

# Verify *before* any optional signing that not even an ad-hoc signature exists.
python3 "${project_root}/Scripts/preview-app-metadata.py" "$app" --unsigned >"${run_directory}/unsigned-receipt.json"
if [[ -n "$identity" ]]; then
  echo "Signing explicitly requested preview with its sandbox entitlements"
  /usr/bin/codesign --sign "$identity" --keychain "$keychain" --options runtime \
    --timestamp=none --generate-entitlement-der \
    --entitlements "${project_root}/LiveLingo/Resources/LiveLingo.entitlements" "$app"
  /usr/bin/codesign --verify --strict "$app"
fi
python3 "${project_root}/Scripts/preview-app-metadata.py" "$app" >"${run_directory}/receipt.json"
echo "Preview: $app"
echo "Receipt: ${run_directory}/receipt.json"
[[ -n "$identity" ]] || echo "Signing skipped (including ad-hoc). Sandbox is not active."
if [[ "$architecture" == arm64 && -z "$identity" ]]; then
  echo "Unsigned arm64 is build evidence only; it needs separately authorized signing to launch."
fi
