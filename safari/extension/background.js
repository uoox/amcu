// amcu bridge for Safari — background page.
//
// Safari has no stdio native messaging host and no debugger API, so this is
// not the Chrome worker with a different transport; it is its own small
// backend sharing only the content script (the page outline and refs).
//
// Transport: long polling. `browser.runtime.sendNativeMessage` reaches the
// container app's extension (`.appex`), which forwards to the amcu relay on
// 127.0.0.1; the relay holds each poll until the CLI has a request. Answers
// travel back as {type:"response"}.
//
// Input: Safari gives extensions no trusted input, so clicks, keys and text
// are DOM events dispatched by the content script (isTrusted=false) and every
// result says so (`mode: synthetic…`). Screenshots are captureVisibleTab:
// the visible part of the selected tab only. Console, network, dialogs and
// drag are refused with an explanation rather than faked.

const api = globalThis.browser || globalThis.chrome;
const VERSION = api.runtime.getManifest().version;
// Safari ignores the application id and routes to the containing app.
const APP_ID = 'cc.uoox.amcu.safari';
const POLL_WAIT_MS = 15000;

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
  if (/next page in history|no (previous|next) page|history/i.test(message) && /history/i.test(message)) {
    return new BridgeError('unsupported', `this tab has no page to go to in that direction (${message})`, ['Use `amcu browser navigate --url …` instead.']);
  }
  if (/permission|not allowed|access to|Cannot access|Missing host/i.test(message)) {
    return new BridgeError('unsupported', `Safari did not let the extension touch this page: ${message}`, [
      'Give the extension website access: Safari → Settings → Extensions → amcu bridge → Edit Websites… → Other websites: Allow.',
      'Safari\'s own pages (Settings, Start Page, the Extensions gallery) are off limits to extensions.'
    ]);
  }
  return new BridgeError('page_error', message);
}

function unsupported(what, why, nextSteps) {
  return new BridgeError('unsupported', `${what} is not available in Safari: ${why}`, nextSteps);
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new BridgeError('timeout', `${what} did not complete within ${ms} ms`, [
      'The page may be busy or blocked by a JavaScript dialog (Safari gives extensions no way to answer one; desktop amcu can: `amcu snapshot --app com.apple.Safari`).',
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
// State that must outlive a sleeping background page lives in storage.

const memory = new Map();
const store = {
  async get(key) {
    if (api.storage && api.storage.session) {
      try { return (await api.storage.session.get(key))[key]; } catch (_) { /* fall back */ }
    }
    return memory.get(key);
  },
  async set(key, value) {
    memory.set(key, value);
    if (api.storage && api.storage.session) {
      try { await api.storage.session.set({ [key]: value }); } catch (_) { /* memory only */ }
    }
  },
  async remove(key) {
    memory.delete(key);
    if (api.storage && api.storage.session) {
      try { await api.storage.session.remove(key); } catch (_) { /* memory only */ }
    }
  },
  async all() {
    if (api.storage && api.storage.session) {
      try { return await api.storage.session.get(null); } catch (_) { /* fall back */ }
    }
    return Object.fromEntries(memory);
  }
};

// ---------------------------------------------------------------------------
// Relay connection (long polling through the app extension)

const status = { state: 'starting', error: null, since: null, requests: 0, lastContact: null };
const recentErrors = [];
let polling = false;
let hostAccess = null;
let hostAccessCheckedAt = 0;

function noteError(where, error) {
  recentErrors.push({ at: Date.now(), where, message: String(error && error.message || error) });
  while (recentErrors.length > 20) recentErrors.shift();
}

async function checkHostAccess() {
  if (Date.now() - hostAccessCheckedAt < 30000 && hostAccess !== null) return hostAccess;
  try {
    hostAccess = await api.permissions.contains({ origins: ['<all_urls>'] });
  } catch (_) {
    hostAccess = null;
  }
  hostAccessCheckedAt = Date.now();
  return hostAccess;
}

function setStatus(update) {
  Object.assign(status, update);
  store.set('status', Object.assign({}, status)).catch(() => {});
}

async function pollLoop() {
  if (polling) return;
  polling = true;
  let backoff = 500;
  try {
    while (true) {
      let reply;
      try {
        reply = await api.runtime.sendNativeMessage(APP_ID, {
          type: 'poll',
          version: VERSION,
          userAgent: navigator.userAgent,
          hostAccess: await checkHostAccess(),
          waitMs: POLL_WAIT_MS
        });
      } catch (error) {
        noteError('poll', error);
        setStatus({ state: 'disconnected', error: String(error && error.message || error) });
        await sleep(backoff);
        backoff = Math.min(backoff * 2, 3000);
        continue;
      }
      if (reply && reply.type === 'request') {
        backoff = 500;
        if (status.state !== 'connected') setStatus({ state: 'connected', error: null, since: Date.now() });
        status.lastContact = Date.now();
        serve(reply);
        continue;
      }
      if (reply && reply.type === 'idle') {
        backoff = 500;
        status.lastContact = Date.now();
        if (status.state !== 'connected') setStatus({ state: 'connected', error: null, since: Date.now() });
        // Another Safari profile is the one being driven; check back later.
        if (reply.reason) await sleep(5000);
        continue;
      }
      // {type:"error"}: the relay is not running (it starts with the next
      // CLI command) or the install is inconsistent. Retry gently.
      setStatus({ state: 'disconnected', error: reply && reply.message || 'no reply from the app extension' });
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 3000);
    }
  } finally {
    polling = false;
  }
}

async function respond(message) {
  try {
    await api.runtime.sendNativeMessage(APP_ID, message);
  } catch (error) {
    noteError('respond', error);
    if (message.ok) {
      try {
        await api.runtime.sendNativeMessage(APP_ID, { type: 'response', id: message.id, ok: false, error: new BridgeError('page_error', `the extension could not deliver its reply: ${error && error.message || error}`).toJSON() });
      } catch (_) { /* the relay will time the request out */ }
    }
  }
}

function serve(request) {
  status.requests += 1;
  handleRequest(request.method, request.params || {})
    .then(result => respond({ type: 'response', id: request.id, ok: true, result }))
    .catch(error => {
      noteError(request.method, error);
      respond({ type: 'response', id: request.id, ok: false, error: asBridgeError(error).toJSON() });
    });
}

// Safari unloads an idle background page. Anything that wakes it — an
// alarm, a tab loading, the browser starting — restarts the loop.
api.alarms.create('amcu-poll', { periodInMinutes: 1 });
api.alarms.onAlarm.addListener(() => pollLoop());
api.tabs.onUpdated.addListener(() => pollLoop());
api.tabs.onActivated.addListener(() => pollLoop());
api.runtime.onStartup.addListener(() => pollLoop());
api.runtime.onInstalled.addListener(() => pollLoop());
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.__amcuPopup) {
    pollLoop();
    sendResponse({ status, recentErrors, hostAccess });
  }
  return false;
});
pollLoop();

// ---------------------------------------------------------------------------
// Tabs and sessions. Safari cannot open a window without focusing it (and
// with it, Safari itself), so amcu's tabs open unselected in the user's
// front window instead of a window of amcu's own.

const createdTabs = [];
api.tabs.onCreated.addListener(tab => {
  createdTabs.push({ id: tab.id, openerTabId: tab.openerTabId, at: Date.now() });
  while (createdTabs.length > 50) createdTabs.shift();
});

async function currentTabId(session) {
  return (await store.get('session:' + session)) || null;
}

async function setCurrentTab(session, tabId) {
  if (tabId) await store.set('session:' + session, tabId);
  else await store.remove('session:' + session);
}

async function ownTabs() {
  return (await store.get('ownTabs')) || [];
}

async function noteOwnTab(tabId) {
  const list = await ownTabs();
  if (!list.includes(tabId)) list.push(tabId);
  await store.set('ownTabs', list.slice(-200));
}

async function getTab(tabId) {
  try {
    return await api.tabs.get(tabId);
  } catch (_) {
    return null;
  }
}

async function resolveTab(params, { acting = false } = {}) {
  if (params.tab !== undefined && params.tab !== null) {
    const tab = await getTab(params.tab);
    if (!tab) throw new BridgeError('tab_not_found', `no tab with id ${params.tab}`, ['Run `amcu browser tabs --browser safari` to list tabs with their ids.']);
    return tab;
  }
  const session = params.session || 'default';
  const current = await currentTabId(session);
  if (current) {
    const tab = await getTab(current);
    if (tab) return tab;
    await setCurrentTab(session, null);
  }
  const [active] = await api.tabs.query({ active: true, currentWindow: true });
  const [any] = active ? [active] : await api.tabs.query({ active: true });
  if (any) {
    if (acting && !(await ownTabs()).includes(any.id)) {
      throw new BridgeError('no_current_tab', `this session has no current tab, and acting would hit the tab the user is looking at ("${truncate(any.title, 80)}")`, [
        'Open a tab of your own with `amcu browser tab --new --url … --browser safari` — it opens unselected and never takes the user\'s focus.',
        'To act on an existing tab deliberately: `amcu browser tabs --browser safari`, then `tab --select ID` or --tab ID.'
      ]);
    }
    return any;
  }
  throw new BridgeError('tab_not_found', 'Safari has no tabs', ['Open one with `amcu browser tab --new --url https://… --browser safari`.']);
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
    attached: false
  }, extra);
}

// ---------------------------------------------------------------------------
// Content script calls

async function inject(tabId, frameId) {
  const target = frameId === undefined ? { tabId, allFrames: true } : { tabId, frameIds: [frameId] };
  try {
    await api.scripting.executeScript({ target, files: ['content.js'] });
  } catch (error) {
    if (frameId === undefined) {
      try {
        await api.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
        return;
      } catch (inner) {
        throw asBridgeError(inner);
      }
    }
    throw asBridgeError(error);
  }
}

async function callFrame(tabId, frameId, op, params, timeoutMs = 10000) {
  const message = { __amcu: true, op, params };
  const send = () => (frameId ? api.tabs.sendMessage(tabId, message, { frameId }) : api.tabs.sendMessage(tabId, message, { frameId: 0 }));
  let response;
  try {
    response = await withTimeout(send(), timeoutMs, `content script '${op}'`);
  } catch (error) {
    if (error instanceof BridgeError && error.code === 'timeout') throw error;
    await inject(tabId, frameId);
    response = await withTimeout(send(), timeoutMs, `content script '${op}'`);
  }
  if (!response) throw new BridgeError('page_error', `no response from the page for '${op}'`);
  if (!response.ok) throw asBridgeError(response.error);
  return response.result;
}

async function listFrames(tabId) {
  try {
    const frames = await api.webNavigation.getAllFrames({ tabId }) || [];
    const usable = frames.filter(f => f.frameId >= 0 && !f.errorOccurred);
    if (usable.length) return usable;
  } catch (_) { /* fall through */ }
  const tab = await getTab(tabId);
  return [{ frameId: 0, parentFrameId: -1, url: tab ? tab.url : '' }];
}

function parseRef(ref) {
  const match = /^(?:f(\d+))?e(\d+)$/.exec(String(ref || '').trim());
  if (!match) {
    throw new BridgeError('invalid_argument', `'${ref}' is not a ref`, [
      'Refs look like e12 (main frame) or f42e12 (frame 42), as printed by `amcu browser snapshot`.'
    ]);
  }
  return { frameId: match[1] ? parseInt(match[1], 10) : 0, local: 'e' + match[2] };
}

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
    const frame = (await listFrames(tab.id)).find(f => f.frameId === frameId);
    places.push({ what: `frame ${frameId}`, host: frame ? hostOf(frame.url || '') : '' });
  }
  for (const place of places) {
    if (domains.some(pattern => hostMatches(place.host, pattern))) continue;
    throw new BridgeError('secret_scope', `secret ${params.secretKey || ''} is restricted to ${domains.join(', ')}; ${place.what} is at ${place.host || '(unknown host)'}`, [
      'The secrets file limits where this key may be typed (KEY__DOMAINS=host,*.example.com). Check that the page is the one you meant.',
      'If the restriction itself is wrong, widen KEY__DOMAINS in the secrets file.'
    ]);
  }
}

async function openedTabSince(openerId, since, params) {
  const hits = createdTabs.filter(t => t.at >= since && t.openerTabId === openerId);
  if (!hits.length) return null;
  const tab = await getTab(hits[hits.length - 1].id);
  if (!tab) return null;
  await noteOwnTab(tab.id);
  let nowCurrent = false;
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
// Navigation and effects

async function settle(tabId, before, timeoutMs = 5000) {
  await sleep(150);
  const started = Date.now();
  let tab = await getTab(tabId);
  while (tab && tab.status === 'loading' && Date.now() - started < timeoutMs) {
    await sleep(100);
    tab = await getTab(tabId);
  }
  if (!tab) return { closed: true };
  return { navigated: tab.url !== before.url, url: tab.url, title: tab.title, loading: tab.status === 'loading' };
}

async function waitForNavigation(tabId, timeoutMs, { from = null, expect = null, reload = false } = {}) {
  const started = Date.now();
  let transitioned = false;
  while (Date.now() - started < timeoutMs) {
    const tab = await getTab(tabId);
    if (!tab) throw new BridgeError('tab_not_found', 'the tab closed while navigating');
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
  return tab;
}

async function waitForLoad(tabId, timeoutMs) {
  const started = Date.now();
  await sleep(100);
  let tab = await getTab(tabId);
  while (tab && tab.status !== 'complete' && Date.now() - started < timeoutMs) {
    await sleep(100);
    tab = await getTab(tabId);
  }
  if (!tab) throw new BridgeError('tab_not_found', 'the tab closed while loading');
  return tab;
}

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
  if (!after || after.closed || after.navigated) {
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
// Keys

const MODIFIER_ALIASES = { option: 'alt', opt: 'alt', control: 'ctrl', cmd: 'meta', command: 'meta', super: 'meta', win: 'meta' };

function modifierSet(list) {
  const out = { alt: false, ctrl: false, meta: false, shift: false };
  for (const raw of list || []) {
    const name = MODIFIER_ALIASES[String(raw).toLowerCase()] || String(raw).toLowerCase();
    if (!(name in out)) throw new BridgeError('invalid_argument', `unknown modifier '${raw}'`, ['Use cmd, ctrl, alt, shift.']);
    out[name] = true;
  }
  return out;
}

const NAMED_KEYS = {
  enter: ['Enter', 'Enter', 13], return: ['Enter', 'Enter', 13], tab: ['Tab', 'Tab', 9],
  escape: ['Escape', 'Escape', 27], esc: ['Escape', 'Escape', 27], backspace: ['Backspace', 'Backspace', 8],
  delete: ['Delete', 'Delete', 46], del: ['Delete', 'Delete', 46], space: [' ', 'Space', 32],
  arrowleft: ['ArrowLeft', 'ArrowLeft', 37], arrowup: ['ArrowUp', 'ArrowUp', 38], arrowright: ['ArrowRight', 'ArrowRight', 39], arrowdown: ['ArrowDown', 'ArrowDown', 40],
  left: ['ArrowLeft', 'ArrowLeft', 37], up: ['ArrowUp', 'ArrowUp', 38], right: ['ArrowRight', 'ArrowRight', 39], down: ['ArrowDown', 'ArrowDown', 40],
  home: ['Home', 'Home', 36], end: ['End', 'End', 35], pageup: ['PageUp', 'PageUp', 33], pagedown: ['PageDown', 'PageDown', 34]
};
for (let i = 1; i <= 12; i++) NAMED_KEYS['f' + i] = ['F' + i, 'F' + i, 111 + i];

function lookupKey(raw, mods) {
  const name = String(raw);
  const named = NAMED_KEYS[name.toLowerCase()];
  if (named) return { key: named[0], code: named[1], keyCode: named[2], text: named[0] === ' ' ? ' ' : undefined };
  if (name.length === 1) {
    const upper = name.toUpperCase();
    const isLetter = /[a-z]/i.test(name);
    const isDigit = /[0-9]/.test(name);
    const key = mods.shift && isLetter ? upper : name;
    return {
      key,
      code: isLetter ? 'Key' + upper : isDigit ? 'Digit' + name : '',
      keyCode: isLetter ? upper.charCodeAt(0) : isDigit ? name.charCodeAt(0) : 0,
      text: key
    };
  }
  throw new BridgeError('invalid_argument', `unknown key '${raw}'`, [
    'Use a key name (Enter, Tab, Escape, Backspace, ArrowDown, Home, F5, a, 1, …), with --mod cmd,shift for modifiers.'
  ]);
}

async function pressKey(tabId, frameId, raw, modifiers) {
  const mods = modifierSet(modifiers);
  const key = lookupKey(raw, mods);
  const result = await callFrame(tabId, frameId, 'synthetic-key', Object.assign({}, key, { modifiers: mods }));
  return Object.assign({ key: key.key }, result);
}

// ---------------------------------------------------------------------------
// --element check (same rules as the Chrome extension)

async function expectElement(params) {
  const ref = params.ref || params.from;
  if (!ref) {
    throw new BridgeError('invalid_argument', '--element needs an element to check against; this command has no --ref', [
      'Add --ref (or --target) with a ref from `amcu browser snapshot`, or drop --element.'
    ]);
  }
  const tab = await resolveTab(params);
  const { frameId, local } = parseRef(ref);
  const described = await callFrame(tab.id, frameId, 'describe', { ref: local });
  const actual = String(described.description || '').replace(/\s*\[ref=[^\]]*\]/g, '').replace(/\s*<[^>]*>/g, '');
  if (elementMatches(params.expect, actual)) return;
  throw new BridgeError('element_mismatch', `element ${ref} is ${actual}, not "${params.expect}"`, [
    'Re-run `amcu browser snapshot` and use the ref whose role and name match what you mean.',
    'If the description was merely loosely worded, drop --element; the ref alone addresses the element.'
  ]);
}

const STOP_WORDS = new Set(['the', 'a', 'an', 'to', 'of', 'for', 'in', 'on', 'at', 'with', 'this', 'that', 'element', 'control', 'page']);
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
  const words = String(expect).toLowerCase()
    .replace(/按钮|链接|输入框|文本框|复选框|单选框|下拉框|下拉|菜单项|菜单|选项卡|选项|图片|图标|标题|字段|元素|控件|文本/g, ' ')
    .split(/[^\p{L}\p{N}]+/u).filter(word => word && !STOP_WORDS.has(word));
  if (words.length === 0) return true;
  const specific = words.filter(word => !(word in ROLE_SYNONYMS));
  if (specific.length > 0) return specific.every(word => wordPresent(word, haystack));
  return words.every(word => wordPresent(word, haystack) || ROLE_SYNONYMS[word].some(role => wordPresent(role, haystack)));
}

function wordPresent(word, haystack) {
  if (/^[\p{Script=Latin}\p{N}]+$/u.test(word)) {
    const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(`(^|[^\\p{Script=Latin}\\p{N}])${escaped}(?=$|[^\\p{Script=Latin}\\p{N}])`, 'u').test(haystack);
  }
  return haystack.includes(word);
}

// ---------------------------------------------------------------------------
// Evaluation in the page's own world

// Runs inside the page (MAIN world): page globals are visible, and so is the
// page's Content-Security-Policy, which may forbid compiling strings.
function pageEvaluate(source, tag) {
  const element = tag ? document.querySelector(`[data-amcu-target="${tag}"]`) : undefined;
  const pack = value => {
    const type = value === null ? 'object' : typeof value;
    if (value === undefined) return { ok: true, value: null, type: 'undefined' };
    if (value instanceof Element) return { ok: true, value: value.outerHTML.slice(0, 2000), type: 'node' };
    try {
      return { ok: true, value: JSON.parse(JSON.stringify(value)), type };
    } catch (_) {
      return { ok: true, value: String(value), type };
    }
  };
  const failed = error => ({
    ok: false,
    error: String(error && error.message || error),
    csp: error instanceof EvalError || /unsafe-eval|Content Security Policy|Refused to evaluate/i.test(String(error && error.message || error))
  });
  let fn;
  try {
    fn = new Function('element', `return (async () => { const __v = (${source}\n); return typeof __v === 'function' ? await __v(element) : __v; })()`);
  } catch (error) {
    if (!(error instanceof SyntaxError)) return failed(error);
    try {
      fn = new Function('element', `return (async () => { ${source}\n })()`);
    } catch (inner) {
      return failed(inner);
    }
  }
  return Promise.resolve().then(() => fn(element)).then(pack, error => Object.assign(failed(error), { thrown: true }));
}

// ---------------------------------------------------------------------------
// Handlers

async function handleRequest(method, params) {
  const handler = handlers[method];
  if (!handler) throw new BridgeError('unsupported', `unknown method '${method}'`, ['Update the bridge: `amcu browser install --browser safari`.']);
  if (params && params.expect) await expectElement(params);
  return handler(params);
}

const WINDOW_REFUSAL = [
  'Safari cannot open a window without bringing it (and Safari) to the front, so amcu\'s Safari tabs open unselected in the user\'s front window instead — `amcu browser tabs --browser safari` lists them.',
  'To watch one: `amcu browser tab --select ID --activate --browser safari` (a visible change).'
];

const handlers = {
  async hello() {
    return { version: VERSION, extensionId: api.runtime.id };
  },

  async status(params) {
    const tabs = await api.tabs.query({});
    const sessions = {};
    for (const [key, value] of Object.entries(await store.all())) {
      if (key.startsWith('session:')) sessions[key.slice(8)] = value;
    }
    return {
      version: VERSION,
      extensionId: api.runtime.id,
      tabs: tabs.length,
      attached: [],
      sessions,
      requests: status.requests,
      hostConnectedSince: status.since,
      hostAccess: await checkHostAccess(),
      recentErrors
    };
  },

  async 'extension.reload'() {
    setTimeout(() => api.runtime.reload(), 200);
    return { reloading: true, version: VERSION };
  },

  async frames(params) {
    const tab = await resolveTab(params);
    const frames = await listFrames(tab.id);
    return { tab: tabSummary(tab), frames: frames.map(f => ({ frameId: f.frameId, parentFrameId: f.parentFrameId, url: f.url })) };
  },

  async 'tabs.list'(params) {
    const current = await currentTabId(params.session || 'default');
    const tabs = await api.tabs.query({});
    return { tabs: tabs.map(tab => tabSummary(tab, { current: tab.id === current })), current };
  },

  async 'tabs.create'(params) {
    const session = params.session || 'default';
    const create = { url: params.url || 'about:blank', active: !!params.activate };
    const [front] = await api.tabs.query({ active: true, currentWindow: true });
    if (front) create.windowId = front.windowId;
    const tab = await api.tabs.create(create);
    await noteOwnTab(tab.id);
    await setCurrentTab(session, tab.id);
    const loaded = params.url && params.wait !== false ? await waitForLoad(tab.id, params.timeoutMs || 30000) : tab;
    return { tab: tabSummary(loaded, { current: true }), placement: params.activate ? 'user-window-active' : 'user-window-background' };
  },

  async 'tabs.select'(params) {
    const tab = await getTab(params.tab);
    if (!tab) throw new BridgeError('tab_not_found', `no tab with id ${params.tab}`, ['Run `amcu browser tabs --browser safari`.']);
    await setCurrentTab(params.session || 'default', tab.id);
    if (params.activate) {
      await api.tabs.update(tab.id, { active: true });
      await api.windows.update(tab.windowId, { focused: true });
    }
    return { tab: tabSummary(await getTab(tab.id) || tab, { current: true }) };
  },

  async 'tabs.close'(params) {
    const tab = await resolveTab(params, { acting: true });
    await api.tabs.remove(tab.id);
    return { closed: tabSummary(tab) };
  },

  async navigate(params) {
    const tab = await resolveTab(params, { acting: true });
    if (!params.url) throw new BridgeError('invalid_argument', '--url is required');
    let url = params.url;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) url = 'https://' + url;
    const from = tab.url;
    await api.tabs.update(tab.id, { url });
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab), loading: true };
    const loaded = await waitForNavigation(tab.id, params.timeoutMs || 30000, { from, expect: url });
    return { tab: tabSummary(loaded), loading: loaded.status !== 'complete' };
  },

  async back(params) {
    const tab = await resolveTab(params, { acting: true });
    const from = tab.url;
    await api.tabs.goBack(tab.id);
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 15000, { from })) };
  },

  async forward(params) {
    const tab = await resolveTab(params, { acting: true });
    const from = tab.url;
    await api.tabs.goForward(tab.id);
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 15000, { from })) };
  },

  async reload(params) {
    const tab = await resolveTab(params, { acting: true });
    await api.tabs.reload(tab.id, { bypassCache: !!params.hard });
    if (params.wait === false) return { tab: tabSummary(await getTab(tab.id) || tab) };
    return { tab: tabSummary(await waitForNavigation(tab.id, params.timeoutMs || 30000, { reload: true })) };
  },

  async snapshot(params) {
    const tab = await resolveTab(params);
    await inject(tab.id);
    const frames = await listFrames(tab.id);
    const options = { selector: params.selector, maxNodes: params.maxNodes, allRefs: params.allRefs, interactiveOnly: params.interactiveOnly, diff: params.diff };
    const within = params.within ? parseRef(params.within) : null;
    let wanted = params.frame !== undefined && params.frame !== null ? frames.filter(f => f.frameId === params.frame) : frames;
    if (params.selector && (params.frame === undefined || params.frame === null)) wanted = frames.filter(f => f.frameId === 0);
    if (within) {
      wanted = frames.filter(f => f.frameId === within.frameId);
      if (!wanted.length) throw new BridgeError('stale_snapshot', `frame ${within.frameId} no longer exists in this tab`, ['Re-run `amcu browser snapshot`.']);
    }
    if (params.frame !== undefined && params.frame !== null && !wanted.length) {
      throw new BridgeError('element_not_found', `no frame ${params.frame} in this tab`, ['Frame ids appear in the snapshot as f<id>; re-run `amcu browser snapshot`.']);
    }
    const results = [];
    let budget = Math.max(1, params.maxNodes || 1500);
    const iframesByFrame = new Map();
    for (const frame of wanted.slice().sort((a, b) => a.frameId - b.frameId)) {
      const isMain = frame.frameId === 0;
      const frameOptions = Object.assign({}, options, { maxNodes: budget });
      if (!isMain && params.selector) frameOptions.selector = undefined;
      if (within && frame.frameId === within.frameId) frameOptions.within = within.local;
      let result;
      try {
        result = await callFrame(tab.id, frame.frameId, 'snapshot', frameOptions, 15000);
      } catch (error) {
        const bridge = asBridgeError(error);
        if (isMain) throw bridge;
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
        parentRef: null,
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
        listenersScanned: false,
        listenersFound: 0,
        diff: result.diff === true,
        added: result.added,
        removed: result.removed,
        diffBase: result.diffBase
      });
    }
    for (const r of results) {
      if (r.frameId === 0 || r.parentFrameId === undefined) continue;
      const siblings = iframesByFrame.get(r.parentFrameId) || [];
      const url = r.url || '';
      const match = siblings.find(f => f.src && (url === f.src || url.endsWith(f.src) || url.includes(f.src))) || siblings[0];
      if (match) r.parentRef = match.ref;
    }
    return { tab: tabSummary(tab), frames: results };
  },

  async find(params) {
    const tab = await resolveTab(params);
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
      const lines = frame.frameId === 0 ? result.matches : result.matches.map(line => line.replace(/\[ref=e(\d+)\]/g, `[ref=f${frame.frameId}e$1]`));
      matches.push(...lines);
      total += result.total;
      if (frame.frameId === 0) gen = result.gen;
    }
    return { tab: tabSummary(tab), matches, total, gen };
  },

  async click(params) {
    const tab = await resolveTab(params, { acting: true });
    const before = { url: tab.url };
    const { frameId, local } = parseRef(params.ref);
    const measured = await callFrame(tab.id, frameId, 'measure', { ref: local });
    const description = frameId === 0 ? measured.description : String(measured.description || '').replace(/\[ref=e(\d+)\]/g, `[ref=f${frameId}e$1]`);
    if (measured.hit === 'obscured' && !params.force) {
      throw new BridgeError('element_obscured', `element ${params.ref} (${description}) is covered by ${measured.obscuredBy}; a click there would land on the cover`, [
        'If the cover is a dialog, banner or menu, deal with it first (click its close/accept control from a fresh snapshot).',
        'Pass --force to dispatch the click on the element itself regardless.'
      ]);
    }
    if (measured.hit === 'outside' && !params.force) {
      throw new BridgeError('element_not_found', `element ${params.ref} (${description}) could not be scrolled into the viewport`, [
        'Try `amcu browser scroll` on its container first, or --force to dispatch the click anyway.'
      ]);
    }
    const armed = await armObserver(tab.id, frameId);
    const startedAt = Date.now();
    const clicked = await callFrame(tab.id, frameId, 'synthetic-click', {
      ref: local, x: measured.x, y: measured.y, button: params.button, count: params.count || 1, modifiers: modifierSet(params.modifiers)
    });
    const after = await settle(tab.id, before, 5000);
    const effect = await reportObserver(tab.id, armed, after);
    if (effect) after.effect = effect;
    const opened = await openedTabSince(tab.id, startedAt, params);
    if (opened) after.openedTab = opened;
    return {
      tab: tabSummary(tab),
      ref: params.ref,
      description,
      point: { x: Math.round(measured.x), y: Math.round(measured.y) },
      mode: 'synthetic (DOM events, isTrusted=false)',
      synthetic: true,
      fromEarlierSnapshot: measured.fromEarlierSnapshot,
      unstable: measured.stable === false,
      obscuredNote: measured.hit === 'ancestor' ? `pointer lands on ${measured.obscuredBy}` : null,
      after
    };
  },

  async hover(params) {
    const tab = await resolveTab(params, { acting: true });
    const { frameId, local } = parseRef(params.ref);
    const measured = await callFrame(tab.id, frameId, 'measure', { ref: local });
    await callFrame(tab.id, frameId, 'synthetic-hover', { ref: local, x: measured.x, y: measured.y });
    return {
      tab: tabSummary(tab), ref: params.ref, description: measured.description,
      point: { x: Math.round(measured.x), y: Math.round(measured.y) },
      synthetic: true, note: 'mouse events dispatched; CSS :hover does not apply to synthetic events'
    };
  },

  async drag() {
    throw unsupported('drag', 'Safari has no trusted pointer path for extensions, and a synthetic drag does not move sliders or drag-and-drop libraries reliably', [
      'Use desktop amcu on the Safari window (`amcu drag --app com.apple.Safari --from X,Y --to X,Y`) or `--browser chrome`.'
    ]);
  },

  async type(params) {
    const tab = await resolveTab(params, { acting: true });
    const { frameId, local } = parseRef(params.ref);
    await requireSecretScope(tab, params, frameId);
    const focus = await callFrame(tab.id, frameId, 'focus-for-input', { ref: local, mode: params.replace ? 'replace' : 'append' });
    const armed = await armObserver(tab.id, frameId);
    const startedAt = Date.now();
    const text = String(params.text === undefined ? '' : params.text);
    let mode = null;
    if (params.slowly) {
      for (const ch of text) {
        if (ch === '\n') await pressKey(tab.id, frameId, 'Enter', []);
        else await pressKey(tab.id, frameId, ch, []);
        await sleep(15);
      }
      mode = 'key by key';
    } else if (text.length) {
      mode = (await callFrame(tab.id, frameId, 'insert-text', { text })).mode;
    }
    let submitted = false;
    if (params.submit) {
      await pressKey(tab.id, frameId, 'Enter', []);
      submitted = true;
    }
    const before = { url: tab.url };
    const after = params.submit ? await settle(tab.id, before, 5000) : { navigated: false, url: tab.url };
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
      tab: tabSummary(tab), ref: params.ref, description: focus.description, typed: text.length, submitted,
      value: typeof value === 'string' ? value : null, mode, synthetic: true,
      fromEarlierSnapshot: focus.fromEarlierSnapshot, after
    };
  },

  async fill(params) {
    const tab = await resolveTab(params, { acting: true });
    const { frameId, local } = parseRef(params.ref);
    await requireSecretScope(tab, params, frameId);
    const value = String(params.value === undefined ? '' : params.value);
    const focus = await callFrame(tab.id, frameId, 'focus-for-input', { ref: local, mode: 'replace' });
    let mode;
    if (value.length) {
      mode = (await callFrame(tab.id, frameId, 'insert-text', { text: value })).mode;
    } else {
      await pressKey(tab.id, frameId, 'Backspace', []);
      mode = 'synthetic key';
    }
    let read = (await callFrame(tab.id, frameId, 'value', { ref: local }, 3000)).value;
    if (typeof read !== 'string') read = String(read);
    let verified = read === value;
    if (!verified && focus.kind === 'input' && focus.assignable) {
      const direct = await callFrame(tab.id, frameId, 'set-value', { ref: local, value }, 3000);
      read = typeof direct.value === 'string' ? direct.value : String(direct.value);
      verified = read === value;
      mode = 'js:value';
    }
    return { tab: tabSummary(tab), ref: params.ref, description: focus.description, mode, verified, expected: value, actual: read, synthetic: true, fromEarlierSnapshot: focus.fromEarlierSnapshot };
  },

  async 'select-option'(params) {
    const tab = await resolveTab(params, { acting: true });
    const { frameId, local } = parseRef(params.ref);
    const result = await callFrame(tab.id, frameId, 'select-option', { ref: local, values: params.values || [] });
    return Object.assign({ tab: tabSummary(tab), ref: params.ref }, result);
  },

  async key(params) {
    const tab = await resolveTab(params, { acting: true });
    let frameId = 0;
    if (params.ref) {
      const parsed = parseRef(params.ref);
      frameId = parsed.frameId;
      await callFrame(tab.id, frameId, 'focus-for-input', { ref: parsed.local, mode: 'append' }).catch(async () => {
        const focused = await callFrame(tab.id, frameId, 'focus', { ref: parsed.local });
        if (!focused.focused) {
          throw new BridgeError('unsupported', `element ${params.ref} (${focused.description}) cannot take keyboard focus`, [
            'Aim the key at a focusable element, or omit --ref to send it to whatever is focused.'
          ]);
        }
      });
    }
    const before = { url: tab.url };
    const count = Math.max(1, params.count || 1);
    const armed = await armObserver(tab.id, frameId);
    const startedAt = Date.now();
    let pressed;
    for (let i = 0; i < count; i++) pressed = await pressKey(tab.id, frameId, params.key, params.modifiers || []);
    const after = await settle(tab.id, before, 3000);
    const effect = await reportObserver(tab.id, armed, after);
    if (effect) after.effect = effect;
    const opened = await openedTabSince(tab.id, startedAt, params);
    if (opened) after.openedTab = opened;
    return {
      tab: tabSummary(tab), key: pressed.key, modifiers: params.modifiers || [], count, after,
      synthetic: true, cancelled: pressed.cancelled, defaultAction: pressed.action
    };
  },

  async scroll(params) {
    const tab = await resolveTab(params, { acting: true });
    let frameId = 0, local = null;
    if (params.ref) ({ frameId, local } = parseRef(params.ref));
    const result = await callFrame(tab.id, frameId, 'scroll-by', { ref: local, dx: params.dx || 0, dy: params.dy || 0 });
    return { tab: tabSummary(tab), at: result.at, dx: params.dx || 0, dy: params.dy || 0, moved: result.moved, mode: 'programmatic (scrollBy)' };
  },

  async screenshot(params) {
    if (params.full) {
      throw unsupported('screenshot --full', 'Safari extensions can capture only the visible part of the selected tab', [
        'Scroll and take several screenshots, or read the whole page with `amcu browser snapshot`.'
      ]);
    }
    const tab = await resolveTab(params);
    if (!tab.active) {
      throw new BridgeError('capture_failure', `tab ${tab.id} is not the selected tab of its window, and Safari captures only what is on screen`, [
        'Read it with `amcu browser snapshot`, which needs no rendering.',
        'Or make it visible deliberately: `amcu browser tab --select ' + tab.id + ' --activate --browser safari` (a visible change in the user\'s window).'
      ]);
    }
    const format = params.format === 'jpeg' ? 'jpeg' : 'png';
    const options = { format };
    if (format === 'jpeg') options.quality = params.quality || 80;
    // Measure (which scrolls the element into view) before capturing, so the
    // crop rectangle and the pixels describe the same scroll position.
    let measured = null;
    let scrolled = false;
    if (params.ref) {
      const { frameId, local } = parseRef(params.ref);
      if (frameId !== 0) {
        throw unsupported('screenshot --ref in a frame', 'frame geometry needs the debugger protocol', ['Screenshot the whole visible tab instead.']);
      }
      const position = async () => (await callFrame(tab.id, 0, 'scroll-by', { dx: 0, dy: 0 })).after;
      const before = await position();
      await callFrame(tab.id, 0, 'measure', { ref: local });
      const after = await position();
      // A scroll the measurement caused reaches the captured surface only
      // once the browser presents a new frame; the first capture after a
      // scroll can still return the old picture (measured in Chromium), so a
      // throwaway capture comes first.
      scrolled = before.x !== after.x || before.y !== after.y;
      if (scrolled) {
        await sleep(300);
        try { await api.tabs.captureVisibleTab(tab.windowId, options); } catch (_) { /* the real capture reports */ }
        await sleep(500);
      }
      measured = await callFrame(tab.id, 0, 'measure', { ref: local, scroll: false });
    }
    let dataUrl;
    try {
      dataUrl = await api.tabs.captureVisibleTab(tab.windowId, options);
    } catch (error) {
      throw new BridgeError('capture_failure', `Safari refused the capture: ${error && error.message || error}`, [
        'The window may be minimised or on another Space; `amcu browser snapshot` reads the page without rendering.'
      ]);
    }
    let data = String(dataUrl).split(',')[1] || '';
    let clip = null;
    if (measured) {
      clip = measured.rect;
      data = await cropImage(dataUrl, measured.rect, measured.viewport, format, options.quality);
    }
    return { tab: tabSummary(tab), format, data, visibleOnly: true, clip, scrolledIntoView: scrolled };
  },

  async evaluate(params) {
    const tab = await resolveTab(params, { acting: true });
    const source = String(params.expression || '');
    if (!source.trim()) throw new BridgeError('invalid_argument', '--js is required');
    let frameId = 0;
    let tag = null;
    let local = null;
    if (params.ref) {
      ({ frameId, local } = parseRef(params.ref));
      tag = nonce();
      await callFrame(tab.id, frameId, 'tag-element', { ref: local, nonce: tag });
    } else if (params.frame) {
      frameId = params.frame;
    }
    try {
      let injected;
      try {
        injected = await withTimeout(api.scripting.executeScript({
          target: { tabId: tab.id, frameIds: [frameId] }, world: 'MAIN', func: pageEvaluate, args: [source, tag]
        }), params.timeoutMs || 30000, 'evaluation');
      } catch (error) {
        throw asBridgeError(error);
      }
      const outcome = injected && injected[0] && injected[0].result;
      if (!outcome || typeof outcome !== 'object' || !('ok' in outcome)) {
        throw new BridgeError('page_error', 'Safari returned no result for the evaluation', [
          'Return a JSON-serialisable value; a pending promise that never settles also ends here.'
        ]);
      }
      if (!outcome.ok) {
        if (outcome.csp) {
          throw new BridgeError('unsupported', `this page's Content-Security-Policy forbids evaluating code strings (${outcome.error})`, [
            'Read the page with `amcu browser snapshot` / `find` instead, or use `--browser chrome`, whose debugger-based eval is not bound by page CSP.'
          ]);
        }
        throw new BridgeError('page_error', `evaluation threw: ${outcome.error}`, [
          'Pass an expression (`document.title`), a function (`el => el.textContent`, called with the --ref element), or statements ending in `return …`.'
        ]);
      }
      return { tab: tabSummary(tab), value: outcome.value, type: outcome.type, world: 'main' };
    } finally {
      if (tag) callFrame(tab.id, frameId, 'tag-element', { ref: local, nonce: null }).catch(() => {});
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
        try { re = new RegExp(params.urlPattern); } catch (error) {
          throw new BridgeError('invalid_argument', `--url-matches is not a valid regex: ${error.message}`);
        }
        return re.test(live.url || '') ? { waited: 'url-matches', url: live.url } : null;
      }
      if (params.url) return (live.url || '').includes(params.url) ? { waited: 'url', url: live.url } : null;
      if (params.text || params.textGone) {
        let found = false;
        for (const frame of await listFrames(tab.id)) {
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

  async console() {
    throw unsupported('console', 'Safari gives extensions no access to a page\'s console', [
      'Read state with `amcu browser eval --js …`, or use `--browser chrome` / `amcu lab` for console capture.'
    ]);
  },

  async network() {
    throw unsupported('network', 'Safari gives extensions no view of a page\'s network requests', [
      'Use `--browser chrome` or `amcu lab`; `eval --js "performance.getEntriesByType(\'resource\').map(e => e.name)"` lists resource URLs.'
    ]);
  },

  async dialog() {
    throw unsupported('dialog', 'Safari gives extensions no way to see or answer alert/confirm/prompt dialogs', [
      'Desktop amcu can press the dialog\'s button: `amcu snapshot --app com.apple.Safari`, then `amcu click --element N`.'
    ]);
  },

  async upload(params) {
    const tab = await resolveTab(params, { acting: true });
    const { frameId, local } = parseRef(params.ref);
    const files = params.fileData || [];
    if (!files.length) throw new BridgeError('invalid_argument', '--file is required');
    const result = await callFrame(tab.id, frameId, 'set-files', { ref: local, files }, 30000);
    if (!result.verified) {
      throw new BridgeError('value_mismatch', `element ${params.ref} holds ${result.names.length} file(s) after the assignment, expected ${files.length}`, [
        'The page may replace its file input on change; re-snapshot and retry once.'
      ]);
    }
    return { tab: tabSummary(tab), ref: params.ref, files: result.names, mode: 'programmatic (DataTransfer)', synthetic: true };
  },

  async resize() {
    throw new BridgeError('unsupported', 'amcu\'s Safari tabs live in the user\'s own window; resizing it would disturb the user', [
      'Resize deliberately with desktop amcu: `amcu window --app com.apple.Safari --resize W,H`.'
    ]);
  },

  async 'window.info'() {
    return { window: null, note: WINDOW_REFUSAL[0] };
  },

  async 'window.show'() {
    throw new BridgeError('unsupported', 'amcu has no window of its own in Safari', WINDOW_REFUSAL);
  },

  async 'window.hide'() {
    throw new BridgeError('unsupported', 'amcu has no window of its own in Safari', WINDOW_REFUSAL);
  },

  async 'window.close'() {
    throw new BridgeError('unsupported', 'amcu has no window of its own in Safari', WINDOW_REFUSAL);
  },

  async detach() {
    // Nothing is ever attached in Safari; say so rather than pretend.
    return { detached: [], note: 'Safari has no debugger attachment to release' };
  }
};

async function cropImage(dataUrl, rect, viewport, format, quality) {
  const blob = await (await fetch(dataUrl)).blob();
  const bitmap = await createImageBitmap(blob);
  const scale = viewport && viewport.width ? bitmap.width / viewport.width : 1;
  const x = Math.max(0, Math.round(rect.x * scale));
  const y = Math.max(0, Math.round(rect.y * scale));
  const w = Math.max(1, Math.min(bitmap.width - x, Math.round(rect.width * scale)));
  const h = Math.max(1, Math.min(bitmap.height - y, Math.round(rect.height * scale)));
  const canvas = new OffscreenCanvas(w, h);
  canvas.getContext('2d').drawImage(bitmap, x, y, w, h, 0, 0, w, h);
  const out = await canvas.convertToBlob({ type: format === 'jpeg' ? 'image/jpeg' : 'image/png', quality: quality ? quality / 100 : undefined });
  const bytes = new Uint8Array(await out.arrayBuffer());
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
