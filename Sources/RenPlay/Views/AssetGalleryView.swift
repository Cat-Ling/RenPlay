// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import AVFoundation
import ImageIO
import RenPlayCore
import SwiftUI
import UIKit

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
    let relativePath: String
    let displayName: String
    let folderCategory: String
    let kind: Kind
    let source: Source

    init(id: String, relativePath: String, kind: Kind, source: Source) {
        self.id = id
        self.relativePath = relativePath
        self.displayName = URL(fileURLWithPath: relativePath).lastPathComponent
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 1 {
            self.folderCategory = String(parts[0])
        } else {
            self.folderCategory = "Root"
        }
        self.kind = kind
        self.source = source
    }

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

private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    static func downsampleThumbnail(data: Data, maxPixelSize: Int = 320) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

struct AssetGalleryView: View {
    let gameDir: URL
    var remoteSource: SMBGameSource? = nil
    var remotePassword: String = ""

    @State private var assets: [AssetItem] = []
    @State private var filterKind: AssetItem.Kind = .image
    @State private var selectedFolder = "All"
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var activeLightboxItem: AssetItem?

    @State private var playingAudioID: String?
    @State private var isAudioPlaying = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var audioCurrentTime: TimeInterval = 0
    @State private var audioDuration: TimeInterval = 0
    @State private var isScrubbingAudio = false

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    private static let audioExtensions: Set<String> = ["mp3", "ogg", "wav", "m4a", "aac"]

    private var kindAssets: [AssetItem] {
        assets.filter { $0.kind == filterKind }
    }

    private var folderCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in kindAssets {
            counts[item.folderCategory, default: 0] += 1
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filtered: [AssetItem] {
        let byFolder = selectedFolder == "All"
            ? kindAssets
            : kindAssets.filter { $0.folderCategory == selectedFolder }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return byFolder }
        return byFolder.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.relativePath.localizedCaseInsensitiveContains(q)
        }
    }

    private var currentAudioTrack: AssetItem? {
        guard let playingAudioID else { return nil }
        return assets.first { $0.id == playingAudioID && $0.kind == .audio }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isLoading && folderCounts.count > 1 {
                folderChipBar
            }

            Group {
                if isLoading {
                    ProgressView("Scanning game assets...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter by name or folder")
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
        .onChange(of: filterKind) {
            selectedFolder = "All"
        }
        .safeAreaInset(edge: .bottom) {
            if let track = currentAudioTrack {
                audioMiniPlayerBar(track: track)
            }
        }
        .fullScreenCover(item: $activeLightboxItem) { startItem in
            FullscreenGalleryViewer(items: filtered, initialID: startItem.id)
        }
        .task {
            await scanAssets()
        }
        .task(id: playingAudioID) {
            guard playingAudioID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let player = audioPlayer else { break }
                if !isScrubbingAudio {
                    audioCurrentTime = player.currentTime
                }
                audioDuration = player.duration
                if !player.isPlaying && isAudioPlaying && player.currentTime >= max(0, player.duration - 0.15) {
                    isAudioPlaying = false
                }
            }
        }
        .onDisappear {
            stopAudio()
        }
    }

    private var folderChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderChip(title: "All (\(kindAssets.count))", isSelected: selectedFolder == "All") {
                    selectedFolder = "All"
                }
                ForEach(folderCounts, id: \.name) { entry in
                    folderChip(title: "\(entry.name) (\(entry.count))", isSelected: selectedFolder == entry.name) {
                        selectedFolder = entry.name
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func folderChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(filtered) { item in
                    Button {
                        activeLightboxItem = item
                    } label: {
                        AssetThumbView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private var audioList: some View {
        List(filtered) { item in
            let isCurrent = playingAudioID == item.id
            Button {
                toggleAudio(item)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: (isCurrent && isAudioPlaying) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private func audioMiniPlayerBar(track: AssetItem) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(formatAudioTime(audioCurrentTime)) / \(formatAudioTime(audioDuration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Previous", systemImage: "backward.fill") {
                    stepAudioTrack(delta: -1)
                }
                .labelStyle(.iconOnly)
                .font(.body)

                Button(isAudioPlaying ? "Pause" : "Play", systemImage: isAudioPlaying ? "pause.fill" : "play.fill") {
                    togglePlayPauseCurrent()
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 34, height: 34)

                Button("Next", systemImage: "forward.fill") {
                    stepAudioTrack(delta: 1)
                }
                .labelStyle(.iconOnly)
                .font(.body)

                Button("Close", systemImage: "xmark.circle.fill") {
                    stopAudio()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .font(.title3)
            }

            if audioDuration > 0 {
                Slider(
                    value: Binding(
                        get: { audioCurrentTime },
                        set: { audioCurrentTime = $0 }
                    ),
                    in: 0...max(audioDuration, 0.1)
                ) { editing in
                    isScrubbingAudio = editing
                    if !editing {
                        audioPlayer?.currentTime = audioCurrentTime
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func formatAudioTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func toggleAudio(_ item: AssetItem) {
        if playingAudioID == item.id {
            togglePlayPauseCurrent()
            return
        }
        playTrack(item)
    }

    private func playTrack(_ item: AssetItem) {
        guard let data = item.loadData(),
              let player = try? AVAudioPlayer(data: data) else {
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer?.stop()
        audioPlayer = player
        audioDuration = player.duration
        audioCurrentTime = 0
        player.play()
        playingAudioID = item.id
        isAudioPlaying = true
    }

    private func togglePlayPauseCurrent() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isAudioPlaying = false
        } else {
            player.play()
            isAudioPlaying = true
        }
    }

    private func stepAudioTrack(delta: Int) {
        let audioItems = assets.filter { $0.kind == .audio }
        guard !audioItems.isEmpty,
              let idx = audioItems.firstIndex(where: { $0.id == playingAudioID }) else {
            return
        }
        let nextIndex = (idx + delta + audioItems.count) % audioItems.count
        playTrack(audioItems[nextIndex])
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingAudioID = nil
        isAudioPlaying = false
        audioCurrentTime = 0
        audioDuration = 0
    }

    private func scanAssets() async {
        let dir = gameDir
        let smbSource = remoteSource
        let smbPass = remotePassword
        let found = await Task.detached(priority: .userInitiated) {
            let maxAssets = 5000
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp"]
            let audioExts: Set<String> = ["mp3", "ogg", "wav", "m4a", "aac"]
            var collected: [AssetItem] = []
            let fm = FileManager.default
            let scanRoot = dir.appendingPathComponent("game")
            let targetDir = fm.fileExists(atPath: scanRoot.path) ? scanRoot : dir
            let basePrefix = targetDir.standardizedFileURL.path.hasSuffix("/")
                ? targetDir.standardizedFileURL.path
                : targetDir.standardizedFileURL.path + "/"

            if let enumerator = fm.enumerator(at: targetDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let ext = url.pathExtension.lowercased()
                    if ext == "rpa" {
                        if let archive = try? RPAArchive(fileURL: url) {
                            for entry in archive.listEntries() {
                                let eExt = URL(fileURLWithPath: entry).pathExtension.lowercased()
                                if imageExts.contains(eExt) {
                                    collected.append(AssetItem(id: "rpa:\(url.lastPathComponent):\(entry)", relativePath: entry, kind: .image, source: .rpa(archiveURL: url, entryPath: entry)))
                                } else if audioExts.contains(eExt) {
                                    collected.append(AssetItem(id: "rpa:\(url.lastPathComponent):\(entry)", relativePath: entry, kind: .audio, source: .rpa(archiveURL: url, entryPath: entry)))
                                }
                                if collected.count >= maxAssets { break }
                            }
                        }
                    } else if imageExts.contains(ext) {
                        let stdPath = url.standardizedFileURL.path
                        let rel = stdPath.hasPrefix(basePrefix) ? String(stdPath.dropFirst(basePrefix.count)) : url.lastPathComponent
                        collected.append(AssetItem(id: "file:\(url.path)", relativePath: rel, kind: .image, source: .loose(url)))
                    } else if audioExts.contains(ext) {
                        let stdPath = url.standardizedFileURL.path
                        let rel = stdPath.hasPrefix(basePrefix) ? String(stdPath.dropFirst(basePrefix.count)) : url.lastPathComponent
                        collected.append(AssetItem(id: "file:\(url.path)", relativePath: rel, kind: .audio, source: .loose(url)))
                    }
                    if collected.count >= maxAssets { break }
                }
            }

            let manifestURL = dir.appendingPathComponent(SMBIndexManifest.manifestFileName)
            if let smbSource,
               let manifestText = try? String(contentsOf: manifestURL, encoding: .utf8) {
                let manifest = SMBIndexManifest.parse(manifestText)
                for entry in manifest.entries {
                    if collected.count >= maxAssets { break }
                    let ext = URL(fileURLWithPath: entry.logicalPath).pathExtension.lowercased()
                    if imageExts.contains(ext) {
                        collected.append(AssetItem(
                            id: "smb:\(entry.logicalPath)",
                            relativePath: entry.logicalPath,
                            kind: .image,
                            source: .smb(entry: entry, source: smbSource, password: smbPass)
                        ))
                    } else if audioExts.contains(ext) {
                        collected.append(AssetItem(
                            id: "smb:\(entry.logicalPath)",
                            relativePath: entry.logicalPath,
                            kind: .audio,
                            source: .smb(entry: entry, source: smbSource, password: smbPass)
                        ))
                    }
                }
            }

            return collected.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
        }.value

        assets = found
        isLoading = false
    }
}

private struct AssetThumbView: View {
    let item: AssetItem
    @State private var thumbnail: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.secondarySystemGroupedBackground)
                        .overlay { ProgressView() }
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .overlay(alignment: .bottomLeading) {
                    Text(item.displayName)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 3)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: item.id) {
                if let cached = ThumbnailCache.shared.image(forKey: item.id) {
                    thumbnail = cached
                    return
                }
                let src = item
                let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let data = src.loadData() else { return nil }
                    return ThumbnailCache.downsampleThumbnail(data: data, maxPixelSize: 320)
                }.value
                if let loaded {
                    ThumbnailCache.shared.setImage(loaded, forKey: src.id)
                    thumbnail = loaded
                }
            }
    }
}

private struct FullscreenGalleryViewer: View {
    let items: [AssetItem]
    @State private var currentID: String
    @State private var showChrome = true
    @State private var decodedDimensions: [String: CGSize] = [:]
    @State private var shareFileURL: URL?
    @State private var dragOffsetY: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(items: [AssetItem], initialID: String) {
        self.items = items
        _currentID = State(initialValue: initialID)
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    private var currentItem: AssetItem? {
        guard !items.isEmpty else { return nil }
        return items[min(max(0, currentIndex), items.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !items.isEmpty {
                TabView(selection: $currentID) {
                    ForEach(items) { item in
                        ZoomableGalleryPageView(
                            item: item,
                            onSingleTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showChrome.toggle()
                                }
                            },
                            onImageDecoded: { size in
                                decodedDimensions[item.id] = size
                            },
                            onVerticalDragChanged: { dy in
                                dragOffsetY = max(0, dy)
                            },
                            onVerticalDragEnded: { dy in
                                if dy > 110 {
                                    dismiss()
                                } else {
                                    withAnimation(.spring(duration: 0.25)) {
                                        dragOffsetY = 0
                                    }
                                }
                            }
                        )
                        .tag(item.id)
                        .ignoresSafeArea()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: dragOffsetY)
            }

            if showChrome {
                chromeOverlay
            }
        }
        .statusBarHidden(!showChrome)
        .onChange(of: currentID) {
            prepareShareFile()
        }
        .onAppear {
            prepareShareFile()
        }
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.55))
                        .clipShape(.circle)
                }

                Spacer()

                if !items.isEmpty {
                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55))
                        .clipShape(.capsule)
                }

                Spacer()

                if let shareFileURL {
                    ShareLink(item: shareFileURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.55))
                            .clipShape(.circle)
                    }
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
            )

            Spacer()

            if let item = currentItem {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.relativePath)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let dim = decodedDimensions[item.id] {
                        Text("\(Int(dim.width)) × \(Int(dim.height))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .padding(.top, 20)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
    }

    private func prepareShareFile() {
        guard let item = currentItem else {
            shareFileURL = nil
            return
        }
        Task.detached(priority: .utility) {
            guard let data = item.loadData() else {
                await MainActor.run { shareFileURL = nil }
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("renplay-gallery-share", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(item.displayName)
            try? data.write(to: url, options: .atomic)
            await MainActor.run {
                if currentItem?.id == item.id {
                    shareFileURL = url
                }
            }
        }
    }
}

private struct ZoomableGalleryPageView: View {
    let item: AssetItem
    let onSingleTap: () -> Void
    let onImageDecoded: (CGSize) -> Void
    let onVerticalDragChanged: (CGFloat) -> Void
    let onVerticalDragEnded: (CGFloat) -> Void

    @State private var fullImage: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let fullImage {
                ZoomableImageScrollView(
                    image: fullImage,
                    onSingleTap: onSingleTap,
                    onVerticalDragChanged: onVerticalDragChanged,
                    onVerticalDragEnded: onVerticalDragEnded
                )
            } else if failed {
                ContentUnavailableView("Unable to Load Image", systemImage: "exclamationmark.triangle")
                    .preferredColorScheme(.dark)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .onTapGesture { onSingleTap() }
            }
        }
        .task(id: item.id) {
            let src = item
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = src.loadData() else { return nil }
                return UIImage(data: data)
            }.value
            if let loaded {
                fullImage = loaded
                onImageDecoded(CGSize(
                    width: loaded.size.width * loaded.scale,
                    height: loaded.size.height * loaded.scale
                ))
            } else {
                failed = true
            }
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void
    let onVerticalDragChanged: (CGFloat) -> Void
    let onVerticalDragEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = true
        scroll.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        let dismissPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        scroll.addGestureRecognizer(dismissPan)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
        }
        let bounds = scroll.bounds.size
        if bounds.width > 0 && bounds.height > 0 && context.coordinator.lastBounds != bounds {
            context.coordinator.layoutImage(in: scroll)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageScrollView
        let imageView = UIImageView()
        var lastBounds: CGSize = .zero

        init(parent: ZoomableImageScrollView) {
            self.parent = parent
        }

        func layoutImage(in scroll: UIScrollView) {
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0, let img = imageView.image, img.size.width > 0, img.size.height > 0 else {
                return
            }
            lastBounds = bounds
            scroll.zoomScale = 1.0
            let scale = min(bounds.width / img.size.width, bounds.height / img.size.height)
            let w = img.size.width * scale
            let h = img.size.height * scale
            imageView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            scroll.contentSize = CGSize(width: w, height: h)
            centerImage(in: scroll)
        }

        func centerImage(in scroll: UIScrollView) {
            let bounds = scroll.bounds.size
            let content = scroll.contentSize
            let offsetX = max(0, (bounds.width - content.width) * 0.5)
            let offsetY = max(0, (bounds.height - content.height) * 0.5)
            imageView.center = CGPoint(x: content.width * 0.5 + offsetX, y: content.height * 0.5 + offsetY)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        @objc func handleSingleTap() {
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.05 {
                scroll.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let targetScale: CGFloat = 2.5
                let w = scroll.bounds.width / targetScale
                let h = scroll.bounds.height / targetScale
                let zoomRect = CGRect(x: point.x - w * 0.5, y: point.y - h * 0.5, width: w, height: h)
                scroll.zoom(to: zoomRect, animated: true)
            }
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.zoomScale <= 1.02 else { return }
            let ty = gesture.translation(in: scroll).y
            switch gesture.state {
            case .changed:
                parent.onVerticalDragChanged(ty)
            case .ended, .cancelled:
                parent.onVerticalDragEnded(ty)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scroll = pan.view as? UIScrollView,
                  scroll.zoomScale <= 1.02 else {
                return false
            }
            let vel = pan.velocity(in: scroll)
            return vel.y > 0 && abs(vel.y) > abs(vel.x) * 1.35
        }
    }
}
#endif
