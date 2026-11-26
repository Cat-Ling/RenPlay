// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI
import UniformTypeIdentifiers

struct GlobalSavesView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if appState.games.isEmpty {
                    ContentUnavailableView(
                        "No Games",
                        systemImage: "externaldrive",
                        description: Text("Import a visual novel to manage its save slots and backups.")
                    )
                } else {
                    ForEach(appState.games) { game in
                        NavigationLink {
                            GameSaveManagerView(appState: appState, game: game)
                        } label: {
                            let count = appState.saveManager.listSaves(
                                in: appState.libraryStore.saveDirectory(for: game)
                            ).count
                            HStack {
                                Text(game.displayName)
                                Spacer()
                                Text("\(count) files")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Save Manager")
        }
    }
}

struct GameSaveManagerView: View {
    let appState: AppState
    let game: GameEntry

    @State private var slots: [SaveSlot] = []
    @State private var backups: [BackupEntry] = []
    @State private var showSaveImporter = false
    @State private var exportedZipURL: URL?
    @State private var statusBanner: String?

    private var saveDir: URL { appState.libraryStore.saveDirectory(for: game) }
    private var backupDir: URL { appState.libraryStore.backupDirectory(for: game) }

    var body: some View {
        List {
            if let statusBanner {
                Section {
                    Text(statusBanner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if slots.isEmpty {
                    Text("No save files found yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(slots) { slot in
                        HStack(spacing: 12) {
                            if let data = slot.screenshotData, let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 48)
                                    .clipShape(.rect(cornerRadius: 6))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .frame(width: 72, height: 48)
                                    .overlay {
                                        Image(systemName: slot.kind == .persistent ? "gearshape.2" : "doc")
                                            .foregroundStyle(.secondary)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.slotLabel)
                                    .font(.subheadline.weight(.medium))
                                if let info = slot.extraInfo, !info.isEmpty {
                                    Text(info)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(slot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                try? FileManager.default.removeItem(at: saveDir.appendingPathComponent(slot.filename))
                                reload()
                            }
                        }
                    }
                }
            } header: {
                Text("Save Slots (\(slots.count))")
            }

            Section {
                Button("Create Backup Now", systemImage: "archivebox") {
                    do {
                        if let created = try appState.saveManager.createBackup(
                            of: saveDir,
                            to: backupDir,
                            maxBackups: appState.appSettings.autoBackupCount
                        ) {
                            statusBanner = "Created \(created.lastPathComponent)"
                            reload()
                        } else {
                            statusBanner = "No saves to back up."
                        }
                    } catch {
                        statusBanner = error.localizedDescription
                    }
                }

                ForEach(backups) { backup in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(backup.url.lastPathComponent)
                                .font(.caption.monospaced())
                            Text(ByteCountFormatter.string(fromByteCount: backup.fileSize, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            do {
                                let count = try appState.saveManager.importSaves(from: backup.url, into: saveDir, backupDir: nil)
                                statusBanner = "Restored \(count) save files."
                                reload()
                            } catch {
                                statusBanner = error.localizedDescription
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("Backups (\(backups.count))")
            }
        }
        .navigationTitle("Saves")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Import", systemImage: "square.and.arrow.down") {
                    showSaveImporter = true
                }
                if let exportedZipURL {
                    ShareLink(item: exportedZipURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showSaveImporter,
            allowedContentTypes: [.zip, UTType(filenameExtension: "save") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                var total = 0
                for url in urls {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let n = try? appState.saveManager.importSaves(from: url, into: saveDir, backupDir: backupDir) {
                        total += n
                    }
                }
                statusBanner = "Imported \(total) save file(s)."
                reload()
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        slots = appState.saveManager.listSaves(in: saveDir)
        backups = appState.saveManager.listBackups(in: backupDir)
        let tempExport = FileManager.default.temporaryDirectory.appendingPathComponent("\(game.folderName)-saves.zip")
        if !slots.isEmpty {
            try? appState.saveManager.exportSavesZip(from: saveDir, to: tempExport)
            exportedZipURL = tempExport
        } else {
            exportedZipURL = nil
        }
    }
}
#endif
