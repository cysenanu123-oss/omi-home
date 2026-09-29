const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, nativeImage, screen } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');

// ─── Config ────────────────────────────────────────────────────────────────────
const BACKEND_URL = 'http://localhost:3000';
const BACKEND_SCRIPT = path.join(__dirname, '..', 'home-agent', 'server.py');
const VENV_PYTHON = path.join(__dirname, '..', 'home-agent', '.venv', 'bin', 'python');
const ENV_FILE = path.join(__dirname, '..', 'Backend-Rust', '.env');
const HOTKEY = 'Alt+A';

let win = null;
let tray = null;
let backendProc = null;
let isQuitting = false;

// ─── Load env vars ─────────────────────────────────────────────────────────────
function loadEnv() {
  const env = { ...process.env };
  if (fs.existsSync(ENV_FILE)) {
    const lines = fs.readFileSync(ENV_FILE, 'utf8').split('\n');
    for (const line of lines) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m && !m[2].startsWith('#')) env[m[1]] = m[2].trim();
    }
  }
  return env;
}

// ─── Start Python backend ──────────────────────────────────────────────────────
function startBackend() {
  const env = loadEnv();
  const python = fs.existsSync(VENV_PYTHON) ? VENV_PYTHON : 'python3';

  console.log('Starting Ama backend...');
  backendProc = spawn(python, [BACKEND_SCRIPT], {
    env,
    detached: false,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  backendProc.stdout.on('data', d => console.log('[backend]', d.toString().trim()));
  backendProc.stderr.on('data', d => console.error('[backend]', d.toString().trim()));
  backendProc.on('exit', code => {
    if (!isQuitting) console.log(`Backend exited (${code}), will retry...`);
  });
}

// ─── Wait for backend to be ready ─────────────────────────────────────────────
function waitForBackend(retries = 20) {
  return new Promise((resolve, reject) => {
    let attempts = 0;
    const check = () => {
      http.get(BACKEND_URL, res => {
        if (res.statusCode < 500) resolve();
        else retry();
      }).on('error', retry);
    };
    const retry = () => {
      if (++attempts >= retries) return reject(new Error('Backend did not start'));
      setTimeout(check, 600);
    };
    check();
  });
}

// ─── Create window ─────────────────────────────────────────────────────────────
function createWindow() {
  const { width: sw, height: sh } = screen.getPrimaryDisplay().workAreaSize;

  win = new BrowserWindow({
    width: 420,
    height: 680,
    x: sw - 440,
    y: sh - 710,
    frame: false,
    transparent: true,
    resizable: true,
    skipTaskbar: false,
    alwaysOnTop: false,
    backgroundColor: '#00000000',
    icon: path.join(__dirname, 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadURL(BACKEND_URL);

  // Hide instead of close
  win.on('close', e => {
    if (!isQuitting) {
      e.preventDefault();
      win.hide();
    }
  });

  // Add custom title bar controls via CSS injection
  win.webContents.on('did-finish-load', () => {
    win.webContents.insertCSS(`
      body { -webkit-app-region: no-drag; border-radius: 16px; overflow: hidden; }
      #titlebar {
        position: fixed; top: 0; left: 0; right: 0; height: 36px;
        -webkit-app-region: drag;
        display: flex; align-items: center; justify-content: flex-end;
        padding: 0 10px; gap: 8px; z-index: 9999;
        background: linear-gradient(rgba(7,8,15,0.95), transparent);
      }
      .tb-btn {
        width: 12px; height: 12px; border-radius: 50%; border: none;
        cursor: pointer; -webkit-app-region: no-drag;
        transition: opacity 0.2s;
      }
      .tb-btn:hover { opacity: 0.7; }
      #tb-close  { background: #ff5f57; }
      #tb-min    { background: #febc2e; }
      #tb-pin    { background: #28c840; }
    `);
    win.webContents.executeJavaScript(`
      const bar = document.createElement('div');
      bar.id = 'titlebar';
      bar.innerHTML = \`
        <button class="tb-btn" id="tb-pin"  title="Always on top" onclick="window.__ama_pin()">⬆</button>
        <button class="tb-btn" id="tb-min"  title="Minimize"      onclick="window.__ama_min()">─</button>
        <button class="tb-btn" id="tb-close" title="Hide"          onclick="window.__ama_close()">✕</button>
      \`;
      document.body.prepend(bar);
    `);
  });
}

// ─── System tray ───────────────────────────────────────────────────────────────
function createTray() {
  const iconPath = path.join(__dirname, 'icon.png');
  const img = fs.existsSync(iconPath)
    ? nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 })
    : nativeImage.createEmpty();

  tray = new Tray(img);
  tray.setToolTip('Ama — Personal AI Assistant');

  const menu = Menu.buildFromTemplate([
    { label: 'Show Ama',       click: () => { win.show(); win.focus(); } },
    { label: 'Hide',           click: () => win.hide() },
    { type: 'separator' },
    { label: `Hotkey: ${HOTKEY}`, enabled: false },
    { type: 'separator' },
    { label: 'Quit Ama',       click: quit },
  ]);
  tray.setContextMenu(menu);
  tray.on('click', () => win.isVisible() ? win.hide() : (win.show(), win.focus()));
}

// ─── IPC from renderer ─────────────────────────────────────────────────────────
ipcMain.on('window-close',  () => win.hide());
ipcMain.on('window-min',    () => win.minimize());
ipcMain.on('window-pin',    () => win.setAlwaysOnTop(!win.isAlwaysOnTop()));

// ─── Quit ──────────────────────────────────────────────────────────────────────
function quit() {
  isQuitting = true;
  if (backendProc) backendProc.kill();
  app.quit();
}

// ─── App lifecycle ─────────────────────────────────────────────────────────────
app.whenReady().then(async () => {
  // Single instance lock
  if (!app.requestSingleInstanceLock()) {
    app.quit();
    return;
  }

  app.on('second-instance', () => {
    if (win) { win.show(); win.focus(); }
  });

  // Start backend then window
  startBackend();

  try {
    await waitForBackend();
  } catch (e) {
    console.error('Backend failed to start:', e.message);
  }

  createWindow();
  createTray();

  // Global hotkey Alt+A to toggle
  globalShortcut.register(HOTKEY, () => {
    if (!win) return;
    if (win.isVisible() && win.isFocused()) win.hide();
    else { win.show(); win.focus(); }
  });
});

app.on('window-all-closed', e => e.preventDefault()); // Keep alive in tray
app.on('before-quit', () => { isQuitting = true; });
app.on('will-quit', () => globalShortcut.unregisterAll());
