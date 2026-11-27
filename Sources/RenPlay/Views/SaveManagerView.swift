// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI
import UniformTypeIdentifiers

private enum SaveFolderSortMode: String, CaseIterable {
    case name = "Name"
    case count = "Save Count"
    case linked = "Linked Games"
}

private enum SaveSlotFilter: String, CaseIterable {
    case all = "All Saves"
    case auto = "Auto Saves"
    case quick = "Quick Saves"
    case manual = "Manual Saves"
    case persistent = "Persistent Data"

    func matches(_ slot: SaveSlot) -> Bool {
        switch self {
        case .all: return true
        case .auto: return slot.kind == .auto
        case .quick: return slot.kind == .quick
        case .manual: return slot.kind == .manual
        case .persistent: return slot.kind == .persistent
        }
    }
}

struct GlobalSavesView: View {
    @Bindable var appState: AppState
    @State private var sortMode: SaveFolderSortMode = .name
    @State private var folders: [SaveFolderSummary] = []
    @State private var sharedItems: [SharedPersistentItem] = []
    @State private var showCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var renameTarget: SaveFolderSummary?
    @State private var renameText = ""
    @State private var importPickerMode: SideloadPickerMode?
    @State private var exportedZipURL: URL?

    private var sortedFolders: [SaveFolderSummary] {
        switch sortMode {
        case .name:
            return folders.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        case .count:
            return folders.sorted { $0.slotCount > $1.slotCount }
        case .linked:
            return folders.sorted {
                if ($0.linkedGameID != nil) != ($1.linkedGameID != nil) {
                    return $0.linkedGameID != nil
                }
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Sort", selection: $sortMode) {
                    ForEach(SaveFolderSortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Section {
                    ForEach(sharedItems) { item in
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename)
                                    .font(.subheadline.weight(.medium))
                                Text("\(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) • \(item.modifiedAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
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

                    Button {
                        importPickerMode = .archiveCopy
                    } label: {
                        Label("Import File", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Multipersistent")
                } footer: {
                    Text("Shared persistent files accessed across compatible games.")
                }

                Section {
                    if sortedFolders.isEmpty {
                        Text("No save folders yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedFolders) { folder in
                            NavigationLink {
                                GameSaveManagerView(appState: appState, folder: folder)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.id)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            Text("\(folder.slotCount) saves")
                                                .foregroundStyle(.secondary)
                                            Text("•")
                                                .foregroundStyle(.secondary)
                                            if let linkedTitle = folder.linkedGameTitle {
                                                Text(linkedTitle)
                                                    .foregroundStyle(.green)
                                                    .lineLimit(1)
                                            } else {
                                                Text("Unlinked")
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .font(.caption)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .contextMenu {
                                Button("Rename Folder...", systemImage: "pencil") {
                                    renameText = folder.id
                                    renameTarget = folder
                                }
                                if folder.linkedGameID == nil {
                                    Button("Delete Folder", systemImage: "trash", role: .destructive) {
                                        deleteUnlinkedFolder(folder.id)
                                    }
                                }
                            }
                            .swipeActions {
                                if folder.linkedGameID == nil {
                                    Button("Delete", role: .destructive) {
                                        deleteUnlinkedFolder(folder.id)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Local • \(sortedFolders.count)")
                }
            }
            .navigationTitle("Save Manager")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showCreateFolderAlert = true
                    }
                    Button("Backup All", systemImage: "clock.arrow.circlepath") {
                        exportedZipURL = appState.backupAllSaves()
                    }
                }
            }
            .sheet(item: $importPickerMode) { mode in
                SideloadDocumentPicker(
                    mode: mode,
                    onPick: { items in
                        importPickerMode = nil
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
                        importPickerMode = nil
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

    private func reloadAll() {
        folders = appState.libraryStore.listAllSaveFolders()
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

struct GameSaveManagerView: View {
    @Bindable var appState: AppState
    let gameID: UUID?
    let title: String
    let fixedFolderID: String

    @State private var slots: [SaveSlot] = []
    @State private var backups: [BackupEntry] = []
    @State private var slotFilter: SaveSlotFilter = .all
    @State private var isSelecting = false
    @State private var selectedFilenames = Set<String>()
    @State private var savePickerMode: SideloadPickerMode?
    @State private var exportedZipURL: URL?
    @State private var showLinkSheet = false
    @State private var showBackupsSheet = false
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
        self.title = folder.id
        self.fixedFolderID = folder.id
    }

    private var activeFolderID: String {
        if let gameID,
           let live = appState.games.first(where: { $0.id == gameID }) {
            return live.saveIdentifier ?? live.id.uuidString
        }
        return fixedFolderID
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
                    filterChipsRow

                    if let statusBanner {
                        Text(statusBanner)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    if filteredSlots.isEmpty {
                        ContentUnavailableView(
                            "No Saves",
                            systemImage: "externaldrive",
                            description: Text("Saves created in game appear here.")
                        )
                        .padding(.top, 36)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 102, maximum: 170), spacing: 10)],
                            spacing: 12
                        ) {
                            ForEach(filteredSlots) { slot in
                                saveSlotTile(slot)
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
        .navigationTitle("Saves")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedFilenames.removeAll() }
                } label: {
                    Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                }

                Menu("Import", systemImage: "square.and.arrow.down") {
                    Button("Choose Save / ZIP...") { savePickerMode = .archiveCopy }
                    Button("Open in Place...") { savePickerMode = .archiveInPlace }
                }

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Backups (\(backups.count))", systemImage: "clock.arrow.circlepath") {
                        showBackupsSheet = true
                    }
                    Button("Create Backup", systemImage: "archivebox") {
                        createBackupNow()
                    }
                    if !slots.isEmpty {
                        Button("Export to App Folder", systemImage: "folder.badge.plus") {
                            exportToFolder()
                        }
                    }
                    if let exportedZipURL {
                        ShareLink("Share All Saves", item: exportedZipURL)
                    }
                }
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            if let gameID {
                SaveFolderLinkSheet(appState: appState, gameID: gameID)
            }
        }
        .sheet(isPresented: $showBackupsSheet) {
            NavigationStack {
                List {
                    if backups.isEmpty {
                        Text("No backups yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(backups) { backup in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
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
                                        statusBanner = "Restored \(count) files."
                                        showBackupsSheet = false
                                        reload()
                                    } catch {
                                        appState.showError(error.localizedDescription, title: "Restore Failed")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .navigationTitle("Backups")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showBackupsSheet = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Backup Now") { createBackupNow() }
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
        .onAppear { reload() }
        .onChange(of: activeFolderID) { reload() }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    if gameID != nil {
                        showLinkSheet = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(activeFolderID)
                            .lineLimit(1)
                        if gameID != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.capsule)
                }
                .disabled(gameID == nil)

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
                        Text(slotFilter.rawValue)
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
            }
            .padding(.horizontal)
        }
    }

    private func saveSlotTile(_ slot: SaveSlot) -> some View {
        let selected = selectedFilenames.contains(slot.filename)
        return Button {
            if isSelecting {
                if selected {
                    selectedFilenames.remove(slot.filename)
                } else {
                    selectedFilenames.insert(slot.filename)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let data = slot.screenshotData, let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(.secondarySystemGroupedBackground)
                                .overlay {
                                    Image(systemName: slot.kind == .persistent ? "gearshape.2" : "doc")
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? .blue : .white)
                                .padding(5)
                        }
                    }
                    .overlay {
                        if isSelecting && selected {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue, lineWidth: 2)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 8))

                Text(slot.slotLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(slot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                try? FileManager.default.removeItem(at: saveDir.appendingPathComponent(slot.filename))
                reload()
            }
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
                for name in selectedFilenames {
                    try? FileManager.default.removeItem(at: saveDir.appendingPathComponent(name))
                }
                selectedFilenames.removeAll()
                isSelecting = false
                reload()
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

                Section("Save Folders") {
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
                                Text(folder.id)
                                    .foregroundStyle(.primary)
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
