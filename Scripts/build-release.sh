#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${LIVELINGO_DERIVED_DATA_PATH:-${project_root}/work/ReleaseDerivedData}"
product="${derived_data}/Build/Products/Release/LiveLingo.app"
entitlements="${project_root}/LiveLingo/Resources/LiveLingo.entitlements"

/usr/bin/xcodebuild \
  -project "${project_root}/LiveLingo.xcodeproj" \
  -scheme LiveLingo \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CLANG_COVERAGE_MAPPING=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  ENABLE_CODE_COVERAGE=NO \
  VALIDATE_PRODUCT=YES \
  build

if [[ -z "${LIVELINGO_SIGN_IDENTITY:-}" ]]; then
  echo "Unsigned Release build: ${product}"
  echo "Set LIVELINGO_SIGN_IDENTITY, LIVELINGO_CERTIFICATE_PATH, and LIVELINGO_KEYCHAIN_PATH to create a Developer ID-signed build."
  exit 0
fi

: "${LIVELINGO_CERTIFICATE_PATH:?Set LIVELINGO_CERTIFICATE_PATH to the public .cer matching the signing identity.}"
: "${LIVELINGO_KEYCHAIN_PATH:?Set LIVELINGO_KEYCHAIN_PATH to the keychain containing the matching private key.}"

if [[ ! -f "${LIVELINGO_CERTIFICATE_PATH}" ]]; then
  echo "Certificate file not found: ${LIVELINGO_CERTIFICATE_PATH}" >&2
  exit 1
fi

if [[ ! -f "${LIVELINGO_KEYCHAIN_PATH}" ]]; then
  echo "Keychain not found: ${LIVELINGO_KEYCHAIN_PATH}" >&2
  exit 1
fi

if ! /usr/bin/openssl x509 -inform DER -in "${LIVELINGO_CERTIFICATE_PATH}" -checkend 0 -noout; then
  echo "The supplied Developer ID certificate is expired or not yet valid." >&2
  exit 1
fi

certificate_sha1="$({ /usr/bin/openssl x509 -inform DER -in "${LIVELINGO_CERTIFICATE_PATH}" -noout -fingerprint -sha1; } | /usr/bin/awk -F= '{gsub(":", "", $2); print toupper($2)}')"
identity_list="$(/usr/bin/security find-identity -v -p codesigning "${LIVELINGO_KEYCHAIN_PATH}")"

if ! /usr/bin/grep -Fq "${certificate_sha1} \"${LIVELINGO_SIGN_IDENTITY}\"" <<<"${identity_list}"; then
  echo "The certificate does not match an available signing identity in the supplied keychain." >&2
  exit 1
fi

# Xcode's linker applies an ad-hoc signature even when target signing is disabled.
# Remove it before applying the final signature; overwriting it on macOS 27 can
# leave a malformed legacy entitlement slot even when strict verification passes.
/usr/bin/codesign --remove-signature "${product}"

/usr/bin/codesign \
  --force \
  --sign "${LIVELINGO_SIGN_IDENTITY}" \
  --keychain "${LIVELINGO_KEYCHAIN_PATH}" \
  --options runtime \
  --timestamp \
  --generate-entitlement-der \
  --entitlements "${entitlements}" \
  "${product}"

/usr/bin/codesign --verify --strict --verbose=2 "${product}"

entitlements_output="$(/usr/bin/mktemp -t livelingo-entitlements)"
trap '/bin/rm -f -- "${entitlements_output}"' EXIT
entitlements_dump="$(/usr/bin/codesign -d --entitlements :- "${product}" 2>&1)"

if /usr/bin/grep -Fq "invalid entitlements blob" <<<"${entitlements_dump}"; then
  echo "Release verification failed: macOS reports an invalid entitlement blob." >&2
  exit 1
fi

/usr/bin/awk 'BEGIN { emit = 0 } /^<\?xml/ { emit = 1 } emit { print }' <<<"${entitlements_dump}" >"${entitlements_output}"
/usr/bin/plutil -lint "${entitlements_output}" >/dev/null

for key in \
  com.apple.security.app-sandbox \
  com.apple.security.device.audio-input \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client
do
  escaped_key="${key//./\\.}"
  value="$(/usr/bin/plutil -extract "${escaped_key}" raw -o - "${entitlements_output}")"
  if [[ "${value}" != "true" ]]; then
    echo "Required entitlement is missing or false: ${key}" >&2
    exit 1
  fi
done

if /usr/bin/plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - "${entitlements_output}" >/dev/null 2>&1; then
  echo "Release verification failed: com.apple.security.get-task-allow is present." >&2
  exit 1
fi

echo "Verified signed Release build: ${product}"
