import SwiftUI
import WebKit

final class BrowserModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var address = "duckduckgo.com"
    @Published var videos: [DetectedVideo] = []
    private var urlObserver: NSKeyValueObservation?

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
        // Observe l'URL plutôt que les navigations : les sites "SPA" (YouTube) changent de vidéo sans recharger.
        // YouTube change l'URL avant la source vidéo, donc la nouvelle vidéo arrive après la remise à zéro.
        urlObserver = webView.observe(\.url) { [weak self] webView, _ in
            self?.videos = []
            if let url = webView.url { self?.address = url.absoluteString }
        }
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
        // Titre lu maintenant : à la détection, YouTube affiche encore "YouTube".
        let title = model.webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? video.title
        let named = DetectedVideo(url: video.url, kind: video.kind, title: title, referer: video.referer)
        model.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            downloader.start(named, cookies: cookies)
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
