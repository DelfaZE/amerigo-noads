// Injecté par WKUserScript dans chaque page et iframe : signale à l'app les URLs de vidéos.
// IIFE pour ne rien exposer à la page ; module.exports pour les tests Node.
(function () {
  function classify(raw, base) {
    if (typeof raw !== 'string' || !raw) return null;
    if (raw.startsWith('blob:')) return { url: raw, kind: 'blob' };
    let u;
    try { u = new URL(raw, base); } catch (e) { return null; }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    const path = u.pathname.toLowerCase();
    if (path.endsWith('.m3u8')) return { url: u.href, kind: 'hls' };
    if (path.endsWith('.mp4')) return { url: u.href, kind: 'mp4' };
    return null;
  }

  function installSniffer(win, post) {
    const seen = new Set();
    const report = raw => {
      const v = classify(raw, win.location.href);
      if (!v || seen.has(v.url)) return;
      seen.add(v.url);
      post({ url: v.url, kind: v.kind, pageTitle: win.document.title || '', pageUrl: win.location.href });
    };
    const scan = root => {
      if (root.querySelectorAll) root.querySelectorAll('video, source').forEach(el => report(el.src));
    };

    const origFetch = win.fetch;
    if (origFetch) {
      win.fetch = function (input) {
        report(input && input.url ? input.url : String(input));
        return origFetch.apply(win, arguments);
      };
    }
    const origOpen = win.XMLHttpRequest && win.XMLHttpRequest.prototype.open;
    if (origOpen) {
      win.XMLHttpRequest.prototype.open = function (method, url) {
        report(String(url));
        return origOpen.apply(this, arguments);
      };
    }

    scan(win.document);
    new win.MutationObserver(records => records.forEach(r => {
      if (r.type === 'attributes') return report(r.target.src);
      r.addedNodes.forEach(n => {
        if (n.nodeType !== 1) return;
        if (n.nodeName === 'VIDEO' || n.nodeName === 'SOURCE') report(n.src);
        scan(n);
      });
    })).observe(win.document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
  }

  if (typeof module !== 'undefined') {
    module.exports = { classify, installSniffer };
  } else if (window.webkit && window.webkit.messageHandlers.video) {
    installSniffer(window, m => window.webkit.messageHandlers.video.postMessage(m));
  }
})();
