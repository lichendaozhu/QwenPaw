# QwenPaw Electron Linux package

This is the Linux desktop target for machines such as Kylin V10 SP1 with
glibc 2.31. Electron supplies the Chromium/WebView runtime, so the host does
not need WebKitGTK. The package intentionally has no automatic update path.

Build from the repository root:

```bash
bash scripts/pack-tauri/build_electron_appimage.sh
```

The x86_64 AppImage is written to `electron/dist/`. The build also runs the
frontend production build and the PyInstaller backend build. For a local smoke
test, set `QWENPAW_BACKEND_PATH` to a built backend executable and run
`npm --prefix electron start`.
