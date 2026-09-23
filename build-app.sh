#!/bin/bash
# Build DSH Launcher into a signed .app bundle and install it.
#
# Why a signed .app and a real certificate (not ad-hoc): the app is a normal GUI
# app, and ad-hoc signing binds the code-signing requirement to the CDHash, so
# every rebuild invalidates any TCC grant (e.g. if the launcher ever needs one).
# An Apple Development certificate binds bundle id + cert CN and survives
# rebuilds. See ~/Desktop/dsh-computer-use/build-app.sh for the same reasoning
# applied to an app that genuinely needs Accessibility.
#
# Usage: ./build-app.sh [--install]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DSH Launcher"
EXECUTABLE="DSHLauncher"
BUNDLE_ID="com.tristan.dsh.launcher"
INSTALL_DIR="${HOME}/Applications"
SIGN_ID="${DSH_LAUNCHER_SIGN_ID:-127DF7DB6EF964270A527F4E9B0A2CAD32EBD2A5}"

# Assemble OFF iCloud Drive. ~/Desktop on this machine is a symlink INTO
# ~/Library/Mobile Documents (iCloud), and iCloud re-applies com.apple.FinderInfo
# to items it indexes — reattaching the "detritus" xattr between `xattr -cr` and
# `codesign`, which makes signing fail with a misleading error. /tmp is not
# fileprovider-managed, so staging there sidesteps it entirely.
STAGE_DIR="$(mktemp -d /tmp/dsh-launcher-build.XXXXXX)"
BUNDLE="${STAGE_DIR}/${APP_NAME}.app"
trap 'rm -rf "${STAGE_DIR}"' EXIT

echo "==> Compiling ${EXECUTABLE}"
cd "${PROJECT_DIR}"
mkdir -p build
swiftc \
  -O \
  -target arm64-apple-macos14.0 \
  -framework Cocoa -framework WebKit \
  -o "build/${EXECUTABLE}" \
  Sources/DSHLauncher/*.swift

echo "==> Assembling ${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"
cp "build/${EXECUTABLE}" "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
chmod +x "${BUNDLE}/Contents/MacOS/${EXECUTABLE}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"

echo "==> Building AppIcon.icns"
ICONSET="${STAGE_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"
# The 1024px master ships in Assets/; every other size is derived from it so the
# repository holds one source of truth.
for size in 16 32 64 128 256 512 1024; do
  sips -z "${size}" "${size}" Assets/icon-1024.png \
       --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
done
# Retina variants: iconutil wants the @2x names spelled out explicitly.
cp "${ICONSET}/icon_32x32.png"    "${ICONSET}/icon_16x16@2x.png"
cp "${ICONSET}/icon_64x64.png"    "${ICONSET}/icon_32x32@2x.png"
cp "${ICONSET}/icon_256x256.png"  "${ICONSET}/icon_128x128@2x.png"
cp "${ICONSET}/icon_512x512.png"  "${ICONSET}/icon_256x256@2x.png"
cp "${ICONSET}/icon_1024x1024.png" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "${ICONSET}" -o "${BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Validating plist"
plutil -lint "${BUNDLE}/Contents/Info.plist"

# codesign refuses to seal a bundle carrying Finder detritus; the failure reads
# "resource fork, Finder information, or similar detritus not allowed".
echo "==> Stripping extended attributes"
xattr -cr "${BUNDLE}"

echo "==> Signing with Apple Development identity ${SIGN_ID:0:16}…"
codesign --force --deep --sign "${SIGN_ID}" \
         --options runtime --timestamp=none \
         "${BUNDLE}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"
codesign -dv --verbose=4 "${BUNDLE}" 2>&1 \
  | grep -E "Identifier|TeamIdentifier|Signature|Authority" | head -5

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to ${INSTALL_DIR}/${APP_NAME}.app"
  mkdir -p "${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
  cp -R "${BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"

  # Exactly ONE copy of this bundle id may exist: LaunchServices resolves a
  # bundle id to a single registered location, and a leftover build copy makes
  # that resolution ambiguous. (The staged copy lives under /tmp and is removed
  # by the EXIT trap, so it never competes.)
  for stray in "${PROJECT_DIR}/build/${APP_NAME}.app" "${HOME}/Desktop/${APP_NAME}.app"; do
    if [[ -e "${stray}" ]]; then
      echo "    removing stray copy ${stray}"
      rm -rf "${stray}"
    fi
  done

  echo "==> Re-registering with LaunchServices"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

  echo
  echo "Installed: ${INSTALL_DIR}/${APP_NAME}.app"
fi

echo
echo "Done: ${BUNDLE}"
