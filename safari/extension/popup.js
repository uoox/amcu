// amcu bridge for Safari — popup. Shows whether the relay answers and whether
// the extension has website access; opening it also wakes the poll loop.

const api = globalThis.browser || globalThis.chrome;
const zh = /^zh/i.test(api.i18n && api.i18n.getUILanguage ? api.i18n.getUILanguage() : '')
  || (navigator.languages || [navigator.language || '']).some(l => /^zh/i.test(l));
const tr = (en, cn) => (zh ? cn : en);
const stageButton = document.getElementById('stage');
const stageStatus = document.getElementById('stage-status');
stageButton.textContent = tr('Move to Stage', '收入舞台');

async function refresh() {
  document.getElementById('version').textContent = 'v' + api.runtime.getManifest().version;
  let reply = null;
  try {
    reply = await api.runtime.sendMessage({ __amcuPopup: true });
  } catch (_) { /* background asleep; it wakes on this message */ }
  const status = reply && reply.status;
  const relay = document.getElementById('relay');
  const hint = document.getElementById('hint');
  if (status && status.state === 'connected') {
    relay.textContent = 'connected';
    relay.className = 'ok';
    hint.textContent = 'The amcu CLI can drive Safari. Try: amcu browser tabs --browser safari';
  } else {
    relay.textContent = 'not connected';
    relay.className = 'bad';
    hint.innerHTML = 'The relay starts with the next <code>amcu browser … --browser safari</code> command. ' +
      (status && status.error ? 'Last error: ' + status.error.replace(/</g, '&lt;') : '');
  }
  const access = document.getElementById('access');
  access.textContent = reply && reply.hostAccess === true ? 'all websites' : reply && reply.hostAccess === false ? 'not granted' : 'unknown';
  access.className = reply && reply.hostAccess === true ? 'ok' : 'bad';
  document.getElementById('requests').textContent = status && status.requests ? String(status.requests) : '0';
}

stageButton.addEventListener('click', async () => {
  stageButton.disabled = true;
  stageButton.textContent = tr('Moving…', '收入中…');
  stageStatus.textContent = '';
  stageStatus.className = '';
  try {
    const win = await api.windows.getCurrent();
    const reply = await api.runtime.sendMessage({ __amcuStageCurrent: true, windowId: win ? win.id : null });
    if (reply && reply.ok) {
      stageStatus.textContent = reply.result && reply.result.alreadyOnStage ? tr('Already on the stage.', '已在舞台上。') : tr('Moved to the stage.', '已收入舞台。');
      stageStatus.className = 'ok';
      setTimeout(() => window.close(), 350);
      return;
    }
    stageStatus.textContent = (reply && reply.error && reply.error.message) || (reply && reply.message) || tr('Could not move this window to the stage.', '收入舞台失败。');
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
setInterval(refresh, 2000);
