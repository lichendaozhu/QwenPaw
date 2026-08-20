#!/usr/bin/env bash
# Build QwenPaw Desktop for Linux as an AppImage.
#
# This script must run on Linux. PyInstaller and the Tauri AppImage bundle are
# native Linux artifacts and are intentionally not cross-built on macOS.

set -euo pipefail

# GitHub-hosted runners do not expose FUSE reliably. Tauri downloads
# linuxdeploy as an AppImage; force AppImage tools to self-extract instead of
# trying to mount through FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1
export DEBUG="${DEBUG:-1}"
# Make the exact linuxdeploy command and its stderr visible in CI.  Tauri's
# default error only reports "failed to run linuxdeploy".
export RUST_LOG="${RUST_LOG:-tauri_bundler=trace,tauri_cli=debug}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DIST="${DIST:-dist}"
VERSION="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)"
BINARIES_DIR="${REPO_ROOT}/console/src-tauri/binaries"
BUNDLE_DIR="${REPO_ROOT}/console/src-tauri/target/release/bundle"

echo "========================================="
echo "QwenPaw Tauri Build - Linux AppImage"
echo "========================================="
echo "Version: ${VERSION}"
echo ""

missing=()
for command in npm rustc cargo uv python3; do
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

echo "== Building Tauri AppImage =="
rm -rf "${BUNDLE_DIR}/appimage"
pushd console >/dev/null
QWENPAW_TAURI_BUNDLE_TARGETS=appimage \
  VITE_DESKTOP_UPDATES_ENABLED=false \
  node ../scripts/pack-tauri/sync_tauri_version.mjs
npm exec -- tauri build --config src-tauri/tauri.version.conf.json
popd >/dev/null

APPIMAGE="$(find "${BUNDLE_DIR}/appimage" -maxdepth 1 -type f -name '*.AppImage' -print -quit)"
if [[ -z "${APPIMAGE}" ]]; then
    echo "ERROR: no AppImage found under ${BUNDLE_DIR}/appimage" >&2
    exit 1
fi

if [[ "${DIST}" = /* ]]; then
    DIST_ROOT="${DIST}"
else
    DIST_ROOT="${REPO_ROOT}/${DIST}"
fi
mkdir -p "${DIST_ROOT}"
OUTPUT="${DIST_ROOT}/QwenPaw-Tauri-${VERSION}-Linux-x86_64.AppImage"
cp "${APPIMAGE}" "${OUTPUT}"
chmod +x "${OUTPUT}"

echo ""
echo "Build complete: ${OUTPUT}"
du -h "${OUTPUT}"
