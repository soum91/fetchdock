(() => {
  const api = globalThis.browser || globalThis.chrome;
  const core = globalThis.FetchDockCore;
  if (!api || !core || location.protocol !== 'https:') return;
  const key = 'captureOrigins';
  let enabled = false;
  const update = (data) => { enabled = Array.isArray(data[key]) && data[key].includes(location.origin); };
  api.storage.local.get(key).then(update).catch(() => {});
  api.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[key]) update({ [key]: changes[key].newValue });
  });
  function candidates() {
    const seen = new Set(), result = [];
    function add(value, title) {
      const url = core.downloadURL(value, location.href);
      if (!url || seen.has(url) || result.length >= 100) return;
      seen.add(url); result.push({ url, title: (title || new URL(url).pathname.split('/').pop() || 'Download').trim().slice(0, 160) });
    }
    for (const link of document.querySelectorAll('a[href]')) {
      if (link.hasAttribute('download') || core.looksLikeFile(link.href, location.href)) add(link.href, link.getAttribute('download') || link.textContent);
    }
    for (const media of document.querySelectorAll('video,audio,video source,audio source')) {
      add(media.currentSrc || media.src, media.getAttribute('title'));
    }
    if (core.looksLikeFile(location.href)) add(location.href, document.title);
    return result;
  }
  api.runtime.onMessage.addListener((message) => {
    if (message?.type === 'fetchdock.scan') return Promise.resolve({ origin: location.origin, url: location.href, candidates: candidates(), enabled });
  });
  function banner(link) {
    document.getElementById('__fetchdock_handoff')?.remove();
    const box = document.createElement('div'); box.id = '__fetchdock_handoff';
    Object.assign(box.style, { position: 'fixed', bottom: '16px', left: '16px', right: '16px', zIndex: '2147483647', background: '#102d32', color: '#fff', padding: '16px', border: '1px solid #64f4cb', borderRadius: '16px', font: '15px system-ui', boxShadow: '0 5px 25px #0008' });
    const title = document.createElement('div'); title.textContent = 'Open this file in FetchDock'; title.style.marginBottom = '12px';
    const send = document.createElement('a'); send.textContent = 'Download with FetchDock'; send.href = core.handoff(link.href); send.style.cssText = 'color:#64f4cb;margin-right:20px;font-weight:bold';
    const original = document.createElement('a'); original.textContent = 'Use browser'; original.href = link.href; original.dataset.fetchdockBypass = '1'; original.style.color = '#fff';
    if (link.hasAttribute('download')) original.setAttribute('download', link.getAttribute('download') || '');
    const close = document.createElement('button'); close.textContent = 'Dismiss'; close.style.cssText = 'margin-left:18px;background:transparent;color:#aaa;border:0'; close.onclick = () => box.remove();
    box.append(title, send, original, close); document.documentElement.append(box);
  }
  document.addEventListener('click', (event) => {
    if (!enabled || !event.isTrusted || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const element = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!element || element.closest('#__fetchdock_handoff') || element.dataset.fetchdockBypass) return;
    if (!core.downloadURL(element.href) || (!element.hasAttribute('download') && !core.looksLikeFile(element.href))) return;
    event.preventDefault(); event.stopImmediatePropagation();
    // A visible second tap preserves the platform's explicit external-app consent.
    banner(element);
  }, true);
})();
