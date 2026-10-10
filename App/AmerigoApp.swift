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
