#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds NectarLink.app: the release binary inside a bundle, with Qt and its
# plugins collected into it, ad-hoc signed. macOS has no installer to mirror
# the Windows one: the .app is the deliverable (build-dmg.sh wraps it).
#
#   VERSION=0.1.5 ./desktop/packaging/macos/build-app.sh
#
# Environment:
#   VERSION   the version in CFBundleShortVersionString (default: Cargo.toml's)
#   BIN_PATH  the built executable (default: target/release/nectarlink-desktop)
#   OUT_DIR   where NectarLink.app goes (default: dist/)
#   SIGN_ID   the signing identity (default: "-", an ad-hoc signature)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"
VERSION="${VERSION:-$(awk -F'"' '/^version = "/ { print $2; exit }' "${REPO_ROOT}/Cargo.toml")}"
BIN_PATH="${BIN_PATH:-${REPO_ROOT}/target/release/nectarlink-desktop}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
SIGN_ID="${SIGN_ID:--}"
APP="${OUT_DIR}/NectarLink.app"
ICON_SRC="${REPO_ROOT}/assets/brand/icon-512.png"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$(uname -s)" == "Darwin" ]] || die "this packages a macOS app; run it on macOS"
[[ -f "${BIN_PATH}" ]] || die "no binary at ${BIN_PATH}: cargo build --release -p nectarlink-desktop first"
[[ -f "${ICON_SRC}" ]] || die "no icon at ${ICON_SRC}"
[[ -n "${VERSION}" ]] || die "no version"

# CFBundleVersion is a build number: digits only. 0.1.5 -> 15, 0.1.5-nightly.7 -> 15.
BUILD="$(printf '%s' "${VERSION}" | sed 's/-.*//' | tr -d '.')"

step "Bundling NectarLink ${VERSION} (build ${BUILD})"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks" "${APP}/Contents/PlugIns"
install -m 0755 "${BIN_PATH}" "${APP}/Contents/MacOS/nectarlink-desktop"

step "Compiling the translations"
LRELEASE="${LRELEASE:-}"
if [[ -z "${LRELEASE}" ]]; then
    if [[ -n "${QT_ROOT_DIR:-}" && -x "${QT_ROOT_DIR}/bin/lrelease" ]]; then
        LRELEASE="${QT_ROOT_DIR}/bin/lrelease"
    else
        LRELEASE="$(command -v lrelease || true)"
    fi
fi
[[ -n "${LRELEASE}" && -x "${LRELEASE}" ]] || die "no lrelease: put Qt's bin on PATH or set QT_ROOT_DIR"

# The app looks for its catalogues next to the executable (src/i18n.rs,
# select_translation_dir), so they go in Contents/MacOS. build.rs compiles them
# on Linux only and package.ps1 compiles them for Windows, so without this step
# the bundle speaks English whatever the system language.
#
# Only the languages Settings offers are compiled, as on Windows: a catalogue
# still being translated stays out (i18n::LANGUAGES is the list).
LANG_CODES="$(sed -n '/pub const LANGUAGES/,/^];/p' "${REPO_ROOT}/desktop/app/src/i18n.rs" \
    | grep -oE '^[[:space:]]*\("[A-Za-z_]*"' \
    | tr -d ' ("' \
    | grep -v '^$')"
[[ -n "${LANG_CODES}" ]] || die "couldn't read the language list from src/i18n.rs"
for code in ${LANG_CODES}; do
    # English is the source language: it has no catalogue, and needs none.
    if [[ "${code}" == "en" ]]; then
        continue
    fi
    ts="${REPO_ROOT}/desktop/app/i18n/nectarlink_${code}.ts"
    [[ -f "${ts}" ]] || die "no catalogue for ${code}: ${ts}"
    "${LRELEASE}" -silent "${ts}" -qm "${APP}/Contents/MacOS/nectarlink_${code}.qm"
    echo "    ${code}"
done
ls -1 "${APP}/Contents/MacOS/"*.qm | wc -l | xargs printf '    %s catalogues\n'

# Qt's own strings (the standard buttons, the file dialogs, the context menus
# QML doesn't draw itself). install_translator looks for qt_<locale>.qm in a
# translations/ folder beside the executable; Qt ships qtbase_<locale>.qm, so
# it's copied under the name the loader asks for.
QT_TRANSLATIONS="${QT_ROOT_DIR:-}/translations"
if [[ -d "${QT_TRANSLATIONS}" ]]; then
    mkdir -p "${APP}/Contents/MacOS/translations"
    for code in ${LANG_CODES}; do
        if [[ -f "${QT_TRANSLATIONS}/qtbase_${code}.qm" ]]; then
            cp "${QT_TRANSLATIONS}/qtbase_${code}.qm" "${APP}/Contents/MacOS/translations/qt_${code}.qm"
        fi
    done
    printf '    %s Qt catalogues\n' "$(ls -1 "${APP}/Contents/MacOS/translations" | wc -l | tr -d ' ')"
fi
step "Writing Info.plist"
sed -e "s/@VERSION@/${VERSION}/g" -e "s/@BUILD@/${BUILD}/g" \
    "${HERE}/Info.plist" > "${APP}/Contents/Info.plist"
plutil -lint "${APP}/Contents/Info.plist" >/dev/null || die "Info.plist didn't lint"

step "Making the icon"
ICONSET="$(mktemp -d)/NectarLink.iconset"
mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/NectarLink.icns"

step "Collecting Qt into the bundle (macdeployqt)"
MACDEPLOYQT="${MACDEPLOYQT:-}"
if [[ -z "${MACDEPLOYQT}" ]]; then
    if [[ -n "${QT_ROOT_DIR:-}" && -x "${QT_ROOT_DIR}/bin/macdeployqt" ]]; then
        MACDEPLOYQT="${QT_ROOT_DIR}/bin/macdeployqt"
    else
        MACDEPLOYQT="$(command -v macdeployqt || true)"
    fi
fi
[[ -n "${MACDEPLOYQT}" && -x "${MACDEPLOYQT}" ]] || die "no macdeployqt: put Qt's bin on PATH or set QT_ROOT_DIR"

# The QML is compiled into the binary (ahead-of-time, see build.rs), so
# macdeployqt can't discover the imports by itself: -qmldir points it at the
# sources to scan. It reports `app.nectarlink` as unresolvable, which is
# expected -- that module lives inside the executable.
DEPLOY_LOG="$(mktemp -t nectarlink-macdeployqt)"
if ! "${MACDEPLOYQT}" "${APP}" \
        -qmldir="${REPO_ROOT}/desktop/app/qml" \
        -always-overwrite \
        -verbose=1 >"${DEPLOY_LOG}" 2>&1; then
    cat "${DEPLOY_LOG}" >&2
    die "macdeployqt failed (log above)"
fi
grep -viE 'cannot resolve|Cannot find|WARNING' "${DEPLOY_LOG}" | sed 's/^/    /' || true
[[ -d "${APP}/Contents/Frameworks/QtCore.framework" ]] || die "macdeployqt left no QtCore.framework in the bundle"
[[ -f "${APP}/Contents/PlugIns/platforms/libqcocoa.dylib" ]] || die "macdeployqt left no cocoa platform plugin: the app can't open a window"

# Our own QML lives in the binary, but Qt's modules are loaded from the bundle
# at run time, and macdeployqt only takes what qmlimportscanner resolved. This
# is the list desktop/app/qml imports; a missing one is a blank window, not a
# build error, so it's checked here rather than discovered on someone's Mac.
QML_ROOT="${APP}/Contents/Resources/qml"
for module in QtQuick QtQuick/Shapes QtQuick/Effects QtQuick/Layouts QtQuick/Dialogs QtQuick/Window QtQml QtQml/Models; do
    [[ -f "${QML_ROOT}/${module}/qmldir" ]] || die "the bundle lacks the ${module} QML module"
done

step "Signing (${SIGN_ID})"
# Ad-hoc by default: it runs, but every rebuild is a different identity, so the
# first launch needs Open from the context menu (or xattr -dr com.apple.quarantine).
# A Developer ID and notarization are what make it open with a double click;
# that needs an Apple Developer account.
codesign --force --deep --sign "${SIGN_ID}" --timestamp=none "${APP}" 2>&1 | sed 's/^/    /' || die "codesign failed"

step "Checking the result"
codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | sed 's/^/    /' || die "the signature didn't verify"

# A catalogue that compiled to nothing is worse than an absent one: the app
# would load it and show empty strings.
for code in ${LANG_CODES}; do
    if [[ "${code}" == "en" ]]; then
        continue
    fi
    [[ -s "${APP}/Contents/MacOS/nectarlink_${code}.qm" ]] || die "the ${code} catalogue is empty"
done

BIN="${APP}/Contents/MacOS/nectarlink-desktop"
# Anything still pointing at the build machine's Qt or Homebrew means the app
# only works on the machine that built it. The first line otool prints is the
# binary's own path, which is inside the checkout, so it's skipped: only the
# indented dependency lines matter.
if otool -L "${BIN}" | tail -n +2 | grep -qE '/Users/|/opt/homebrew/|/usr/local/(Cellar|Qt)'; then
    otool -L "${BIN}" | tail -n +2 | grep -E '/Users/|/opt/homebrew/|/usr/local/(Cellar|Qt)' | sed 's/^/    /'
    die "the executable still links libraries outside the bundle"
fi
# dyld resolves the frameworks and Qt's own plugins at load time, so this
# fails loudly here if the bundle is incomplete -- before anyone double-clicks it.
GOT="$("${BIN}" --version 2>&1)" || die "the bundled app doesn't start: ${GOT}"
printf '    %s\n' "${GOT}" "${APP}"

step "Done: ${APP} ($(du -sh "${APP}" | cut -f1), $(lipo -archs "${BIN}"))"
echo "    open it with: open ${APP}"
