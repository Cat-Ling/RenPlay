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
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .recent
    @State private var showFileImporter = false
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
                        appState.refreshLibrary()
                    }
                    Button("Import Game", systemImage: "plus") {
                        showFileImporter = true
                    }
                }
            }
            .navigationDestination(for: GameEntry.self) { game in
                GameDetailView(appState: appState, gameID: game.id)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [
                    .zip,
                    .folder,
                    UTType(filenameExtension: "apk") ?? .data,
                    UTType(filenameExtension: "tar") ?? .data,
                    .gzip,
                ],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    appState.importFiles(urls)
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

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Visual Novels", systemImage: "book.closed")
        } description: {
            Text("Import a Ren'Py .zip, .apk, .tar.gz, or folder, or drop a game folder into Files > On My iPhone > RenPlay > Games.")
        } actions: {
            Button("Import Game") {
                showFileImporter = true
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
