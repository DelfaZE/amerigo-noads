# Amerigo NoAds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App iPhone perso : navigateur qui détecte les vidéos (.mp4/.m3u8), les télécharge, les lit, et gère les fichiers — sans pubs.

**Architecture:** SwiftUI + WKWebView. Un script JS injecté (`Web/sniffer.js`) poste les URLs de vidéos à l'app ; `Downloader` télécharge via `URLSession` (mp4) ou `AVAssetDownloadURLSession` (HLS) dans `Documents/`, exposé dans l'app Fichiers. Projet Xcode généré par XcodeGen et compilé sans signature sur GitHub Actions ; installation via Sideloadly sous Windows.

**Tech Stack:** Swift 5 / SwiftUI (iOS 16+), WebKit, AVFoundation/AVKit, XcodeGen, GitHub Actions (macos-15), Node `node:test` pour le JS.

Spec : `docs/superpowers/specs/2026-10-11-amerigo-noads-design.md`

**Contrainte de vérification :** pas de Mac. Le JS est testé localement (`node --test`). Le Swift n'est vérifié que par la compilation CI (Task 7) puis à la main sur l'iPhone (Task 8).

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `Web/sniffer.js` | `classify(url, base)` pur + `installSniffer(win, post)` ; auto-installation sous WebKit, `module.exports` sous Node |
| `test/sniffer.test.js` | Tests `node:test` avec une fausse `window` |
| `App/Downloader.swift` | `DetectedVideo`, `DownloadItem`, `Downloader` (sessions, progression, erreurs, nommage) |
| `App/PlayerView.swift` | Wrapper `AVPlayerViewController` |
| `App/BrowserView.swift` | `BrowserModel` (WKWebView + delegates) et `BrowserView` (barre, badge, liste) |
| `App/FilesView.swift` | `FilesView` / `FolderView` : téléchargements en cours + navigation dans `Documents/` |
| `App/AmerigoApp.swift` | `@main`, `TabView`, session audio |
| `project.yml` | Spec XcodeGen (Info.plist inclus) |
| `.gitignore` | Artefacts générés |
| `.github/workflows/build.yml` | Tests JS + build `.ipa` |

---

### Task 1: Sniffer JS (TDD)

**Files:**
- Create: `test/sniffer.test.js`
- Create: `Web/sniffer.js`

- [ ] **Step 1: Écrire les tests**

`test/sniffer.test.js` :

```js
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
```

- [ ] **Step 2: Lancer les tests, vérifier l'échec**

Run: `node --test test/sniffer.test.js`
Expected: FAIL — `Cannot find module '../Web/sniffer.js'`

- [ ] **Step 3: Implémenter**

`Web/sniffer.js` :

```js
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
```

- [ ] **Step 4: Lancer les tests, vérifier le succès**

Run: `node --test test/sniffer.test.js`
Expected: `# pass 4`, `# fail 0`

- [ ] **Step 5: Commit**

```bash
git add Web/sniffer.js test/sniffer.test.js
git commit -m "feat: video sniffer script with node tests"
```

---

### Task 2: Downloader

**Files:**
- Create: `App/Downloader.swift`

- [ ] **Step 1: Écrire `App/Downloader.swift`**

```swift
import AVFoundation
import Foundation

struct DetectedVideo: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let kind: String // "mp4", "hls" ou "blob"
    let title: String
    let referer: String
}

struct DownloadItem: Identifiable {
    let id = UUID()
    let video: DetectedVideo
    let cookies: [HTTPCookie]
    var progress = 0.0
    var error: String?
}

final class Downloader: NSObject, ObservableObject {
    static let shared = Downloader()
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @Published var items: [DownloadItem] = []
    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var owners: [URLSessionTask: UUID] = [:]
    private var hlsLocations: [URLSessionTask: URL] = [:]

    override init() {
        super.init()
        // Sessions "background" : le téléchargement continue quand l'app est en arrière-plan.
        // Recréées au lancement avec le même identifiant, elles livrent les téléchargements finis entre-temps.
        fileSession = URLSession(configuration: .background(withIdentifier: "noads.files"), delegate: self, delegateQueue: .main)
        hlsSession = AVAssetDownloadURLSession(configuration: .background(withIdentifier: "noads.hls"), assetDownloadDelegate: self, delegateQueue: .main)
    }

    func start(_ video: DetectedVideo, cookies: [HTTPCookie]) {
        let item = DownloadItem(video: video, cookies: cookies)
        items.insert(item, at: 0)
        launch(item)
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].error = nil
        items[i].progress = 0
        launch(items[i])
    }

    func remove(_ id: UUID) {
        owners.first { $0.value == id }?.key.cancel()
        items.removeAll { $0.id == id }
    }

    private func launch(_ item: DownloadItem) {
        let video = item.video
        let host = video.url.host ?? ""
        let cookies = item.cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        var headers = HTTPCookie.requestHeaderFields(with: cookies)
        headers["Referer"] = video.referer

        let task: URLSessionTask
        if video.kind == "hls" {
            // Clé non documentée mais très utilisée pour passer des en-têtes à AVURLAsset.
            let asset = AVURLAsset(url: video.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            guard let assetTask = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: video.title, assetArtworkData: nil, options: nil) else {
                return setError(item.id, "Impossible de créer le téléchargement HLS")
            }
            task = assetTask
        } else {
            var request = URLRequest(url: video.url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            task = fileSession.downloadTask(with: request)
        }
        // Le nom voyage avec la tâche : il survit à un relancement de l'app.
        task.taskDescription = Self.fileName(for: video)
        owners[task] = item.id
        task.resume()
    }

    private func setError(_ id: UUID?, _ message: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].error = message
    }

    private func setProgress(_ task: URLSessionTask, _ value: Double) {
        guard let i = items.firstIndex(where: { $0.id == owners[task] }) else { return }
        items[i].progress = value
    }

    private func save(_ location: URL, for task: URLSessionTask) {
        let destination = Self.uniqueURL(in: Self.documents, name: task.taskDescription ?? "video.mp4")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setError(owners[task], error.localizedDescription)
        }
    }

    static func fileName(for video: DetectedVideo) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let raw = video.title.isEmpty ? video.url.deletingPathExtension().lastPathComponent : video.title
        var base = raw.components(separatedBy: forbidden).joined().trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "video" }
        return String(base.prefix(80)) + (video.kind == "hls" ? ".movpkg" : ".mp4")
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

extension Downloader: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { setProgress(downloadTask, Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire est supprimé au retour de cette méthode : on le déplace tout de suite.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            return setError(owners[downloadTask], "Erreur HTTP \(status)")
        }
        save(location, for: downloadTask)
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let loaded = loadedTimeRanges.reduce(0) { $0 + $1.timeRangeValue.duration.seconds }
        let total = timeRangeExpectedToLoad.duration.seconds
        if total > 0 { setProgress(assetDownloadTask, loaded / total) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        // Le .movpkg n'est complet qu'à didCompleteWithError : on mémorise, on déplacera là.
        hlsLocations[assetDownloadTask] = location
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { owners[task] = nil }
        let hlsLocation = hlsLocations.removeValue(forKey: task)
        if let error {
            if let hlsLocation { try? FileManager.default.removeItem(at: hlsLocation) }
            return setError(owners[task], error.localizedDescription)
        }
        if let hlsLocation { save(hlsLocation, for: task) }
        // Terminé sans erreur : il quitte la liste "En cours", le fichier est dans Documents.
        if let id = owners[task], items.first(where: { $0.id == id })?.error == nil {
            items.removeAll { $0.id == id }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/Downloader.swift
git commit -m "feat: downloader for mp4 and HLS"
```

---

### Task 3: Lecteur

**Files:**
- Create: `App/PlayerView.swift`

- [ ] **Step 1: Écrire `App/PlayerView.swift`**

```swift
import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        // Passe en image dans l'image quand on quitte l'app : la lecture continue en arrière-plan.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/PlayerView.swift
git commit -m "feat: native player view"
```

---

### Task 4: Navigateur

**Files:**
- Create: `App/BrowserView.swift`

- [ ] **Step 1: Écrire `App/BrowserView.swift`**

```swift
import SwiftUI
import WebKit

final class BrowserModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var address = "duckduckgo.com"
    @Published var videos: [DetectedVideo] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let sniffer = Bundle.main.url(forResource: "sniffer", withExtension: "js").flatMap { try? String(contentsOf: $0) } ?? ""
        config.userContentController.addUserScript(WKUserScript(source: sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.add(self, name: "video")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        go()
    }

    func go() {
        if let url = Self.url(for: address) { webView.load(URLRequest(url: url)) }
    }

    /// Adresse tapée → URL ; ce qui ne ressemble pas à un domaine part en recherche DuckDuckGo.
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.contains(".") && !text.contains(" ") {
            return URL(string: text.contains("://") ? text : "https://" + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://duckduckgo.com/?q=" + query)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String],
              let url = URL(string: body["url"] ?? ""),
              let kind = body["kind"],
              !videos.contains(where: { $0.url == url }) else { return }
        let title = body["pageTitle"] ?? ""
        videos.append(DetectedVideo(url: url, kind: kind, title: title.isEmpty ? (webView.title ?? "") : title, referer: body["pageUrl"] ?? ""))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        videos = []
        address = webView.url?.absoluteString ?? address
    }

    // Liens target=_blank ouverts dans la même vue ; les popups non issues d'un clic (pubs) sont ignorées.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated { webView.load(action.request) }
        return nil
    }
}

struct BrowserView: View {
    @StateObject private var model = BrowserModel()
    @EnvironmentObject private var downloader: Downloader
    @State private var showVideos = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                TextField("Adresse ou recherche", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.go() }
                Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                if !model.videos.isEmpty {
                    Button { showVideos = true } label: { Label("\(model.videos.count)", systemImage: "film") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(8)
            WebContainer(webView: model.webView)
        }
        .sheet(isPresented: $showVideos) {
            NavigationStack {
                List(model.videos) { video in
                    Button { download(video) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.title.isEmpty ? video.url.lastPathComponent : video.title).lineLimit(1)
                            Text(video.kind == "blob" ? "Flux protégé : non téléchargeable" : "\(video.kind.uppercased()) · \(video.url.lastPathComponent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .disabled(video.kind == "blob")
                }
                .navigationTitle("Vidéos détectées")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func download(_ video: DetectedVideo) {
        model.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            downloader.start(video, cookies: cookies)
        }
        showVideos = false
    }
}

/// Nommé ainsi pour ne pas entrer en collision avec `WebKit.WebView` (SDK iOS 26).
struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
```

- [ ] **Step 2: Commit**

```bash
git add App/BrowserView.swift
git commit -m "feat: browser with video detection"
```

---

### Task 5: Fichiers

**Files:**
- Create: `App/FilesView.swift`

- [ ] **Step 1: Écrire `App/FilesView.swift`**

```swift
import SwiftUI

struct FilesView: View {
    var body: some View {
        NavigationStack { FolderView(url: Downloader.documents) }
    }
}

struct FolderView: View {
    let url: URL
    @EnvironmentObject private var downloader: Downloader
    @State private var entries: [URL] = []
    @State private var playing: URL?
    @State private var renameSource: URL?
    @State private var showRename = false
    @State private var showNewFolder = false
    @State private var name = ""

    private var isRoot: Bool { url == Downloader.documents }

    var body: some View {
        List {
            if isRoot && !downloader.items.isEmpty {
                Section("En cours") {
                    ForEach(downloader.items) { item in downloadRow(item) }
                }
            }
            Section {
                ForEach(entries, id: \.self) { entry in entryRow(entry) }
            }
        }
        .navigationTitle(isRoot ? "Fichiers" : url.lastPathComponent)
        .toolbar {
            Button { name = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
        }
        .onAppear(perform: reload)
        .onChange(of: downloader.items.count) { _ in reload() }
        .refreshable { reload() }
        .alert("Renommer", isPresented: $showRename) {
            TextField("Nom", text: $name)
            Button("OK") {
                if let source = renameSource, !name.isEmpty, name != source.lastPathComponent {
                    try? FileManager.default.moveItem(at: source, to: Downloader.uniqueURL(in: url, name: name))
                }
                reload()
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Nouveau dossier", isPresented: $showNewFolder) {
            TextField("Nom", text: $name)
            Button("Créer") {
                if !name.isEmpty {
                    try? FileManager.default.createDirectory(at: Downloader.uniqueURL(in: url, name: name), withIntermediateDirectories: false)
                }
                reload()
            }
            Button("Annuler", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) {
            if let playing { PlayerView(url: playing).ignoresSafeArea() }
        }
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.video.title.isEmpty ? item.video.url.lastPathComponent : item.video.title).lineLimit(1)
            if let error = item.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Réessayer") { downloader.retry(item.id) }.buttonStyle(.borderless)
                }
            } else {
                ProgressView(value: item.progress)
            }
        }
        .swipeActions { Button("Annuler", role: .destructive) { downloader.remove(item.id) } }
    }

    private func entryRow(_ entry: URL) -> some View {
        Group {
            if Self.isFolder(entry) {
                NavigationLink { FolderView(url: entry) } label: { Label(entry.lastPathComponent, systemImage: "folder") }
            } else {
                Button { playing = entry } label: { Label(entry.lastPathComponent, systemImage: "play.rectangle") }
            }
        }
        .swipeActions {
            Button("Supprimer", role: .destructive) {
                try? FileManager.default.removeItem(at: entry)
                reload()
            }
            Button("Renommer") {
                name = entry.lastPathComponent
                renameSource = entry
                showRename = true
            }
        }
    }

    private func reload() {
        let found = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        entries = found.sorted {
            let (a, b) = (Self.isFolder($0), Self.isFolder($1))
            return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Les .movpkg (vidéos HLS) sont des dossiers pour le système mais des fichiers pour nous.
    static func isFolder(_ url: URL) -> Bool {
        url.pathExtension != "movpkg" && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/FilesView.swift
git commit -m "feat: files tab with downloads, rename, delete, folders"
```

---

### Task 6: Point d'entrée et projet XcodeGen

**Files:**
- Create: `App/AmerigoApp.swift`
- Create: `project.yml`
- Create: `.gitignore`

- [ ] **Step 1: Écrire `App/AmerigoApp.swift`**

```swift
import AVFoundation
import SwiftUI

@main
struct AmerigoApp: App {
    init() {
        // .playback : son même en mode silencieux, et lecture possible en arrière-plan.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                BrowserView().tabItem { Label("Navigateur", systemImage: "globe") }
                FilesView().tabItem { Label("Fichiers", systemImage: "folder") }
            }
            .environmentObject(Downloader.shared)
        }
    }
}
```

- [ ] **Step 2: Écrire `project.yml`**

```yaml
name: AmerigoNoAds
options:
  bundleIdPrefix: com.dede
  deploymentTarget:
    iOS: "16.0"
targets:
  AmerigoNoAds:
    type: application
    platform: iOS
    sources:
      - App
      - path: Web
        buildPhase: resources
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: NoAds
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UIBackgroundModes: [audio]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.dede.amerigonoads
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "5.0"
        CODE_SIGNING_ALLOWED: "NO"
```

- [ ] **Step 3: Écrire `.gitignore`**

```
*.xcodeproj/
Info.plist
build/
Payload/
*.ipa
```

- [ ] **Step 4: Commit**

```bash
git add App/AmerigoApp.swift project.yml .gitignore
git commit -m "feat: app entry point and XcodeGen project"
```

---

### Task 7: CI GitHub Actions et premier build

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Écrire `.github/workflows/build.yml`**

```yaml
name: build
on:
  push:
  workflow_dispatch:

jobs:
  ipa:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Tests du sniffer
        run: node --test test/sniffer.test.js
      - name: Générer le projet Xcode
        run: brew install xcodegen && xcodegen generate
      - name: Compiler sans signature
        run: >
          xcodebuild -project AmerigoNoAds.xcodeproj -target AmerigoNoAds
          -configuration Release -sdk iphoneos SYMROOT="$PWD/build"
          CODE_SIGNING_ALLOWED=NO build
      - name: Empaqueter l'ipa
        run: |
          mkdir Payload
          cp -R build/Release-iphoneos/AmerigoNoAds.app Payload/
          zip -qr AmerigoNoAds.ipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: AmerigoNoAds
          path: AmerigoNoAds.ipa
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build unsigned ipa on GitHub Actions"
```

- [ ] **Step 3: Créer le repo public et pousser** (avec accord de l'utilisateur)

```bash
gh repo create amerigo-noads --public --source . --push
```

- [ ] **Step 4: Suivre le build**

Run: `gh run watch --exit-status`
Expected: toutes les étapes vertes. En cas d'erreur de compilation Swift : `gh run view --log-failed`, corriger le fichier en cause, commit, push, recommencer.

- [ ] **Step 5: Récupérer l'ipa**

Run: `gh run download --name AmerigoNoAds --dir dist`
Expected: `dist/AmerigoNoAds.ipa` présent. (Ajouter `dist/` au `.gitignore`.)

---

### Task 8: Installation et recette sur l'iPhone (utilisateur)

- [ ] **Step 1:** Installer iTunes et iCloud **versions .exe d'apple.com** (pas Microsoft Store), puis Sideloadly (sideloadly.io).
- [ ] **Step 2:** iPhone en USB, ouvrir `dist/AmerigoNoAds.ipa` dans Sideloadly, saisir l'Apple ID, Start.
- [ ] **Step 3:** iPhone : Réglages → Confidentialité et sécurité → Mode développeur (activer, redémarrer) ; Réglages → Général → VPN et gestion de l'appareil → faire confiance au profil.
- [ ] **Step 4:** Sideloadly : activer l'auto-refresh (PC allumé, même Wi-Fi).
- [ ] **Step 5: Recette**
  - Un site avec une vidéo .mp4 → badge 🎬 → Télécharger → progression dans Fichiers → fichier listé → lecture.
  - Un site HLS (.m3u8) → idem, fichier `.movpkg` → lecture hors-ligne (mode avion).
  - Pendant la lecture, revenir à l'accueil → passage en image dans l'image, le son continue.
  - App Fichiers d'iOS → « Sur mon iPhone » → NoAds → le fichier est visible.
  - Renommer, supprimer, créer un dossier depuis l'onglet Fichiers.
