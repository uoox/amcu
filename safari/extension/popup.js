// amcu bridge for Safari — popup. Shows whether the relay answers and whether
// the extension has website access; opening it also wakes the poll loop.

const api = globalThis.browser || globalThis.chrome;

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

refresh();
setInterval(refresh, 2000);
