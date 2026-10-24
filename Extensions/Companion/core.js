/* Pure URL policy shared by both browser packages and the Node test suite. */
(function (root) {
  const extensions = new Set('zip rar 7z tar gz bz2 xz zst iso dmg exe msi ipa apk apks apkm pdf epub mobi mp3 m4a flac wav ogg mp4 mkv mov webm avi png jpg jpeg gif webp csv xlsx docx pptx bin deb xpi'.split(' '));
  function downloadURL(value, base) {
    try {
      const url = new URL(value, base);
      if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) return null;
      return url.href;
    } catch (_) { return null; }
  }
  function looksLikeFile(value, base) {
    const safe = downloadURL(value, base);
    if (!safe) return false;
    const path = new URL(safe).pathname;
    return extensions.has(path.slice(path.lastIndexOf('.') + 1).toLowerCase());
  }
  function handoff(value, base) {
    const url = downloadURL(value, base);
    return url ? 'fetchdock://download?url=' + encodeURIComponent(url) : null;
  }
  const api = { downloadURL, looksLikeFile, handoff };
  root.FetchDockCore = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
