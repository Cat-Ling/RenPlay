// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Foundation
import Observation
import RenPlayCore

@MainActor
@Observable
public final class AppState {
    public let documentsDir: URL
    public let libraryStore: LibraryStore
    public let saveManager = SaveManager()
    public let launcher: EngineLauncher

    public var games: [GameEntry] = []
    public var smbServers: [SMBServerProfile] = []
    public var appSettings: AppSettings
    public var engines: [EngineInfo] = []
    public var isImporting = false
    public var importProgress: Double = 0
    public var importStatus: String = ""
    public var isLaunching = false
    public var launchStatus: String = ""
    public var activeErrorTitle: String = "Error"
    public var activeError: String?

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = docs.appendingPathComponent("RenPlay", isDirectory: true)
        let store = LibraryStore(rootDir: root)
        store.seedVisibleDocumentsFolderIfNeeded(documentsDir: docs)
        AIHelp.install(documentsDir: docs)
        self.documentsDir = docs
        self.libraryStore = store
        self.appSettings = store.loadSettings()
        self.launcher = EngineLauncher(libraryStore: store, saveManager: SaveManager())
        self.engines = Self.loadBundledManifest().engines
        self.smbServers = store.loadSMBServers()
        refreshLibrary()
    }

    public static func loadBundledManifest() -> EngineManifest {
        if let url = Bundle.main.url(forResource: "engines-manifest", withExtension: "json", subdirectory: "Engines"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(EngineManifest.self, from: data) {
            return manifest
        }
        return EngineManifest(engines: [])
    }

    public func showError(_ message: String, title: String = "Error") {
        activeErrorTitle = title
        activeError = message
    }

    public func refreshLibrary() {
        do {
            games = try libraryStore.syncWithDisk()
        } catch {
            showError(error.localizedDescription, title: "Library Error")
        }
    }

    public func saveAppSettings() {
        do {
            try libraryStore.saveSettings(appSettings)
        } catch {
            showError(error.localizedDescription, title: "Settings Error")
        }
    }

    public func updateGame(_ updated: GameEntry) {
        if let idx = games.firstIndex(where: { $0.id == updated.id }) {
            games[idx] = updated
        }
        do {
            try libraryStore.saveGames(games)
        } catch {
            showError(error.localizedDescription, title: "Save Error")
        }
    }

    public func deleteGame(_ game: GameEntry, deleteSaves: Bool) {
        do {
            try libraryStore.deleteGame(game, deleteSaves: deleteSaves)
            games.removeAll { $0.id == game.id }
        } catch {
            showError(error.localizedDescription, title: "Delete Failed")
        }
    }

    public func renameGameDirectory(_ game: GameEntry, to newName: String) {
        do {
            let updated = try libraryStore.renameGameDirectory(game, to: newName)
            if let idx = games.firstIndex(where: { $0.id == updated.id }) {
                games[idx] = updated
            }
        } catch {
            showError(error.localizedDescription, title: "Rename Failed")
        }
    }

    public func linkGame(_ gameID: UUID, toSaveFolder folderID: String) {
        do {
            let updated = try libraryStore.linkGame(gameID, toSaveFolder: folderID)
            if let idx = games.firstIndex(where: { $0.id == updated.id }) {
                games[idx] = updated
            }
        } catch {
            showError(error.localizedDescription, title: "Link Failed")
        }
    }

    @discardableResult
    public func createSaveFolder(named rawName: String) -> String? {
        do {
            return try libraryStore.createSaveFolder(named: rawName)
        } catch {
            showError(error.localizedDescription, title: "Create Folder Failed")
            return nil
        }
    }

    @discardableResult
    public func renameSaveFolder(from oldID: String, to newName: String) -> String? {
        do {
            let renamed = try libraryStore.renameSaveFolder(from: oldID, to: newName)
            games = libraryStore.loadGames()
            return renamed
        } catch {
            showError(error.localizedDescription, title: "Rename Folder Failed")
            return nil
        }
    }

    public func setCustomArtwork(data: Data, kind: CustomArtworkKind, for game: GameEntry) {
        do {
            let updated = try libraryStore.setCustomArtwork(data: data, kind: kind, for: game)
            if let idx = games.firstIndex(where: { $0.id == updated.id }) {
                games[idx] = updated
            }
        } catch {
            showError(error.localizedDescription, title: "Artwork Failed")
        }
    }

    public func clearCustomArtwork(kind: CustomArtworkKind, for game: GameEntry) {
        do {
            let updated = try libraryStore.clearCustomArtwork(kind: kind, for: game)
            if let idx = games.firstIndex(where: { $0.id == updated.id }) {
                games[idx] = updated
            }
        } catch {
            showError(error.localizedDescription, title: "Artwork Failed")
        }
    }

    public func backupAllSaves() -> URL? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dst = libraryStore.exportsDir.appendingPathComponent("RenPlay-Saves-\(fmt.string(from: Date())).zip")
        do {
            _ = try libraryStore.backupAllSavesZip(to: dst)
            return dst
        } catch {
            showError(error.localizedDescription, title: "Backup Failed")
            return nil
        }
    }

    public func importUploadedArchive(
        at url: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async -> Result<GameEntry, Error> {
        let store = libraryStore
        do {
            let entry = try await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                return try store.importGameArchive(from: url, progress: progress)
            }.value
            games.append(entry)
            return .success(entry)
        } catch {
            return .failure(error)
        }
    }

    public func saveSMBServer(_ server: SMBServerProfile, password: String) {
        do {
            smbServers = try libraryStore.upsertSMBServer(server, password: password)
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func deleteSMBServer(_ server: SMBServerProfile) {
        do {
            smbServers = try libraryStore.deleteSMBServer(server)
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func importRemoteSMBGame(
        server: SMBServerProfile,
        password: String,
        share: String,
        remotePath: String,
        preferredName: String? = nil
    ) async -> Bool {
        isImporting = true
        importProgress = 0.02
        importStatus = "Indexing SMB game..."
        let store = libraryStore

        do {
            let entry = try await Task.detached(priority: .userInitiated) {
                try store.importRemoteSMBGame(
                    server: server,
                    password: password,
                    share: share,
                    remotePath: remotePath,
                    preferredName: preferredName
                ) { frac, msg in
                    Task { @MainActor in
                        self.importProgress = frac
                        self.importStatus = msg
                    }
                }
            }.value
            games.append(entry)
            isImporting = false
            importProgress = 0
            importStatus = ""
            return true
        } catch {
            isImporting = false
            importProgress = 0
            importStatus = ""
            showError("Failed to add game: \(error.localizedDescription)", title: "Share Error")
            return false
        }
    }

    public func refreshRemoteSMBGame(_ game: GameEntry) async {
        isImporting = true
        importProgress = 0.05
        importStatus = "Syncing scripts..."
        let store = libraryStore
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try store.refreshRemoteSMBGame(game) { frac, msg in
                    Task { @MainActor in
                        self.importProgress = frac
                        self.importStatus = msg
                    }
                }
            }.value
            if let idx = games.firstIndex(where: { $0.id == updated.id }) {
                games[idx] = updated
            }
            isImporting = false
            importProgress = 0
            importStatus = ""
        } catch {
            isImporting = false
            importProgress = 0
            importStatus = ""
            showError("Failed to sync scripts: \(error.localizedDescription)", title: "Sync Failed")
        }
    }

    public func installDemoGame() {
        do {
            let entry = try libraryStore.installSmokeTestGame()
            games.append(entry)
        } catch {
            showError(error.localizedDescription, title: "Demo Failed")
        }
    }

    public func importFiles(_ urls: [URL], deleteSourceAfterImport: Bool = false) {
        let items: [PickedImportItem] = urls.map { url in
            let accessed = url.startAccessingSecurityScopedResource()
            let cleanup: (@Sendable () -> Void)?
            if accessed {
                cleanup = { url.stopAccessingSecurityScopedResource() }
            } else {
                cleanup = nil
            }
            return PickedImportItem(url: url, deleteAfterImport: deleteSourceAfterImport, stopSecurityScope: cleanup)
        }
        importPickedItems(items)
    }

    public func importPickedItems(_ items: [PickedImportItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        importProgress = 0
        importStatus = "Preparing import..."
        let store = libraryStore

        Task {
            var errors: [String] = []
            for item in items {
                do {
                    let entry: GameEntry = try await Task.detached(priority: .userInitiated) {
                        defer {
                            item.stopSecurityScope?()
                            if item.deleteAfterImport {
                                try? FileManager.default.removeItem(at: item.url)
                            }
                        }
                        let fm = FileManager.default
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: item.url.path, isDirectory: &isDir)
                        if isDir.boolValue {
                            await MainActor.run {
                                self.importStatus = "Copying \(item.url.lastPathComponent)..."
                            }
                            return try store.importGameFolder(from: item.url)
                        } else {
                            return try store.importGameArchive(from: item.url) { frac, name in
                                Task { @MainActor in
                                    self.importProgress = frac
                                    self.importStatus = name
                                }
                            }
                        }
                    }.value
                    games.append(entry)
                } catch {
                    errors.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            isImporting = false
            importProgress = 0
            importStatus = ""
            if !errors.isEmpty {
                showError("Import failed for \(errors.joined(separator: "; "))", title: "Import Failed")
            }
        }
    }

    public func scanDropzones(silentIfEmpty: Bool = true) {
        guard !isImporting && !isLaunching else { return }
        let store = libraryStore
        let extraDirs = [
            documentsDir,
            documentsDir.appendingPathComponent("Inbox", isDirectory: true),
            documentsDir.appendingPathComponent("Import", isDirectory: true),
        ]
        if !silentIfEmpty {
            isImporting = true
            importProgress = 0
            importStatus = "Scanning folders..."
        }
        Task {
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    try store.scanAndImportDropzones(additionalDirs: extraDirs) { frac, name in
                        Task { @MainActor in
                            self.importProgress = frac
                            self.importStatus = name
                        }
                    }
                }.value
                isImporting = false
                importProgress = 0
                importStatus = ""
                refreshLibrary()
                if !silentIfEmpty && count == 0 {
                    showError("No archives or game folders found in Documents, Inbox, or Import.", title: "Nothing Found")
                }
            } catch {
                isImporting = false
                importProgress = 0
                importStatus = ""
                showError("Folder scan failed: \(error.localizedDescription)", title: "Import Failed")
            }
        }
    }

    public func downloadAndImport(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            showError("Enter a valid http:// or https:// archive URL.", title: "Invalid URL")
            return
        }
        isImporting = true
        importProgress = 0
        importStatus = "Downloading \(url.lastPathComponent)..."

        Task {
            do {
                let (tmpURL, response) = try await URLSession.shared.download(from: url)
                let suggested = (response as? HTTPURLResponse)?.suggestedFilename
                    ?? (url.lastPathComponent.isEmpty ? "downloaded-game.zip" : url.lastPathComponent)
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("renplay-dl-\(UUID().uuidString)-\(suggested)")
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: tmpURL, to: staged)
                importPickedItems([PickedImportItem(url: staged, deleteAfterImport: true)])
            } catch {
                isImporting = false
                importProgress = 0
                importStatus = ""
                showError("Download failed: \(error.localizedDescription)", title: "Download Failed")
            }
        }
    }

    public func resolvedEngine(for game: GameEntry) -> EngineInfo? {
        switch game.settings.engineMode {
        case .pinned(let versionID):
            if let pinned = engines.first(where: { $0.id == versionID || $0.version == versionID }) {
                return pinned
            }
        case .auto:
            break
        }
        // Detection runs at import/sync time; re-scanning the game folder here would run on every grid render.
        let detected = game.detectedEngineVersion.flatMap(DetectedVersion.init(storedDescription:))
        return EngineSelector.selectEngine(
            detected: detected,
            available: engines,
            strategy: appSettings.defaultEngineStrategy
        )
    }

    public func launch(game: GameEntry, autoloadSlot: String? = nil) {
        guard let engine = resolvedEngine(for: game) else {
            showError("No matching Ren'Py engine is bundled to launch this game.", title: "Launch Failed")
            return
        }
        isLaunching = true
        launchStatus = "Preparing Ren'Py \(engine.version)..."

        Task {
            do {
                var updated = game
                updated.lastPlayedAt = Date()
                updateGame(updated)

                try await launcher.launch(
                    game: updated,
                    engine: engine,
                    appSettings: appSettings,
                    autoloadSlot: autoloadSlot
                ) { status in
                    Task { @MainActor in
                        self.launchStatus = status
                    }
                } onFailure: { msg in
                    self.isLaunching = false
                    self.launchStatus = ""
                    self.showError(msg, title: "Launch Failed")
                }
            } catch {
                isLaunching = false
                launchStatus = ""
                showError(error.localizedDescription, title: "Launch Failed")
            }
        }
    }
}
#endif
