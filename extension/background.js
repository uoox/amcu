// amcu bridge — background service worker.
//
// Connects to the amcu native messaging host (the `amcu` binary, launched by
// the browser through the manifest `amcu browser install` writes) and answers
// its requests. Reading goes through the content script; trusted input,
// screenshots, evaluation and console/network capture go through the debugger
// protocol via chrome.debugger.
//
// No tokens and no listening ports: the browser launches the host itself and
// enforces which extension may talk to it.

const HOST_NAME = 'cc.uoox.amcu';
const VERSION = chrome.runtime.getManifest().version;
const KEEPALIVE_ALARM = 'amcu-keepalive';

// ---------------------------------------------------------------------------
// Errors

class BridgeError extends Error {
  constructor(code, message, nextSteps = []) {
    super(message);
    this.code = code;
    this.nextSteps = nextSteps;
  }
  toJSON() {
    return { code: this.code, message: this.message, nextSteps: this.nextSteps };
  }
}

function asBridgeError(error) {
  if (error instanceof BridgeError) return error;
  if (error && error.code && error.message && Array.isArray(error.nextSteps)) {
    return new BridgeError(error.code, error.message, error.nextSteps);
  }
  const message = String(error && error.message || error);
  if (/Cannot find a next page in history/i.test(message)) {
    return new BridgeError('unsupported', 'this tab has no page to go to in that direction', ['Use `amcu browser navigate --url …` instead.']);
  }
  if (/Another debugger is already attached/i.test(message)) {
    return new BridgeError('unsupported', 'another debugger is attached to this tab (DevTools, or another automation extension)', [
      'Close DevTools for that tab, or detach the other tool, then retry.'
    ]);
  }
  if (/Cannot access|cannot be scripted|Cannot attach|chrome:\/\/|Extension manifest must request permission/i.test(message)) {
    return new BridgeError('unsupported', `this page cannot be automated: ${message}`, [
      'chrome:// pages, the Web Store and other browser-owned pages are off limits to extensions.',
      'file:// URLs need "Allow access to file URLs" enabled for the amcu bridge extension.'
    ]);
  }
  return new BridgeError('page_error', message);
}

// ---------------------------------------------------------------------------
// Small utilities

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new BridgeError('timeout', `${what} did not complete within ${ms} ms`, [
      'The page may be busy or blocked by a modal dialog; `amcu browser dialog --accept` handles an open alert/confirm/prompt.',
      'Raise the limit with --timeout SECONDS if the operation is legitimately slow.'
    ])), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function truncate(text, max = 200) {
  text = String(text === undefined ? '' : text);
  return text.length > max ? text.slice(0, max) + '…' : text;
}

let nonceCounter = 0;
function nonce() {
  nonceCounter += 1;
  return `${Date.now().toString(36)}-${nonceCounter}`;
}

// ---------------------------------------------------------------------------
// Native host connection

let port = null;
let connectTimer = null;
let backoffMs = 1000;
const status = { state: 'disconnected', error: null, since: null, requests: 0 };

function setStatus(update) {
  Object.assign(status, update);
  chrome.storage.session.set({ status }).catch(() => {});
}

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    scheduleReconnect(String(error && error.message || error));
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError ? chrome.runtime.lastError.message : 'host disconnected';
    port = null;
    scheduleReconnect(reason);
  });
  let brands = [];
  try {
    brands = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => `${b.brand} ${b.version}`);
  } catch (_) { /* older browsers */ }
  post({ type: 'hello', version: VERSION, brands, userAgent: navigator.userAgent, extensionId: chrome.runtime.id });
  backoffMs = 1000;
  setStatus({ state: 'connected', error: null, since: Date.now() });
}

function scheduleReconnect(reason) {
  setStatus({ state: 'disconnected', error: reason });
  if (connectTimer) return;
  connectTimer = setTimeout(() => {
    connectTimer = null;
    connect();
  }, backoffMs);
  backoffMs = Math.min(backoffMs * 2, 30000);
}

const recentErrors = [];
function noteError(where, error) {
  recentErrors.push({ at: Date.now(), where, message: String(error && error.message || error) });
  while (recentErrors.length > 20) recentErrors.shift();
}

function post(message) {
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (error) {
    noteError('post', error);
    // A message the port cannot serialise must not take the connection down;
    // answer with an error instead so the caller hears about it.
    if (message && message.type === 'response' && message.ok) {
      try {
        port.postMessage({ type: 'response', id: message.id, ok: false, error: new BridgeError('page_error', `the extension could not serialise its reply: ${error && error.message || error}`).toJSON() });
        return;
      } catch (_) { /* fall through */ }
    }
    scheduleReconnect(String(error && error.message || error));
  }
}

function onHostMessage(message) {
  if (!message || typeof message !== 'object') return;
  if (message.type === 'ping') {
    post({ type: 'pong' });
    return;
  }
  if (message.type !== 'request') return;
  status.requests += 1;
  handleRequest(message.method, message.params || {})
    .then(result => post({ type: 'response', id: message.id, ok: true, result }))
    .catch(error => {
      noteError(message.method, error);
      post({ type: 'response', id: message.id, ok: false, error: asBridgeError(error).toJSON() });
    });
}

// The worker is idle-terminated after ~30 s without activity; any extension API
// call resets that clock, and an alarm brings it back if it does go away.
setInterval(() => chrome.runtime.getPlatformInfo(() => {}), 20000);
chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === KEEPALIVE_ALARM) connect();
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();

// ---------------------------------------------------------------------------
// The automation window.
//
// Tabs the CLI opens live in a window of amcu's own, created unfocused so the
// user's focus, active tab and window order are never touched. Inside that
// window tabs can be freely activated — activation is only visible when a
// window is focused — which keeps them rendering, so screenshots work without
// ever surfacing anything. Its first tab is a pinned extension page that says
// what the window is, and keeps the window alive between tasks.

const AMCU_WINDOW_KEY = 'amcuWindow';

async function amcuWindowId() {
  const stored = await chrome.storage.session.get(AMCU_WINDOW_KEY);
  const id = stored[AMCU_WINDOW_KEY];
  if (id === undefined || id === null) return null;
  try {
    const win = await chrome.windows.get(id);
    if (win && win.type === 'normal') return id;
  } catch (_) { /* closed */ }
  await chrome.storage.session.remove(AMCU_WINDOW_KEY);
  return null;
}

async function ensureAmcuWindow() {
  const existing = await amcuWindowId();
  if (existing !== null) return existing;
  const win = await chrome.windows.create({
    url: chrome.runtime.getURL('window.html'),
    focused: false,
    type: 'normal',
    width: 1280,
    height: 850
  });
  await chrome.storage.session.set({ [AMCU_WINDOW_KEY]: win.id });
  const first = win.tabs && win.tabs[0];
  if (first) await chrome.tabs.update(first.id, { pinned: true }).catch(() => {});
  return win.id;
}

async function inAmcuWindow(tab) {
  const id = await amcuWindowId();
  return id !== null && tab.windowId === id;
}

// ---------------------------------------------------------------------------
// Sessions: each CLI --session has its own current tab.

async function currentTabId(session) {
  const key = 'session:' + session;
  const stored = await chrome.storage.session.get(key);
  return stored[key] || null;
}

async function setCurrentTab(session, tabId) {
  const key = 'session:' + session;
  if (tabId) await chrome.storage.session.set({ [key]: tabId });
  else await chrome.storage.session.remove(key);
}

async function getTab(tabId) {
  try {
    return await chrome.tabs.get(tabId);
  } catch (_) {
    return null;
  }
}

// `acting: true` marks the commands that change the page (navigate, click,
// type, eval, …). Reading the tab the user happens to be looking at is fine;
// silently *acting* on it is exactly the "my tab suddenly changed under me"
// failure, so an acting command with neither a pinned session tab nor an
// explicit --tab refuses instead of falling through to the user's tab.
async function resolveTab(params, { acting = false } = {}) {
  if (params.tab !== undefined && params.tab !== null) {
    const tab = await getTab(params.tab);
    if (!tab) {
      throw new BridgeError('tab_not_found', `no tab with id ${params.tab}`, [
        'Run `amcu browser tabs` to list tabs with their ids.'
      ]);
    }
    return tab;
  }
  const session = params.session || 'default';
  const current = await currentTabId(session);
  if (current) {
    const tab = await getTab(current);
    if (tab) return tab;
    await setCurrentTab(session, null);
  }
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const [any] = active ? [active] : await chrome.tabs.query({ active: true });
  if (any) {
    if (acting && !(await inAmcuWindow(any))) {
      throw new BridgeError('no_current_tab', `this session has no current tab, and acting would hit the tab the user is looking at ("${truncate(any.title, 80)}")`, [
        'Open a tab of your own with `amcu browser tab --new --url …` — it lives in amcu\'s background window and never disturbs the user.',
        'To act on an existing tab deliberately: `amcu browser tabs`, then `tab --select ID` or --tab ID.'
      ]);
    }
    return any;
  }
  throw new BridgeError('tab_not_found', 'the browser has no tabs', ['Open one with `amcu browser tab --new --url https://…`.']);
}

function tabSummary(tab, extra = {}) {
  return Object.assign({
    id: tab.id,
    windowId: tab.windowId,
    index: tab.index,
    active: !!tab.active,
    title: tab.title || '',
    url: tab.url || tab.pendingUrl || '',
    status: tab.status || '',
    attached: attached.has(tab.id)
  }, extra);
}

// ---------------------------------------------------------------------------
// Content script calls

async function callFrame(tabId, frameId, op, params, timeoutMs = 10000) {
  const message = { __amcu: true, op, params };
  const send = () => chrome.tabs.sendMessage(tabId, message, { frameId });
  let response;
  try {
    response = await withTimeout(send(), timeoutMs, `content script '${op}'`);
  } catch (error) {
    if (error instanceof BridgeError && error.code === 'timeout') throw error;
    if (/No frame with id/i.test(String(error && error.message))) {
      throw new BridgeError('stale_snapshot', `frame ${frameId} no longer exists in this tab (the page navigated or reloaded)`, [
        'Re-run `amcu browser snapshot`; frame ids and refs are assigned per document.'
      ]);
    }
    // Not injected yet (or the page reloaded): inject and retry once.
    await inject(tabId, frameId);
    response = await withTimeout(send(), timeoutMs, `content script '${op}'`);
  }
  if (!response) throw new BridgeError('page_error', `no response from the page for '${op}'`);
  if (!response.ok) throw asBridgeError(response.error);
  return response.result;
}

async function inject(tabId, frameId) {
  const target = frameId === undefined ? { tabId, allFrames: true } : { tabId, frameIds: [frameId] };
  try {
    await chrome.scripting.executeScript({ target, files: ['content.js'] });
  } catch (error) {
    if (frameId === undefined) {
      // One unscriptable child frame must not take the whole page down with it.
      try {
        await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
        return;
      } catch (inner) {
        throw asBridgeError(inner);
      }
    }
    throw asBridgeError(error);
  }
}

async function listFrames(tabId) {
  const frames = await chrome.webNavigation.getAllFrames({ tabId }) || [];
  return frames.filter(f => f.frameId >= 0 && !f.errorOccurred);
}

// ---------------------------------------------------------------------------
// Script-bound click handlers. The DOM shows inline handlers and framework
// attributes; a listener added with addEventListener is invisible to it. The
// debugger protocol can list them (`DOMDebugger.getEventListeners` over the
// document subtree — one call, milliseconds), so while a tab is attached
// anyway — after its first action — the snapshot asks for them. This never
// attaches on its own: a read must not raise the infobar.
//
// The protocol names elements by backendNodeId, which a content script cannot
// resolve, so `DOM.getDocument` supplies the tree and the same pre-order walk
// the content script performs (`domOrderElements`: open shadow roots first,
// then light children, elements only) turns each id into a DOM-order position
// plus a tag|id|class signature. The content script re-derives the position
// and checks the signature; a mismatch (the page mutated in between) is
// dropped rather than guessed at. Delegated handlers (React attaches at the
// root) are not on the element and are not found; direct ones (vanilla,
// jQuery, Vue, Angular, Svelte) are.
//
// (The command-line API `getEventListeners` would be simpler, but a
// chrome.debugger session receives an empty answer from it where a raw CDP
// session on the same tab lists everything — measured, not assumed.)

const LISTENER_TYPES = new Set(['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'touchstart', 'touchend']);
const LISTENER_NODE_LIMIT = 12000;
const LISTENER_HINT_LIMIT = 1500;

async function listenerHints(tabId, frameId) {
  if (!attached.has(tabId)) return null;
  try {
    const evalParams = { expression: 'document' };
    if (frameId !== 0) evalParams.contextId = await executionContextFor(tabId, frameId);
    const doc = await cdp(tabId, 'Runtime.evaluate', evalParams, 3000);
    if (!doc.result || !doc.result.objectId) return null;
    const found = await cdp(tabId, 'DOMDebugger.getEventListeners', { objectId: doc.result.objectId, depth: -1, pierce: true }, 5000);
    const wanted = new Set();
    for (const listener of found.listeners || []) {
      if (LISTENER_TYPES.has(listener.type) && listener.backendNodeId) wanted.add(listener.backendNodeId);
    }
    if (!wanted.size) return [];

    const tree = await cdp(tabId, 'DOM.getDocument', { depth: -1, pierce: true }, 10000);
    let documentNode = tree.root;
    if (frameId !== 0) {
      const cdpFrameId = (await matchFrames(tabId)).get(frameId);
      documentNode = cdpFrameId ? findFrameDocument(tree.root, cdpFrameId) : null;
      if (!documentNode) return null;
    }
    const html = (documentNode.children || []).find(n => n.nodeType === 1);
    if (!html) return null;

    // Pre-order, open shadow roots before light children, elements only —
    // the content script's domOrderElements, expressed over protocol nodes.
    const hints = [];
    const stack = [html];
    let index = -1;
    while (stack.length && hints.length < LISTENER_HINT_LIMIT) {
      const node = stack.pop();
      index += 1;
      if (index > LISTENER_NODE_LIMIT) break;
      if (wanted.has(node.backendNodeId) && node.nodeName !== 'HTML' && node.nodeName !== 'BODY') {
        hints.push([index, signatureOfNode(node)]);
      }
      const kids = [];
      for (const root of node.shadowRoots || []) {
        if (root.shadowRootType !== 'open') continue;
        for (const c of root.children || []) if (c.nodeType === 1) kids.push(c);
      }
      for (const c of node.children || []) if (c.nodeType === 1) kids.push(c);
      for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
    }
    return hints;
  } catch (error) {
    noteError('listenerHints', error);
    return null; // a frame without a reachable context, or a page mid-navigation: the outline stands on its own
  }
}

function signatureOfNode(node) {
  const attrs = node.attributes || [];
  let id = '';
  let cls = '';
  for (let i = 0; i + 1 < attrs.length; i += 2) {
    if (attrs[i] === 'id') id = attrs[i + 1];
    else if (attrs[i] === 'class') cls = attrs[i + 1];
  }
  return node.nodeName + '|' + id + '|' + cls.slice(0, 40);
}

function findFrameDocument(node, cdpFrameId) {
  if (node.frameId === cdpFrameId && node.contentDocument) return node.contentDocument;
  for (const child of node.children || []) {
    const hit = findFrameDocument(child, cdpFrameId);
    if (hit) return hit;
  }
  for (const root of node.shadowRoots || []) {
    const hit = findFrameDocument(root, cdpFrameId);
    if (hit) return hit;
  }
  if (node.contentDocument) return findFrameDocument(node.contentDocument, cdpFrameId);
  return null;
}

// ---------------------------------------------------------------------------
// Tabs an action opened. A target=_blank link or window.open() looks like a
// no-op from the acting tab — nothing navigated, little changed — while the
// interesting page is somewhere else. Tab creation is recorded as it happens
// and matched back to the acting tab by opener; when the acting tab was the
// session's current tab, the new one takes its place, and the result says so.

const createdTabs = [];

chrome.tabs.onCreated.addListener(tab => {
  createdTabs.push({ id: tab.id, openerTabId: tab.openerTabId, at: Date.now() });
  while (createdTabs.length > 50) createdTabs.shift();
});

async function openedTabSince(openerId, since, params) {
  const hits = createdTabs.filter(t => t.at >= since && t.openerTabId === openerId);
  if (!hits.length) return null;
  const tab = await getTab(hits[hits.length - 1].id);
  if (!tab) return null;
  let nowCurrent = false;
  // Only a session tab is followed; an explicit --tab stays where it pointed.
  if (params.tab === undefined || params.tab === null) {
    const session = params.session || 'default';
    if ((await currentTabId(session)) === openerId) {
      await setCurrentTab(session, tab.id);
      nowCurrent = true;
    }
  }
  return tabSummary(tab, { nowCurrent, opened: hits.length });
}

// ---------------------------------------------------------------------------
// Secrets scoped to hosts. A key the secrets file restricts (KEY__DOMAINS=…)
// is typed only into a tab — and, for a frame-targeted field, a frame — whose
// host matches. The value has crossed the local pipe by now, but it never
// enters a page that is not the one it was meant for.

function hostMatches(host, pattern) {
  pattern = String(pattern || '').trim().toLowerCase();
  if (!pattern || !host) return false;
  if (pattern.startsWith('*.')) {
    const base = pattern.slice(2);
    return host === base || host.endsWith('.' + base);
  }
  return host === pattern;
}

async function requireSecretScope(tab, params, frameId) {
  const domains = params.secretDomains;
  if (!Array.isArray(domains) || !domains.length) return;
  const hostOf = url => {
    try { return new URL(url).hostname.toLowerCase(); } catch (_) { return ''; }
  };
  const places = [{ what: 'this tab', host: hostOf(tab.url || '') }];
  if (frameId && frameId !== 0) {
    let host = '';
    try {
      const frame = await chrome.webNavigation.getFrame({ tabId: tab.id, frameId });
      host = frame ? hostOf(frame.url || '') : '';
    } catch (_) { /* fails closed below */ }
    places.push({ what: `frame ${frameId}`, host });
  }
  for (const place of places) {
    if (domains.some(pattern => hostMatches(place.host, pattern))) continue;
    throw new BridgeError('secret_scope', `secret ${params.secretKey || ''} is restricted to ${domains.join(', ')}; ${place.what} is at ${place.host || '(unknown host)'}`, [
      'The secrets file limits where this key may be typed (KEY__DOMAINS=host,*.example.com). Check that the page is the one you meant — a look-alike host is exactly what this guard is for.',
      'If the restriction itself is wrong, widen KEY__DOMAINS in the secrets file.'
    ]);
  }
}

// A ref is `e12` for the main frame or `f<frameId>e12` for a child frame.
function parseRef(ref) {
  const match = /^(?:f(\d+))?e(\d+)$/.exec(String(ref || '').trim());
  if (!match) {
    throw new BridgeError('invalid_argument', `'${ref}' is not a ref`, [
      'Refs look like e12 (main frame) or f42e12 (frame 42), as printed by `amcu browser snapshot`.'
    ]);
  }
  return { frameId: match[1] ? parseInt(match[1], 10) : 0, local: 'e' + match[2] };
}

// ---------------------------------------------------------------------------
// Frame geometry.
//
// A point inside a child frame is translated to the top document's viewport
// using only browser-trusted data: the frame tree (webNavigation + CDP) and
// the geometry of each iframe's owner element (DOM.getBoxModel). No page script
// is consulted, so a hostile page cannot redirect a click aimed at one frame
// into another by forging messages.

// Matches the extension's frame ids (used to address content scripts) to CDP's
// frame ids (used to read geometry). Both label the same tree; they are matched
// structurally by parent and url, so it needs no cooperation from the page.
async function matchFrames(tabId) {
  const navFrames = await listFrames(tabId);
  const tree = await cdp(tabId, 'Page.getFrameTree');
  const cdpChildren = new Map(); // cdpParentId (or '') -> [cdp frame]
  (function walk(node, parentId) {
    const frame = node.frame;
    const key = parentId || '';
    if (!cdpChildren.has(key)) cdpChildren.set(key, []);
    cdpChildren.get(key).push(frame);
    for (const child of node.childFrames || []) walk(child, frame.id);
  })(tree.frameTree, null);

  const navChildren = new Map(); // extParentId -> [nav frame]
  for (const frame of navFrames) {
    if (frame.frameId === 0) continue;
    if (!navChildren.has(frame.parentFrameId)) navChildren.set(frame.parentFrameId, []);
    navChildren.get(frame.parentFrameId).push(frame);
  }

  const extToCdp = new Map();
  extToCdp.set(0, tree.frameTree.frame.id);
  const queue = [[0, tree.frameTree.frame.id]];
  while (queue.length) {
    const [extId, cdpId] = queue.shift();
    const exts = (navChildren.get(extId) || []).slice();
    const cdps = (cdpChildren.get(cdpId) || []).slice();
    for (const ext of exts) {
      // Prefer a same-url CDP child; fall back to positional order.
      let idx = cdps.findIndex(c => c.url === ext.url);
      if (idx < 0) idx = 0;
      const cdp = cdps.splice(idx, 1)[0];
      if (!cdp) continue;
      extToCdp.set(ext.frameId, cdp.id);
      queue.push([ext.frameId, cdp.id]);
    }
  }
  return extToCdp;
}

// The viewport origin of each frame in the top document, in CSS pixels.
async function frameOrigins(tabId) {
  const origins = new Map();
  origins.set(0, { x: 0, y: 0 });
  const navFrames = await listFrames(tabId);
  if (navFrames.length <= 1) return origins;
  const extToCdp = await matchFrames(tabId);
  for (const frame of navFrames) {
    if (frame.frameId === 0) continue;
    const cdpId = extToCdp.get(frame.frameId);
    if (!cdpId) continue;
    try {
      const owner = await cdp(tabId, 'DOM.getFrameOwner', { frameId: cdpId });
      const box = await cdp(tabId, 'DOM.getBoxModel', { backendNodeId: owner.backendNodeId });
      // content quad [x1,y1,x2,y2,x3,y3,x4,y4]; its top-left is the child frame's
      // viewport origin in the top document, already resolved through nesting.
      const c = box.model && box.model.content;
      if (c && c.length >= 2) origins.set(frame.frameId, { x: c[0], y: c[1] });
    } catch (_) { /* a frame with no box (detached, display:none) is unreachable anyway */ }
  }
  return origins;
}

async function toMainFramePoint(tabId, frameId, x, y) {
  if (frameId === 0) return { x, y };
  const origins = await frameOrigins(tabId);
  const origin = origins.get(frameId);
  if (!origin) {
    throw new BridgeError('unsupported', `cannot locate frame ${frameId} in the page`, [
      'Re-run `amcu browser snapshot`; the frame may have been removed or is not rendered.'
    ]);
  }
  return { x: x + origin.x, y: y + origin.y };
}

// ---------------------------------------------------------------------------
// Debugger (CDP)

const attached = new Map(); // tabId -> { console: [], network: Map, dialog, attachedAt }
const attaching = new Map();

const CONSOLE_LIMIT = 1000;
const NETWORK_LIMIT = 500;

async function ensureAttached(tabId) {
  if (attached.has(tabId)) return attached.get(tabId);
  if (attaching.has(tabId)) return attaching.get(tabId);
  const promise = (async () => {
    try {
      await chrome.debugger.attach({ tabId }, '1.3');
    } catch (error) {
      throw asBridgeError(error);
    }
    const entry = { console: [], network: new Map(), networkOrder: [], dialog: null, attachedAt: Date.now() };
    attached.set(tabId, entry);
    const send = (method, params) => chrome.debugger.sendCommand({ tabId }, method, params || {}).catch(() => {});
    await send('Page.enable');
    await send('Runtime.enable');
    await send('Log.enable');
    await send('Network.enable', { maxTotalBufferSize: 10 * 1024 * 1024, maxResourceBufferSize: 2 * 1024 * 1024 });
    await send('DOM.enable');
    // The page believes it has focus, so focus-dependent widgets behave as if
    // the user were there — required for typing into a background window.
    await send('Emulation.setFocusEmulationEnabled', { enabled: true });
    return entry;
  })();
  attaching.set(tabId, promise);
  try {
    return await promise;
  } finally {
    attaching.delete(tabId);
  }
}

async function cdp(tabId, method, params = {}, timeoutMs = 20000) {
  await ensureAttached(tabId);
  const call = chrome.debugger.sendCommand({ tabId }, method, params);
  try {
    return await withTimeout(call, timeoutMs, method);
  } catch (error) {
    throw asBridgeError(error);
  }
}

async function detach(tabId) {
  if (!attached.has(tabId)) return false;
  attached.delete(tabId);
  try {
    await chrome.debugger.detach({ tabId });
  } catch (_) { /* already gone */ }
  return true;
}

chrome.debugger.onDetach.addListener(source => {
  if (source.tabId !== undefined) attached.delete(source.tabId);
});

chrome.tabs.onRemoved.addListener(tabId => {
  attached.delete(tabId);
});

function formatRemoteObject(object) {
  if (!object) return '';
  if (object.type === 'string') return object.value;
  if (object.value !== undefined) return typeof object.value === 'object' ? JSON.stringify(object.value) : String(object.value);
  if (object.unserializableValue) return object.unserializableValue;
  if (object.description) return object.description;
  return object.type;
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  const entry = attached.get(source.tabId);
  if (!entry) return;
  switch (method) {
    case 'Runtime.consoleAPICalled': {
      const text = (params.args || []).map(formatRemoteObject).join(' ');
      pushConsole(entry, { level: params.type, text, timestamp: params.timestamp, source: 'console' });
      break;
    }
    case 'Runtime.exceptionThrown': {
      const details = params.exceptionDetails || {};
      const text = details.exception ? formatRemoteObject(details.exception) : details.text;
      pushConsole(entry, { level: 'error', text: `Uncaught ${text}`, timestamp: params.timestamp, source: 'exception', url: details.url, line: details.lineNumber });
      break;
    }
    case 'Log.entryAdded': {
      const e = params.entry || {};
      pushConsole(entry, { level: e.level, text: e.text, timestamp: e.timestamp, source: e.source, url: e.url, line: e.lineNumber });
      break;
    }
    case 'Page.javascriptDialogOpening':
      entry.dialog = { type: params.type, message: params.message, defaultPrompt: params.defaultPrompt, url: params.url, at: Date.now() };
      notifyDialog(source.tabId, entry.dialog);
      break;
    case 'Page.javascriptDialogClosed':
      entry.dialog = null;
      break;
    case 'Network.requestWillBeSent': {
      const r = params.request || {};
      const record = { id: params.requestId, method: r.method, url: r.url, type: params.type, status: null, statusText: '', mimeType: '', failed: null, timestamp: params.timestamp };
      entry.network.set(params.requestId, record);
      entry.networkOrder.push(params.requestId);
      while (entry.networkOrder.length > NETWORK_LIMIT) entry.network.delete(entry.networkOrder.shift());
      break;
    }
    case 'Network.responseReceived': {
      const record = entry.network.get(params.requestId);
      if (record) {
        record.status = params.response.status;
        record.statusText = params.response.statusText;
        record.mimeType = params.response.mimeType;
      }
      break;
    }
    case 'Network.loadingFailed': {
      const record = entry.network.get(params.requestId);
      if (record) record.failed = params.errorText || 'failed';
      break;
    }
    default:
      break;
  }
});

function pushConsole(entry, message) {
  entry.console.push(message);
  while (entry.console.length > CONSOLE_LIMIT) entry.console.shift();
}

// Input events block for as long as a dialog they opened stays open, so
// input commands race against the dialog notification and return early.
const dialogWaiters = new Map(); // tabId -> Set(resolve)

function notifyDialog(tabId, dialog) {
  const waiters = dialogWaiters.get(tabId);
  if (!waiters) return;
  for (const resolve of waiters) resolve(dialog);
  waiters.clear();
}

async function cdpInput(tabId, method, params, timeoutMs = 20000) {
  const entry = await ensureAttached(tabId);
  if (entry.dialog) return { dialog: entry.dialog };
  let resolveWaiter;
  const opened = new Promise(resolve => { resolveWaiter = resolve; });
  if (!dialogWaiters.has(tabId)) dialogWaiters.set(tabId, new Set());
  dialogWaiters.get(tabId).add(resolveWaiter);
  try {
    const command = chrome.debugger.sendCommand({ tabId }, method, params).then(result => ({ result }));
    return await withTimeout(Promise.race([command, opened.then(dialog => ({ dialog }))]), timeoutMs, method);
  } catch (error) {
    throw asBridgeError(error);
  } finally {
    const waiters = dialogWaiters.get(tabId);
    if (waiters) waiters.delete(resolveWaiter);
  }
}

function requireNoDialog(tabId) {
  const entry = attached.get(tabId);
  if (entry && entry.dialog) {
    throw new BridgeError('dialog_open', `a ${entry.dialog.type} dialog is open: "${truncate(entry.dialog.message)}"`, [
      'Handle it with `amcu browser dialog --accept [--text T]` or `amcu browser dialog --dismiss`, then retry.'
    ]);
  }
}

// ---------------------------------------------------------------------------
// Input plumbing

const MODIFIER_BITS = { alt: 1, ctrl: 2, meta: 4, shift: 8 };
const MODIFIER_ALIASES = { option: 'alt', opt: 'alt', control: 'ctrl', cmd: 'meta', command: 'meta', super: 'meta', win: 'meta' };

function modifierMask(list) {
  let mask = 0;
  for (const raw of list || []) {
    const name = MODIFIER_ALIASES[raw.toLowerCase()] || raw.toLowerCase();
    if (!(name in MODIFIER_BITS)) {
      throw new BridgeError('invalid_argument', `unknown modifier '${raw}'`, ['Use cmd, ctrl, alt, shift.']);
    }
    mask |= MODIFIER_BITS[name];
  }
  return mask;
}

const KEY_TABLE = {
  enter: { key: 'Enter', code: 'Enter', vk: 13, text: '\r' },
  return: { key: 'Enter', code: 'Enter', vk: 13, text: '\r' },
  tab: { key: 'Tab', code: 'Tab', vk: 9, text: '\t' },
  escape: { key: 'Escape', code: 'Escape', vk: 27 },
  esc: { key: 'Escape', code: 'Escape', vk: 27 },
  backspace: { key: 'Backspace', code: 'Backspace', vk: 8 },
  delete: { key: 'Delete', code: 'Delete', vk: 46 },
  del: { key: 'Delete', code: 'Delete', vk: 46 },
  insert: { key: 'Insert', code: 'Insert', vk: 45 },
  space: { key: ' ', code: 'Space', vk: 32, text: ' ' },
  ' ': { key: ' ', code: 'Space', vk: 32, text: ' ' },
  arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', vk: 37 },
  arrowup: { key: 'ArrowUp', code: 'ArrowUp', vk: 38 },
  arrowright: { key: 'ArrowRight', code: 'ArrowRight', vk: 39 },
  arrowdown: { key: 'ArrowDown', code: 'ArrowDown', vk: 40 },
  left: { key: 'ArrowLeft', code: 'ArrowLeft', vk: 37 },
  up: { key: 'ArrowUp', code: 'ArrowUp', vk: 38 },
  right: { key: 'ArrowRight', code: 'ArrowRight', vk: 39 },
  down: { key: 'ArrowDown', code: 'ArrowDown', vk: 40 },
  home: { key: 'Home', code: 'Home', vk: 36 },
  end: { key: 'End', code: 'End', vk: 35 },
  pageup: { key: 'PageUp', code: 'PageUp', vk: 33 },
  pagedown: { key: 'PageDown', code: 'PageDown', vk: 34 },
  capslock: { key: 'CapsLock', code: 'CapsLock', vk: 20 },
  '-': { key: '-', code: 'Minus', vk: 189, text: '-' },
  '=': { key: '=', code: 'Equal', vk: 187, text: '=' },
  '[': { key: '[', code: 'BracketLeft', vk: 219, text: '[' },
  ']': { key: ']', code: 'BracketRight', vk: 221, text: ']' },
  '\\': { key: '\\', code: 'Backslash', vk: 220, text: '\\' },
  ';': { key: ';', code: 'Semicolon', vk: 186, text: ';' },
  "'": { key: "'", code: 'Quote', vk: 222, text: "'" },
  ',': { key: ',', code: 'Comma', vk: 188, text: ',' },
  '.': { key: '.', code: 'Period', vk: 190, text: '.' },
  '/': { key: '/', code: 'Slash', vk: 191, text: '/' },
  '`': { key: '`', code: 'Backquote', vk: 192, text: '`' }
};
for (let i = 1; i <= 12; i++) KEY_TABLE['f' + i] = { key: 'F' + i, code: 'F' + i, vk: 111 + i };
for (let i = 0; i <= 9; i++) KEY_TABLE[String(i)] = { key: String(i), code: 'Digit' + i, vk: 48 + i, text: String(i) };
for (let c = 97; c <= 122; c++) {
  const letter = String.fromCharCode(c);
  KEY_TABLE[letter] = { key: letter, code: 'Key' + letter.toUpperCase(), vk: c - 32, text: letter };
}
const SHIFTED = { '1': '!', '2': '@', '3': '#', '4': '$', '5': '%', '6': '^', '7': '&', '8': '*', '9': '(', '0': ')', '-': '_', '=': '+', '[': '{', ']': '}', '\\': '|', ';': ':', "'": '"', ',': '<', '.': '>', '/': '?', '`': '~' };

// macOS handles editing shortcuts in the browser process, which synthetic
// events bypass; the debugger protocol lets us name the command instead.
function editingCommands(key, mask) {
  const meta = !!(mask & 4), shift = !!(mask & 8), alt = !!(mask & 1), ctrl = !!(mask & 2);
  const k = key.key;
  if (meta && !alt && !ctrl) {
    if (k === 'a') return ['selectAll'];
    if (k === 'c') return ['copy'];
    if (k === 'v') return ['paste'];
    if (k === 'x') return ['cut'];
    if (k === 'z') return [shift ? 'redo' : 'undo'];
    if (k === 'ArrowLeft') return [shift ? 'moveToLeftEndOfLineAndModifySelection' : 'moveToLeftEndOfLine'];
    if (k === 'ArrowRight') return [shift ? 'moveToRightEndOfLineAndModifySelection' : 'moveToRightEndOfLine'];
    if (k === 'ArrowUp') return [shift ? 'moveToBeginningOfDocumentAndModifySelection' : 'moveToBeginningOfDocument'];
    if (k === 'ArrowDown') return [shift ? 'moveToEndOfDocumentAndModifySelection' : 'moveToEndOfDocument'];
    if (k === 'Backspace') return ['deleteToBeginningOfLine'];
    return [];
  }
  if (alt && !meta && !ctrl) {
    if (k === 'ArrowLeft') return [shift ? 'moveWordLeftAndModifySelection' : 'moveWordLeft'];
    if (k === 'ArrowRight') return [shift ? 'moveWordRightAndModifySelection' : 'moveWordRight'];
    if (k === 'ArrowUp') return [shift ? 'moveParagraphBackwardAndModifySelection' : 'moveParagraphBackward'];
    if (k === 'ArrowDown') return [shift ? 'moveParagraphForwardAndModifySelection' : 'moveParagraphForward'];
    if (k === 'Backspace') return ['deleteWordBackward'];
    if (k === 'Delete') return ['deleteWordForward'];
    return [];
  }
  if (!meta && !alt && !ctrl) {
    if (k === 'Backspace') return ['deleteBackward'];
    if (k === 'Delete') return ['deleteForward'];
    if (k === 'ArrowLeft') return [shift ? 'moveLeftAndModifySelection' : 'moveLeft'];
    if (k === 'ArrowRight') return [shift ? 'moveRightAndModifySelection' : 'moveRight'];
    if (k === 'ArrowUp') return [shift ? 'moveUpAndModifySelection' : 'moveUp'];
    if (k === 'ArrowDown') return [shift ? 'moveDownAndModifySelection' : 'moveDown'];
    if (k === 'Home') return [shift ? 'moveToBeginningOfDocumentAndModifySelection' : 'scrollToBeginningOfDocument'];
    if (k === 'End') return [shift ? 'moveToEndOfDocumentAndModifySelection' : 'scrollToEndOfDocument'];
    if (k === 'PageUp') return [shift ? 'pageUpAndModifySelection' : 'scrollPageUp'];
    if (k === 'PageDown') return [shift ? 'pageDownAndModifySelection' : 'scrollPageDown'];
    if (k === 'Escape') return ['cancelOperation'];
  }
  return [];
}

function lookupKey(raw) {
  const name = String(raw);
  let entry = KEY_TABLE[name.toLowerCase()];
  let shift = false;
  if (!entry && name.length === 1) {
    const lower = name.toLowerCase();
    if (KEY_TABLE[lower] && lower !== name) { entry = KEY_TABLE[lower]; shift = true; }
    else {
      const base = Object.keys(SHIFTED).find(k => SHIFTED[k] === name);
      if (base) { entry = KEY_TABLE[base]; shift = true; }
      else entry = { key: name, code: '', vk: 0, text: name };
    }
  }
  if (!entry) {
    throw new BridgeError('invalid_argument', `unknown key '${raw}'`, [
      'Use a key name (Enter, Tab, Escape, Backspace, ArrowDown, Home, F5, a, 1, …), with --mod cmd,shift for modifiers.'
    ]);
  }
  return { entry, shift };
}

async function pressKey(tabId, raw, modifiers) {
  const { entry, shift } = lookupKey(raw);
  let mask = modifierMask(modifiers);
  if (shift) mask |= 8;
  const key = shift && SHIFTED[entry.key] ? SHIFTED[entry.key] : (shift && entry.key.length === 1 ? entry.key.toUpperCase() : entry.key);
  const commands = editingCommands(entry, mask);
  const text = (mask & (1 | 2 | 4)) ? undefined : (shift && entry.text ? key : entry.text);
  const down = {
    type: text ? 'keyDown' : 'rawKeyDown',
    modifiers: mask,
    key,
    code: entry.code,
    windowsVirtualKeyCode: entry.vk,
    nativeVirtualKeyCode: entry.vk,
    autoRepeat: false,
    isKeypad: false
  };
  if (text) { down.text = text; down.unmodifiedText = text; }
  if (commands.length) down.commands = commands;
  const pressed = await cdpInput(tabId, 'Input.dispatchKeyEvent', down);
  if (pressed.dialog) return { key, modifiers: mask, dialog: pressed.dialog };
  const released = await cdpInput(tabId, 'Input.dispatchKeyEvent', { type: 'keyUp', modifiers: mask, key, code: entry.code, windowsVirtualKeyCode: entry.vk, nativeVirtualKeyCode: entry.vk });
  return { key, modifiers: mask, dialog: released.dialog || null };
}

async function insertText(tabId, text) {
  const outcome = await cdpInput(tabId, 'Input.insertText', { text });
  return { dialog: outcome.dialog || null };
}

async function typeSlowly(tabId, text) {
  for (const ch of text) {
    let outcome;
    if (ch === '\n') outcome = await pressKey(tabId, 'Enter', []);
    else if (ch === '\t') outcome = await pressKey(tabId, 'Tab', []);
    else if (KEY_TABLE[ch.toLowerCase()] || Object.values(SHIFTED).includes(ch)) outcome = await pressKey(tabId, ch, []);
    else outcome = await insertText(tabId, ch);
    if (outcome.dialog) return { dialog: outcome.dialog };
    await sleep(15);
  }
  return { dialog: null };
}

async function mouseAt(tabId, x, y, options = {}) {
  const button = options.button || 'left';
  const clickCount = options.clickCount || 1;
  const modifiers = options.modifiers || 0;
  let outcome = await cdpInput(tabId, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, modifiers, button: 'none' });
  if (outcome.dialog) return { dialog: outcome.dialog };
  for (let i = 1; i <= clickCount; i++) {
    outcome = await cdpInput(tabId, 'Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, clickCount: i, modifiers });
    if (outcome.dialog) return { dialog: outcome.dialog };
    outcome = await cdpInput(tabId, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, clickCount: i, modifiers });
    if (outcome.dialog) return { dialog: outcome.dialog };
  }
  return { dialog: null };
}

/// Locates a ref, checks it is reachable by a pointer, and returns the point
/// in top-frame viewport coordinates.
async function locate(tabId, ref, options = {}) {
  const { frameId, local } = parseRef(ref);
  let measured = await callFrame(tabId, frameId, 'measure', { ref: local, scroll: options.scroll });
  let point = await toMainFramePoint(tabId, frameId, measured.x, measured.y);
  if (frameId !== 0 && options.scroll !== false) {
    // The element sits inside a frame; it may be visible within that frame yet
    // its frame scrolled out of the top viewport. If the translated point is
    // off the top viewport, force a cross-frame scroll and re-measure once.
    const inView = await pointInTopViewport(tabId, point);
    if (!inView) {
      measured = await callFrame(tabId, frameId, 'measure', { ref: local, scroll: 'force' });
      point = await toMainFramePoint(tabId, frameId, measured.x, measured.y);
    }
  }
  const description = frameId === 0 ? measured.description : String(measured.description || '').replace(/\[ref=e(\d+)\]/g, `[ref=f${frameId}e$1]`);
  return Object.assign({}, measured, { frameId, local, x: point.x, y: point.y, description });
}

async function pointInTopViewport(tabId, point) {
  try {
    const metrics = await cdp(tabId, 'Page.getLayoutMetrics');
    const vp = metrics.cssVisualViewport || metrics.cssLayoutViewport || {};
    const w = vp.clientWidth || 100000;
    const h = vp.clientHeight || 100000;
    return point.x >= 0 && point.y >= 0 && point.x <= w && point.y <= h;
  } catch (_) {
    return true;
  }
}

/// After an action, gives the page a moment and reports whether it navigated.
async function settle(tabId, before, timeoutMs = 5000, dialog = null) {
  if (dialog) return { dialog };
  await sleep(150);
  const started = Date.now();
  let tab = await getTab(tabId);
  while (tab && tab.status === 'loading' && Date.now() - started < timeoutMs) {
    await sleep(100);
    tab = await getTab(tabId);
  }
  if (!tab) return { closed: true };
  const navigated = tab.url !== before.url;
  return { navigated, url: tab.url, title: tab.title, loading: tab.status === 'loading' };
}

// Waits for a navigation to actually start (a loading transition or the URL
// changing) and then finish, so we never report "ok" on a navigation a dialog
// or an ignored click prevented. `from` is the URL before the request; `expect`
// (optional) is the URL we asked for; `reload` means the URL will not change.
async function waitForNavigation(tabId, timeoutMs, { from = null, expect = null, reload = false } = {}) {
  const started = Date.now();
  let transitioned = false;
  while (Date.now() - started < timeoutMs) {
    const tab = await getTab(tabId);
    if (!tab) throw new BridgeError('tab_not_found', 'the tab closed while navigating');
    const dialogEntry = attached.get(tabId);
    if (dialogEntry && dialogEntry.dialog) {
      // A beforeunload (or other) dialog is holding the navigation.
      return tab;
    }
    const urlChanged = from !== null && tab.url && tab.url !== from;
    if (tab.status === 'loading') transitioned = true;
    if ((reload || expect || urlChanged) && (transitioned || urlChanged)) {
      if (tab.status === 'complete') return tab;
    } else if (!from && !expect && !reload && tab.status === 'complete') {
      return tab;
    }
    await sleep(80);
  }
  const tab = await getTab(tabId);
  if (!tab) throw new BridgeError('tab_not_found', 'the tab closed while navigating');
  return tab; // report what we have; tabSummary carries the (possibly still-loading) status
}

async function waitForLoad(tabId, timeoutMs) {
  const started = Date.now();
  let tab = await getTab(tabId);
  // The status flips to loading a beat after tabs.update returns.
  await sleep(100);
  tab = await getTab(tabId);
  while (tab && tab.status !== 'complete' && Date.now() - started < timeoutMs) {
    await sleep(100);
    tab = await getTab(tabId);
  }
  if (!tab) throw new BridgeError('tab_not_found', 'the tab closed while loading');
  return tab;
}

// ---------------------------------------------------------------------------
// Action-effect observation. Armed in the top frame (portals/menus land in the
// top document's <body>) and, for a frame-targeted action, in that frame too.
// Everything is best-effort: an unarmable page just yields no effect report.

async function armObserver(tabId, frameId) {
  const targets = frameId && frameId !== 0 ? [0, frameId] : [0];
  const armed = [];
  for (const target of targets) {
    try {
      await callFrame(tabId, target, 'observe-start', {}, 3000);
      armed.push(target);
    } catch (_) { /* frame not scriptable */ }
  }
  return armed;
}

async function reportObserver(tabId, armed, after) {
  if (!armed.length) return null;
  // A navigation replaced the document (observer gone with it), and an open
  // dialog blocks the page's event loop — the report would hang. Still tell a
  // surviving content script (same-document navigation) to stand down, so the
  // observer does not keep counting until the next action.
  if (!after || after.closed || after.navigated || after.dialog) {
    for (const frameId of armed) callFrame(tabId, frameId, 'observe-stop', {}, 1500).catch(() => {});
    return null;
  }
  const out = { changes: { added: 0, removed: 0, attributes: 0, text: 0 }, appeared: [], appearedMore: 0, focus: null, settled: true };
  let any = false;
  for (const frameId of armed) {
    try {
      const report = await callFrame(tabId, frameId, 'observe-report', {}, 5000);
      if (!report || !report.armed) continue;
      any = true;
      for (const key of Object.keys(out.changes)) out.changes[key] += (report.changes && report.changes[key]) || 0;
      for (const item of report.appeared || []) {
        if (out.appeared.includes(item)) continue;
        if (out.appeared.length >= 5) { out.appearedMore += 1; continue; }
        out.appeared.push(item);
      }
      out.appearedMore += report.appearedMore || 0;
      if (report.focus && !out.focus) out.focus = report.focus;
      if (report.settled === false) out.settled = false;
    } catch (_) { /* the page may have navigated after all */ }
  }
  return any ? out : null;
}

// ---------------------------------------------------------------------------
// Handlers

async function handleRequest(method, params) {
  const handler = handlers[method];
  if (!handler) throw new BridgeError('unsupported', `unknown method '${method}'`, ['Update the extension: run `amcu browser install` and reload it.']);
  if (params && params.expect) await expectElement(params);
  return handler(params);
}

// `--element "Submit button"` — the caller's own description of what the ref
// is, in the style Playwright's tools take alongside a ref. It is never used
// to find the element; it is checked against the live one so that a ref
// remembered wrongly, or reused after the page changed, is refused before
// anything is pressed. The comparison is lenient on purpose: role words are
// optional, and the remaining words need only appear somewhere in the
// element's role, name, tag or ref.
async function expectElement(params) {
  // Insurance that is silently dropped is worse than none: a verb with no
  // element to check against refuses rather than ignoring the flag. drag
  // checks its --from element.
  const ref = params.ref || params.from;
  if (!ref) {
    throw new BridgeError('invalid_argument', `--element needs an element to check against; this command has no --ref`, [
      'Add --ref (or --target) with a ref from `amcu browser snapshot`, or drop --element.'
    ]);
  }
  const tab = await resolveTab(params);
  requireNoDialog(tab.id);
  const { frameId, local } = parseRef(ref);
  const described = await callFrame(tab.id, frameId, 'describe', { ref: local });
  // Only the role and the name count; the ref and tag the description carries
  // would let "--element e12" pass on anything.
  const actual = String(described.description || '').replace(/\s*\[ref=[^\]]*\]/g, '').replace(/\s*<[^>]*>/g, '');
  if (elementMatches(params.expect, actual)) return;
  throw new BridgeError('element_mismatch', `element ${ref} is ${actual}, not "${params.expect}"`, [
    'Re-run `amcu browser snapshot` and use the ref whose role and name match what you mean.',
    'If the description was merely loosely worded, drop --element; the ref alone addresses the element.'
  ]);
}

const STOP_WORDS = new Set(['the', 'a', 'an', 'to', 'of', 'for', 'in', 'on', 'at', 'with', 'this', 'that', 'element', 'control', 'page']);

// Words a caller uses for a role, and the ARIA roles each may stand for.
const ROLE_SYNONYMS = {
  button: ['button'], link: ['link'],
  input: ['textbox', 'searchbox', 'textarea', 'spinbutton', 'combobox'], field: ['textbox', 'searchbox', 'textarea', 'spinbutton', 'combobox'],
  textbox: ['textbox', 'searchbox', 'textarea'], box: ['textbox', 'searchbox', 'checkbox', 'combobox'], textarea: ['textarea', 'textbox'],
  text: ['textbox', 'textarea'], checkbox: ['checkbox'], radio: ['radio'],
  dropdown: ['combobox', 'listbox'], select: ['combobox', 'listbox'], combobox: ['combobox'],
  menu: ['menu', 'menuitem', 'menubar'], menuitem: ['menuitem'], item: ['menuitem', 'listitem', 'treeitem', 'option'], option: ['option'],
  tab: ['tab'], image: ['img', 'image'], img: ['img', 'image'], icon: ['img', 'image', 'button'],
  heading: ['heading'], title: ['heading'], label: ['label'], area: ['textarea'],
  row: ['row'], cell: ['cell', 'gridcell'], list: ['list', 'listbox'], listbox: ['listbox'],
  dialog: ['dialog', 'alertdialog'], form: ['form'], search: ['searchbox'], main: ['main']
};

function elementMatches(expect, actual) {
  const haystack = String(actual).toLowerCase();
  // CJK descriptions carry the role word glued to the name ("登录按钮"), so
  // those are stripped as substrings before the split.
  const words = String(expect).toLowerCase()
    .replace(/按钮|链接|输入框|文本框|复选框|单选框|下拉框|下拉|菜单项|菜单|选项卡|选项|图片|图标|标题|字段|元素|控件|文本/g, ' ')
    .split(/[^\p{L}\p{N}]+/u).filter(word => word && !STOP_WORDS.has(word));
  if (words.length === 0) return true;
  // Role words are optional decoration next to a name ("Submit button"). When
  // they are all there is ("Search input"), each must fit the live role.
  const specific = words.filter(word => !(word in ROLE_SYNONYMS));
  if (specific.length > 0) return specific.every(word => wordPresent(word, haystack));
  return words.every(word => wordPresent(word, haystack) || ROLE_SYNONYMS[word].some(role => wordPresent(role, haystack)));
}

// Latin words match on word boundaries so "Log in" does not pass on "Logout"
// and "Save" does not pass on "Don't save"... it does, and should: the name
// contains the word. What must not pass is a different word that merely
// contains the letters. CJK has no word boundaries; substring is the only test.
function wordPresent(word, haystack) {
  if (/^[\p{Script=Latin}\p{N}]+$/u.test(word)) {
    const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(`(^|[^\\p{Script=Latin}\\p{N}])${escaped}(?=$|[^\\p{Script=Latin}\\p{N}])`, 'u').test(haystack);
  }
  return haystack.includes(word);
}

const handlers = {
  async hello() {
    return { version: VERSION, extensionId: chrome.runtime.id };
  },

  async status(params) {
    const tabs = await chrome.tabs.query({});
    const sessions = {};
    const stored = await chrome.storage.session.get(null);
    for (const [key, value] of Object.entries(stored)) {
      if (key.startsWith('session:')) sessions[key.slice(8)] = value;
    }
    return {
      version: VERSION,
      extensionId: chrome.runtime.id,
      tabs: tabs.length,
      attached: Array.from(attached.keys()),
      sessions,
      requests: status.requests,
      hostConnectedSince: status.since,
      recentErrors
    };
  },

  async 'extension.reload'() {
    // Answer first, then reload: the host sees the disconnect and the next
    // connection is the new code.
    setTimeout(() => chrome.runtime.reload(), 200);
    return { reloading: true, version: VERSION };
  },

  async frames(params) {
    const tab = await resolveTab(params);
    const frames = await listFrames(tab.id);
    return { tab: tabSummary(tab), frames: frames.map(f => ({ frameId: f.frameId, parentFrameId: f.parentFrameId, url: f.url })) };
  },

  async 'tabs.list'(params) {
    const session = params.session || 'default';
    const current = await currentTabId(session);
    const tabs = await chrome.tabs.query({});
    return { tabs: tabs.map(tab => tabSummary(tab, { current: tab.id === current })), current };
  },

  async 'tabs.create'(params) {
    const session = params.session || 'default';
    const create = { url: params.url || 'about:blank' };
    if (params.userWindow) {
      // Explicitly asked for the user's window — the old behaviour.
      create.active = !!params.activate;
    } else {
      create.windowId = await ensureAmcuWindow();
      // Active within the unfocused amcu window: invisible to the user, and
      // the tab renders, so screenshots work without any visible change.
      create.active = true;
    }
    const tab = await chrome.tabs.create(create);
    if (params.activate && !params.userWindow) {
      await chrome.windows.update(tab.windowId, { focused: true });
    }
    await setCurrentTab(session, tab.id);
    const loaded = params.url && params.wait !== false ? await waitForLoad(tab.id, params.timeoutMs || 30000) : tab;
    return { tab: tabSummary(loaded, { current: true }) };
  },

  async 'tabs.select'(params) {
    const session = params.session || 'default';
    const tab = await getTab(params.tab);
    if (!tab) throw new BridgeError('tab_not_found', `no tab with id ${params.tab}`, ['Run `amcu browser tabs`.']);
    await setCurrentTab(session, tab.id);
    if (params.activate) {
      await chrome.tabs.update(tab.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
    } else if (await inAmcuWindow(tab)) {
      // Activation inside the amcu window is invisible and keeps the tab
      // rendering; in the user's windows it would be a visible change.
      await chrome.tabs.update(tab.id, { active: true });
    }
    return { tab: tabSummary(await getTab(tab.id) || tab, { current: true }) };
  },

  async 'tabs.close'(params) {
    const tab = await resolveTab(params, { acting: true });
    await chrome.tabs.remove(tab.id);
    return { closed: tabSummary(tab) };
  },

  async navigate(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    if (!params.url) throw new BridgeError('invalid_argument', '--url is required');
    let url = params.url;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) url = 'https://' + url;
    const from = tab.url;
    await chrome.tabs.update(tab.id, { url });
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab), loading: true };
    const loaded = await waitForNavigation(tab.id, params.timeoutMs || 30000, { from, expect: url });
    return { tab: tabSummary(loaded), loading: loaded.status !== 'complete' };
  },

  async back(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    const from = tab.url;
    await chrome.tabs.goBack(tab.id);
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 15000, { from })) };
  },

  async forward(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    const from = tab.url;
    await chrome.tabs.goForward(tab.id);
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 15000, { from })) };
  },

  async reload(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await chrome.tabs.reload(tab.id, { bypassCache: !!params.hard });
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 30000, { reload: true })) };
  },

  async snapshot(params) {
    const tab = await resolveTab(params);
    requireNoDialog(tab.id);
    await inject(tab.id);
    const frames = await listFrames(tab.id);
    const options = { selector: params.selector, maxNodes: params.maxNodes, allRefs: params.allRefs, interactiveOnly: params.interactiveOnly, diff: params.diff };
    let within = null;
    if (params.within) within = parseRef(params.within);
    let wanted = params.frame !== undefined && params.frame !== null ? frames.filter(f => f.frameId === params.frame) : frames;
    // A CSS selector addresses one document; without --frame that is the main one.
    if (params.selector && (params.frame === undefined || params.frame === null)) wanted = frames.filter(f => f.frameId === 0);
    // --within names one element in one frame; snapshot only that frame.
    if (within) {
      wanted = frames.filter(f => f.frameId === within.frameId);
      if (!wanted.length) {
        throw new BridgeError('stale_snapshot', `frame ${within.frameId} no longer exists in this tab`, ['Re-run `amcu browser snapshot`.']);
      }
    }
    if (params.frame !== undefined && params.frame !== null && !wanted.length) {
      throw new BridgeError('element_not_found', `no frame ${params.frame} in this tab`, ['Frame ids appear in the snapshot as f<id>; re-run `amcu browser snapshot`.']);
    }
    const results = [];
    let budget = Math.max(1, params.maxNodes || 1500);
    const mainFirst = wanted.slice().sort((a, b) => a.frameId - b.frameId);
    const iframesByFrame = new Map(); // frameId -> [{ref, src}] its own iframes
    for (const frame of mainFirst) {
      const isMain = frame.frameId === 0;
      const frameOptions = Object.assign({}, options, { maxNodes: budget });
      if (!isMain && params.selector) frameOptions.selector = undefined;
      if (within && frame.frameId === within.frameId) frameOptions.within = within.local;
      const hints = await listenerHints(tab.id, frame.frameId);
      if (hints) frameOptions.listenerHints = hints;
      let result;
      try {
        result = await callFrame(tab.id, frame.frameId, 'snapshot', frameOptions, 15000);
      } catch (error) {
        const bridge = asBridgeError(error);
        if (isMain) throw bridge;
        // A frame that cannot be scripted (about:blank sandbox, chrome-error) is skipped.
        results.push({ frameId: frame.frameId, url: frame.url, error: bridge.message, text: '', nodes: 0, rendered: 0 });
        continue;
      }
      if (!isMain && !result.text) continue;
      budget = Math.max(1, budget - result.rendered);
      const prefixed = isMain ? result.text : result.text.replace(/\[ref=e(\d+)\]/g, `[ref=f${frame.frameId}e$1]`);
      const localIframes = (result.iframes || []).map(f => ({ ref: isMain ? f.ref : `f${frame.frameId}${f.ref}`, src: f.src }));
      iframesByFrame.set(frame.frameId, localIframes);
      results.push({
        frameId: frame.frameId,
        parentFrameId: frame.parentFrameId,
        parentRef: null, // filled in below from the parent's iframe list (display only)
        url: result.url || frame.url,
        title: result.title,
        text: prefixed,
        nodes: result.nodes,
        rendered: result.rendered,
        truncated: result.truncated,
        hiddenGenerics: result.hiddenGenerics,
        focusedRef: result.focusedRef ? (isMain ? result.focusedRef : `f${frame.frameId}${result.focusedRef}`) : null,
        iframes: localIframes,
        gen: result.gen,
        scroll: result.scroll || null,
        listenersScanned: !!hints,
        listenersFound: hints ? hints.length : 0,
        diff: result.diff === true,
        added: result.added,
        removed: result.removed,
        diffBase: result.diffBase
      });
    }
    // Best-effort: name the iframe each child frame lives in, by matching the
    // child's url to one of the parent's iframe srcs. Display only; it is never
    // used to place a click (that goes through trusted frame geometry).
    for (const r of results) {
      if (r.frameId === 0 || r.parentFrameId === undefined) continue;
      const siblings = (iframesByFrame.get(r.parentFrameId) || []).slice();
      const url = r.url || '';
      let match = siblings.find(f => f.src && (url === f.src || url.endsWith(f.src) || (f.src && url.includes(f.src))));
      if (!match) match = siblings[0];
      if (match) r.parentRef = match.ref;
    }
    return { tab: tabSummary(tab), frames: results };
  },

  async find(params) {
    const tab = await resolveTab(params);
    requireNoDialog(tab.id);
    await inject(tab.id);
    const frames = await listFrames(tab.id);
    const matches = [];
    let total = 0;
    let gen = null;
    for (const frame of frames.slice().sort((a, b) => a.frameId - b.frameId)) {
      let result;
      try {
        result = await callFrame(tab.id, frame.frameId, 'find', { query: params.query, role: params.role, limit: params.limit }, 15000);
      } catch (error) {
        if (frame.frameId === 0) throw asBridgeError(error);
        continue;
      }
      const lines = frame.frameId === 0
        ? result.matches
        : result.matches.map(line => line.replace(/\[ref=e(\d+)\]/g, `[ref=f${frame.frameId}e$1]`));
      for (const line of lines) matches.push(line);
      total += result.total;
      if (frame.frameId === 0) gen = result.gen;
    }
    return { tab: tabSummary(tab), matches, total, gen };
  },

  async click(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    const before = { url: tab.url };
    await ensureAttached(tab.id);
    const target = await locate(tab.id, params.ref);
    if (target.hit === 'obscured' && !params.force) {
      throw new BridgeError('element_obscured', `element ${params.ref} (${target.description}) is covered by ${target.obscuredBy}; a click there would land on the cover`, [
        'If the cover is a dialog, banner or menu, deal with it first (click its close/accept control from a fresh snapshot).',
        'Pass --force to dispatch a JavaScript click on the element itself instead (not a real pointer event; some pages ignore it).'
      ]);
    }
    if (target.hit === 'outside' && !params.force) {
      throw new BridgeError('element_not_found', `element ${params.ref} (${target.description}) could not be scrolled into the viewport`, [
        'It may sit in a container that hides overflow, or be positioned off screen; try `amcu browser scroll` on the container first, or --force for a JavaScript click.'
      ]);
    }
    let mode = 'cdp';
    let dialog = null;
    const armed = await armObserver(tab.id, target.frameId);
    const startedAt = Date.now();
    if (params.force && target.hit !== 'ok' && target.hit !== 'ancestor') {
      await callFrame(tab.id, target.frameId, 'js-click', { ref: target.local });
      mode = 'js:click';
    } else {
      const button = params.button === 'right' ? 'right' : params.button === 'middle' ? 'middle' : 'left';
      dialog = (await mouseAt(tab.id, target.x, target.y, { button, clickCount: params.count || 1, modifiers: modifierMask(params.modifiers) })).dialog;
    }
    const after = await settle(tab.id, before, 5000, dialog);
    const effect = await reportObserver(tab.id, armed, after);
    if (effect) after.effect = effect;
    const opened = await openedTabSince(tab.id, startedAt, params);
    if (opened) after.openedTab = opened;
    return {
      tab: tabSummary(tab),
      ref: params.ref,
      description: target.description,
      point: { x: Math.round(target.x), y: Math.round(target.y) },
      mode,
      fromEarlierSnapshot: target.fromEarlierSnapshot,
      unstable: target.stable === false,
      obscuredNote: target.hit === 'ancestor' ? `pointer lands on ${target.obscuredBy}` : null,
      after
    };
  },

  async hover(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const target = await locate(tab.id, params.ref);
    await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x: target.x, y: target.y, button: 'none' });
    return { tab: tabSummary(tab), ref: params.ref, description: target.description, point: { x: Math.round(target.x), y: Math.round(target.y) } };
  },

  async drag(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const from = await locate(tab.id, params.from);
    const to = await locate(tab.id, params.to, { scroll: false });
    await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x: from.x, y: from.y, button: 'none' });
    await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mousePressed', x: from.x, y: from.y, button: 'left', clickCount: 1 });
    const steps = Math.max(2, params.steps || 12);
    for (let i = 1; i <= steps; i++) {
      const x = from.x + (to.x - from.x) * i / steps;
      const y = from.y + (to.y - from.y) * i / steps;
      await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'left', buttons: 1 });
      await sleep(10);
    }
    await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x: to.x, y: to.y, button: 'left', clickCount: 1 });
    return { tab: tabSummary(tab), from: from.description, to: to.description };
  },

  async type(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const { frameId, local } = parseRef(params.ref);
    await requireSecretScope(tab, params, frameId);
    const focus = await callFrame(tab.id, frameId, 'focus-for-input', { ref: local, mode: params.replace ? 'replace' : 'append' });
    const armed = await armObserver(tab.id, frameId);
    const startedAt = Date.now();
    const text = String(params.text === undefined ? '' : params.text);
    let dialog = null;
    if (params.slowly) dialog = (await typeSlowly(tab.id, text)).dialog;
    else if (text.length) dialog = (await insertText(tab.id, text)).dialog;
    let submitted = false;
    if (params.submit && !dialog) {
      dialog = (await pressKey(tab.id, 'Enter', [])).dialog;
      submitted = true;
    }
    const before = { url: tab.url };
    const after = params.submit || dialog ? await settle(tab.id, before, 5000, dialog) : { navigated: false, url: tab.url };
    const effect = await reportObserver(tab.id, armed, after);
    if (effect) after.effect = effect;
    if (params.submit) {
      const opened = await openedTabSince(tab.id, startedAt, params);
      if (opened) after.openedTab = opened;
    }
    let value = null;
    try {
      value = (await callFrame(tab.id, frameId, 'value', { ref: local }, 3000)).value;
    } catch (_) { /* the page may have navigated */ }
    return {
      tab: tabSummary(tab),
      ref: params.ref,
      description: focus.description,
      typed: text.length,
      submitted,
      value: typeof value === 'string' ? value : null,
      fromEarlierSnapshot: focus.fromEarlierSnapshot,
      after
    };
  },

  async fill(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const { frameId, local } = parseRef(params.ref);
    await requireSecretScope(tab, params, frameId);
    const value = String(params.value === undefined ? '' : params.value);
    const focus = await callFrame(tab.id, frameId, 'focus-for-input', { ref: local, mode: 'replace' });
    let mode = 'cdp:insertText';
    if (value.length) {
      await insertText(tab.id, value);
    } else {
      // Emptying a field: delete the selection the focus step made.
      await pressKey(tab.id, 'Backspace', []);
      mode = 'cdp:key';
    }
    let read = (await callFrame(tab.id, frameId, 'value', { ref: local }, 3000)).value;
    if (typeof read !== 'string') read = String(read);
    let verified = read === value;
    if (!verified && focus.kind === 'input' && focus.assignable) {
      // date/color/range/number and the like do not accept typed text; assign
      // the value directly. Never for contenteditable — a direct textContent
      // write would flatten a rich editor's DOM, and "verifying" against the
      // wreckage would report a success that destroyed the field.
      const direct = await callFrame(tab.id, frameId, 'set-value', { ref: local, value }, 3000);
      read = typeof direct.value === 'string' ? direct.value : String(direct.value);
      verified = read === value;
      mode = 'js:value';
    }
    return {
      tab: tabSummary(tab),
      ref: params.ref,
      description: focus.description,
      mode,
      verified,
      expected: value,
      actual: read,
      fromEarlierSnapshot: focus.fromEarlierSnapshot
    };
  },

  async 'select-option'(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    const { frameId, local } = parseRef(params.ref);
    const result = await callFrame(tab.id, frameId, 'select-option', { ref: local, values: params.values || [] });
    return Object.assign({ tab: tabSummary(tab), ref: params.ref }, result);
  },

  async key(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    if (params.ref) {
      const { frameId, local } = parseRef(params.ref);
      await callFrame(tab.id, frameId, 'focus-for-input', { ref: local, mode: 'append' }).catch(async () => {
        // Not a text field: give it focus without clicking it, so a Space on
        // a checkbox toggles once, not twice.
        const focused = await callFrame(tab.id, frameId, 'focus', { ref: local });
        if (!focused.focused) {
          throw new BridgeError('unsupported', `element ${params.ref} (${focused.description}) cannot take keyboard focus`, [
            'Aim the key at a focusable element (a field, button, link or control), or omit --ref to send it to whatever is focused.'
          ]);
        }
      });
    }
    const before = { url: tab.url };
    const count = Math.max(1, params.count || 1);
    const armed = await armObserver(tab.id, params.ref ? parseRef(params.ref).frameId : 0);
    const startedAt = Date.now();
    let pressed;
    for (let i = 0; i < count; i++) {
      pressed = await pressKey(tab.id, params.key, params.modifiers || []);
      if (pressed.dialog) break;
    }
    const after = await settle(tab.id, before, 3000, pressed.dialog);
    const effect = await reportObserver(tab.id, armed, after);
    if (effect) after.effect = effect;
    const opened = await openedTabSince(tab.id, startedAt, params);
    if (opened) after.openedTab = opened;
    return { tab: tabSummary(tab), key: pressed.key, modifiers: params.modifiers || [], count, after };
  },

  async scroll(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    let x, y, description = 'viewport';
    if (params.ref) {
      const target = await locate(tab.id, params.ref);
      x = target.x; y = target.y; description = target.description;
    } else {
      const metrics = await cdp(tab.id, 'Page.getLayoutMetrics');
      const viewport = metrics.cssVisualViewport || metrics.visualViewport || metrics.layoutViewport;
      x = (viewport.clientWidth || 800) / 2;
      y = (viewport.clientHeight || 600) / 2;
    }
    const deltaX = params.dx || 0;
    // amcu convention: positive --dy scrolls up (content moves down); the wheel wants the opposite sign.
    const deltaY = -(params.dy || 0);
    await cdpInput(tab.id, 'Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: -deltaX, deltaY, button: 'none' });
    await sleep(120);
    return { tab: tabSummary(tab), at: description, dx: params.dx || 0, dy: params.dy || 0 };
  },

  async screenshot(params) {
    const tab = await resolveTab(params);
    await ensureAttached(tab.id);
    // A tab that is not its window's active tab does not render. In the amcu
    // window that is fixable invisibly; restore from minimised too, unfocused.
    if (await inAmcuWindow(tab)) {
      const win = await chrome.windows.get(tab.windowId).catch(() => null);
      if (win && win.state === 'minimized') {
        await chrome.windows.update(tab.windowId, { state: 'normal', focused: false }).catch(() => {});
      }
      if (!tab.active) {
        await chrome.tabs.update(tab.id, { active: true }).catch(() => {});
        await sleep(200);
      }
    }
    const format = params.format === 'jpeg' ? 'jpeg' : 'png';
    const request = { format, fromSurface: true, captureBeyondViewport: !!params.full };
    if (format === 'jpeg') request.quality = params.quality || 80;
    if (params.ref) {
      const { frameId, local } = parseRef(params.ref);
      const measured = await callFrame(tab.id, frameId, 'measure', { ref: local });
      const origin = await toMainFramePoint(tab.id, frameId, measured.rect.x, measured.rect.y);
      // Clips are in page coordinates: add the scroll offset to the viewport rect.
      const metrics = await cdp(tab.id, 'Page.getLayoutMetrics');
      const viewport = metrics.cssVisualViewport || metrics.visualViewport || { pageX: 0, pageY: 0 };
      request.clip = { x: origin.x + (viewport.pageX || 0), y: origin.y + (viewport.pageY || 0), width: measured.rect.width, height: measured.rect.height, scale: 1 };
      request.captureBeyondViewport = true;
    } else if (params.full) {
      const metrics = await cdp(tab.id, 'Page.getLayoutMetrics');
      const size = metrics.cssContentSize || metrics.contentSize;
      request.clip = { x: 0, y: 0, width: Math.ceil(size.width), height: Math.ceil(size.height), scale: 1 };
    }
    let result;
    try {
      result = await cdp(tab.id, 'Page.captureScreenshot', request, params.timeoutMs || 10000);
    } catch (error) {
      const bridge = asBridgeError(error);
      if (bridge.code === 'timeout') {
        throw new BridgeError('capture_failure', 'the tab did not produce a frame — a tab that is not its window\'s active tab may not render', [
          'Move the work into amcu\'s background window: `amcu browser tab --new --url …` opens there and renders without disturbing the user.',
          'Or read the page with `amcu browser snapshot`, which needs no rendering.',
          'Only as a last resort make the tab visible: `amcu browser tab --select ID --activate` (a visible change in the user\'s window).'
        ]);
      }
      throw bridge;
    }
    return { tab: tabSummary(tab), format, data: result.data };
  },

  async evaluate(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const source = String(params.expression || '');
    if (!source.trim()) throw new BridgeError('invalid_argument', '--js is required');
    let contextId;
    let cleanup = null;
    let frameId = 0;
    let elementLookup = 'undefined';
    if (params.ref) {
      const parsed = parseRef(params.ref);
      frameId = parsed.frameId;
      const tag = nonce();
      await callFrame(tab.id, frameId, 'tag-element', { ref: parsed.local, nonce: tag });
      cleanup = () => callFrame(tab.id, frameId, 'tag-element', { ref: parsed.local, nonce: null }).catch(() => {});
      elementLookup = `document.querySelector('[data-amcu-target="${tag}"]')`;
    } else if (params.frame) {
      frameId = params.frame;
    }
    if (frameId !== 0) contextId = await executionContextFor(tab.id, frameId);
    // An expression (or a function to call with the element) first; if that
    // does not parse, the text is taken as a function body that may `return`.
    const asExpression = `(async () => { const element = ${elementLookup}; const __v = (${source}\n); return typeof __v === 'function' ? await __v(element) : __v; })()`;
    const asBody = `(async () => { const element = ${elementLookup}; ${source}\n })()`;
    try {
      const run = async expression => {
        const evalParams = { expression, returnByValue: true, awaitPromise: true, userGesture: true, generatePreview: false };
        if (contextId) evalParams.contextId = contextId;
        return cdp(tab.id, 'Runtime.evaluate', evalParams, params.timeoutMs || 30000);
      };
      let result = await run(asExpression);
      if (result.exceptionDetails && /SyntaxError/.test(formatRemoteObject(result.exceptionDetails.exception) || result.exceptionDetails.text || '')) {
        result = await run(asBody);
      }
      if (result.exceptionDetails) {
        const details = result.exceptionDetails;
        const text = details.exception ? formatRemoteObject(details.exception) : details.text;
        throw new BridgeError('page_error', `evaluation threw: ${text}`, [
          'Pass an expression (`document.title`), a function (`el => el.textContent`, called with the --ref element), or statements ending in `return …`.'
        ]);
      }
      const value = result.result;
      return { tab: tabSummary(tab), value: value.value !== undefined ? value.value : (value.unserializableValue || value.description || null), type: value.type };
    } finally {
      if (cleanup) await cleanup();
    }
  },

  async wait(params) {
    const tab = await resolveTab(params);
    const timeoutMs = params.timeoutMs || 30000;
    const started = Date.now();
    if (params.time) {
      await sleep(Math.min(params.time * 1000, timeoutMs));
      return { tab: tabSummary(await getTab(tab.id) || tab), waited: 'time', seconds: params.time };
    }
    const check = async () => {
      const live = await getTab(tab.id);
      if (!live) throw new BridgeError('tab_not_found', 'the tab closed while waiting');
      if (params.load) return live.status === 'complete' ? { waited: 'load' } : null;
      if (params.urlPattern) {
        let re;
        try {
          re = new RegExp(params.urlPattern);
        } catch (error) {
          throw new BridgeError('invalid_argument', `--url-matches is not a valid regex: ${error.message}`);
        }
        return re.test(live.url || '') ? { waited: 'url-matches', url: live.url } : null;
      }
      if (params.url) return (live.url || '').includes(params.url) ? { waited: 'url', url: live.url } : null;
      if (params.text || params.textGone) {
        const frames = await listFrames(tab.id);
        let found = false;
        for (const frame of frames) {
          try {
            const page = await callFrame(tab.id, frame.frameId, 'page-text', {}, 3000);
            if (page.text && page.text.includes(params.text || params.textGone)) { found = true; break; }
          } catch (_) { /* frame not scriptable */ }
        }
        if (params.text) return found ? { waited: 'text' } : null;
        return found ? null : { waited: 'text-gone' };
      }
      throw new BridgeError('invalid_argument', 'wait needs --text, --text-gone, --url, --url-matches, --load or --time');
    };
    // Backing-off poll (Playwright's cadence): fast first checks, calm later.
    const delays = [100, 250, 500];
    let attempt = 0;
    while (true) {
      const done = await check();
      if (done) return Object.assign({ tab: tabSummary(await getTab(tab.id) || tab), elapsedMs: Date.now() - started }, done);
      if (Date.now() - started > timeoutMs) {
        throw new BridgeError('timeout', `condition not met within ${Math.round(timeoutMs / 1000)}s`, [
          'Take `amcu browser snapshot` to see what the page shows instead.',
          'Raise the limit with --timeout SECONDS if the page is legitimately slow.'
        ]);
      }
      await sleep(attempt < delays.length ? delays[attempt] : 1000);
      attempt += 1;
    }
  },

  async console(params) {
    const tab = await resolveTab(params);
    const fresh = !attached.has(tab.id);
    const entry = await ensureAttached(tab.id);
    // Runtime.enable replays messages the page already logged; give them a beat to arrive.
    if (fresh) await sleep(300);
    let messages = entry.console.slice();
    if (params.level) {
      const wanted = params.level === 'error' ? ['error', 'assert'] : params.level === 'warning' ? ['warning', 'warn'] : [params.level];
      messages = messages.filter(m => wanted.includes(m.level));
    }
    if (params.clear) entry.console.length = 0;
    return { tab: tabSummary(tab), messages, since: entry.attachedAt, replayed: fresh };
  },

  async network(params) {
    const tab = await resolveTab(params);
    const fresh = !attached.has(tab.id);
    const entry = await ensureAttached(tab.id);
    const requests = entry.networkOrder.map(id => entry.network.get(id)).filter(Boolean);
    if (params.clear) { entry.network.clear(); entry.networkOrder.length = 0; }
    return { tab: tabSummary(tab), requests, since: entry.attachedAt, fresh };
  },

  async dialog(params) {
    const tab = await resolveTab(params, { acting: true });
    const entry = await ensureAttached(tab.id);
    if (!entry.dialog) {
      // The event only arrives while attached; ask the page whether it is stuck.
      const probe = await Promise.race([
        cdp(tab.id, 'Runtime.evaluate', { expression: '1', returnByValue: true }, 1500).then(() => 'responsive').catch(() => 'blocked')
      ]);
      if (probe === 'responsive') {
        return { tab: tabSummary(tab), dialog: null, handled: false };
      }
    }
    const dialog = entry.dialog;
    const accept = params.accept !== false && !params.dismiss;
    const request = { accept };
    if (accept && params.text !== undefined && params.text !== null) request.promptText = String(params.text);
    try {
      await cdp(tab.id, 'Page.handleJavaScriptDialog', request, 3000);
    } catch (error) {
      const bridge = asBridgeError(error);
      if (/No dialog is showing/i.test(bridge.message)) return { tab: tabSummary(tab), dialog: null, handled: false };
      throw bridge;
    }
    entry.dialog = null;
    return { tab: tabSummary(tab), dialog, handled: true, accepted: accept };
  },

  async upload(params) {
    const tab = await resolveTab(params, { acting: true });
    requireNoDialog(tab.id);
    await ensureAttached(tab.id);
    const { frameId, local } = parseRef(params.ref);
    const files = params.files || [];
    if (!files.length) throw new BridgeError('invalid_argument', '--file is required');
    const tag = nonce();
    await callFrame(tab.id, frameId, 'tag-element', { ref: local, nonce: tag });
    try {
      const evalParams = { expression: `document.querySelector('[data-amcu-target="${tag}"]')` };
      if (frameId !== 0) evalParams.contextId = await executionContextFor(tab.id, frameId);
      const found = await cdp(tab.id, 'Runtime.evaluate', evalParams);
      if (!found.result || !found.result.objectId) throw new BridgeError('element_not_found', `element ${params.ref} could not be reached through the debugger`);
      const objectId = found.result.objectId;
      const description = await cdp(tab.id, 'DOM.describeNode', { objectId });
      const isFileInput = description.node && description.node.nodeName === 'INPUT' && (description.node.attributes || []).some((a, i, arr) => a === 'type' && (arr[i + 1] || '').toLowerCase() === 'file');
      if (!isFileInput) {
        throw new BridgeError('unsupported', `element ${params.ref} is not an <input type="file">`, [
          'Find the file input in the snapshot (it may be hidden; use --all-refs or --selector input[type=file]).',
          'For drop zones and custom pickers, the underlying <input type=file> is usually in the DOM; target that.'
        ]);
      }
      await cdp(tab.id, 'DOM.setFileInputFiles', { files, objectId });
      return { tab: tabSummary(tab), ref: params.ref, files };
    } finally {
      await callFrame(tab.id, frameId, 'tag-element', { ref: local, nonce: null }).catch(() => {});
    }
  },

  async resize(params) {
    const tab = await resolveTab(params, { acting: true });
    const update = {};
    if (params.width) update.width = params.width;
    if (params.height) update.height = params.height;
    if (!Object.keys(update).length) throw new BridgeError('invalid_argument', 'resize needs --width and/or --height');
    const win = await chrome.windows.update(tab.windowId, update);
    return { tab: tabSummary(tab), window: { id: win.id, width: win.width, height: win.height } };
  },

  async 'window.info'() {
    const id = await amcuWindowId();
    if (id === null) return { window: null };
    const win = await chrome.windows.get(id, { populate: true });
    return {
      window: {
        id: win.id,
        state: win.state,
        focused: !!win.focused,
        width: win.width,
        height: win.height,
        tabs: (win.tabs || []).map(t => tabSummary(t))
      }
    };
  },

  async 'window.show'() {
    const id = await ensureAmcuWindow();
    const win = await chrome.windows.update(id, { state: 'normal', focused: true });
    return { window: { id: win.id, state: win.state, focused: !!win.focused } };
  },

  async 'window.hide'() {
    const id = await amcuWindowId();
    if (id === null) return { window: null };
    const win = await chrome.windows.update(id, { state: 'minimized' });
    return { window: { id: win.id, state: win.state, focused: !!win.focused } };
  },

  async 'window.close'() {
    const id = await amcuWindowId();
    if (id === null) return { closed: false };
    await chrome.windows.remove(id);
    await chrome.storage.session.remove(AMCU_WINDOW_KEY);
    return { closed: true };
  },

  async detach(params) {
    if (params.all) {
      const ids = new Set(attached.keys());
      try {
        const targets = await chrome.debugger.getTargets();
        for (const t of targets) if (t.attached && t.tabId !== undefined) ids.add(t.tabId);
      } catch (_) { /* fall back to our own map */ }
      const done = [];
      for (const id of ids) if (await detach(id)) done.push(id);
      return { detached: done };
    }
    const tab = await resolveTab(params);
    const did = await detach(tab.id);
    return { detached: did ? [tab.id] : [] };
  }
};

// Runtime.evaluate targets the main frame unless told otherwise; child frames
// need their execution context, which is matched by URL against the frame
// tree (the extension and debugger frame id spaces are unrelated).
const contexts = new Map(); // tabId -> Map(contextId -> {frameId (cdp), url, isDefault})

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (method === 'Runtime.executionContextCreated') {
    const ctx = params.context;
    if (!contexts.has(source.tabId)) contexts.set(source.tabId, new Map());
    contexts.get(source.tabId).set(ctx.id, { cdpFrameId: ctx.auxData && ctx.auxData.frameId, isDefault: !!(ctx.auxData && ctx.auxData.isDefault), origin: ctx.origin, name: ctx.name });
  } else if (method === 'Runtime.executionContextDestroyed') {
    const map = contexts.get(source.tabId);
    if (map) map.delete(params.executionContextId);
  } else if (method === 'Runtime.executionContextsCleared') {
    contexts.delete(source.tabId);
  }
});

async function executionContextFor(tabId, frameId) {
  const frame = await chrome.webNavigation.getFrame({ tabId, frameId });
  if (!frame) throw new BridgeError('element_not_found', `no frame ${frameId} in this tab`);
  const tree = await cdp(tabId, 'Page.getFrameTree');
  const flat = [];
  (function walk(node) {
    flat.push(node.frame);
    for (const child of node.childFrames || []) walk(child);
  })(tree.frameTree);
  const candidates = flat.filter(f => f.url === frame.url && f.id !== tree.frameTree.frame.id);
  const map = contexts.get(tabId) || new Map();
  for (const candidate of candidates) {
    for (const [id, ctx] of map) {
      if (ctx.cdpFrameId === candidate.id && ctx.isDefault) return id;
    }
  }
  // Out-of-process frames live in their own targets, which this attachment does not see.
  throw new BridgeError('unsupported', `frame ${frameId} has no reachable script context (cross-origin frames run out of process)`, [
    'Read it with `amcu browser snapshot`; act on its elements with click/type/fill, which do not need script access.'
  ]);
}
