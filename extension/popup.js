// amcu bridge — popup. Shows whether the native host is connected and lets the
// user drop debugger attachments (and the infobar that comes with them).

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

refresh();
