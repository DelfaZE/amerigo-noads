const test = require('node:test');
const assert = require('node:assert');
const { classify, installSniffer } = require('../Web/sniffer.js');

const BASE = 'https://site.test/watch/42';

test('classify reconnait mp4, hls, blob et ignore le reste', () => {
  assert.deepStrictEqual(classify('https://cdn.test/a.mp4', BASE), { url: 'https://cdn.test/a.mp4', kind: 'mp4' });
  assert.deepStrictEqual(classify('/v/a.MP4?token=1', BASE), { url: 'https://site.test/v/a.MP4?token=1', kind: 'mp4' });
  assert.deepStrictEqual(classify('master.m3u8', BASE), { url: 'https://site.test/watch/master.m3u8', kind: 'hls' });
  assert.deepStrictEqual(classify('blob:https://site.test/1234', BASE), { url: 'blob:https://site.test/1234', kind: 'blob' });
  assert.strictEqual(classify('https://site.test/page.html', BASE), null);
  assert.strictEqual(classify('data:video/mp4;base64,AAAA', BASE), null);
  assert.strictEqual(classify('', BASE), null);
  assert.strictEqual(classify(undefined, BASE), null);
});

function fakeWindow() {
  const posted = [];
  const fetched = [];
  let observer;
  const win = {
    location: { href: BASE },
    document: { title: 'Ma vidéo', querySelectorAll: () => [] },
    fetch: async (input) => { fetched.push(input); return 'ok'; },
    XMLHttpRequest: class { open(method, url) { this.opened = url; } },
    MutationObserver: class { constructor(cb) { observer = cb; } observe() {} },
  };
  installSniffer(win, m => posted.push(m));
  return { win, posted, fetched, mutate: records => observer(records) };
}

test('fetch signale la vidéo une seule fois et appelle le vrai fetch', async () => {
  const { win, posted, fetched } = fakeWindow();
  assert.strictEqual(await win.fetch('/hls/master.m3u8'), 'ok');
  await win.fetch({ url: 'https://site.test/hls/master.m3u8' });
  await win.fetch('/api/data.json');
  assert.strictEqual(fetched.length, 3);
  assert.deepStrictEqual(posted, [
    { url: 'https://site.test/hls/master.m3u8', kind: 'hls', pageTitle: 'Ma vidéo', pageUrl: BASE },
  ]);
});

test('XMLHttpRequest.open signale la vidéo et garde le comportement d\'origine', () => {
  const { win, posted } = fakeWindow();
  const xhr = new win.XMLHttpRequest();
  xhr.open('GET', 'https://cdn.test/clip.mp4');
  assert.strictEqual(xhr.opened, 'https://cdn.test/clip.mp4');
  assert.strictEqual(posted[0].url, 'https://cdn.test/clip.mp4');
});

test('les balises video/source ajoutées ou modifiées sont signalées', () => {
  const { posted, mutate } = fakeWindow();
  const source = { nodeType: 1, nodeName: 'SOURCE', src: 'https://cdn.test/b.mp4' };
  const wrapper = { nodeType: 1, nodeName: 'DIV', querySelectorAll: () => [source] };
  const video = { nodeType: 1, nodeName: 'VIDEO', src: 'blob:https://site.test/x', querySelectorAll: () => [] };
  const text = { nodeType: 3, nodeName: '#text' };
  mutate([{ type: 'childList', addedNodes: [wrapper, video, text] }]);
  mutate([{ type: 'attributes', target: { src: 'https://cdn.test/c.m3u8' } }]);
  assert.deepStrictEqual(posted.map(p => p.kind), ['mp4', 'blob', 'hls']);
});
