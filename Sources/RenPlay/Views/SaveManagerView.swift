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
    @State private var savePickerMode: SideloadPickerMode?
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

                if !slots.isEmpty {
                    Button("Export Saves to App Folder", systemImage: "folder.badge.plus") {
                        do {
                            appState.libraryStore.ensureDirectories()
                            let dst = appState.libraryStore.exportsDir.appendingPathComponent("\(game.folderName)-saves.zip")
                            try appState.saveManager.exportSavesZip(from: saveDir, to: dst)
                            statusBanner = "Exported to Files > RenPlay > Exports > \(dst.lastPathComponent)"
                        } catch {
                            statusBanner = "Export failed: \(error.localizedDescription)"
                        }
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
                Menu("Import", systemImage: "square.and.arrow.down") {
                    Button("Import Save / ZIP (Copy Mode)", systemImage: "doc") {
                        savePickerMode = .archiveCopy
                    }
                    Button("Import Save / ZIP (In-Place / LiveContainer)", systemImage: "externaldrive") {
                        savePickerMode = .archiveInPlace
                    }
                }
                if let exportedZipURL {
                    ShareLink(item: exportedZipURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $savePickerMode) { mode in
            SideloadDocumentPicker(
                mode: mode,
                onPick: { items in
                    savePickerMode = nil
                    var total = 0
                    var lastErr: String?
                    for item in items {
                        defer {
                            item.stopSecurityScope?()
                            if item.deleteAfterImport {
                                try? FileManager.default.removeItem(at: item.url)
                            }
                        }
                        do {
                            total += try appState.saveManager.importSaves(from: item.url, into: saveDir, backupDir: backupDir)
                        } catch {
                            lastErr = error.localizedDescription
                        }
                    }
                    statusBanner = total > 0
                        ? "Imported \(total) save file(s)."
                        : (lastErr ?? "No valid .save or persistent files selected.")
                    reload()
                },
                onError: { msg in
                    savePickerMode = nil
                    statusBanner = msg
                }
            )
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
