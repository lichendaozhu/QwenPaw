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

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Linux AppImage builds must run on Linux" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64)
        APPIMAGE_ARCH="x86_64"
        GNU_TRIPLET="x86_64-linux-gnu"
        GLIBC_LOADER="ld-linux-x86-64.so.2"
        ;;
    aarch64|arm64)
        APPIMAGE_ARCH="aarch64"
        GNU_TRIPLET="aarch64-linux-gnu"
        GLIBC_LOADER="ld-linux-aarch64.so.1"
        ;;
    *)
        echo "ERROR: unsupported Linux architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

echo "========================================="
echo "QwenPaw Tauri Build - Linux AppImage"
echo "========================================="
echo "Version: ${VERSION}"
echo "Architecture: ${APPIMAGE_ARCH} (${GNU_TRIPLET})"
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

# numba's Linux TBB threading backend is included by PyInstaller and requires
# the oneTBB ABI shipped by Ubuntu 22.04's libtbb12 package. Check this before
# the expensive frontend/PyInstaller/Rust builds so CI fails fast if the image
# dependency list ever regresses.
if ! find "/lib/${GNU_TRIPLET}" "/usr/lib/${GNU_TRIPLET}" \
    -maxdepth 1 -name 'libtbb.so.12' -print -quit 2>/dev/null | grep -q .; then
    echo "ERROR: libtbb.so.12 is required; install Ubuntu package libtbb12" >&2
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

# ARM64 glibc does not preserve the auxiliary vector correctly when an
# application is launched as `ld-linux-aarch64.so.1 app`. Bundle patchelf so
# AppRun can set the absolute AppImage loader as the ELF interpreter on a
# temporary executable copy and let the kernel perform the normal startup.
if ! command -v patchelf >/dev/null 2>&1; then
    echo "ERROR: patchelf is required to make the ARM64 AppImage self-contained" >&2
    exit 1
fi
cp "$(command -v patchelf)" "${APPDIR}/usr/bin/patchelf"
chmod +x "${APPDIR}/usr/bin/patchelf"

DESKTOP_FILE="$(find "${APPDIR}/usr/share/applications" -maxdepth 1 -type f -name '*.desktop' -print -quit)"
if [[ -z "${DESKTOP_FILE}" ]]; then
    echo "ERROR: Debian bundle did not contain a desktop entry" >&2
    exit 1
fi
cp "${DESKTOP_FILE}" "${APPDIR}/$(basename "${DESKTOP_FILE}")"

# Tauri may omit the Linux icon directory when the base config only contains
# platform-specific icons. Keep the AppImage self-contained by falling back to
# the generated Linux PNG rather than failing after a successful native build.
ICON_FILE=""
if [[ -d "${APPDIR}/usr/share/icons" ]]; then
    ICON_FILE="$(find "${APPDIR}/usr/share/icons" -type f \( -name '*.png' -o -name '*.svg' \) -print -quit)"
fi
if [[ -z "${ICON_FILE}" && -f "${REPO_ROOT}/console/src-tauri/icons/icon.png" ]]; then
    ICON_FILE="${REPO_ROOT}/console/src-tauri/icons/icon.png"
fi
if [[ -z "${ICON_FILE}" ]]; then
    echo "ERROR: no application icon was found in the Debian bundle or source tree" >&2
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
LINUXDEPLOY="${TOOL_DIR}/linuxdeploy-${APPIMAGE_ARCH}.AppImage"
APPIMAGETOOL="${TOOL_DIR}/appimagetool-${APPIMAGE_ARCH}.AppImage"
mkdir -p "${TOOL_DIR}"

if [[ ! -x "${LINUXDEPLOY}" ]]; then
    curl --fail --location --retry 3 \
        "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${APPIMAGE_ARCH}.AppImage" \
        --output "${LINUXDEPLOY}"
    chmod +x "${LINUXDEPLOY}"
fi

# Do not use --plugin gtk here. That plugin is the failing part of Tauri's
# default AppImage path. linuxdeploy's core dependency follower is enough to
# collect libwebkit2gtk, GTK, and their ELF dependencies into AppDir.
echo "== Bundling Linux shared-library dependencies =="
APPIMAGE_EXTRACT_AND_RUN=1 \
  "${LINUXDEPLOY}" --appimage-extract-and-run --verbosity 3 --appdir "${APPDIR}" \
  --exclude-library="libcuda.so.1" \
  --exclude-library="libtriton.so" \
  --exclude-library="libtcl*.so*" \
  --exclude-library="libtk*.so*"

echo "== Bundling glibc and compiler runtimes for glibc 2.31 hosts =="
GLIBC_LIB_DIR="${APPDIR}/usr/lib"
mkdir -p "${GLIBC_LIB_DIR}"
for library in \
    "${GLIBC_LOADER}" \
    libc.so.6 \
    libdl.so.2 \
    libm.so.6 \
    libpthread.so.0 \
    libresolv.so.2 \
    librt.so.1 \
    libutil.so.1 \
    libnss_dns.so.2 \
    libnss_files.so.2 \
    libstdc++.so.6 \
    libgcc_s.so.1; do
    source="/lib/${GNU_TRIPLET}/${library}"
    if [[ ! -e "${source}" ]]; then
        source="/usr/lib/${GNU_TRIPLET}/${library}"
    fi
    if [[ ! -e "${source}" ]]; then
        echo "ERROR: required runtime library not found: ${library}" >&2
        exit 1
    fi
    cp -L "${source}" "${GLIBC_LIB_DIR}/${library}"
done

# Kylin V10 ships an older Wayland client. GTK3 from Ubuntu 22.04 is linked
# against wl_proxy_marshal_flags(), which is absent from that system copy. A
# loader-path-only fix is not enough: libgdk-3.so.0 must see the matching
# Wayland ABI inside the AppImage before it can start on Kylin.
echo "== Bundling GTK Wayland/X11 runtime libraries =="
for library in \
    libwayland-client.so.0 \
    libwayland-cursor.so.0 \
    libwayland-egl.so.1 \
    libfreetype.so.6 \
    libxkbcommon.so.0 \
    libxkbcommon-x11.so.0; do
    source="/lib/${GNU_TRIPLET}/${library}"
    if [[ ! -e "${source}" ]]; then
        source="/usr/lib/${GNU_TRIPLET}/${library}"
    fi
    if [[ ! -e "${source}" ]]; then
        echo "ERROR: required GTK runtime library not found: ${library}" >&2
        exit 1
    fi
    cp -L "${source}" "${GLIBC_LIB_DIR}/${library}"
done

if [[ ! -x "${APPIMAGETOOL}" ]]; then
    curl --fail --location --retry 3 \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage" \
        --output "${APPIMAGETOOL}"
    chmod +x "${APPIMAGETOOL}"
fi

if [[ "${DIST}" = /* ]]; then
    DIST_ROOT="${DIST}"
else
    DIST_ROOT="${REPO_ROOT}/${DIST}"
fi
mkdir -p "${DIST_ROOT}"
OUTPUT="${DIST_ROOT}/QwenPaw-Tauri-${VERSION}-Linux-${APPIMAGE_ARCH}.AppImage"
echo "== Building AppImage with appimagetool =="
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="${APPIMAGE_ARCH}" \
  "${APPIMAGETOOL}" --appimage-extract-and-run "${APPDIR}" "${OUTPUT}"
chmod +x "${OUTPUT}"

echo ""
echo "Build complete: ${OUTPUT}"
du -h "${OUTPUT}"
