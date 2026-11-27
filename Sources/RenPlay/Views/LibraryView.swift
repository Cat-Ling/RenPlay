// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI
import UniformTypeIdentifiers

private enum LibrarySortOrder: String, CaseIterable {
    case recent = "Recent"
    case name = "Title"
    case imported = "Added"
    case size = "Size"
}

struct LibraryView: View {
    @Bindable var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .recent
    @State private var filterCategory: GameCategory?
    @State private var activePickerMode: SideloadPickerMode?
    @State private var showImportOptions = false
    @State private var showWiFiUpload = false
    @State private var showURLDownload = false
    @State private var showSMBBrowser = false
    @State private var showStorageManager = false
    @State private var showSettingsSheet = false
    @State private var gamePendingDelete: GameEntry?
    @State private var gamePendingRename: GameEntry?
    @State private var renameText = ""
    @State private var gameSettingsTarget: GameEntry?
    @State private var exportedBackupURL: URL?

    private var hasCategorizedGames: Bool {
        appState.games.contains { $0.category != nil }
    }

    private var filteredGames: [GameEntry] {
        var base = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? appState.games
            : appState.games.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        if let filterCategory {
            base = base.filter { $0.category == filterCategory }
        }
        switch sortOrder {
        case .recent:
            return base.sorted { ($0.lastPlayedAt ?? $0.importedAt) > ($1.lastPlayedAt ?? $1.importedAt) }
        case .name:
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .imported:
            return base.sorted { $0.importedAt > $1.importedAt }
        case .size:
            return base.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    importBannerCard

                    if appState.games.isEmpty && !appState.isImporting {
                        emptyLibraryCard
                    } else {
                        sectionHeaderBar
                        if appState.appSettings.libraryLayoutMode == .list {
                            listLayoutView
                        } else {
                            gridLayoutView
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("Add Game", systemImage: "plus") {
                        importMenuItems
                    }
                    Menu("Library Options", systemImage: "ellipsis.circle") {
                        Button("Backup All Saves", systemImage: "externaldrive.badge.timemachine") {
                            exportedBackupURL = appState.backupAllSaves()
                        }
                        Button("Storage Manager", systemImage: "internaldrive") {
                            showStorageManager = true
                        }
                        Button("Scan Import Folder", systemImage: "arrow.clockwise") {
                            appState.scanDropzones(silentIfEmpty: false)
                        }
                        Divider()
                        Button("Settings", systemImage: "gearshape") {
                            showSettingsSheet = true
                        }
                    }
                }
            }
            .navigationDestination(for: GameEntry.self) { game in
                GameDetailView(appState: appState, gameID: game.id)
            }
            .confirmationDialog("Import Game", isPresented: $showImportOptions, titleVisibility: .visible) {
                importMenuItems
                Button("Cancel", role: .cancel) {}
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
                        appState.showError(msg, title: "Import Failed")
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
            .sheet(isPresented: $showStorageManager) {
                NavigationStack {
                    StorageManagerView(appState: appState)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showStorageManager = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(appState: appState, showDoneButton: true)
            }
            .sheet(item: $gameSettingsTarget) { target in
                GameSettingsSheet(appState: appState, gameID: target.id)
            }
            .alert("Rename Game", isPresented: Binding(
                get: { gamePendingRename != nil },
                set: { if !$0 { gamePendingRename = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    let clean = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if var g = gamePendingRename, !clean.isEmpty {
                        g.displayName = clean
                        appState.updateGame(g)
                    }
                    gamePendingRename = nil
                }
                Button("Cancel", role: .cancel) { gamePendingRename = nil }
            }
            .alert("Backup Ready", isPresented: Binding(
                get: { exportedBackupURL != nil },
                set: { if !$0 { exportedBackupURL = nil } }
            )) {
                if let url = exportedBackupURL {
                    ShareLink("Share Archive", item: url)
                }
                Button("Done", role: .cancel) { exportedBackupURL = nil }
            } message: {
                if let url = exportedBackupURL {
                    Text("Saved to Exports/\(url.lastPathComponent)")
                }
            }
            .gameDeletionDialog(pending: $gamePendingDelete, appState: appState)
            .refreshable {
                appState.refreshLibrary()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appState.scanDropzones(silentIfEmpty: true)
                }
            }
            .onChange(of: appState.appSettings) {
                appState.saveAppSettings()
            }
            .overlay {
                if appState.isImporting && !showWiFiUpload {
                    importProgressOverlay
                } else if appState.isLaunching {
                    launchProgressOverlay
                }
            }
        }
    }

    private var importBannerCard: some View {
        Button {
            showImportOptions = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import Games")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(".zip • .apk • .7z • .rar • .tar.* • SMB")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.50, blue: 0.98), Color(red: 0.10, green: 0.40, blue: 0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var sectionHeaderBar: some View {
        HStack(spacing: 8) {
            Text("Games • \(filteredGames.count)")
                .font(.headline)
            Spacer()

            if hasCategorizedGames {
                Menu {
                    Button("All Categories") { filterCategory = nil }
                    Divider()
                    ForEach(GameCategory.allCases, id: \.self) { cat in
                        Button {
                            filterCategory = cat
                        } label: {
                            if filterCategory == cat {
                                Label(cat.displayName, systemImage: "checkmark")
                            } else {
                                Text(cat.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: filterCategory == nil ? "tag" : "tag.fill")
                        .font(.subheadline)
                        .foregroundStyle(filterCategory.map { Color(category: $0) } ?? .primary)
                        .padding(7)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                }
            }

            HStack(spacing: 2) {
                Button {
                    appState.appSettings.libraryLayoutMode = appState.appSettings.libraryLayoutMode == .list ? .grid : .list
                } label: {
                    Image(systemName: appState.appSettings.libraryLayoutMode == .list ? "square.grid.2x2" : "list.bullet")
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                Menu {
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
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
            }
            .foregroundStyle(.primary)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 8))
        }
    }

    private var emptyLibraryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Games Imported")
                .font(.title3.weight(.semibold))
            Text("Import a Ren'Py archive, pick a folder, transfer over Wi-Fi, or browse a local network share.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Import Game") { showImportOptions = true }
                    .buttonStyle(.borderedProminent)
                Button("Try Demo") { appState.installDemoGame() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 16))
    }

    private var listLayoutView: some View {
        LazyVStack(spacing: 10) {
            ForEach(filteredGames) { game in
                NavigationLink(value: game) {
                    GameListRowView(
                        game: game,
                        coverURL: coverURL(for: game),
                        resolvedEngine: appState.resolvedEngine(for: game)?.version
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { cardContextMenu(for: game) }
            }
        }
    }

    private var gridLayoutView: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 14)],
            spacing: 14
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
                .contextMenu { cardContextMenu(for: game) }
            }
        }
    }

    @ViewBuilder
    private func cardContextMenu(for game: GameEntry) -> some View {
        Button("Play", systemImage: "play.fill") {
            appState.launch(game: game)
        }
        Button("Game Settings", systemImage: "gearshape") {
            gameSettingsTarget = game
        }
        Button("Rename...", systemImage: "pencil") {
            renameText = game.displayName
            gamePendingRename = game
        }
        Menu("Category", systemImage: "tag") {
            Button("None") {
                var copy = game
                copy.category = nil
                appState.updateGame(copy)
            }
            ForEach(GameCategory.allCases, id: \.self) { cat in
                Button {
                    var copy = game
                    copy.category = cat
                    appState.updateGame(copy)
                } label: {
                    if game.category == cat {
                        Label(cat.displayName, systemImage: "checkmark")
                    } else {
                        Text(cat.displayName)
                    }
                }
            }
        }
        Divider()
        Button(
            game.remoteSource != nil ? "Remove from Library" : "Delete Game",
            systemImage: "trash",
            role: .destructive
        ) {
            gamePendingDelete = game
        }
    }

    @ViewBuilder
    private var importMenuItems: some View {
        Button("Choose Archive...", systemImage: "doc.zipper") {
            activePickerMode = .archiveCopy
        }
        Button("Open Archive in Place...", systemImage: "externaldrive.badge.plus") {
            activePickerMode = .archiveInPlace
        }
        Button("Choose Folder...", systemImage: "folder") {
            activePickerMode = .folder
        }
        Divider()
        Button("Network Share (SMB)", systemImage: "externaldrive.connected.to.line.below") {
            showSMBBrowser = true
        }
        Button("Wi-Fi Transfer", systemImage: "wifi") {
            showWiFiUpload = true
        }
        Button("Download from URL", systemImage: "arrow.down.circle") {
            showURLDownload = true
        }
        Button("Scan Import Folder", systemImage: "tray.and.arrow.down") {
            appState.scanDropzones(silentIfEmpty: false)
        }
    }

    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: appState.importProgress)
                    .progressViewStyle(.linear)
                Text("Importing")
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
        if let rel = game.customCoverPath ?? game.coverRelativePath {
            return appState.libraryStore.gameDirectory(for: game).appendingPathComponent(rel)
        }
        return nil
    }
}

private struct GameListRowView: View {
    let game: GameEntry
    let coverURL: URL?
    let resolvedEngine: String?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(category: game.category))
                .frame(width: 4)
                .padding(.vertical, 6)

            if let coverURL, let uiImage = UIImage(contentsOfFile: coverURL.path) {
                Color.clear
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .clipShape(.rect(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(game.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(game.remoteSource != nil ? "LAN" : "Ren'Py")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(game.remoteSource != nil ? Color.teal : Color.indigo)
                        .clipShape(.rect(cornerRadius: 5))

                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let v = game.gameVersion, !v.isEmpty {
            parts.append("Ver. \(v)")
        } else if let eng = resolvedEngine ?? game.detectedEngineVersion {
            parts.append("Engine \(eng)")
        }
        if let bytes = game.sizeBytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " • ")
    }
}

private struct GameCardView: View {
    let game: GameEntry
    let coverURL: URL?
    let resolvedEngine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover sits in an overlay so wide aspect ratios cannot widen the grid column.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .overlay {
                    coverImage
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if let category = game.category {
                            Circle()
                                .fill(Color(category: category))
                                .frame(width: 8, height: 8)
                                .padding(5)
                                .background(.ultraThinMaterial)
                                .clipShape(.circle)
                        }
                        if game.remoteSource != nil {
                            Label("LAN", systemImage: "network")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial)
                                .clipShape(.rect(cornerRadius: 6))
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let ver = resolvedEngine ?? game.detectedEngineVersion {
                        Text("v\(ver)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial)
                            .clipShape(.rect(cornerRadius: 6))
                            .padding(6)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))

            Text(game.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if let last = game.lastPlayedAt {
                Text(last, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Never played")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
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

extension Color {
    init(category: GameCategory?) {
        guard let category else {
            self = .blue
            return
        }
        let hex = category.hexColor
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

extension View {
    func gameDeletionDialog(
        pending: Binding<GameEntry?>,
        appState: AppState,
        onDeleted: @escaping () -> Void = {}
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }
        )
        let title = if let game = pending.wrappedValue {
            game.remoteSource != nil ? "Remove \(game.displayName)?" : "Delete \(game.displayName)?"
        } else {
            ""
        }
        return confirmationDialog(
            title,
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { game in
            if game.remoteSource != nil {
                Button("Remove & Delete Saves", role: .destructive) {
                    appState.deleteGame(game, deleteSaves: true)
                    pending.wrappedValue = nil
                    onDeleted()
                }
                Button("Remove & Keep Saves") {
                    appState.deleteGame(game, deleteSaves: false)
                    pending.wrappedValue = nil
                    onDeleted()
                }
            } else {
                Button("Delete Game & Saves", role: .destructive) {
                    appState.deleteGame(game, deleteSaves: true)
                    pending.wrappedValue = nil
                    onDeleted()
                }
                Button("Delete Game & Keep Saves") {
                    appState.deleteGame(game, deleteSaves: false)
                    pending.wrappedValue = nil
                    onDeleted()
                }
            }
            Button("Cancel", role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: { game in
            if game.remoteSource != nil {
                Text("Files on the network share are never modified. Kept saves remain available in Save Manager.")
            } else {
                Text("Kept saves remain available in Save Manager and reconnect automatically if you re-import this game.")
            }
        }
    }
}
#endif
