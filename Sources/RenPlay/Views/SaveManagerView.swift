// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI
import UniformTypeIdentifiers

private enum SavesSortOrder: String, CaseIterable {
    case recent = "Recently Updated"
    case title = "Title"
    case saveCount = "Most Saves"
    case size = "Largest Size"
}

private enum SaveSlotFilter: String, CaseIterable {
    case all = "All Saves"
    case manual = "Manual"
    case auto = "Auto"
    case quick = "Quick"
    case persistent = "Persistent"

    func matches(_ slot: SaveSlot) -> Bool {
        switch self {
        case .all: return true
        case .manual: return slot.kind == .manual
        case .auto: return slot.kind == .auto
        case .quick: return slot.kind == .quick
        case .persistent: return slot.kind == .persistent
        }
    }
}

private struct LinkedGameRow: Identifiable {
    let game: GameEntry
    let folder: SaveFolderSummary

    var id: UUID { game.id }
    var slotCount: Int { folder.slotCount }
    var backupCount: Int { folder.backupCount }
    var sizeBytes: Int64 { folder.sizeBytes }
    var modifiedAt: Date { folder.modifiedAt }
}

struct GlobalSavesView: View {
    @Bindable var appState: AppState

    @State private var searchText = ""
    @State private var sortOrder: SavesSortOrder = .recent
    @State private var foldersByID: [String: SaveFolderSummary] = [:]
    @State private var unlinkedFolders: [SaveFolderSummary] = []
    @State private var sharedItems: [SharedPersistentItem] = []

    @State private var showCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var renameTarget: SaveFolderSummary?
    @State private var renameText = ""
    @State private var pendingDeleteFolder: SaveFolderSummary?
    @State private var linkSheetGameID: UUID?
    @State private var sharedPickerMode: SideloadPickerMode?
    @State private var exportedZipURL: URL?

    private var linkedRows: [LinkedGameRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = appState.games.compactMap { game -> LinkedGameRow? in
            let id = game.saveIdentifier ?? game.id.uuidString
            if !query.isEmpty,
               !game.displayName.localizedCaseInsensitiveContains(query),
               !id.localizedCaseInsensitiveContains(query) {
                return nil
            }
            let summary = foldersByID[id] ?? SaveFolderSummary(
                id: id,
                displayName: game.displayName,
                slotCount: 0,
                backupCount: 0,
                sizeBytes: 0,
                modifiedAt: game.lastPlayedAt ?? game.importedAt,
                linkedGameID: game.id,
                linkedGameTitle: game.displayName
            )
            return LinkedGameRow(game: game, folder: summary)
        }

        switch sortOrder {
        case .recent:
            return rows.sorted { lhs, rhs in
                let lhsHasData = lhs.slotCount > 0 || lhs.backupCount > 0
                let rhsHasData = rhs.slotCount > 0 || rhs.backupCount > 0
                if lhsHasData != rhsHasData { return lhsHasData }
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.game.displayName.localizedCaseInsensitiveCompare(rhs.game.displayName) == .orderedAscending
            }
        case .title:
            return rows.sorted { $0.game.displayName.localizedCaseInsensitiveCompare($1.game.displayName) == .orderedAscending }
        case .saveCount:
            return rows.sorted {
                if $0.slotCount != $1.slotCount { return $0.slotCount > $1.slotCount }
                return $0.game.displayName.localizedCaseInsensitiveCompare($1.game.displayName) == .orderedAscending
            }
        case .size:
            return rows.sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.game.displayName.localizedCaseInsensitiveCompare($1.game.displayName) == .orderedAscending
            }
        }
    }

    private var filteredUnlinked: [SaveFolderSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty ? unlinkedFolders : unlinkedFolders.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
        switch sortOrder {
        case .recent:
            return base.sorted { $0.modifiedAt > $1.modifiedAt }
        case .title:
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .saveCount:
            return base.sorted { $0.slotCount > $1.slotCount }
        case .size:
            return base.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.games.isEmpty && unlinkedFolders.isEmpty && sharedItems.isEmpty {
                    ContentUnavailableView(
                        "No Save Data",
                        systemImage: "externaldrive",
                        description: Text("Save files and automatic backups for your games appear here.")
                    )
                } else {
                    savesList
                }
            }
            .navigationTitle("Saves")
            .searchable(text: $searchText, prompt: "Search games or folders")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        ForEach(SavesSortOrder.allCases, id: \.self) { order in
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

                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Backup All Saves", systemImage: "archivebox") {
                            exportedZipURL = appState.backupAllSaves()
                        }
                        Button("New Save Folder...", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showCreateFolderAlert = true
                        }
                        Divider()
                        Button("Import Shared Data...", systemImage: "square.and.arrow.down") {
                            sharedPickerMode = .archiveCopy
                        }
                    }
                }
            }
            .sheet(item: Binding(
                get: { linkSheetGameID.map { IdentifiableUUID(id: $0) } },
                set: { linkSheetGameID = $0?.id }
            )) { item in
                SaveFolderLinkSheet(appState: appState, gameID: item.id)
                    .onDisappear { reloadAll() }
            }
            .sheet(item: $sharedPickerMode) { mode in
                SideloadDocumentPicker(
                    mode: mode,
                    onPick: { items in
                        sharedPickerMode = nil
                        for item in items {
                            defer { item.stopSecurityScope?() }
                            do {
                                try appState.libraryStore.importSharedPersistentFile(from: item.url)
                            } catch {
                                appState.showError(error.localizedDescription, title: "Import Failed")
                            }
                        }
                        reloadAll()
                    },
                    onError: { msg in
                        sharedPickerMode = nil
                        appState.showError(msg, title: "Import Failed")
                    }
                )
            }
            .alert("New Save Folder", isPresented: $showCreateFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Create") {
                    _ = appState.createSaveFolder(named: newFolderName)
                    reloadAll()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Save Folder", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Folder name", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") {
                    if let target = renameTarget {
                        _ = appState.renameSaveFolder(from: target.id, to: renameText)
                        reloadAll()
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                "Delete Kept Saves?",
                isPresented: Binding(
                    get: { pendingDeleteFolder != nil },
                    set: { if !$0 { pendingDeleteFolder = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteFolder
            ) { folder in
                Button("Delete Saves & Backups", role: .destructive) {
                    deleteUnlinkedFolder(folder.id)
                    pendingDeleteFolder = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteFolder = nil
                }
            } message: { folder in
                Text("Permanently remove saved progress and backups for \(folder.displayName).")
            }
            .alert("Backup Ready", isPresented: Binding(
                get: { exportedZipURL != nil },
                set: { if !$0 { exportedZipURL = nil } }
            )) {
                if let url = exportedZipURL {
                    ShareLink("Share Archive", item: url)
                }
                Button("Done", role: .cancel) { exportedZipURL = nil }
            } message: {
                if let url = exportedZipURL {
                    Text("Saved to Exports/\(url.lastPathComponent)")
                }
            }
            .onAppear { reloadAll() }
            .onChange(of: appState.games) { reloadAll() }
        }
    }

    private var savesList: some View {
        List {
            if !linkedRows.isEmpty {
                Section("Games") {
                    ForEach(linkedRows) { row in
                        NavigationLink {
                            GameSaveManagerView(appState: appState, game: row.game)
                        } label: {
                            linkedGameRowView(row)
                        }
                        .contextMenu {
                            Button("Create Backup", systemImage: "archivebox") {
                                _ = try? appState.saveManager.createBackup(
                                    of: appState.libraryStore.saveDirectory(for: row.game),
                                    to: appState.libraryStore.backupDirectory(for: row.game),
                                    maxBackups: appState.appSettings.autoBackupCount
                                )
                                reloadAll()
                            }
                            Button("Change Save Folder...", systemImage: "folder") {
                                linkSheetGameID = row.game.id
                            }
                        }
                    }
                }
            }

            if !filteredUnlinked.isEmpty {
                Section {
                    ForEach(filteredUnlinked) { folder in
                        NavigationLink {
                            GameSaveManagerView(appState: appState, folder: folder)
                        } label: {
                            unlinkedFolderRowView(folder)
                        }
                        .contextMenu {
                            if !appState.games.isEmpty {
                                Menu("Link to Game", systemImage: "link") {
                                    ForEach(appState.games) { game in
                                        Button(game.displayName) {
                                            appState.linkGame(game.id, toSaveFolder: folder.id)
                                            reloadAll()
                                        }
                                    }
                                }
                            }
                            Button("Rename Folder...", systemImage: "pencil") {
                                renameText = folder.id
                                renameTarget = folder
                            }
                            Button("Delete...", systemImage: "trash", role: .destructive) {
                                pendingDeleteFolder = folder
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                pendingDeleteFolder = folder
                            }
                        }
                    }
                } header: {
                    Text("Kept from Removed Games")
                } footer: {
                    Text("Saves kept after removing a game. Re-adding the game reconnects them automatically, or open one to link it to a game manually.")
                }
            }

            if !sharedItems.isEmpty {
                Section {
                    ForEach(sharedItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename)
                                    .font(.subheadline.weight(.medium))
                                Text("\(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) • \(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do {
                                    try appState.libraryStore.deleteSharedPersistentItem(named: item.filename)
                                    reloadAll()
                                } catch {
                                    appState.showError(error.localizedDescription, title: "Delete Failed")
                                }
                            }
                        }
                    }
                    Button("Import Shared Data...", systemImage: "square.and.arrow.down") {
                        sharedPickerMode = .archiveCopy
                    }
                } header: {
                    Text("Shared Across Games")
                } footer: {
                    Text("Persistent data shared between compatible games.")
                }
            }
        }
    }

    private func linkedGameRowView(_ row: LinkedGameRow) -> some View {
        HStack(spacing: 12) {
            coverThumb(for: row.game)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.game.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(rowSubtitle(slots: row.slotCount, backups: row.backupCount, bytes: row.sizeBytes, date: row.modifiedAt))
                    .font(.caption)
                    .foregroundStyle((row.slotCount > 0 || row.backupCount > 0) ? .secondary : .tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func unlinkedFolderRowView(_ folder: SaveFolderSummary) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.18))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(rowSubtitle(slots: folder.slotCount, backups: folder.backupCount, bytes: folder.sizeBytes, date: folder.modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func coverThumb(for game: GameEntry) -> some View {
        let rel = game.customCoverPath ?? game.coverRelativePath
        let url = rel.map { appState.libraryStore.gameDirectory(for: game).appendingPathComponent($0) }
        if let url, let uiImage = UIImage(contentsOfFile: url.path) {
            Color.clear
                .frame(width: 46, height: 46)
                .overlay {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .clipShape(.rect(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(category: game.category).opacity(0.2))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(Color(category: game.category))
                }
        }
    }

    private func rowSubtitle(slots: Int, backups: Int, bytes: Int64, date: Date) -> String {
        if slots > 0 {
            var parts = [
                "\(slots) \(slots == 1 ? "save" : "saves")",
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
            ]
            if backups > 0 {
                parts.append("\(backups) \(backups == 1 ? "backup" : "backups")")
            }
            if date > .distantPast {
                parts.append(date.formatted(.relative(presentation: .named)))
            }
            return parts.joined(separator: " • ")
        }
        if backups > 0 {
            return "\(backups) \(backups == 1 ? "backup" : "backups")"
        }
        return "No saves yet"
    }

    private func reloadAll() {
        let all = appState.libraryStore.listAllSaveFolders()
        var byID: [String: SaveFolderSummary] = [:]
        var orphanList: [SaveFolderSummary] = []
        for f in all {
            byID[f.id] = f
            if f.linkedGameID == nil {
                orphanList.append(f)
            }
        }
        foldersByID = byID
        unlinkedFolders = orphanList
        sharedItems = appState.libraryStore.listSharedPersistentItems()
    }

    private func deleteUnlinkedFolder(_ id: String) {
        do {
            try appState.libraryStore.deleteOrphanedSaveGroup(id: id)
            reloadAll()
        } catch {
            appState.showError(error.localizedDescription, title: "Delete Failed")
        }
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

struct GameSaveManagerView: View {
    @Bindable var appState: AppState
    let gameID: UUID?
    let title: String
    let fixedFolderID: String

    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveSlot] = []
    @State private var backups: [BackupEntry] = []
    @State private var slotFilter: SaveSlotFilter = .all
    @State private var isSelecting = false
    @State private var selectedFilenames = Set<String>()
    @State private var inspectedSlot: SaveSlot?
    @State private var pendingLaunchSlot: String?
    @State private var savePickerMode: SideloadPickerMode?
    @State private var exportedZipURL: URL?
    @State private var showLinkSheet = false
    @State private var showBackupsSheet = false
    @State private var confirmDeleteSelected = false
    @State private var slotPendingDelete: SaveSlot?
    @State private var statusBanner: String?

    init(appState: AppState, game: GameEntry) {
        self.appState = appState
        self.gameID = game.id
        self.title = game.displayName
        self.fixedFolderID = game.saveIdentifier ?? game.id.uuidString
    }

    init(appState: AppState, folder: SaveFolderSummary) {
        self.appState = appState
        self.gameID = folder.linkedGameID
        self.title = folder.displayName
        self.fixedFolderID = folder.id
    }

    private var activeFolderID: String {
        if let gameID,
           let live = appState.games.first(where: { $0.id == gameID }) {
            return live.saveIdentifier ?? live.id.uuidString
        }
        return fixedFolderID
    }

    private var linkedGame: GameEntry? {
        gameID.flatMap { id in appState.games.first(where: { $0.id == id }) }
    }

    private var saveDir: URL {
        appState.libraryStore.saveDirectory(forIdentifier: activeFolderID)
    }

    private var backupDir: URL {
        appState.libraryStore.backupDirectory(forIdentifier: activeFolderID)
    }

    private var filteredSlots: [SaveSlot] {
        slots.filter { slotFilter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if gameID == nil && !appState.games.isEmpty {
                        unlinkedBanner
                    }

                    controlBar

                    if let statusBanner {
                        Text(statusBanner)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    if filteredSlots.isEmpty {
                        ContentUnavailableView(
                            slots.isEmpty ? "No Saves" : "No Matching Saves",
                            systemImage: "externaldrive",
                            description: Text(slots.isEmpty ? "Saves created while playing appear here." : "Try another filter or import a save file.")
                        )
                        .padding(.top, 36)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 12)],
                            spacing: 14
                        ) {
                            ForEach(filteredSlots) { slot in
                                saveSlotCard(slot)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 10)
            }

            if isSelecting {
                selectionBar
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !slots.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selectedFilenames.removeAll() }
                    }
                }

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Import Save or ZIP...", systemImage: "square.and.arrow.down") {
                        savePickerMode = .archiveCopy
                    }
                    Button("Import in Place...", systemImage: "externaldrive.badge.plus") {
                        savePickerMode = .archiveInPlace
                    }
                    Divider()
                    Button("Create Backup Now", systemImage: "archivebox") {
                        createBackupNow()
                    }
                    if !slots.isEmpty {
                        Button("Export ZIP to App Folder", systemImage: "folder.badge.plus") {
                            exportToFolder()
                        }
                    }
                    if let exportedZipURL {
                        ShareLink("Share All Saves (.zip)", item: exportedZipURL)
                    }
                    if gameID != nil {
                        Divider()
                        Button("Change Save Folder...", systemImage: "folder") {
                            showLinkSheet = true
                        }
                    }
                }
            }
        }
        .sheet(item: $inspectedSlot, onDismiss: {
            if let slotName = pendingLaunchSlot {
                pendingLaunchSlot = nil
                if let game = linkedGame,
                   appState.resolvedEngine(for: game) != nil,
                   !appState.isLaunching {
                    appState.launch(game: game, autoloadSlot: slotName)
                }
            }
        }) { slot in
            let loadAction: (() -> Void)? = if let game = linkedGame, let slotName = slot.renpySlotName {
                {
                    guard appState.resolvedEngine(for: game) != nil, !appState.isLaunching else { return }
                    pendingLaunchSlot = slotName
                    inspectedSlot = nil
                }
            } else {
                nil
            }
            SaveSlotDetailSheet(
                slot: slot,
                saveFileURL: saveDir.appendingPathComponent(slot.filename),
                onLoadAndPlay: loadAction,
                onDelete: {
                    inspectedSlot = nil
                    slotPendingDelete = slot
                }
            )
        }
        .sheet(isPresented: $showLinkSheet) {
            if let gameID {
                SaveFolderLinkSheet(appState: appState, gameID: gameID)
            }
        }
        .sheet(isPresented: $showBackupsSheet) {
            BackupsSheet(
                backups: backups,
                onBackupNow: { createBackupNow() },
                onRestore: { backup in
                    do {
                        let count = try appState.saveManager.importSaves(from: backup.url, into: saveDir, backupDir: backupDir)
                        statusBanner = "Restored \(count) save files. Previous saves backed up."
                        showBackupsSheet = false
                        reload()
                    } catch {
                        appState.showError(error.localizedDescription, title: "Restore Failed")
                    }
                },
                onDelete: { backup in
                    try? FileManager.default.removeItem(at: backup.url)
                    reload()
                }
            )
        }
        .sheet(item: $savePickerMode) { mode in
            SideloadDocumentPicker(
                mode: mode,
                onPick: { items in
                    savePickerMode = nil
                    var total = 0
                    for item in items {
                        defer {
                            item.stopSecurityScope?()
                            if item.deleteAfterImport { try? FileManager.default.removeItem(at: item.url) }
                        }
                        if let added = try? appState.saveManager.importSaves(from: item.url, into: saveDir, backupDir: backupDir) {
                            total += added
                        }
                    }
                    statusBanner = total > 0 ? "Imported \(total) save file(s)." : "No .save or persistent files found."
                    reload()
                },
                onError: { msg in
                    savePickerMode = nil
                    appState.showError(msg, title: "Import Failed")
                }
            )
        }
        .confirmationDialog(
            "Delete Save File?",
            isPresented: Binding(
                get: { slotPendingDelete != nil },
                set: { if !$0 { slotPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: slotPendingDelete
        ) { slot in
            Button("Delete \(slot.slotLabel)", role: .destructive) {
                try? FileManager.default.removeItem(at: saveDir.appendingPathComponent(slot.filename))
                slotPendingDelete = nil
                reload()
            }
            Button("Cancel", role: .cancel) { slotPendingDelete = nil }
        }
        .confirmationDialog(
            "Delete \(selectedFilenames.count) Selected Saves?",
            isPresented: $confirmDeleteSelected,
            titleVisibility: .visible
        ) {
            Button("Delete Selected", role: .destructive) {
                for name in selectedFilenames {
                    try? FileManager.default.removeItem(at: saveDir.appendingPathComponent(name))
                }
                selectedFilenames.removeAll()
                isSelecting = false
                reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { reload() }
        .onChange(of: activeFolderID) { reload() }
    }

    private var unlinkedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kept Saves (Unlinked)")
                    .font(.subheadline.weight(.semibold))
                Text("Attach this folder to any game in your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Link") {
                ForEach(appState.games) { game in
                    Button(game.displayName) {
                        appState.linkGame(game.id, toSaveFolder: fixedFolderID)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SaveSlotFilter.allCases, id: \.self) { f in
                    Button {
                        slotFilter = f
                    } label: {
                        if slotFilter == f {
                            Label(f.rawValue, systemImage: "checkmark")
                        } else {
                            Text(f.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(slotFilter == .all ? "All Saves (\(slots.count))" : "\(slotFilter.rawValue) (\(filteredSlots.count))")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.capsule)
            }

            Spacer()

            Button {
                showBackupsSheet = true
            } label: {
                Label("Backups (\(backups.count))", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private func saveSlotCard(_ slot: SaveSlot) -> some View {
        let selected = selectedFilenames.contains(slot.filename)
        let canDirectPlay = !isSelecting && linkedGame != nil && slot.renpySlotName != nil
        return Button {
            if isSelecting {
                if selected {
                    selectedFilenames.remove(slot.filename)
                } else {
                    selectedFilenames.insert(slot.filename)
                }
            } else if let game = linkedGame,
                      let slotName = slot.renpySlotName,
                      appState.resolvedEngine(for: game) != nil,
                      !appState.isLaunching {
                appState.launch(game: game, autoloadSlot: slotName)
            } else {
                inspectedSlot = slot
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let data = slot.screenshotData, let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(.tertiarySystemGroupedBackground)
                                .overlay {
                                    Image(systemName: slot.kind == .persistent ? "gearshape.2" : "doc")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if let tag = kindBadge(for: slot.kind) {
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial)
                                .clipShape(.rect(cornerRadius: 5))
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? .blue : .white)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if canDirectPlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.6))
                                .clipShape(.circle)
                                .padding(6)
                        }
                    }
                    .overlay {
                        if isSelecting && selected {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Color.blue, lineWidth: 2)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.slotLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let note = slot.extraInfo, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(slot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if !isSelecting {
                Button {
                    inspectedSlot = slot
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.55))
                        .clipShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(14)
                .accessibilityLabel("Save Details")
            }
        }
        .contextMenu {
            if let game = linkedGame, let slotName = slot.renpySlotName {
                Button("Load Save & Play", systemImage: "play.fill") {
                    appState.launch(game: game, autoloadSlot: slotName)
                }
                .disabled(appState.resolvedEngine(for: game) == nil || appState.isLaunching)
            }
            Button("Save Details...", systemImage: "info.circle") {
                inspectedSlot = slot
            }
            Button("Delete Save", systemImage: "trash", role: .destructive) {
                slotPendingDelete = slot
            }
        }
    }

    private func kindBadge(for kind: SaveKind) -> String? {
        switch kind {
        case .auto: return "Auto"
        case .quick: return "Quick"
        case .persistent: return "Persistent"
        case .manual: return nil
        }
    }

    private var selectionBar: some View {
        HStack {
            Button("Select All") {
                selectedFilenames = Set(filteredSlots.map(\.filename))
            }
            Spacer()
            Text("\(selectedFilenames.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Delete", role: .destructive) {
                confirmDeleteSelected = true
            }
            .disabled(selectedFilenames.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func createBackupNow() {
        do {
            if let created = try appState.saveManager.createBackup(
                of: saveDir,
                to: backupDir,
                maxBackups: appState.appSettings.autoBackupCount
            ) {
                statusBanner = "Backed up to \(created.lastPathComponent)."
                reload()
            } else {
                statusBanner = "No saves to back up."
            }
        } catch {
            appState.showError(error.localizedDescription, title: "Backup Failed")
        }
    }

    private func exportToFolder() {
        do {
            appState.libraryStore.ensureDirectories()
            let dst = appState.libraryStore.exportsDir.appendingPathComponent("\(activeFolderID)-saves.zip")
            try appState.saveManager.exportSavesZip(from: saveDir, to: dst)
            statusBanner = "Exported to Exports/\(dst.lastPathComponent)."
        } catch {
            appState.showError(error.localizedDescription, title: "Export Failed")
        }
    }

    private func reload() {
        slots = appState.saveManager.listSaves(in: saveDir)
        backups = appState.saveManager.listBackups(in: backupDir)
        let tempExport = FileManager.default.temporaryDirectory.appendingPathComponent("\(activeFolderID)-saves.zip")
        if !slots.isEmpty {
            try? appState.saveManager.exportSavesZip(from: saveDir, to: tempExport)
            exportedZipURL = tempExport
        } else {
            exportedZipURL = nil
        }
    }
}

private struct SaveSlotDetailSheet: View {
    let slot: SaveSlot
    let saveFileURL: URL
    var onLoadAndPlay: (() -> Void)? = nil
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let data = slot.screenshotData, let img = UIImage(data: data) {
                    Section {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(.rect(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                }

                if let onLoadAndPlay {
                    Section {
                        Button {
                            onLoadAndPlay()
                        } label: {
                            Label("Load Save & Play", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }

                Section("Details") {
                    LabeledContent("Slot", value: slot.slotLabel)
                    if let note = slot.extraInfo, !note.isEmpty {
                        LabeledContent("Note", value: note)
                    }
                    LabeledContent("Saved", value: slot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: slot.fileSize, countStyle: .file))
                    LabeledContent("File", value: slot.filename)
                }

                Section {
                    ShareLink("Share Save File", item: saveFileURL)
                    Button("Delete Save", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle(slot.slotLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct BackupsSheet: View {
    let backups: [BackupEntry]
    let onBackupNow: () -> Void
    let onRestore: (BackupEntry) -> Void
    let onDelete: (BackupEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestore: BackupEntry?

    var body: some View {
        NavigationStack {
            List {
                if backups.isEmpty {
                    ContentUnavailableView(
                        "No Backups",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Backups are created automatically on launch or when tapped above.")
                    )
                } else {
                    ForEach(backups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline.weight(.medium))
                                Text("\(backup.url.lastPathComponent) • \(ByteCountFormatter.string(fromByteCount: backup.fileSize, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                pendingRestore = backup
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                onDelete(backup)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Backup Now", action: onBackupNow)
                }
            }
            .confirmationDialog(
                "Restore Backup?",
                isPresented: Binding(
                    get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRestore
            ) { backup in
                Button("Restore Saves", role: .destructive) {
                    onRestore(backup)
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRestore = nil
                }
            } message: { _ in
                Text("Current saves will be backed up automatically before restoring.")
            }
        }
    }
}

struct SaveFolderLinkSheet: View {
    @Bindable var appState: AppState
    let gameID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [SaveFolderSummary] = []
    @State private var selectedID = ""
    @State private var showCreateAlert = false
    @State private var showRenameAlert = false
    @State private var folderInput = ""

    private var currentGame: GameEntry? {
        appState.games.first(where: { $0.id == gameID })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current Save Folder") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(selectedID)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Button("Rename") {
                            folderInput = selectedID
                            showRenameAlert = true
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section {
                    Button {
                        folderInput = ""
                        showCreateAlert = true
                    } label: {
                        Label("New Save Folder...", systemImage: "folder.badge.plus")
                    }

                    ForEach(folders) { folder in
                        Button {
                            selectedID = folder.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.displayName)
                                        .foregroundStyle(.primary)
                                    if folder.id != folder.displayName {
                                        Text(folder.id)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(folder.slotCount) saves")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if selectedID == folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Available Folders")
                } footer: {
                    Text("Switching folders changes which saves this game loads. Saves in the previous folder are kept.")
                }
            }
            .navigationTitle("Save Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        appState.linkGame(gameID, toSaveFolder: selectedID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedID.isEmpty)
                }
            }
            .alert("New Save Folder", isPresented: $showCreateAlert) {
                TextField("Folder name", text: $folderInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Create") {
                    if let created = appState.createSaveFolder(named: folderInput) {
                        selectedID = created
                        folders = appState.libraryStore.listAllSaveFolders()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Save Folder", isPresented: $showRenameAlert) {
                TextField("Folder name", text: $folderInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") {
                    if let renamed = appState.renameSaveFolder(from: selectedID, to: folderInput) {
                        selectedID = renamed
                        folders = appState.libraryStore.listAllSaveFolders()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                if let g = currentGame {
                    selectedID = g.saveIdentifier ?? g.id.uuidString
                }
                folders = appState.libraryStore.listAllSaveFolders()
            }
        }
    }
}
#endif
