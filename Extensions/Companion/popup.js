(async () => {
  const api = globalThis.browser || globalThis.chrome, core = globalThis.FetchDockCore;
  const status = document.getElementById('status'), files = document.getElementById('files');
  const capture = document.getElementById('capture'), toggle = document.getElementById('captureToggle');
  function link(item) {
    const anchor = document.createElement('a'); anchor.href = core.handoff(item.url); anchor.textContent = item.title;
    const host = document.createElement('span'); host.textContent = item.url; anchor.append(host); return anchor;
  }
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) throw new Error('Open a website first.');
    let result;
    try { result = await api.tabs.sendMessage(tab.id, { type: 'fetchdock.scan' }); }
    catch (_) { throw new Error('Allow FetchDock on this website, then reload the page and reopen this menu.'); }
    if (!result?.origin) throw new Error('This page cannot be scanned.');
    toggle.checked = result.enabled;
    toggle.onchange = async () => {
      try {
        const data = await api.storage.local.get('captureOrigins');
        const origins = new Set(data.captureOrigins || []);
        if (toggle.checked) origins.add(result.origin); else origins.delete(result.origin);
        await api.storage.local.set({ captureOrigins: [...origins] });
      } catch (_) { status.textContent = 'Could not save this site preference.'; }
    };
    status.textContent = result.candidates.length ? `${result.candidates.length} file link(s) found` : 'No direct file links found';
    result.candidates.forEach(item => files.append(link(item)));
    const page = document.getElementById('page');
    if (core.handoff(result.url)) { page.href = core.handoff(result.url); page.hidden = false; page.title = 'A normal webpage will download as HTML.'; }
  } catch (error) { status.textContent = error.message; capture.hidden = true; }
})();
