const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("qwenpawElectron", {
  invoke: (command, args) => ipcRenderer.invoke("qwenpaw:invoke", command, args),
  listen: async (event, callback) => {
    const channel = `qwenpaw:event:${event}`;
    const listener = (_ignored, payload) => callback(payload);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.removeListener(channel, listener);
  },
  save: (options) => ipcRenderer.invoke("qwenpaw:dialog-save", options),
  open: (options) => ipcRenderer.invoke("qwenpaw:dialog-open", options),
});
