const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('__ama_close', () => ipcRenderer.send('window-close'));
contextBridge.exposeInMainWorld('__ama_min',   () => ipcRenderer.send('window-min'));
contextBridge.exposeInMainWorld('__ama_pin',   () => ipcRenderer.send('window-pin'));
