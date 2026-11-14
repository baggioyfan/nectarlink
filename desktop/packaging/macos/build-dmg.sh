#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Wraps NectarLink.app in a disk image, the way macOS apps are handed over:
#   dist/NectarLink-<version>-macos-<arch>.dmg
#
# Run build-app.sh first (or let it: it's the default when the app is missing).
#
#   VERSION=0.1.5 ./desktop/packaging/macos/build-dmg.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"
VERSION="${VERSION:-$(awk -F'"' '/^version = "/ { print $2; exit }' "${REPO_ROOT}/Cargo.toml")}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
APP="${OUT_DIR}/NectarLink.app"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "this makes a macOS disk image; run it on macOS"
if [[ ! -d "${APP}" ]]; then
    step "No app yet: building it"
    VERSION="${VERSION}" OUT_DIR="${OUT_DIR}" bash "${HERE}/build-app.sh"
fi

ARCH="$(lipo -archs "${APP}/Contents/MacOS/nectarlink-desktop" | tr -d ' ')"
DMG="${OUT_DIR}/NectarLink-${VERSION}-macos-${ARCH}.dmg"

STAGE="$(mktemp -d -t nectarlink-dmg-XXXXXX)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R "${APP}" "${STAGE}/NectarLink.app"
# The usual drag-to-install target.
ln -s /Applications "${STAGE}/Applications"

step "Making ${DMG}"
rm -f "${DMG}"
hdiutil create \
    -volname "NectarLink ${VERSION}" \
    -srcfolder "${STAGE}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${DMG}" >/dev/null
hdiutil verify "${DMG}" >/dev/null || die "the disk image didn't verify"

step "Done: ${DMG} ($(du -sh "${DMG}" | cut -f1))"
echo "    the app inside is ad-hoc signed: on first launch, right-click > Open"
