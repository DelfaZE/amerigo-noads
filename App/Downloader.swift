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
