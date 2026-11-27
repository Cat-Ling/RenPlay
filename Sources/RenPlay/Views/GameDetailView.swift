// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI

struct GameDetailView: View {
    @Bindable var appState: AppState
    let gameID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    @State private var editedName = ""
    @State private var showRenameAlert = false

    private var game: GameEntry? {
        appState.games.first(where: { $0.id == gameID })
    }

    var body: some View {
        Group {
            if let game {
                detailForm(for: game)
            } else {
                ContentUnavailableView("Game Not Found", systemImage: "questionmark.folder")
            }
        }
    }

    private func detailForm(for game: GameEntry) -> some View {
        let resolved = appState.resolvedEngine(for: game)
        let gameBinding = Binding<GameEntry>(
            get: { appState.games.first(where: { $0.id == gameID }) ?? game },
            set: { appState.updateGame($0) }
        )

        return Form {
            Section {
                HStack(spacing: 14) {
                    coverThumbnail(for: game)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.displayName)
                            .font(.headline)
                        Text("Detected: \(game.detectedEngineVersion ?? "Unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Active Engine: \(resolved?.version ?? "Unavailable")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    appState.launch(game: game)
                } label: {
                    Label("Launch Game", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolved == nil || appState.isLaunching)
            }

            Section {
                Picker("Engine Version", selection: engineSelectionBinding(for: gameBinding)) {
                    Text("Auto (\(resolved?.version ?? "None"))").tag("auto")
                    ForEach(appState.engines) { eng in
                        Text("Ren'Py \(eng.version) (\(eng.sdlVersion))").tag(eng.id)
                    }
                }

                Picker("Orientation", selection: gameBinding.settings.orientation) {
                    Text("Auto").tag(GameOrientation.auto)
                    Text("Landscape").tag(GameOrientation.landscape)
                    Text("Portrait").tag(GameOrientation.portrait)
                }

                Toggle("Allow Network Access", isOn: gameBinding.settings.allowNetwork)
                Toggle("Developer Mode & Console", isOn: gameBinding.settings.developerMode)
                Toggle("Force Enable Rollback", isOn: gameBinding.settings.forceRollback)
                Toggle("Force Enable Skip", isOn: gameBinding.settings.forceSkip)
                Toggle("Low Memory Mode", isOn: gameBinding.settings.lowMemoryMode)
            } header: {
                Text("Runtime Configuration")
            }

            Section {
                NavigationLink {
                    GameSaveManagerView(appState: appState, game: game)
                } label: {
                    Label("Save Manager", systemImage: "externaldrive")
                }

                NavigationLink {
                    AssetGalleryView(
                        gameDir: appState.libraryStore.gameDirectory(for: game),
                        remoteSource: game.remoteSource,
                        remotePassword: game.remoteSource.map { appState.libraryStore.smbPassword(for: $0.serverID) } ?? ""
                    )
                } label: {
                    Label("Asset Gallery", systemImage: "photo.on.rectangle.angled")
                }

                NavigationLink {
                    SessionLogViewer(logDir: appState.libraryStore.logDirectory(for: game))
                } label: {
                    Label("Session Logs", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Tools")
            }

            if let remote = game.remoteSource {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("smb://\(remote.host):\(remote.port)/\(remote.share)/\(remote.remotePath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Last synced: \(remote.lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await appState.refreshRemoteSMBGame(game) }
                    } label: {
                        Label("Refresh Remote Scripts & Index", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(appState.isImporting)
                } header: {
                    Text("LAN Stream Source")
                }
            }

            Section {
                Button("Rename Title") {
                    editedName = game.displayName
                    showRenameAlert = true
                }
                Button("Delete Game", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
        .navigationTitle(game.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Visual Novel", isPresented: $showRenameAlert) {
            TextField("Title", text: $editedName)
            Button("Save") {
                let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    var updated = game
                    updated.displayName = trimmed
                    appState.updateGame(updated)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(game.displayName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Game and Saves", role: .destructive) {
                appState.deleteGame(game, deleteSaves: true)
                dismiss()
            }
            Button("Delete Game Only (Keep Saves)", role: .destructive) {
                appState.deleteGame(game, deleteSaves: false)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func engineSelectionBinding(for game: Binding<GameEntry>) -> Binding<String> {
        Binding<String>(
            get: {
                switch game.wrappedValue.settings.engineMode {
                case .auto: return "auto"
                case .pinned(let id): return id
                }
            },
            set: { newValue in
                var copy = game.wrappedValue
                copy.settings.engineMode = (newValue == "auto") ? .auto : .pinned(newValue)
                game.wrappedValue = copy
            }
        )
    }

    @ViewBuilder
    private func coverThumbnail(for game: GameEntry) -> some View {
        let coverURL = game.coverRelativePath.map {
            appState.libraryStore.gameDirectory(for: game).appendingPathComponent($0)
        }
        if let coverURL, let image = UIImage(contentsOfFile: coverURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 64)
                .clipShape(.rect(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: 84, height: 64)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct SessionLogViewer: View {
    let logDir: URL
    @State private var logText = ""

    var body: some View {
        ScrollView {
            Text(logText.isEmpty ? "No session logs recorded yet." : logText)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Session Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    loadLogs()
                }
            }
        }
        .onAppear { loadLogs() }
    }

    private func loadLogs() {
        let logURL = logDir.appendingPathComponent("renplay_session.log")
        if let content = try? String(contentsOf: logURL, encoding: .utf8) {
            logText = content
        } else {
            logText = ""
        }
    }
}
#endif
