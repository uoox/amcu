// amcu bridge — popup. Shows whether the native host is connected and lets the
// user drop debugger attachments (and the infobar that comes with them).

const zh = /^zh/i.test(chrome.i18n && chrome.i18n.getUILanguage ? chrome.i18n.getUILanguage() : '')
  || (navigator.languages || [navigator.language || '']).some(l => /^zh/i.test(l));
const tr = (en, cn) => (zh ? cn : en);

const stageButton = document.getElementById('stage');
const stageStatus = document.getElementById('stage-status');
stageButton.textContent = tr('Move to Stage', '收入舞台');

async function refresh() {
  document.getElementById('version').textContent = 'v' + chrome.runtime.getManifest().version;
  const { status } = await chrome.storage.session.get('status');
  const host = document.getElementById('host');
  const hint = document.getElementById('hint');
  if (status && status.state === 'connected') {
    host.textContent = 'connected';
    host.className = 'ok';
    hint.textContent = 'The amcu CLI can drive this browser. Try: amcu browser tabs';
  } else {
    host.textContent = 'not connected';
    host.className = 'bad';
    const reason = status && status.error ? status.error : 'unknown';
    hint.innerHTML = /not found|host not found/i.test(reason)
      ? 'The native host is not registered. In a terminal run <code>amcu browser install</code>, then reload this extension.'
      : 'Last error: ' + reason + '. Run <code>amcu browser doctor</code>.';
  }
  const { amcu_identity: identity } = await chrome.storage.local.get('amcu_identity');
  document.getElementById('label').textContent = identity && identity.label ? identity.label : 'none (amcu browser label --name L)';
  document.getElementById('instance').textContent = identity && identity.instanceId ? identity.instanceId : '?';
  document.getElementById('requests').textContent = status && status.requests ? String(status.requests) : '0';
  try {
    const targets = await chrome.debugger.getTargets();
    const ours = targets.filter(t => t.attached && t.tabId !== undefined);
    document.getElementById('attached').textContent = ours.length ? ours.map(t => t.title || t.tabId).join(', ') : 'no tabs';
  } catch (_) {
    document.getElementById('attached').textContent = '?';
  }
}

document.getElementById('detach').addEventListener('click', async () => {
  const targets = await chrome.debugger.getTargets();
  for (const target of targets) {
    if (target.attached && target.tabId !== undefined) {
      try { await chrome.debugger.detach({ tabId: target.tabId }); } catch (_) { /* ignore */ }
    }
  }
  refresh();
});

stageButton.addEventListener('click', async () => {
  stageButton.disabled = true;
  stageButton.textContent = tr('Moving…', '收入中…');
  stageStatus.textContent = '';
  stageStatus.className = '';
  try {
    const win = await chrome.windows.getCurrent();
    const reply = await chrome.runtime.sendMessage({ __amcuStageCurrent: true, windowId: win ? win.id : null });
    if (reply && reply.ok) {
      const already = reply.result && reply.result.alreadyOnStage;
      stageStatus.textContent = already ? tr('Already on the stage.', '已在舞台上。') : tr('Moved to the stage.', '已收入舞台。');
      stageStatus.className = 'ok';
      setTimeout(() => window.close(), 350);
      return;
    }
    const msg = reply && reply.error && reply.error.message ? reply.error.message : tr('Could not move this window to the stage.', '收入舞台失败。');
    stageStatus.textContent = msg;
    stageStatus.className = 'bad';
  } catch (error) {
    stageStatus.textContent = String(error && error.message || error);
    stageStatus.className = 'bad';
  } finally {
    stageButton.disabled = false;
    stageButton.textContent = tr('Move to Stage', '收入舞台');
  }
});

refresh();
