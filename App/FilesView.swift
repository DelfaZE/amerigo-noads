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
