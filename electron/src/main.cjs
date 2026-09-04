const { app, BrowserWindow, dialog, ipcMain, shell, Menu, Tray, nativeImage } = require("electron");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// Kylin installations commonly have no matching VA-API driver. Use software
// rendering by default so the missing libva driver cannot affect startup.
app.commandLine.appendSwitch("disable-gpu");
app.commandLine.appendSwitch("disable-gpu-compositing");

let mainWindow;
let tray;
let backend;
let backendPort = null;
let backendError = null;

function backendPath() {
  return process.env.QWENPAW_BACKEND_PATH || path.join(process.resourcesPath, "backend", "qwenpaw-backend");
}

function startBackend() {
  const executable = backendPath();
  if (!fs.existsSync(executable)) {
    backendError = `Backend executable not found: ${executable}`;
    return;
  }
  backend = spawn(executable, [], {
    cwd: path.dirname(executable),
    env: {
      ...process.env,
      PYTHONUTF8: "1",
      PYTHONIOENCODING: "utf-8",
      PYTHONUNBUFFERED: "1",
      PYTHONFAULTHANDLER: "1",
      QWENPAW_DESKTOP_APP: "1",
      QWENPAW_CORS_ORIGINS: "http://localhost",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const consume = (chunk) => {
    const text = chunk.toString();
    const match = text.match(/QWENPAW_BACKEND_READY\s+(\{[^\n]+\})/);
    if (match) {
      try { backendPort = JSON.parse(match[1]).port; } catch (_) { /* keep polling */ }
    }
    if (process.env.QWENPAW_DESKTOP_DEBUG) process.stderr.write(text);
  };
  backend.stdout.on("data", consume);
  backend.stderr.on("data", (chunk) => {
    const text = chunk.toString();
    if (!backendPort) backendError = text.trim().slice(-4000);
    if (process.env.QWENPAW_DESKTOP_DEBUG) process.stderr.write(text);
  });
  backend.on("error", (error) => { backendError = error.message; });
  backend.on("exit", (code) => {
    if (code && !backendPort) backendError = `Backend exited with code ${code}`;
  });
}

function emit(event, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(`qwenpaw:event:${event}`, payload);
}

async function stopBackend() {
  if (!backend || backend.killed) return;
  try {
    if (backendPort) await fetch(`http://127.0.0.1:${backendPort}/api/desktop/shutdown`, { method: "POST" });
  } catch (_) { /* fallback to process termination */ }
  backend.kill();
  backend = null;
}

async function invokeCommand(command, args = {}) {
  switch (command) {
    case "backend_port": return backendPort;
    case "backend_startup_error": return backendError;
    case "restart_backend": await stopBackend(); backendPort = null; backendError = null; startBackend(); return;
    case "open_devtools": mainWindow.webContents.openDevTools({ mode: "detach" }); return;
    case "open_external_link": await shell.openExternal(args.url); return;
    case "open_workspace_html": {
      const response = await fetch(args.url, { headers: args.headers || {} });
      if (!response.ok) throw new Error(`HTML preview failed: ${response.status}`);
      const preview = new BrowserWindow({ width: 1100, height: 800, webPreferences: { sandbox: true } });
      await preview.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(await response.text())}`);
      return;
    }
    case "download_backend_file": {
      const request = args.request;
      const response = await fetch(request.url, { headers: request.headers || {} });
      if (!response.ok) throw new Error(`Download failed: ${response.status}`);
      fs.writeFileSync(request.filePath, Buffer.from(await response.arrayBuffer()));
      return;
    }
    case "ack_close": return;
    case "minimize_to_tray": mainWindow.hide(); return;
    case "quit_app": await stopBackend(); app.exit(0); return;
    case "set_tray_labels": return;
    // Updates are deliberately disabled for this distribution.
    case "check_desktop_update":
    case "check_cached_update": return null;
    default: throw new Error(`Unsupported desktop command: ${command}`);
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280, height: 800, minWidth: 960, minHeight: 600,
    title: "QwenPaw Desktop",
    webPreferences: { preload: path.join(__dirname, "preload.cjs"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  mainWindow.loadFile(path.join(__dirname, "../console-dist/index.html"));
  mainWindow.on("close", (event) => {
    if (!app.isQuitting) {
      event.preventDefault();
      emit("qwenpaw-close-requested");
    }
  });
}

function createTray() {
  const iconPath = path.join(process.resourcesPath, "icon.png");
  if (!fs.existsSync(iconPath)) {
    console.warn(`Tray icon not found: ${iconPath}`);
    return;
  }
  const icon = nativeImage.createFromPath(iconPath);
  if (icon.isEmpty()) {
    console.warn(`Tray icon could not be decoded: ${iconPath}`);
    return;
  }
  tray = new Tray(icon);
  tray.setContextMenu(Menu.buildFromTemplate([{ label: "Show Window", click: () => mainWindow.show() }, { label: "Quit", click: () => { app.isQuitting = true; void stopBackend().finally(() => app.quit()); } }]));
  tray.on("click", () => mainWindow.show());
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  ipcMain.handle("qwenpaw:invoke", (_event, command, args) => invokeCommand(command, args));
  ipcMain.handle("qwenpaw:dialog-save", (_event, options = {}) => dialog.showSaveDialog(mainWindow, options).then((r) => r.canceled ? null : r.filePath));
  ipcMain.handle("qwenpaw:dialog-open", (_event, options = {}) => dialog.showOpenDialog(mainWindow, options).then((r) => r.canceled ? null : (options.properties || []).includes("multiSelections") ? r.filePaths : r.filePaths[0]));
  startBackend();
  createWindow();
  createTray();
});

app.on("before-quit", (event) => {
  if (backend && !app.isQuitting) { event.preventDefault(); app.isQuitting = true; void stopBackend().finally(() => app.quit()); }
});
