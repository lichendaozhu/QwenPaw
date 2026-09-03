#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
DIST="${DIST:-dist}"
rm -rf "$DIST/electron-backend"
mkdir -p "$DIST/electron-backend"
bash scripts/pack-tauri/build_pyinstaller.sh
cp -a console/src-tauri/binaries/qwenpaw-backend/. "$DIST/electron-backend/"
chmod +x "$DIST/electron-backend/qwenpaw-backend"
VITE_DESKTOP_UPDATES_ENABLED=false npm --prefix console run build:electron
rm -rf electron/console-dist
cp -a console/dist electron/console-dist
npm --prefix electron install --no-audit --no-fund
npm --prefix electron run dist:linux
