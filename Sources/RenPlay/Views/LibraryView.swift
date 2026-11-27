// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI
import UniformTypeIdentifiers

private enum LibrarySortOrder: String, CaseIterable {
    case recent = "Recently Played"
    case name = "Name"
    case imported = "Recently Added"
}

struct LibraryView: View {
    @Bindable var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .recent
    @State private var activePickerMode: SideloadPickerMode?
    @State private var showWiFiUpload = false
    @State private var showURLDownload = false
    @State private var showSMBBrowser = false
    @State private var selectedGame: GameEntry?

    private var filteredGames: [GameEntry] {
        let base = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? appState.games
            : appState.games.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        switch sortOrder {
        case .recent:
            return base.sorted { ($0.lastPlayedAt ?? $0.importedAt) > ($1.lastPlayedAt ?? $1.importedAt) }
        case .name:
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .imported:
            return base.sorted { $0.importedAt > $1.importedAt }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.games.isEmpty && !appState.isImporting {
                    emptyLibraryView
                } else {
                    gameGridView
                }
            }
            .navigationTitle("RenPlay")
            .searchable(text: $searchText, prompt: "Search visual novels")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                if sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        appState.scanDropzones(silentIfEmpty: true)
                    }
                    Menu("Import Game", systemImage: "plus") {
                        importMenuItems
                    }
                }
            }
            .navigationDestination(for: GameEntry.self) { game in
                GameDetailView(appState: appState, gameID: game.id)
            }
            .sheet(item: $activePickerMode) { mode in
                SideloadDocumentPicker(
                    mode: mode,
                    onPick: { items in
                        activePickerMode = nil
                        appState.importPickedItems(items)
                    },
                    onError: { msg in
                        activePickerMode = nil
                        appState.activeError = msg
                    }
                )
            }
            .sheet(isPresented: $showWiFiUpload) {
                WiFiUploadSheetView(appState: appState)
            }
            .sheet(isPresented: $showURLDownload) {
                URLDownloadSheetView(appState: appState)
            }
            .sheet(isPresented: $showSMBBrowser) {
                SMBBrowserView(appState: appState)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appState.scanDropzones(silentIfEmpty: true)
                }
            }
            .overlay {
                if appState.isImporting {
                    importProgressOverlay
                } else if appState.isLaunching {
                    launchProgressOverlay
                }
            }
        }
    }

    @ViewBuilder
    private var importMenuItems: some View {
        Button("Import Archive (.zip / .7z / .rar / .apk / .tar.*)", systemImage: "doc.zipper") {
            activePickerMode = .archiveCopy
        }
        Button("Import Archive (In-Place / LiveContainer)", systemImage: "externaldrive.badge.plus") {
            activePickerMode = .archiveInPlace
        }
        Button("Import Game Folder", systemImage: "folder") {
            activePickerMode = .folder
        }
        Divider()
        Button("Connect to SMB / LAN Share", systemImage: "externaldrive.connected.to.line.below") {
            showSMBBrowser = true
        }
        Button("Wi-Fi Browser Upload", systemImage: "wifi") {
            showWiFiUpload = true
        }
        Button("Download from URL", systemImage: "arrow.down.circle") {
            showURLDownload = true
        }
        Button("Scan App Folder & Inbox", systemImage: "tray.and.arrow.down") {
            appState.scanDropzones(silentIfEmpty: false)
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Visual Novels", systemImage: "book.closed")
        } description: {
            Text("Import a Ren'Py .zip, .7z, .rar, .apk, .tar.xz, .tar.zst, or folder, use Wi-Fi Browser Upload, or drop files into Files > On My iPhone > RenPlay.")
        } actions: {
            Menu("Import Game") {
                importMenuItems
            }
            .buttonStyle(.borderedProminent)

            Button("Install Built-in Demo") {
                appState.installDemoGame()
            }
            .buttonStyle(.bordered)
        }
    }

    private var gameGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 16)],
                spacing: 16
            ) {
                ForEach(filteredGames) { game in
                    NavigationLink(value: game) {
                        GameCardView(
                            game: game,
                            coverURL: coverURL(for: game),
                            resolvedEngine: appState.resolvedEngine(for: game)?.version
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") {
                            appState.launch(game: game)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            appState.deleteGame(game)
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable {
            appState.refreshLibrary()
        }
    }

    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: appState.importProgress)
                    .progressViewStyle(.linear)
                Text("Importing Game")
                    .font(.headline)
                Text(appState.importStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    private var launchProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(appState.launchStatus)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    private func coverURL(for game: GameEntry) -> URL? {
        guard let rel = game.coverRelativePath else { return nil }
        return appState.libraryStore.gameDirectory(for: game).appendingPathComponent(rel)
    }
}

private struct GameCardView: View {
    let game: GameEntry
    let coverURL: URL?
    let resolvedEngine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                coverImage
                    .frame(height: 115)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if game.remoteSource != nil {
                            Label("LAN", systemImage: "network")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial)
                                .clipShape(.rect(cornerRadius: 6))
                                .padding(6)
                        }
                    }

                if let ver = resolvedEngine ?? game.detectedEngineVersion {
                    Text("v\(ver)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .clipShape(.rect(cornerRadius: 6))
                        .padding(6)
                }
            }

            Text(game.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let last = game.lastPlayedAt {
                Text(last, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Never played")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var coverImage: some View {
        if let coverURL,
           let uiImage = UIImage(contentsOfFile: coverURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [.indigo.opacity(0.7), .cyan.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "books.vertical.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}
#endif
