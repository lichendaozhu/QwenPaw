#!/usr/bin/env bash
# Build QwenPaw Desktop for Linux as an AppImage.
#
# Tauri's linuxdeploy GTK plugin is unreliable on GitHub-hosted runners. Build
# the Tauri Debian bundle first, extract its already-correct AppDir layout,
# use linuxdeploy only to collect shared-library dependencies, then use
# appimagetool directly. This keeps WebKitGTK inside the AppImage without the
# failing GTK plugin chain.

set -euo pipefail

# appimagetool is itself an AppImage. GitHub-hosted runners do not expose FUSE
# reliably, so force AppImage tools to self-extract instead of mounting FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DIST="${DIST:-dist}"
VERSION="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)"
BINARIES_DIR="${REPO_ROOT}/console/src-tauri/binaries"
BUNDLE_DIR="${REPO_ROOT}/console/src-tauri/target/release/bundle"
DEB_DIR="${BUNDLE_DIR}/deb"
APPIMAGE_DIR="${BUNDLE_DIR}/appimage"
APPDIR="${APPIMAGE_DIR}/QwenPaw.AppDir"

echo "========================================="
echo "QwenPaw Tauri Build - Linux AppImage"
echo "========================================="
echo "Version: ${VERSION}"
echo ""

missing=()
for command in npm rustc cargo uv python3 dpkg-deb; do
    if command -v "$command" >/dev/null 2>&1; then
        echo "  [OK] ${command}"
    else
        echo "  [MISSING] ${command}"
        missing+=("$command")
    fi
done
if ((${#missing[@]})); then
    echo "Missing prerequisites: ${missing[*]}" >&2
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Linux AppImage builds must run on Linux" >&2
    exit 1
fi

echo "== Building Console Static Assets =="
pushd console >/dev/null
npm ci
npm exec -- tauri icon ../scripts/pack/assets/icon.svg
QWENPAW_TAURI_BUNDLE_TARGETS=appimage \
  VITE_DESKTOP_UPDATES_ENABLED=false \
  node ../scripts/pack-tauri/sync_tauri_version.mjs
VITE_DESKTOP_UPDATES_ENABLED=false npm run build:prod
popd >/dev/null

echo "== Building PyInstaller Backend =="
bash scripts/pack-tauri/build_pyinstaller.sh

if [[ ! -x "${BINARIES_DIR}/qwenpaw-backend/qwenpaw-backend" ]]; then
    echo "ERROR: Linux backend executable was not created" >&2
    exit 1
fi

echo "== Building Tauri Debian bundle for AppDir =="
rm -rf "${DEB_DIR}" "${APPIMAGE_DIR}"
pushd console >/dev/null
QWENPAW_TAURI_BUNDLE_TARGETS=deb \
  VITE_DESKTOP_UPDATES_ENABLED=false \
  node ../scripts/pack-tauri/sync_tauri_version.mjs
npm exec -- tauri build --config src-tauri/tauri.version.conf.json --bundles deb
popd >/dev/null

DEB="$(find "${DEB_DIR}" -maxdepth 1 -type f -name '*.deb' -print -quit)"
if [[ -z "${DEB}" ]]; then
    echo "ERROR: no Debian bundle found under ${DEB_DIR}" >&2
    exit 1
fi

echo "== Extracting Tauri Debian bundle into AppDir =="
mkdir -p "${APPDIR}"
dpkg-deb -x "${DEB}" "${APPDIR}"
cp "${REPO_ROOT}/scripts/pack-tauri/appimage/AppRun" "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"

DESKTOP_FILE="$(find "${APPDIR}/usr/share/applications" -maxdepth 1 -type f -name '*.desktop' -print -quit)"
if [[ -z "${DESKTOP_FILE}" ]]; then
    echo "ERROR: Debian bundle did not contain a desktop entry" >&2
    exit 1
fi
cp "${DESKTOP_FILE}" "${APPDIR}/$(basename "${DESKTOP_FILE}")"

ICON_FILE="$(find "${APPDIR}/usr/share/icons" -type f \( -name '*.png' -o -name '*.svg' \) -print -quit)"
if [[ -z "${ICON_FILE}" ]]; then
    echo "ERROR: Debian bundle did not contain an application icon" >&2
    exit 1
fi
cp "${ICON_FILE}" "${APPDIR}/.DirIcon"
ICON_NAME="$(sed -n 's/^Icon=//p' "${DESKTOP_FILE}" | head -n 1)"
if [[ -z "${ICON_NAME}" ]]; then
    echo "ERROR: desktop entry did not declare an icon name" >&2
    exit 1
fi
case "${ICON_FILE}" in
    *.png)
        cp "${ICON_FILE}" "${APPDIR}/${ICON_NAME}.png"
        ;;
    *.svg)
        cp "${ICON_FILE}" "${APPDIR}/${ICON_NAME}.svg"
        ;;
    *)
        echo "ERROR: unsupported application icon format: ${ICON_FILE}" >&2
        exit 1
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download appimagetool" >&2
    exit 1
fi

TOOL_DIR="${REPO_ROOT}/.cache/packaging"
LINUXDEPLOY="${TOOL_DIR}/linuxdeploy-x86_64.AppImage"
APPIMAGETOOL="${TOOL_DIR}/appimagetool-x86_64.AppImage"
mkdir -p "${TOOL_DIR}"

if [[ ! -x "${LINUXDEPLOY}" ]]; then
    curl --fail --location --retry 3 \
        "https://github.com/tauri-apps/binary-releases/releases/download/linuxdeploy/linuxdeploy-x86_64.AppImage" \
        --output "${LINUXDEPLOY}"
    chmod +x "${LINUXDEPLOY}"
fi

# Do not use --plugin gtk here. That plugin is the failing part of Tauri's
# default AppImage path. linuxdeploy's core dependency follower is enough to
# collect libwebkit2gtk, GTK, and their ELF dependencies into AppDir.
echo "== Bundling Linux shared-library dependencies =="
APPIMAGE_EXTRACT_AND_RUN=1 \
  "${LINUXDEPLOY}" --appimage-extract-and-run --verbosity 3 --appdir "${APPDIR}"

if [[ ! -x "${APPIMAGETOOL}" ]]; then
    curl --fail --location --retry 3 \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
        --output "${APPIMAGETOOL}"
    chmod +x "${APPIMAGETOOL}"
fi

if [[ "${DIST}" = /* ]]; then
    DIST_ROOT="${DIST}"
else
    DIST_ROOT="${REPO_ROOT}/${DIST}"
fi
mkdir -p "${DIST_ROOT}"
OUTPUT="${DIST_ROOT}/QwenPaw-Tauri-${VERSION}-Linux-x86_64.AppImage"
echo "== Building AppImage with appimagetool =="
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 \
  "${APPIMAGETOOL}" --appimage-extract-and-run "${APPDIR}" "${OUTPUT}"
chmod +x "${OUTPUT}"

echo ""
echo "Build complete: ${OUTPUT}"
du -h "${OUTPUT}"
