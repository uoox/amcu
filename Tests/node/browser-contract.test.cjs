// node --test Tests/node/browser-contract.test.cjs (no browser/dependencies)
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');

function content() {
  let listener;
  const elements = [];
  const context = { console, setTimeout, Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    getComputedStyle: el => ({ display: el.hidden ? 'none' : 'block', visibility: 'visible', opacity: '1', content: 'none' }),
    chrome: { runtime: { onMessage: { addListener(fn) { listener = fn; } } } },
    location: { href: 'http://test/' }, window: {}, Element: class {} };
  const doc = { documentElement: { children: elements, matches: () => false }, title: '', getElementById() { return null; } };
  context.document = doc;
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(root, 'extension/content.js'), 'utf8'), context);
  const call = (op, params) => new Promise(resolve => listener({ __amcu: true, op, params }, {}, resolve));
  const add = (attrs = {}, extra = {}) => {
    const el = { nodeType: 1, tagName: 'DIV', children: [], childNodes: [], isConnected: true,
      parentElement: null, getAttribute: k => attrs[k] ?? null, hasAttribute: k => k in attrs,
      getRootNode: () => doc, closest: () => null, matches: s => s === '*' || s === '#' + attrs.id,
      getClientRects: () => [{ width: 20, height: 20 }], ...extra };
    elements.push(el); return el;
  };
  return { call, add };
}

test('shared content: intersect exact name/role/selector; hidden duplicates remain ambiguous', async () => {
  const { call, add } = content();
  add({ id: 'a', role: 'button', 'aria-label': 'Save' });
  add({ id: 'b', role: 'button', 'aria-label': 'Save' }, { hidden: true });
  assert.equal((await call('locator-matches', { role: 'button', name: 'Save' })).result.matches.length, 2);
  assert.equal((await call('locator-matches', { selector: '#a', role: 'button', name: 'Save' })).result.matches.length, 1);
  assert.equal((await call('locator-matches', { name: 'save' })).result.matches.length, 0);
  assert.equal((await call('locator-matches', { ref: 'e1', name: 'Save' })).error.code, 'invalid_argument');
});

test('content-derived names retain hidden duplicates, including hidden ancestors', async () => {
  const { call, add } = content();
  const text = data => ({ nodeType: 3, data });
  const visible = add({ id: 'visible' }, { tagName: 'BUTTON', childNodes: [text('Duplicate target')] });
  const hidden = add({ id: 'hidden' }, { tagName: 'BUTTON', hidden: true, childNodes: [text('Duplicate target')] });
  let result = await call('locator-matches', { name: 'Duplicate target' });
  assert.equal(result.result.matches.length, 2);
  assert.equal(result.result.matches[0].visible, true);
  assert.equal(result.result.matches[1].visible, false);
  // The hidden candidate's ref must remain resolvable by the same name.
  assert.equal((await call('action-state', { ref: result.result.matches[1].ref })).result.visible, false);
  hidden.hidden = false;
  hidden.parentElement = { hidden: true, getAttribute: () => null };
  result = await call('locator-matches', { name: 'Duplicate target' });
  assert.equal(result.result.matches.length, 2);
  assert.equal(result.result.matches[1].visible, false);
  assert.equal((await call('locator-matches', { selector: '#visible', name: 'Duplicate target' })).result.matches.length, 1);
  // Do not accidentally include hidden descendant text in a visible control.
  const child = add({}, { hidden: true, childNodes: [text('extra')] });
  visible.childNodes.push(child);
  assert.equal((await call('locator-matches', { selector: '#visible', name: 'Duplicate target' })).result.matches.length, 1);
});

test('content refuses disabled, mixed/missing ARIA state and radio uncheck; stale refs never relocate', async () => {
  const { call, add } = content();
  const attrs = { id: 'toggle', role: 'checkbox', 'aria-label': 'Toggle' };
  const el = add(attrs);
  const ref = (await call('locator-matches', { selector: '#toggle' })).result.matches[0].ref;
  assert.equal((await call('action-state', { ref, prepare: true, desired: true })).error.code, 'unsupported');
  attrs['aria-checked'] = 'mixed';
  assert.equal((await call('action-state', { ref, prepare: true, desired: true })).error.code, 'unsupported');
  attrs['aria-checked'] = 'false'; attrs['aria-disabled'] = 'true';
  assert.equal((await call('action-state', { ref, prepare: true, desired: true })).error.code, 'unsupported');
  delete attrs['aria-disabled']; attrs['aria-label'] = 'Changed';
  assert.equal((await call('action-state', { ref })).error.code, 'stale_snapshot');
  el.isConnected = false;
  assert.equal((await call('action-state', { ref })).error.code, 'stale_snapshot');
  add({ id: 'radio', role: 'radio', 'aria-checked': 'true' });
  const radio = (await call('locator-matches', { selector: '#radio' })).result.matches[0].ref;
  assert.equal((await call('action-state', { ref: radio, prepare: true, desired: false })).error.code, 'unsupported');
});

function worker(file) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const start = source.indexOf('async function resolveActionTarget(');
  const end = source.indexOf('const handlers = {', start);
  const context = { console, setTimeout, Date,
    BridgeError: class extends Error { constructor(code, message) { super(message); this.code = code; } },
    parseRef(ref) { const m = /^(?:f(\d+))?(e\d+)$/.exec(ref); return { frameId: +(m[1] || 0), local: m[2] }; },
    tabSummary: x => x, resolveTab: async () => ({ id: 1 }),
    listFrames: async () => [{ frameId: 0 }, { frameId: 2 }],
    handlers: {}, sleep: async () => {} };
  vm.createContext(context); vm.runInContext(source.slice(start, end), context);
  return context;
}
for (const file of ['extension/background.js', 'safari/extension/background.js']) {
  test(`${file}: global ambiguity/read errors, check exactly once, idempotence`, async () => {
    const c = worker(file); let clicks = 0; let checked = 'false';
    c.callFrame = async (_tab, _frame, op) => op === 'locator-matches' ? { matches: [{ ref: 'e1' }] } : { checked, enabled: true, visible: true };
    await assert.rejects(c.resolveActionTarget(1, { name: 'x' }), e => e.code === 'ambiguous_element');
    // Also exercise same-frame ambiguity through the wait entry point, not
    // merely cross-frame duplicates through resolveActionTarget.
    c.callFrame = async () => ({ matches: [{ ref: 'e1' }, { ref: 'e2' }] });
    for (const state of ['hidden', 'detached', 'visible']) {
      await assert.rejects(c.waitForElement({ id: 1 }, { name: 'x', state }, Date.now() + 500), e => e.code === 'ambiguous_element');
    }
    c.callFrame = async () => { throw new Error('unreadable'); };
    await assert.rejects(c.waitForElement({ id: 1 }, { name: 'x', state: 'hidden' }, Date.now() + 500), /unreadable/);
    c.callFrame = async () => ({ checked, enabled: true, visible: true });
    c.handlers.click = async () => { clicks++; checked = 'true'; return { state: { after: { checked } } }; };
    assert.equal((await c.setChecked({ ref: 'e1' }, true)).verified, true);
    assert.equal(clicks, 1);
    assert.equal((await c.setChecked({ ref: 'e1' }, true)).changed, false);
    assert.equal(clicks, 1);
    c.handlers.click = async () => { clicks++; return { state: { after: { checked: 'true' } } }; };
    assert.equal((await c.setChecked({ ref: 'e1' }, false)).verified, false);
    assert.equal(clicks, 2);
    await assert.rejects(c.setChecked({ ref: 'e1', count: 2 }, true), e => e.code === 'invalid_argument');
  });
}

test('dialog e2e shell passes intact JavaScript as a single --js argument', () => {
  const { execFileSync } = require('node:child_process');
  const script = fs.readFileSync(path.join(root, 'Tests/e2e/browser/run.sh'), 'utf8');
  const start = script.indexOf('echo "eval blocked by confirm / chained dialogs"');
  const end = script.indexOf('echo "dialogs"', start);
  assert.ok(start >= 0 && end > start);
  // Execute only this section with a shell-function CLI double. bash -n alone
  // does not catch the old escaped quotes inside command substitutions.
  const harness = `
set -euo pipefail
AMCU=mock_amcu
check() { [[ "$2" == *"$3"* ]]; }
mock_amcu() {
  if [[ "$1 $2" == 'browser eval' ]]; then
    [[ "$3" == '--js' && "$5" == '--timeout' && "$6" == '5' && "$#" == 6 ]] || return 9
    printf '%s\\n' "$4" >&2
    printf 'evaluation incomplete'
  elif [[ "$1 $2" == 'browser dialog' ]]; then
    printf 'dismissed confirm chain-two'
  else
    printf 'dialog_open'
  fi
}
`;
  const result = require('node:child_process').spawnSync('bash', ['-c', harness + script.slice(start, end)], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "confirm('eval confirm')\n() => { alert('chain-one'); alert('chain-two'); return 42; }\n");
  execFileSync('bash', ['-n', path.join(root, 'Tests/e2e/browser/run.sh')]);
});

test('stage prepare creates a marker, reuses only on-stage identity, and validates registration', async () => {
  const c = worker('extension/background.js');
  const bounds = { left: 1000, top: 0, width: 1000, height: 800 };
  let saved = {}; let creates = 0; let removes = 0; const updates = [];
  let window; let marker;
  c.nonce = () => 'test-token';
  c.chrome = {
    runtime: { getURL: value => `chrome-extension://test/${value}` },
    storage: { local: { get: async () => saved, set: async value => { saved = value; } } },
    windows: {
      get: async () => window,
      create: async options => {
        creates++;
        assert.equal(options.focused, false);
        assert.equal(options.url, 'chrome-extension://test/stage-window.html?stageToken=test-token');
        window = { ...options, id: creates, tabs: [{ id: creates + 10 }] };
        marker = { id: creates + 10, windowId: creates, url: options.url, title: 'amcu-stage-test-token' };
        return window;
      },
      remove: async () => { removes++; }
    },
    tabs: { update: async (id, changes) => { updates.push({ id, changes }); } }
  };
  c.getTab = async () => marker;
  const first = await c.prepareStageWindow({ stageBounds: bounds });
  assert.equal(first.reused, false);
  assert.equal(first.markerTabId, 11);
  assert.equal(saved.amcuStageWindow.windowId, 1);
  assert.equal((await c.prepareStageWindow({ stageBounds: bounds })).reused, true);
  assert.equal(creates, 1);
  assert.equal(updates.at(-1).changes.active, true);
  assert.equal((await c.registeredStageWindow({ stageBounds: bounds, stageWindowId: 1 })).id, 1);
  await assert.rejects(c.registeredStageWindow({ stageBounds: bounds, stageWindowId: 99 }), e => e.code === 'invalid_argument');
  // Moving the registered window away must not retarget or move it back.
  window.left = 0;
  await assert.rejects(c.registeredStageWindow({ stageBounds: bounds, stageWindowId: 1 }), e => e.code === 'invalid_argument');
  assert.equal((await c.prepareStageWindow({ stageBounds: bounds })).reused, false);
  assert.equal(creates, 2);
  marker.url = 'https://example.test/';
  assert.equal((await c.prepareStageWindow({ stageBounds: bounds })).reused, false);
  assert.equal(creates, 3);
  // macOS may ignore initial placement. Only the new marker is returned;
  // working tabs remain refused until the CLI registers its proven window.
  saved = {};
  c.chrome.windows.create = async options => {
    marker = { id: 109, windowId: 99, url: options.url, title: 'amcu-stage-test-token' };
    window = { id: 99, ...bounds, left: 0, state: 'normal', tabs: [{ id: 109 }] };
    return window;
  };
  const misplaced = await c.prepareStageWindow({ stageBounds: bounds });
  assert.equal(misplaced.needsPlacement, true);
  assert.equal(removes, 0);
  assert.equal(saved.amcuStageWindow.windowId, 99);
  await assert.rejects(c.registeredStageWindow({ stageBounds: bounds, stageWindowId: 99 }), e => e.code === 'invalid_argument');
});

test('stage overlap uses window area and rejects minimized/off-stage windows', () => {
  const c = worker('extension/background.js');
  const bounds = { left: 1000, top: 0, width: 1000, height: 800 };
  assert.equal(c.overlapsStage({ left: 1100, top: 0, width: 500, height: 500, state: 'normal' }, bounds), true);
  assert.equal(c.overlapsStage({ left: 0, top: 0, width: 500, height: 500, state: 'normal' }, bounds), false);
  assert.equal(c.overlapsStage({ left: 1100, top: 0, width: 500, height: 500, state: 'minimized' }, bounds), false);
  assert.throws(() => c.stageBounds({ stageBounds: bounds, activate: true }), e => e.code === 'invalid_argument');
});
