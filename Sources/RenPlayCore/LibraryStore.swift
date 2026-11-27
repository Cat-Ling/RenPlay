// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SaveRetentionError: Error, LocalizedError, Sendable {
    case invalidIdentifier(String)
    case attachedToGame(String)
    case folderAlreadyExists(String)
    case folderNotFound(String)
    case gameNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "Invalid folder name: \(id)"
        case .attachedToGame(let id):
            return "Save folder \(id) belongs to a game that is still in the library."
        case .folderAlreadyExists(let name):
            return "A folder named \(name) already exists."
        case .folderNotFound(let name):
            return "Save folder \(name) could not be found."
        case .gameNotFound:
            return "The selected game is no longer in the library."
        }
    }
}

public enum CustomArtworkKind: Sendable {
    case cover
    case hero

    var fileName: String {
        switch self {
        case .cover: return ".renplay_custom_cover.png"
        case .hero: return ".renplay_custom_hero.png"
        }
    }
}

public final class LibraryStore: @unchecked Sendable {
    public let rootDir: URL
    public let gamesDir: URL
    public let savesDir: URL
    public let backupsDir: URL
    public let logsDir: URL
    public let importDropzoneDir: URL
    public let exportsDir: URL
    public var multipersistentDir: URL { savesDir.appendingPathComponent("_multipersistent", isDirectory: true) }
    private let libraryFileURL: URL
    private let settingsFileURL: URL
    private let smbServersFileURL: URL
    public let credentialStore: SMBCredentialStore

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(rootDir: URL) {
        self.rootDir = rootDir
        self.gamesDir = rootDir.appendingPathComponent("Games", isDirectory: true)
        self.savesDir = rootDir.appendingPathComponent("Saves", isDirectory: true)
        self.backupsDir = rootDir.appendingPathComponent("Backups", isDirectory: true)
        self.logsDir = rootDir.appendingPathComponent("Logs", isDirectory: true)
        self.importDropzoneDir = rootDir.appendingPathComponent("Import", isDirectory: true)
        self.exportsDir = rootDir.appendingPathComponent("Exports", isDirectory: true)
        self.libraryFileURL = rootDir.appendingPathComponent("library.json")
        self.settingsFileURL = rootDir.appendingPathComponent("settings.json")
        self.smbServersFileURL = rootDir.appendingPathComponent("smb_servers.json")
        let credDir: URL
        #if os(iOS)
        credDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RenPlay", isDirectory: true) ?? rootDir
        #else
        credDir = rootDir
        #endif
        self.credentialStore = SMBCredentialStore(storageDir: credDir)
        ensureDirectories()
    }

    public func ensureDirectories() {
        let fm = FileManager.default
        for dir in [rootDir, gamesDir, savesDir, multipersistentDir, backupsDir, logsDir, importDropzoneDir, exportsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // Create a visible folder and readme under Documents so iOS Files exposes RenPlay immediately.
    public func seedVisibleDocumentsFolderIfNeeded(documentsDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: documentsDir.appendingPathComponent("Import", isDirectory: true), withIntermediateDirectories: true)
        let readmeURL = documentsDir.appendingPathComponent("HOW_TO_IMPORT.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            let instructions = """
            RenPlay Import & File Access
            ----------------------------
            Drop .zip, .7z, .rar, .apk, .tar.gz, .tar.xz, .tar.zst, .tar.bz2 archives or unpacked Ren'Py game folders into:
            - Documents/Import/
            - Documents/ (this folder)
            - Documents/RenPlay/Import/

            Then return to RenPlay or tap Import > Scan App Folder & Inbox.
            Exported save archives are saved under Documents/RenPlay/Exports/.
            """
            try? instructions.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    public func gameDirectory(for game: GameEntry) -> URL {
        gamesDir.appendingPathComponent(game.folderName, isDirectory: true)
    }

    public func saveDirectory(for game: GameEntry) -> URL {
        saveDirectory(forIdentifier: game.saveIdentifier ?? game.id.uuidString)
    }

    public func backupDirectory(for game: GameEntry) -> URL {
        backupDirectory(forIdentifier: game.saveIdentifier ?? game.id.uuidString)
    }

    public func saveDirectory(forIdentifier identifier: String) -> URL {
        savesDir.appendingPathComponent(identifier, isDirectory: true)
    }

    public func backupDirectory(forIdentifier identifier: String) -> URL {
        backupsDir.appendingPathComponent(identifier, isDirectory: true)
    }

    public func logDirectory(for game: GameEntry) -> URL {
        logsDir.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func saveSettings(_ settings: AppSettings) throws {
        ensureDirectories()
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
    }

    public func loadGames() -> [GameEntry] {
        guard let data = try? Data(contentsOf: libraryFileURL),
              let decoded = try? decoder.decode([GameEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveGames(_ games: [GameEntry]) throws {
        ensureDirectories()
        let data = try encoder.encode(games)
        try data.write(to: libraryFileURL, options: .atomic)
    }

    public func loadSMBServers() -> [SMBServerProfile] {
        guard let data = try? Data(contentsOf: smbServersFileURL),
              let decoded = try? decoder.decode([SMBServerProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveSMBServers(_ servers: [SMBServerProfile]) throws {
        ensureDirectories()
        let data = try encoder.encode(servers)
        try data.write(to: smbServersFileURL, options: .atomic)
    }

    public func upsertSMBServer(_ server: SMBServerProfile, password: String) throws -> [SMBServerProfile] {
        var servers = loadSMBServers()
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        try saveSMBServers(servers)
        credentialStore.setPassword(password, forServerID: server.id)
        return servers
    }

    public func deleteSMBServer(_ server: SMBServerProfile) throws -> [SMBServerProfile] {
        var servers = loadSMBServers()
        servers.removeAll { $0.id == server.id }
        try saveSMBServers(servers)
        credentialStore.deletePassword(forServerID: server.id)
        return servers
    }

    public func smbPassword(for serverID: UUID) -> String {
        credentialStore.password(forServerID: serverID)
    }

    public func importRemoteSMBGame(
        server: SMBServerProfile,
        password: String,
        share: String,
        remotePath: String,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> GameEntry {
        ensureDirectories()
        let cleanRemote = SMBClient.normalizeRelativePath(remotePath)
        let fallbackName = cleanRemote.split(separator: "/").last.map(String.init) ?? share
        let rawTitle = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? preferredName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : fallbackName
        let folderName = uniqueFolderName(base: sanitizeFolderName(rawTitle))
        let localDir = gamesDir.appendingPathComponent(folderName, isDirectory: true)

        do {
            let normalizedRoot = try SMBClient.prepareStreamedGame(
                server: server,
                password: password,
                share: share,
                remoteGamePath: cleanRemote,
                localGameDir: localDir,
                progress: progress
            )
            let detected = RenPyVersionDetector.detectVersion(in: localDir)
            let gameVer = RenPyVersionDetector.parseGameVersion(in: localDir)
            let cover = extractCoverIfNeeded(in: localDir)
            let totalSize = computeGameSizeBytes(in: localDir, isRemote: true)
            let source = SMBGameSource(
                serverID: server.id,
                host: server.host,
                port: server.port,
                share: share,
                remotePath: normalizedRoot,
                username: server.username,
                domain: server.domain,
                isGuest: server.isGuest,
                lastSyncedAt: Date()
            )
            var entry = GameEntry(
                displayName: rawTitle,
                folderName: folderName,
                detectedEngineVersion: detected?.libraryLabel,
                coverRelativePath: cover,
                remoteSource: source,
                gameVersion: gameVer,
                sizeBytes: totalSize
            )
            var games = loadGames()
            adoptKeptSaves(for: &entry, gameRoot: localDir, existing: games)
            games.append(entry)
            try saveGames(games)
            return entry
        } catch {
            try? FileManager.default.removeItem(at: localDir)
            throw error
        }
    }

    public func refreshRemoteSMBGame(
        _ game: GameEntry,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> GameEntry {
        guard let source = game.remoteSource else {
            throw SMBError.invalidConfiguration("Selected game is not configured for SMB streaming.")
        }
        let server = SMBServerProfile(
            id: source.serverID,
            displayName: source.host,
            host: source.host,
            port: source.port,
            username: source.username,
            domain: source.domain,
            isGuest: source.isGuest
        )
        let password = credentialStore.password(forServerID: source.serverID)
        let localDir = gameDirectory(for: game)
        let normalizedRoot = try SMBClient.prepareStreamedGame(
            server: server,
            password: password,
            share: source.share,
            remoteGamePath: source.remotePath,
            localGameDir: localDir,
            progress: progress
        )
        let detected = RenPyVersionDetector.detectVersion(in: localDir)
        let cover = extractCoverIfNeeded(in: localDir)

        var updated = game
        updated.detectedEngineVersion = detected?.libraryLabel
        if updated.gameVersion == nil {
            updated.gameVersion = RenPyVersionDetector.parseGameVersion(in: localDir)
        }
        updated.sizeBytes = computeGameSizeBytes(in: localDir, isRemote: true)
        updated.coverRelativePath = cover
        updated.remoteSource = SMBGameSource(
            serverID: source.serverID,
            host: source.host,
            port: source.port,
            share: source.share,
            remotePath: normalizedRoot,
            username: source.username,
            domain: source.domain,
            isGuest: source.isGuest,
            lastSyncedAt: Date()
        )
        var games = loadGames()
        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx] = updated
            try saveGames(games)
        }
        return updated
    }

    // Reconcile library.json against Games/ so folders dropped via Files app are auto-discovered.
    public func syncWithDisk() throws -> [GameEntry] {
        ensureDirectories()
        let fm = FileManager.default
        var games = loadGames()

        let existingFolders = Set(games.map(\.folderName))
        let diskDirs = (try? fm.contentsOfDirectory(at: gamesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var presentFolderNames = Set<String>()
        for dir in diskDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folder = dir.lastPathComponent
            presentFolderNames.insert(folder)

            if !existingFolders.contains(folder) {
                let detected = RenPyVersionDetector.detectVersion(in: dir)
                let gameVer = RenPyVersionDetector.parseGameVersion(in: dir)
                let cover = extractCoverIfNeeded(in: dir)
                let size = computeGameSizeBytes(in: dir, isRemote: false)
                var entry = GameEntry(
                    displayName: folder,
                    folderName: folder,
                    detectedEngineVersion: detected?.libraryLabel,
                    coverRelativePath: cover,
                    gameVersion: gameVer,
                    sizeBytes: size
                )
                adoptKeptSaves(for: &entry, gameRoot: dir, existing: games)
                games.append(entry)
            }
        }

        for idx in games.indices where presentFolderNames.contains(games[idx].folderName) {
            let gDir = gameDirectory(for: games[idx])
            if games[idx].detectedEngineVersion == nil {
                games[idx].detectedEngineVersion = RenPyVersionDetector.detectVersion(in: gDir)?.libraryLabel
            }
            if games[idx].gameVersion == nil {
                games[idx].gameVersion = RenPyVersionDetector.parseGameVersion(in: gDir)
            }
            if games[idx].sizeBytes == nil {
                games[idx].sizeBytes = computeGameSizeBytes(in: gDir, isRemote: games[idx].remoteSource != nil)
            }
            reconcileSessionStats(for: &games[idx])
        }

        for game in games where !presentFolderNames.contains(game.folderName) {
            let saveDir = saveDirectory(for: game)
            if fm.fileExists(atPath: saveDir.path),
               !fm.fileExists(atPath: saveDir.appendingPathComponent(Self.saveMetaFileName).path) {
                writeSaveMeta(for: game, saveKey: titleSaveKey(game.displayName))
            }
        }

        games.removeAll { !presentFolderNames.contains($0.folderName) }
        try saveGames(games)
        return games
    }

    public func importGameArchive(
        from archiveURL: URL,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> GameEntry {
        ensureDirectories()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("renplay-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }

        try ArchiveExtractor.extractArchive(at: archiveURL, to: staging, progress: progress)
        let gameRoot = ArchiveExtractor.locateGameRoot(inside: staging)

        let rawTitle = preferredName ?? ArchiveExtractor.stripArchiveExtension(from: archiveURL.lastPathComponent)
        let folderName = uniqueFolderName(base: sanitizeFolderName(rawTitle))
        let finalDir = gamesDir.appendingPathComponent(folderName, isDirectory: true)
        try fm.moveItem(at: gameRoot, to: finalDir)

        let detected = RenPyVersionDetector.detectVersion(in: finalDir)
        let gameVer = RenPyVersionDetector.parseGameVersion(in: finalDir)
        let cover = extractCoverIfNeeded(in: finalDir)
        let size = computeGameSizeBytes(in: finalDir, isRemote: false)
        var entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.libraryLabel,
            coverRelativePath: cover,
            gameVersion: gameVer,
            sizeBytes: size
        )

        var games = loadGames()
        adoptKeptSaves(for: &entry, gameRoot: finalDir, existing: games)
        games.append(entry)
        try saveGames(games)
        return entry
    }

    public func importGameFolder(from sourceFolder: URL) throws -> GameEntry {
        ensureDirectories()
        let rawTitle = sourceFolder.lastPathComponent
        let folderName = uniqueFolderName(base: sanitizeFolderName(rawTitle))
        let finalDir = gamesDir.appendingPathComponent(folderName, isDirectory: true)

        let gameRoot = ArchiveExtractor.locateGameRoot(inside: sourceFolder)
        try copyDirectoryResilient(from: gameRoot, to: finalDir)

        let detected = RenPyVersionDetector.detectVersion(in: finalDir)
        let gameVer = RenPyVersionDetector.parseGameVersion(in: finalDir)
        let cover = extractCoverIfNeeded(in: finalDir)
        let size = computeGameSizeBytes(in: finalDir, isRemote: false)
        var entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.libraryLabel,
            coverRelativePath: cover,
            gameVersion: gameVer,
            sizeBytes: size
        )

        var games = loadGames()
        adoptKeptSaves(for: &entry, gameRoot: finalDir, existing: games)
        games.append(entry)
        try saveGames(games)
        return entry
    }

    // Fallback to byte-by-byte file copies when FileManager.copyItem fails across FileProvider/container boundaries.
    private func copyDirectoryResilient(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        do {
            try fm.copyItem(at: src, to: dst)
            return
        } catch {
            try? fm.removeItem(at: dst)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            guard let enumerator = fm.enumerator(
                at: src,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw error
            }
            let basePath = src.standardizedFileURL.path
            while let item = enumerator.nextObject() as? URL {
                let itemPath = item.standardizedFileURL.path
                guard itemPath.hasPrefix(basePath) else { continue }
                let rel = String(itemPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rel.isEmpty else { continue }
                let target = dst.appendingPathComponent(rel)
                let vals = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if vals.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try Data(contentsOf: item, options: .mappedIfSafe)
                    try data.write(to: target, options: .atomic)
                }
            }
        }
    }

    public func scanAndImportDropzones(
        additionalDirs: [URL] = [],
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> Int {
        ensureDirectories()
        let fm = FileManager.default
        let reservedDirNames: Set<String> = ["renplay", "import", "exports", "inbox"]
        var importedCount = 0

        var seenPaths = Set<String>()
        var searchDirs: [URL] = []
        for dir in [importDropzoneDir] + additionalDirs {
            let std = dir.standardizedFileURL.path
            if !seenPaths.contains(std) && fm.fileExists(atPath: std) {
                seenPaths.insert(std)
                searchDirs.append(dir)
            }
        }

        for dir in searchDirs {
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in items {
                let name = item.lastPathComponent
                if name == "HOW_TO_IMPORT.txt" { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir {
                    if reservedDirNames.contains(name.lowercased()) {
                        continue
                    }
                    if looksLikeRenPyGameFolder(at: item) {
                        _ = try importGameFolder(from: item)
                        try? fm.removeItem(at: item)
                        importedCount += 1
                    }
                } else if ArchiveExtractor.isSupportedArchive(item) {
                    _ = try importGameArchive(from: item, progress: progress)
                    try? fm.removeItem(at: item)
                    importedCount += 1
                }
            }
        }

        let gameTopItems = (try? fm.contentsOfDirectory(
            at: gamesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for item in gameTopItems {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isDir && ArchiveExtractor.isSupportedArchive(item) {
                _ = try importGameArchive(from: item, progress: progress)
                try? fm.removeItem(at: item)
                importedCount += 1
            }
        }

        _ = try syncWithDisk()
        return importedCount
    }

    private func looksLikeRenPyGameFolder(at url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("game").path)
            || fm.fileExists(atPath: url.appendingPathComponent("renpy").path)
            || fm.fileExists(atPath: url.appendingPathComponent("script_version.txt").path) {
            return true
        }
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for child in children {
            let ext = child.pathExtension.lowercased()
            if ext == "rpa" || ext == "rpy" || ext == "rpyc" {
                return true
            }
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               fm.fileExists(atPath: child.appendingPathComponent("game").path) {
                return true
            }
        }
        return false
    }

    public func deleteGame(_ game: GameEntry, deleteSaves: Bool) throws {
        let fm = FileManager.default
        let saveDir = saveDirectory(for: game)
        if deleteSaves {
            try? fm.removeItem(at: saveDir)
            try? fm.removeItem(at: backupDirectory(for: game))
        } else if fm.fileExists(atPath: saveDir.path) {
            // The key must be read from the game folder before it is removed below.
            let key = saveKey(forGameRoot: gameDirectory(for: game), displayName: game.displayName, remoteSource: game.remoteSource)
            writeSaveMeta(for: game, saveKey: key)
        }
        try? fm.removeItem(at: gameDirectory(for: game))
        var games = loadGames()
        games.removeAll { $0.id == game.id }
        try saveGames(games)
    }

    public func listOrphanedSaveGroups() -> [OrphanedSaveGroup] {
        let fm = FileManager.default
        let attached = attachedSaveIdentifiers(loadGames())
        let dirs = (try? fm.contentsOfDirectory(at: savesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var groups: [OrphanedSaveGroup] = []
        for dir in dirs {
            let id = dir.lastPathComponent
            guard !id.hasPrefix("_"),
                  !attached.contains(id),
                  (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            let saveFiles = saveFilesInDirectory(dir)
            let backupZips = backupFilesInDirectory(backupDirectory(forIdentifier: id))
            guard !saveFiles.isEmpty || !backupZips.isEmpty else { continue }

            let newest = (saveFiles + backupZips)
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? Date.distantPast
            let name = readSaveMeta(in: dir)?.displayName ?? (UUID(uuidString: id) == nil ? id : "Removed game (\(id.prefix(8)))")
            groups.append(OrphanedSaveGroup(id: id, displayName: name, slotCount: saveFiles.count, modifiedAt: newest))
        }
        return groups.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func deleteOrphanedSaveGroup(id: String) throws {
        try validateSaveIdentifier(id)
        guard !attachedSaveIdentifiers(loadGames()).contains(id) else {
            throw SaveRetentionError.attachedToGame(id)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: backupDirectory(forIdentifier: id))
        try fm.removeItem(at: saveDirectory(forIdentifier: id))
    }

    public func listAllSaveFolders() -> [SaveFolderSummary] {
        ensureDirectories()
        let fm = FileManager.default
        let games = loadGames()
        var byIdentifier: [String: GameEntry] = [:]
        for g in games {
            let key = g.saveIdentifier ?? g.id.uuidString
            if byIdentifier[key] == nil {
                byIdentifier[key] = g
            }
        }

        let dirs = (try? fm.contentsOfDirectory(at: savesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var summaries: [SaveFolderSummary] = []
        var seen = Set<String>()

        for dir in dirs {
            let id = dir.lastPathComponent
            guard !id.hasPrefix("_"),
                  (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            seen.insert(id)
            let linked = byIdentifier[id]
            let files = saveFilesInDirectory(dir)
            let backups = backupFilesInDirectory(backupDirectory(forIdentifier: id))
            // Unlinked empty folders with no backups are stale artifacts unless explicitly created with meta.
            if linked == nil && files.isEmpty && backups.isEmpty && readSaveMeta(in: dir) == nil {
                continue
            }
            let bytes = directoryFileBytes(dir)
            let newest = (files + backups)
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? Date.distantPast
            let display = linked?.displayName ?? readSaveMeta(in: dir)?.displayName ?? (UUID(uuidString: id) == nil ? id : "Saved Data (\(id.prefix(6)))")
            summaries.append(SaveFolderSummary(
                id: id,
                displayName: display,
                slotCount: files.count,
                backupCount: backups.count,
                sizeBytes: bytes,
                modifiedAt: newest,
                linkedGameID: linked?.id,
                linkedGameTitle: linked?.displayName
            ))
        }

        // Surface linked games whose save folder has not been created yet so users can still inspect/relink them.
        for g in games {
            let id = g.saveIdentifier ?? g.id.uuidString
            if !seen.contains(id) {
                let backups = backupFilesInDirectory(backupDirectory(forIdentifier: id))
                summaries.append(SaveFolderSummary(
                    id: id,
                    displayName: g.displayName,
                    slotCount: 0,
                    backupCount: backups.count,
                    sizeBytes: 0,
                    modifiedAt: g.lastPlayedAt ?? g.importedAt,
                    linkedGameID: g.id,
                    linkedGameTitle: g.displayName
                ))
            }
        }

        return summaries.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    public func createSaveFolder(named rawName: String) throws -> String {
        ensureDirectories()
        let cleaned = sanitizeFolderName(rawName)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("_"), !cleaned.hasPrefix(".") else {
            throw SaveRetentionError.invalidIdentifier(rawName)
        }
        let target = saveDirectory(forIdentifier: cleaned)
        if FileManager.default.fileExists(atPath: target.path) {
            throw SaveRetentionError.folderAlreadyExists(cleaned)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let meta = SaveMeta(displayName: cleaned, saveKey: "manual:\(cleaned)", updatedAt: Date())
        if let data = try? encoder.encode(meta) {
            try? data.write(to: target.appendingPathComponent(Self.saveMetaFileName), options: .atomic)
        }
        return cleaned
    }

    public func renameSaveFolder(from oldID: String, to rawNewName: String) throws -> String {
        try validateSaveIdentifier(oldID)
        let newID = sanitizeFolderName(rawNewName)
        guard !newID.isEmpty, !newID.hasPrefix("_"), !newID.hasPrefix(".") else {
            throw SaveRetentionError.invalidIdentifier(rawNewName)
        }
        if newID == oldID { return oldID }

        let fm = FileManager.default
        let oldSave = saveDirectory(forIdentifier: oldID)
        let newSave = saveDirectory(forIdentifier: newID)
        guard fm.fileExists(atPath: oldSave.path) else {
            throw SaveRetentionError.folderNotFound(oldID)
        }
        guard !fm.fileExists(atPath: newSave.path) else {
            throw SaveRetentionError.folderAlreadyExists(newID)
        }

        try fm.moveItem(at: oldSave, to: newSave)
        let oldBackup = backupDirectory(forIdentifier: oldID)
        let newBackup = backupDirectory(forIdentifier: newID)
        if fm.fileExists(atPath: oldBackup.path), !fm.fileExists(atPath: newBackup.path) {
            try? fm.moveItem(at: oldBackup, to: newBackup)
        }

        var games = loadGames()
        var touched = false
        for idx in games.indices where (games[idx].saveIdentifier ?? games[idx].id.uuidString) == oldID {
            games[idx].saveIdentifier = newID
            touched = true
        }
        if touched {
            try saveGames(games)
        }
        return newID
    }

    @discardableResult
    public func linkGame(_ gameID: UUID, toSaveFolder folderID: String) throws -> GameEntry {
        try validateSaveIdentifier(folderID)
        let fm = FileManager.default
        let dir = saveDirectory(forIdentifier: folderID)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var games = loadGames()
        guard let idx = games.firstIndex(where: { $0.id == gameID }) else {
            throw SaveRetentionError.gameNotFound
        }
        games[idx].saveIdentifier = folderID
        let updated = games[idx]
        try saveGames(games)
        let key = saveKey(forGameRoot: gameDirectory(for: updated), displayName: updated.displayName, remoteSource: updated.remoteSource)
        writeSaveMeta(for: updated, saveKey: key)
        return updated
    }

    public func listSharedPersistentItems() -> [SharedPersistentItem] {
        ensureDirectories()
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: multipersistentDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.compactMap { url -> SharedPersistentItem? in
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { return nil }
            return SharedPersistentItem(
                filename: url.lastPathComponent,
                sizeBytes: Int64(vals?.fileSize ?? 0),
                modifiedAt: vals?.contentModificationDate ?? Date.distantPast
            )
        }.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    public func importSharedPersistentFile(from sourceURL: URL) throws {
        ensureDirectories()
        let name = sanitizeFolderName(sourceURL.lastPathComponent)
        let dst = multipersistentDir.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: sourceURL, to: dst)
    }

    public func deleteSharedPersistentItem(named filename: String) throws {
        try validateSaveIdentifier(filename)
        try FileManager.default.removeItem(at: multipersistentDir.appendingPathComponent(filename))
    }

    @discardableResult
    public func backupAllSavesZip(to destinationZipURL: URL) throws -> Int {
        ensureDirectories()
        let fm = FileManager.default
        var payload: [(String, Data)] = []

        let dirs = (try? fm.contentsOfDirectory(at: savesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            let folder = dir.lastPathComponent
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if folder == "_multipersistent" {
                let mpFiles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                for file in mpFiles {
                    if let data = try? Data(contentsOf: file) {
                        payload.append(("_multipersistent/\(file.lastPathComponent)", data))
                    }
                }
            } else {
                for file in saveFilesInDirectory(dir) {
                    if let data = try? Data(contentsOf: file) {
                        payload.append(("\(folder)/\(file.lastPathComponent)", data))
                    }
                }
            }
        }
        try ArchiveExtractor.createZip(fromFiles: payload, to: destinationZipURL)
        return payload.count
    }

    public func renameGameDirectory(_ game: GameEntry, to rawNewFolder: String) throws -> GameEntry {
        let newFolder = sanitizeFolderName(rawNewFolder)
        if newFolder == game.folderName { return game }
        let fm = FileManager.default
        let oldURL = gameDirectory(for: game)
        let newURL = gamesDir.appendingPathComponent(newFolder, isDirectory: true)
        guard !fm.fileExists(atPath: newURL.path) else {
            throw SaveRetentionError.folderAlreadyExists(newFolder)
        }
        try fm.moveItem(at: oldURL, to: newURL)
        var games = loadGames()
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else {
            throw SaveRetentionError.gameNotFound
        }
        games[idx].folderName = newFolder
        let updated = games[idx]
        try saveGames(games)
        return updated
    }

    public func setCustomArtwork(data: Data, kind: CustomArtworkKind, for game: GameEntry) throws -> GameEntry {
        let dir = gameDirectory(for: game)
        let dest = dir.appendingPathComponent(kind.fileName)
        try data.write(to: dest, options: .atomic)
        var games = loadGames()
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else {
            throw SaveRetentionError.gameNotFound
        }
        switch kind {
        case .cover: games[idx].customCoverPath = kind.fileName
        case .hero: games[idx].customHeroPath = kind.fileName
        }
        let updated = games[idx]
        try saveGames(games)
        return updated
    }

    public func clearCustomArtwork(kind: CustomArtworkKind, for game: GameEntry) throws -> GameEntry {
        let dir = gameDirectory(for: game)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(kind.fileName))
        var games = loadGames()
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else {
            throw SaveRetentionError.gameNotFound
        }
        switch kind {
        case .cover: games[idx].customCoverPath = nil
        case .hero: games[idx].customHeroPath = nil
        }
        let updated = games[idx]
        try saveGames(games)
        return updated
    }

    public func computeStorageBreakdown(engineCacheBytes: Int64) -> StorageBreakdown {
        let games = loadGames()
        var usages: [StorageBreakdown.GameUsage] = []
        var gamesTotal: Int64 = 0
        for g in games {
            let localBytes = directoryFileBytes(gameDirectory(for: g))
            gamesTotal += localBytes
            usages.append(StorageBreakdown.GameUsage(
                title: g.displayName,
                isRemote: g.remoteSource != nil,
                bytes: localBytes,
                game: g
            ))
        }
        usages.sort { $0.bytes > $1.bytes }
        return StorageBreakdown(
            games: usages,
            totalGamesBytes: gamesTotal,
            savesBytes: directoryFileBytes(savesDir),
            backupsBytes: directoryFileBytes(backupsDir),
            exportsBytes: directoryFileBytes(exportsDir),
            engineCacheBytes: engineCacheBytes
        )
    }

    public func clearExports() throws {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    public func reconcileSessionStats(for game: inout GameEntry) {
        let saveDir = saveDirectory(for: game)
        let statsURL = saveDir.appendingPathComponent(Self.statsFileName)
        guard let data = try? Data(contentsOf: statsURL),
              let stats = try? decoder.decode(SessionStatsPayload.self, from: data) else {
            return
        }
        if stats.totalBlocks > 0 {
            game.dialogueSeenCount = stats.seenBlocks
            game.dialogueTotalCount = stats.totalBlocks
        }
        let appliedURL = saveDir.appendingPathComponent(Self.statsAppliedFileName)
        var applied = (try? Data(contentsOf: appliedURL)).flatMap {
            try? decoder.decode(AppliedSessionStats.self, from: $0)
        }
        let delta: TimeInterval
        if let prev = applied, prev.sessionId == stats.sessionId {
            delta = max(0, stats.elapsedSeconds - prev.appliedSeconds)
        } else {
            delta = max(0, stats.elapsedSeconds)
        }
        if delta > 0 {
            game.playTimeSeconds += delta
        }
        applied = AppliedSessionStats(sessionId: stats.sessionId, appliedSeconds: max(0, stats.elapsedSeconds))
        if let out = try? encoder.encode(applied) {
            try? out.write(to: appliedURL, options: .atomic)
        }
    }

    private func validateSaveIdentifier(_ id: String) throws {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != "..", !id.hasPrefix("_") else {
            throw SaveRetentionError.invalidIdentifier(id)
        }
    }

    private func saveFilesInDirectory(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter {
                let lower = $0.lastPathComponent.lowercased()
                return lower.hasSuffix(".save") || lower == "persistent"
            }
    }

    private func backupFilesInDirectory(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "zip" }
    }

    private func directoryFileBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               vals.isRegularFile == true {
                total += Int64(vals.fileSize ?? 0)
            }
        }
        return total
    }

    private func computeGameSizeBytes(in gameRoot: URL, isRemote: Bool) -> Int64 {
        let localBytes = directoryFileBytes(gameRoot)
        if !isRemote { return localBytes }
        let manifestURL = gameRoot.appendingPathComponent(SMBIndexManifest.manifestFileName)
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return localBytes }
        let remoteBytes = SMBIndexManifest.parse(text).entries.reduce(Int64(0)) { $0 + Int64($1.totalSize) }
        return localBytes + remoteBytes
    }

    // Stable identity for a game's saves across remove/re-add, preferring the game's own save_directory.
    func saveKey(forGameRoot root: URL, displayName: String, remoteSource: SMBGameSource?) -> String {
        let optionsURL = root.appendingPathComponent("game/options.rpy")
        let pattern = #"(?m)^\s*(?:define\s+)?config\.save_directory\s*=\s*[ru]?["']([^"'\n]+)["']"#
        if let text = try? String(contentsOf: optionsURL, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return "savedir:\(text[range])"
        }
        if let remote = remoteSource {
            return "smb:\(remote.host.lowercased())/\(remote.share.lowercased())/\(remote.remotePath.lowercased())"
        }
        return titleSaveKey(displayName)
    }

    private func titleSaveKey(_ displayName: String) -> String {
        "title:\(displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))"
    }

    private static let saveMetaFileName = ".renplay_save_meta.json"
    private static let statsFileName = ".renplay_stats.json"
    private static let statsAppliedFileName = ".renplay_stats_applied.json"

    private struct SessionStatsPayload: Codable {
        var sessionId: String
        var elapsedSeconds: Double
        var seenBlocks: Int
        var totalBlocks: Int
    }

    private struct AppliedSessionStats: Codable {
        var sessionId: String
        var appliedSeconds: Double
    }

    private struct SaveMeta: Codable {
        var displayName: String
        var saveKey: String
        var updatedAt: Date
    }

    private func attachedSaveIdentifiers(_ games: [GameEntry]) -> Set<String> {
        Set(games.map { $0.saveIdentifier ?? $0.id.uuidString })
    }

    private func readSaveMeta(in saveDir: URL) -> SaveMeta? {
        guard let data = try? Data(contentsOf: saveDir.appendingPathComponent(Self.saveMetaFileName)) else { return nil }
        return try? decoder.decode(SaveMeta.self, from: data)
    }

    // Best-effort: missing metadata only costs the friendly name and automatic re-linking.
    private func writeSaveMeta(for game: GameEntry, saveKey: String) {
        let saveDir = saveDirectory(for: game)
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let meta = SaveMeta(displayName: game.displayName, saveKey: saveKey, updatedAt: Date())
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: saveDir.appendingPathComponent(Self.saveMetaFileName), options: .atomic)
    }

    private func adoptKeptSaves(for entry: inout GameEntry, gameRoot: URL, existing: [GameEntry]) {
        let key = saveKey(forGameRoot: gameRoot, displayName: entry.displayName, remoteSource: entry.remoteSource)
        let attached = attachedSaveIdentifiers(existing)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: savesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where !attached.contains(dir.lastPathComponent) && !dir.lastPathComponent.hasPrefix("_") {
            if readSaveMeta(in: dir)?.saveKey == key {
                entry.saveIdentifier = dir.lastPathComponent
                break
            }
        }
        if entry.saveIdentifier == nil {
            let base = readableSaveFolderBase(gameRoot: gameRoot, displayName: entry.displayName)
            var candidate = base
            var suffix = 2
            while attached.contains(candidate) || FileManager.default.fileExists(atPath: saveDirectory(forIdentifier: candidate).path) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            entry.saveIdentifier = candidate
        }
        writeSaveMeta(for: entry, saveKey: key)
    }

    private func readableSaveFolderBase(gameRoot: URL, displayName: String) -> String {
        if let raw = RenPyVersionDetector.parseConfiguredSaveDirName(in: gameRoot) {
            // Strip Ren'Py's trailing Unix timestamp suffix (e.g. "MyGame-1700000000") for clean folder names.
            let stripped = raw.replacingOccurrences(of: #"-\d{8,}$"#, with: "", options: .regularExpression)
            let cleaned = sanitizeFolderName(stripped.isEmpty ? raw : stripped)
            if !cleaned.isEmpty && !cleaned.hasPrefix("_") {
                return cleaned
            }
        }
        let fromTitle = sanitizeFolderName(displayName)
        return fromTitle.hasPrefix("_") ? "Game_\(fromTitle)" : fromTitle
    }

    @discardableResult
    public func installSmokeTestGame() throws -> GameEntry {
        ensureDirectories()
        let fm = FileManager.default
        let folderName = uniqueFolderName(base: "RenPlay Demo")
        let gameRoot = gamesDir.appendingPathComponent(folderName, isDirectory: true)
        let scriptDir = gameRoot.appendingPathComponent("game", isDirectory: true)
        try fm.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let optionsRpy = """
        define config.name = _("RenPlay Demo")
        define gui.show_name = True
        define config.version = "1.0"
        define config.save_directory = "RenPlayDemo"
        """
        let scriptRpy = """
        define e = Character("Eileen", color="#6ee7b7")

        label start:
            scene black
            e "Welcome to RenPlay on iOS."
            e "This built-in visual novel verifies Python execution, rendering, and save slots."
            menu:
                "Test Save & Rollback":
                    e "Rollback and skip work from the floating RenPlay overlay."
                "Test Text Input":
                    $ entered_name = renpy.input("Enter your name:", default="Traveler")
                    e "Hello, [entered_name]! You can hide and reopen the keyboard anytime."
                "Check Platform":
                    python:
                        import sys, renpy
                        ver = renpy.version()
                        py = sys.version.split()[0]
                    e "Running Ren'Py [ver] on Python [py]."
            e "Demo complete. Returning to title screen."
            return
        """
        try optionsRpy.write(to: scriptDir.appendingPathComponent("options.rpy"), atomically: true, encoding: .utf8)
        try scriptRpy.write(to: scriptDir.appendingPathComponent("script.rpy"), atomically: true, encoding: .utf8)
        try "8.5.3\n".write(to: gameRoot.appendingPathComponent("script_version.txt"), atomically: true, encoding: .utf8)

        var entry = GameEntry(
            displayName: "RenPlay Demo",
            folderName: folderName,
            detectedEngineVersion: "8.5.3",
            coverRelativePath: nil,
            gameVersion: "1.0",
            sizeBytes: computeGameSizeBytes(in: gameRoot, isRemote: false)
        )
        var games = loadGames()
        adoptKeptSaves(for: &entry, gameRoot: gameRoot, existing: games)
        games.append(entry)
        try saveGames(games)
        return entry
    }

    public func extractCoverIfNeeded(in gameRoot: URL) -> String? {
        let fm = FileManager.default
        let cachedCover = ".renplay_cover.png"
        if fm.fileExists(atPath: gameRoot.appendingPathComponent(cachedCover).path) {
            return cachedCover
        }

        let candidates = [
            "game/gui/main_menu.png",
            "game/gui/game_menu.png",
            "game/gui/window_icon.png",
            "game/images/bg.png",
            "game/gui/main_menu.jpg",
        ]
        for rel in candidates {
            if fm.fileExists(atPath: gameRoot.appendingPathComponent(rel).path) {
                return rel
            }
        }

        let gameSubdir = gameRoot.appendingPathComponent("game")
        if let items = try? fm.contentsOfDirectory(at: gameSubdir, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension.lowercased() == "rpa" {
                guard let archive = try? RPAArchive(fileURL: item) else { continue }
                let archiveCandidates = [
                    "gui/main_menu.png",
                    "gui/game_menu.png",
                    "gui/window_icon.png",
                ]
                for target in archiveCandidates {
                    if let data = try? archive.readEntry(target) {
                        let outURL = gameRoot.appendingPathComponent(cachedCover)
                        if (try? data.write(to: outURL, options: .atomic)) != nil {
                            return cachedCover
                        }
                    }
                }
            }
        }
        return nil
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "RenPyGame" : cleaned
    }

    private func uniqueFolderName(base: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: gamesDir.appendingPathComponent(base).path) {
            return base
        }
        var idx = 2
        while fm.fileExists(atPath: gamesDir.appendingPathComponent("\(base) (\(idx))").path) {
            idx += 1
        }
        return "\(base) (\(idx))"
    }
}
