#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
DIST="${DIST:-dist}"
rm -rf "$DIST/electron-backend"
mkdir -p "$DIST/electron-backend"
"${NPM:-npm}" --prefix console ci --no-audit --no-fund
VITE_DESKTOP_UPDATES_ENABLED=false npm --prefix console run build:electron
bash scripts/pack-tauri/build_pyinstaller.sh
cp -a console/src-tauri/binaries/qwenpaw-backend/. "$DIST/electron-backend/"
chmod +x "$DIST/electron-backend/qwenpaw-backend"
rm -rf electron/console-dist
cp -a console/dist electron/console-dist
npm --prefix electron install --no-audit --no-fund
ELECTRON_ARCH="${ELECTRON_ARCH:-x64}"
case "$ELECTRON_ARCH" in
  x64) npm --prefix electron run dist:linux:x64 ;;
  arm64) npm --prefix electron run dist:linux:arm64 ;;
  *) echo "Unsupported ELECTRON_ARCH: $ELECTRON_ARCH" >&2; exit 2 ;;
esac
