// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import AVFoundation
import RenPlayCore
import SwiftUI

private struct AssetItem: Identifiable, Hashable {
    enum Source: Hashable {
        case loose(URL)
        case rpa(archiveURL: URL, entryPath: String)
        case smb(entry: SMBIndexEntry, source: SMBGameSource, password: String)
    }
    enum Kind: String {
        case image = "Images"
        case audio = "Audio"
    }

    let id: String
    let name: String
    let kind: Kind
    let source: Source

    func loadData() -> Data? {
        switch source {
        case .loose(let url):
            return try? Data(contentsOf: url)
        case .rpa(let archiveURL, let entryPath):
            return (try? RPAArchive(fileURL: archiveURL))?.readEntryOrNil(entryPath)
        case .smb(let entry, let remoteSource, let password):
            return try? SMBClient.readManifestEntry(entry, source: remoteSource, password: password)
        }
    }
}

private extension RPAArchive {
    func readEntryOrNil(_ path: String) -> Data? {
        try? readEntry(path)
    }
}

struct AssetGalleryView: View {
    let gameDir: URL
    var remoteSource: SMBGameSource? = nil
    var remotePassword: String = ""

    @State private var assets: [AssetItem] = []
    @State private var filterKind: AssetItem.Kind = .image
    @State private var isLoading = true
    @State private var selectedImageAsset: AssetItem?
    @State private var playingAudioID: String?
    @State private var audioPlayer: AVAudioPlayer?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    private static let audioExtensions: Set<String> = ["mp3", "ogg", "wav", "m4a", "aac"]

    private var filtered: [AssetItem] {
        assets.filter { $0.kind == filterKind }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Scanning game assets...")
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No \(filterKind.rawValue)",
                    systemImage: filterKind == .image ? "photo" : "waveform"
                )
            } else if filterKind == .image {
                imageGrid
            } else {
                audioList
            }
        }
        .navigationTitle("Asset Gallery")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $filterKind) {
                    Text("Images").tag(AssetItem.Kind.image)
                    Text("Audio").tag(AssetItem.Kind.audio)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .sheet(item: $selectedImageAsset) { item in
            NavigationStack {
                Group {
                    if let data = item.loadData(), let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    } else {
                        Text("Unable to decode image.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selectedImageAsset = nil }
                    }
                }
            }
        }
        .task {
            await scanAssets()
        }
        .onDisappear {
            audioPlayer?.stop()
        }
    }

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(filtered) { item in
                    Button {
                        selectedImageAsset = item
                    } label: {
                        AssetThumbView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private var audioList: some View {
        List(filtered) { item in
            Button {
                toggleAudio(item)
            } label: {
                HStack {
                    Image(systemName: playingAudioID == item.id ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
    }

    private func toggleAudio(_ item: AssetItem) {
        if playingAudioID == item.id {
            audioPlayer?.stop()
            playingAudioID = nil
            return
        }
        guard let data = item.loadData(),
              let player = try? AVAudioPlayer(data: data) else {
            return
        }
        audioPlayer?.stop()
        audioPlayer = player
        player.play()
        playingAudioID = item.id
    }

    private func scanAssets() async {
        let dir = gameDir
        let smbSource = remoteSource
        let smbPass = remotePassword
        let found = await Task.detached(priority: .userInitiated) {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp"]
            let audioExts: Set<String> = ["mp3", "ogg", "wav", "m4a", "aac"]
            var collected: [AssetItem] = []
            let fm = FileManager.default
            let scanRoot = dir.appendingPathComponent("game")
            let targetDir = fm.fileExists(atPath: scanRoot.path) ? scanRoot : dir

            if let enumerator = fm.enumerator(at: targetDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    if ext == "rpa" {
                        if let archive = try? RPAArchive(fileURL: url) {
                            for entry in archive.listEntries() {
                                let eExt = URL(fileURLWithPath: entry).pathExtension.lowercased()
                                if imageExts.contains(eExt) {
                                    collected.append(AssetItem(id: "rpa:\(url.lastPathComponent):\(entry)", name: entry, kind: .image, source: .rpa(archiveURL: url, entryPath: entry)))
                                } else if audioExts.contains(eExt) {
                                    collected.append(AssetItem(id: "rpa:\(url.lastPathComponent):\(entry)", name: entry, kind: .audio, source: .rpa(archiveURL: url, entryPath: entry)))
                                }
                            }
                        }
                    } else if imageExts.contains(ext) {
                        collected.append(AssetItem(id: "file:\(url.path)", name: url.lastPathComponent, kind: .image, source: .loose(url)))
                    } else if audioExts.contains(ext) {
                        collected.append(AssetItem(id: "file:\(url.path)", name: url.lastPathComponent, kind: .audio, source: .loose(url)))
                    }
                    if collected.count >= 500 { break }
                }
            }

            let manifestURL = dir.appendingPathComponent(SMBIndexManifest.manifestFileName)
            if let smbSource,
               let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) {
                let manifest = SMBIndexManifest.parse(manifestText)
                for entry in manifest.entries {
                    if collected.count >= 500 { break }
                    let ext = URL(fileURLWithPath: entry.logicalPath).pathExtension.lowercased()
                    if imageExts.contains(ext) {
                        collected.append(AssetItem(
                            id: "smb:\(entry.logicalPath)",
                            name: entry.logicalPath,
                            kind: .image,
                            source: .smb(entry: entry, source: smbSource, password: smbPass)
                        ))
                    } else if audioExts.contains(ext) {
                        collected.append(AssetItem(
                            id: "smb:\(entry.logicalPath)",
                            name: entry.logicalPath,
                            kind: .audio,
                            source: .smb(entry: entry, source: smbSource, password: smbPass)
                        ))
                    }
                }
            }
            return collected
        }.value

        assets = found
        isLoading = false
    }
}

private struct AssetThumbView: View {
    let item: AssetItem
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: 100)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 100)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                ProgressView()
            }
        }
        .task {
            let src = item
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = src.loadData() else { return nil }
                return UIImage(data: data)
            }.value
            thumbnail = loaded
        }
    }
}
#endif
