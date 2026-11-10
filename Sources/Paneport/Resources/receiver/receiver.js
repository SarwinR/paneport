// Viewer page logic. Loaded after protocol.js (the server joins the two files).
//
// Two parts:
// - PaneportEngine: network, decoding, drawing and timing for one display. It runs in a
//   background worker when the browser allows, so several windows of one browser
//   don't queue behind each other on a single main thread. It talks to the page
//   only through emit() and the handle() function it returns.
// - The page: display picker, fullscreen, stats overlay, and hosting the engine.

(function () {
'use strict';

const PaneportProtocol = PaneportProtocolFactory();

const panel = document.getElementById('panel');
const statusEl = document.getElementById('status');
const hostEl = document.getElementById('host');
const help = document.getElementById('help');
let displays = (typeof BAKED !== 'undefined') ? BAKED : [];
let current = null;

// The Mac's address is remembered in the browser. 'ndl-host' is the key from before the
// project was renamed; pages saved back then still read it, so it's kept up to date too.
const HOST_KEYS = ['paneport-host', 'ndl-host'];
const STATS_KEY = 'paneport-stats';

function loadSavedHost() {
  try {
    for (const key of HOST_KEYS) {
      const value = localStorage.getItem(key);
      if (value) return value;
    }
  } catch (e) {}
  return null;
}

function saveHost(value) {
  try { for (const key of HOST_KEYS) localStorage.setItem(key, value); } catch (e) {}
}

const savedHost = loadSavedHost();
if (savedHost && location.protocol === 'file:') hostEl.value = savedHost;

if (!('VideoDecoder' in window)) {
  help.textContent = 'This browser blocks video decoding on pages loaded from a plain network address. ' +
    'Press Ctrl+S, save as "Webpage, HTML Only", then open the saved file in Edge or Chrome.';
}

// =============================================================================
// Engine. Must only use PaneportProtocol and browser APIs available in workers, since
// it's copied into the worker with toString().
// =============================================================================
function PaneportEngine(emit) {
  // A viewer this many frames behind skips to the next keyframe instead of lagging.
  const MAX_DECODE_QUEUE = 3;
  const PING_INTERVAL_MS = 1000;
  const RECONNECT_DELAY_MS = 1000;

  let session = null;           // { host, port, name } while showing a display
  let ws = null, retryTimer = null, pingTimer = null, statsTimer = null;
  let decoder = null, configured = false, waitingForKeyframe = true, codec = 'not configured';
  let canvas = null, ctx = null;
  let clockSamples = [], clockOffset = null, lastRtt = null;
  let frameNumber = 0;
  const inFlight = new Map();   // frame number → timing, until the frame is shown
  let stats = newStatsWindow();

  // The pointer is drawn on its own transparent layer, so moving it never waits for video.
  let pointerCanvas = null, pointerCtx = null;
  let pointerShape = null, pointerState = null, pointerDrawn = null;
  let pointerMessages = 0;      // for the overlay's diagnostic line

  const nextFrame = (typeof requestAnimationFrame === 'function')
    ? cb => requestAnimationFrame(cb)
    : cb => setTimeout(cb, 0);

  function status(text) { emit({ type: 'status', text }); }

  // ---------- stats ----------

  function newStatsWindow() {
    return { total: [], encode: [], network: [], decode: [], browser: [], pointer: [], shown: 0, bytes: 0, drops: 0 };
  }

  function recordFrame(timing, decodedAt, shownAt) {
    stats.shown++;
    stats.decode.push(decodedAt - timing.arrivedAt);
    stats.browser.push(shownAt - decodedAt);
    if (clockOffset === null) return;
    stats.encode.push((timing.sentMicros - timing.capturedMicros) / 1000);
    stats.network.push(Math.max(0, timing.arrivedAt + clockOffset - timing.sentMicros / 1000));
    stats.total.push(shownAt + clockOffset - timing.capturedMicros / 1000);
  }

  function reportStats() {
    if (!session || !ws || ws.readyState !== WebSocket.OPEN) { stats = newStatsWindow(); return; }
    const avg = PaneportProtocol.average;
    const summary = {
      total: avg(stats.total), encode: avg(stats.encode), network: avg(stats.network),
      decode: avg(stats.decode), browser: avg(stats.browser), pointer: avg(stats.pointer),
      rtt: lastRtt, fps: stats.shown, mbps: stats.bytes * 8 / 1e6, drops: stats.drops,
    };
    try { ws.send('s:' + JSON.stringify(summary)); } catch (e) {}
    emit({
      type: 'stats', stats: summary, worst: PaneportProtocol.maximum(stats.total),
      width: canvas ? canvas.width : 0, height: canvas ? canvas.height : 0, synced: clockOffset !== null,
      pointerInfo: {
        messages: pointerMessages, hasShape: !!pointerShape,
        visible: !!(pointerState && pointerState.visible),
        x: pointerState ? Math.round(pointerState.x) : null, y: pointerState ? Math.round(pointerState.y) : null,
        layer: pointerCanvas ? pointerCanvas.width + '×' + pointerCanvas.height : 'none',
      },
    });
    pointerMessages = 0;
    stats = newStatsWindow();
  }

  // ---------- clock sync ----------

  function ping() {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send('p:' + performance.now());
  }

  function onPong(text) {
    const sample = PaneportProtocol.clockSample(text, performance.now());
    lastRtt = sample.rtt;
    clockSamples.push(sample);
    if (clockSamples.length > 20) clockSamples.shift();
    clockOffset = PaneportProtocol.bestOffset(clockSamples);
  }

  // ---------- pointer ----------

  function matchPointerLayerToVideo() {
    if (!pointerCanvas || !canvas) return;
    if (pointerCanvas.width !== canvas.width || pointerCanvas.height !== canvas.height) {
      pointerCanvas.width = canvas.width;
      pointerCanvas.height = canvas.height;
      pointerDrawn = null;
    }
  }

  function drawPointer() {
    if (!pointerCtx) return;
    if (pointerDrawn) {
      const d = pointerDrawn;
      pointerCtx.clearRect(d.x - 2, d.y - 2, d.w + 4, d.h + 4);
      pointerDrawn = null;
    }
    if (!pointerState || !pointerState.visible) return;
    if (!pointerShape) { drawFallbackArrow(); return; }
    const x = Math.round(pointerState.x - pointerShape.hx);
    const y = Math.round(pointerState.y - pointerShape.hy);
    pointerCtx.drawImage(pointerShape.image, x, y, pointerShape.w, pointerShape.h);
    pointerDrawn = { x, y, w: Math.ceil(pointerShape.w), h: Math.ceil(pointerShape.h) };
  }

  /** A plain arrow, used until the Mac's pointer image arrives. */
  function drawFallbackArrow() {
    const x = Math.round(pointerState.x), y = Math.round(pointerState.y);
    const c = pointerCtx;
    c.beginPath();
    c.moveTo(x, y);
    c.lineTo(x, y + 17);
    c.lineTo(x + 4, y + 13);
    c.lineTo(x + 7, y + 20);
    c.lineTo(x + 10, y + 19);
    c.lineTo(x + 7, y + 12);
    c.lineTo(x + 12, y + 12);
    c.closePath();
    c.fillStyle = '#000';
    c.strokeStyle = '#fff';
    c.lineWidth = 1.5;
    c.fill();
    c.stroke();
    pointerDrawn = { x: x - 1, y: y - 1, w: 15, h: 23 };
  }

  function onPointerMove(text) {
    pointerState = PaneportProtocol.parsePointerMove(text);
    pointerMessages++;
    if (clockOffset !== null && pointerState.visible) {
      stats.pointer.push(Math.max(0, performance.now() + clockOffset - pointerState.micros / 1000));
    }
    drawPointer();
  }

  async function onPointerShape(text) {
    try {
      const shape = JSON.parse(text.slice(2));
      const binary = atob(shape.png);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      const image = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
      if (pointerShape && pointerShape.image.close) pointerShape.image.close();
      pointerShape = { image, w: shape.w, h: shape.h, hx: shape.hx, hy: shape.hy };
      drawPointer();
    } catch (e) {
      // A bad shape just keeps the previous one.
    }
  }

  // ---------- video ----------

  function makeDecoder() {
    if (decoder && decoder.state !== 'closed') decoder.close();
    configured = false;
    waitingForKeyframe = true;
    inFlight.clear();
    decoder = new VideoDecoder({
      output: frame => {
        const decodedAt = performance.now();
        const timing = inFlight.get(frame.timestamp);
        inFlight.delete(frame.timestamp);
        if (!ctx) { frame.close(); return; }
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth;
          canvas.height = frame.displayHeight;
          matchPointerLayerToVideo();
          drawPointer();
        }
        ctx.drawImage(frame, 0, 0);
        frame.close();
        // The browser shows the drawing on its next frame; count that as "on screen".
        if (timing) nextFrame(() => recordFrame(timing, decodedAt, performance.now()));
      },
      error: e => {
        status('decoder error (' + codec + '): ' + e.name + ': ' + e.message);
        makeDecoder();
        requestKeyframe();
      },
    });
  }

  function requestKeyframe() {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send('k');
  }

  function onFrame(buffer) {
    const arrivedAt = performance.now();
    const frame = PaneportProtocol.parseFrame(buffer);
    if (!frame) return;
    stats.bytes += buffer.byteLength;

    if (frame.isKeyframe && !configured) {
      const found = PaneportProtocol.codecFromAnnexB(frame.payload);
      if (!found) return;
      codec = found;
      decoder.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
      configured = true;
    }
    if (!configured || (waitingForKeyframe && !frame.isKeyframe)) return;

    if (!frame.isKeyframe && decoder.decodeQueueSize > MAX_DECODE_QUEUE) {
      waitingForKeyframe = true;
      stats.drops++;
      requestKeyframe();
      return;
    }
    waitingForKeyframe = false;

    frameNumber++;
    inFlight.set(frameNumber, { capturedMicros: frame.capturedMicros, sentMicros: frame.sentMicros, arrivedAt });
    if (inFlight.size > 120) inFlight.delete(inFlight.keys().next().value);
    decoder.decode(new EncodedVideoChunk({
      type: frame.isKeyframe ? 'key' : 'delta', timestamp: frameNumber, data: frame.payload,
    }));
  }

  // ---------- connection ----------

  function onHello(text) {
    const hello = PaneportProtocol.parseHello(text);
    if (hello && hello.protocol !== PaneportProtocol.VERSION) {
      status('This page (protocol ' + PaneportProtocol.VERSION + ') doesn\'t match the Mac (protocol ' +
        hello.protocol + ', Paneport ' + hello.app + '). Reload the page, or open the Mac\'s address and save it again.');
    }
  }

  function connect() {
    if (!session) return;
    makeDecoder();
    clockSamples = [];
    clockOffset = null;
    lastRtt = null;
    status('connecting…');

    ws = new WebSocket('ws://' + session.host + ':' + session.port);
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      status('');
      for (let i = 0; i < 5; i++) setTimeout(ping, i * 100);   // quick first clock sync
      clearInterval(pingTimer);
      pingTimer = setInterval(ping, PING_INTERVAL_MS);
    };
    ws.onclose = () => {
      clearInterval(pingTimer);
      status('disconnected, retrying…');
      retryTimer = setTimeout(connect, RECONNECT_DELAY_MS);
    };
    ws.onmessage = e => {
      if (typeof e.data !== 'string') { onFrame(e.data); return; }
      const text = e.data;
      if (text.startsWith('m:')) onPointerMove(text);
      else if (text.startsWith('c:')) onPointerShape(text);
      else if (text.startsWith('q:')) onPong(text);
      else if (text.startsWith('h:')) onHello(text);
    };
  }

  function stop() {
    session = null;
    clearTimeout(retryTimer);
    clearInterval(pingTimer);
    clearInterval(statsTimer);
    if (ws) { ws.onclose = null; ws.close(); ws = null; }
    if (decoder && decoder.state !== 'closed') decoder.close();
    decoder = null;
    canvas = ctx = null;
    pointerCanvas = pointerCtx = null;
    pointerState = pointerDrawn = null;
    inFlight.clear();
  }

  return function handle(message) {
    if (message.type === 'start') {
      stop();
      if (typeof VideoDecoder === 'undefined') { emit({ type: 'unsupported' }); return; }
      session = { host: message.host, port: message.port, name: message.name };
      canvas = message.canvas;
      ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
      pointerCanvas = message.pointer || null;
      pointerCtx = pointerCanvas ? pointerCanvas.getContext('2d', { desynchronized: true }) : null;
      statsTimer = setInterval(reportStats, 1000);
      connect();
    } else if (message.type === 'stop') {
      stop();
    }
  };
}

// =============================================================================
// Page
// =============================================================================

let engineMode = null;        // 'worker' or 'inline'
let worker = null, inlineEngine = null;

function useInlineEngine(reason) {
  if (worker) { worker.terminate(); worker = null; }
  if (engineMode !== 'inline') console.warn('Paneport: decoding on the main thread (' + reason + ')');
  engineMode = 'inline';
  inlineEngine = PaneportEngine(onEngineMessage);
}

function startEngine() {
  if (!HTMLCanvasElement.prototype.transferControlToOffscreen) { useInlineEngine('no OffscreenCanvas'); return; }
  try {
    const source =
      'const PaneportProtocol = (' + PaneportProtocolFactory.toString() + ')();\n' +
      'const PaneportEngine = ' + PaneportEngine.toString() + ';\n' +
      'const handle = PaneportEngine(m => self.postMessage(m));\n' +
      'self.onmessage = e => handle(e.data);\n';
    worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
    worker.onmessage = e => onEngineMessage(e.data);
    worker.onerror = e => {
      if (e.preventDefault) e.preventDefault();
      if (engineMode !== 'worker') return;
      useInlineEngine('worker error: ' + (e.message || 'unknown'));
      if (current) startSession();
    };
    engineMode = 'worker';
  } catch (e) {
    useInlineEngine('worker blocked: ' + e.message);
  }
}

/** Fresh video and pointer canvases (a canvas can only be handed to a worker once). */
function newCanvases() {
  const video = document.createElement('canvas');
  video.id = 'screen';
  const oldVideo = document.getElementById('screen');
  if (oldVideo) oldVideo.replaceWith(video); else document.body.prepend(video);

  const pointer = document.createElement('canvas');
  pointer.id = 'pointer';
  pointer.style.zIndex = '1';
  pointer.style.pointerEvents = 'none';
  const oldPointer = document.getElementById('pointer');
  if (oldPointer) oldPointer.replaceWith(pointer); else video.after(pointer);
  return { video, pointer };
}

function startSession() {
  const { video, pointer } = newCanvases();
  const message = { type: 'start', host: hostEl.value.trim().split(':')[0], port: current.port, name: current.name };
  if (engineMode === 'worker') {
    message.canvas = video.transferControlToOffscreen();
    message.pointer = pointer.transferControlToOffscreen();
    worker.postMessage(message, [message.canvas, message.pointer]);
  } else {
    message.canvas = video;
    message.pointer = pointer;
    inlineEngine(message);
  }
}

function stopSession() {
  if (engineMode === 'worker' && worker) worker.postMessage({ type: 'stop' });
  else if (inlineEngine) inlineEngine({ type: 'stop' });
  newCanvases();
}

// ---------- stats overlay ----------

const statsEl = document.createElement('div');
statsEl.style.cssText =
  'position:fixed;top:10px;right:10px;z-index:5;padding:10px 12px;border-radius:8px;' +
  'background:rgba(0,0,0,.72);color:#ddd;font:12px/1.5 ui-monospace,Consolas,monospace;white-space:pre;' +
  'pointer-events:none;display:none;border:1px solid rgba(255,255,255,.12)';
document.body.appendChild(statsEl);

let showStats = true;
try { showStats = localStorage.getItem(STATS_KEY) !== '0'; } catch (e) {}

document.addEventListener('keydown', e => {
  if ((e.key === 's' || e.key === 'S') && current) {
    showStats = !showStats;
    try { localStorage.setItem(STATS_KEY, showStats ? '1' : '0'); } catch (err) {}
    statsEl.style.display = showStats ? 'block' : 'none';
  }
});

const ms = v => (v === null || v === undefined) ? '   –  ' : (v < 10 ? v.toFixed(1) : v.toFixed(0)).padStart(5) + ' ms';

function renderStats(m) {
  const s = m.stats;
  statsEl.style.display = showStats ? 'block' : 'none';
  statsEl.textContent =
    current.name + ' · ' + m.width + '×' + m.height + ' · ' + (engineMode === 'worker' ? 'worker' : 'main thread') + '\n' +
    (m.synced ? '' : 'syncing clocks…\n') +
    'delay        ' + ms(s.total) + '   max ' + ms(m.worst) + '\n' +
    ' encode Mac  ' + ms(s.encode) + '\n' +
    ' network     ' + ms(s.network) + '\n' +
    ' decode PC   ' + ms(s.decode) + '\n' +
    ' browser     ' + ms(s.browser) + '\n' +
    (s.pointer !== null ? 'pointer      ' + ms(s.pointer) + '   (drawn on PC)\n' : '') +
    pointerDiagnostics(m.pointerInfo) +
    'round trip   ' + ms(s.rtt) + '\n' +
    String(s.fps).padStart(3) + ' fps · ' + s.mbps.toFixed(1) + ' Mbit/s · ' + s.drops + ' dropped\n' +
    '+ monitor lag (not measured) · S hides';
}

/** One line saying whether pointer updates arrive and what the page does with them. */
function pointerDiagnostics(p) {
  if (!p) return '';
  if (p.messages === 0 && p.x === null) return 'pointer: no updates from the Mac yet\n';
  return 'pointer: ' + p.messages + ' updates/s · ' + (p.visible ? 'on this screen' : 'elsewhere') +
    (p.x !== null ? ' at ' + p.x + ',' + p.y : '') + ' · image ' + (p.hasShape ? 'yes' : 'no') +
    ' · layer ' + p.layer + '\n';
}

function onEngineMessage(m) {
  if (m.type === 'status') {
    statusEl.textContent = m.text;
  } else if (m.type === 'unsupported') {
    if (engineMode === 'worker') {
      useInlineEngine('no decoder in worker');
      if (current) startSession();
    } else {
      help.textContent = 'This browser cannot decode video here. Use Edge or Chrome with the saved page.';
    }
  } else if (m.type === 'stats' && current) {
    renderStats(m);
  }
}

// ---------- display picker ----------

function renderPicker() {
  const box = document.getElementById('buttons');
  box.textContent = '';
  if (!displays.length) { box.textContent = 'No displays are streaming. Press Start on the Mac.'; return; }
  for (const d of displays) {
    const button = document.createElement('button');
    button.className = 'display';
    button.textContent = d.name;
    const size = document.createElement('small');
    size.textContent = d.width + ' × ' + d.height;
    button.appendChild(size);
    button.onclick = () => begin(d);
    box.appendChild(button);
  }
}

/** Offers the Windows app when the Mac has one to download. */
async function showDownloadLink() {
  const existing = document.getElementById('download');
  if (existing) existing.remove();
  try {
    const host = hostEl.value.trim();
    const response = await fetch('http://' + host + '/version', { cache: 'no-store' });
    const info = await response.json();
    if (!info.windowsReceiver || !navigator.userAgent.includes('Windows')) return;
    const link = document.createElement('a');
    link.id = 'download';
    link.className = 'hint';
    link.href = 'http://' + host + info.windowsReceiver.path;
    link.textContent = 'Get the Paneport app for Windows (version ' + info.windowsReceiver.version + ') for even lower delay';
    link.style.color = '#0a84ff';
    document.getElementById('buttons').after(link);
  } catch (e) {
    // An older Mac app without /version: no download to offer.
  }
}

async function loadDisplayList() {
  try {
    const response = await fetch('http://' + hostEl.value.trim() + '/displays.json', { cache: 'no-store' });
    displays = await response.json();
  } catch (e) {
    displays = (typeof BAKED !== 'undefined') ? BAKED : [];
  }
  renderPicker();
  showDownloadLink();
}

hostEl.addEventListener('change', () => {
  saveHost(hostEl.value.trim());
  loadDisplayList();
});

function begin(display) {
  if (!('VideoDecoder' in window)) return;
  current = display;
  saveHost(hostEl.value.trim());
  panel.classList.add('hidden');
  document.documentElement.requestFullscreen().catch(() => {});
  if (navigator.wakeLock) navigator.wakeLock.request('screen').catch(() => {});
  if (!engineMode) startEngine();
  startSession();
}

function leave() {
  current = null;
  stopSession();
  statusEl.textContent = '';
  statsEl.style.display = 'none';
  panel.classList.remove('hidden');
  loadDisplayList();
}

document.addEventListener('fullscreenchange', () => { if (!document.fullscreenElement && current) leave(); });
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && current && navigator.wakeLock) navigator.wakeLock.request('screen').catch(() => {});
});

renderPicker();
loadDisplayList();
})();
