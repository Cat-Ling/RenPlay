// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SaveRetentionError: Error, LocalizedError, Sendable {
    case invalidIdentifier(String)
    case attachedToGame(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "Invalid save folder name: \(id)"
        case .attachedToGame(let id):
            return "Save folder \(id) belongs to a game that is still in the library."
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
        for dir in [rootDir, gamesDir, savesDir, backupsDir, logsDir, importDropzoneDir, exportsDir] {
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
            let cover = extractCoverIfNeeded(in: localDir)
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
                remoteSource: source
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
                let cover = extractCoverIfNeeded(in: dir)
                var entry = GameEntry(
                    displayName: folder,
                    folderName: folder,
                    detectedEngineVersion: detected?.libraryLabel,
                    coverRelativePath: cover
                )
                adoptKeptSaves(for: &entry, gameRoot: dir, existing: games)
                games.append(entry)
            }
        }

        for idx in games.indices where games[idx].detectedEngineVersion == nil && presentFolderNames.contains(games[idx].folderName) {
            games[idx].detectedEngineVersion = RenPyVersionDetector.detectVersion(in: gameDirectory(for: games[idx]))?.libraryLabel
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
        let cover = extractCoverIfNeeded(in: finalDir)
        var entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.libraryLabel,
            coverRelativePath: cover
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
        let cover = extractCoverIfNeeded(in: finalDir)
        var entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.libraryLabel,
            coverRelativePath: cover
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
            guard !attached.contains(id),
                  (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            let saveFiles = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
                .filter {
                    let lower = $0.lastPathComponent.lowercased()
                    return lower.hasSuffix(".save") || lower == "persistent"
                }
            let backupZips = ((try? fm.contentsOfDirectory(at: backupDirectory(forIdentifier: id), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "zip" }
            guard !saveFiles.isEmpty || !backupZips.isEmpty else { continue }

            let newest = (saveFiles + backupZips)
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? Date.distantPast
            let name = readSaveMeta(in: dir)?.displayName ?? "Removed game (\(id.prefix(8)))"
            groups.append(OrphanedSaveGroup(id: id, displayName: name, slotCount: saveFiles.count, modifiedAt: newest))
        }
        return groups.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func deleteOrphanedSaveGroup(id: String) throws {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw SaveRetentionError.invalidIdentifier(id)
        }
        guard !attachedSaveIdentifiers(loadGames()).contains(id) else {
            throw SaveRetentionError.attachedToGame(id)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: backupDirectory(forIdentifier: id))
        try fm.removeItem(at: saveDirectory(forIdentifier: id))
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
        for dir in dirs where !attached.contains(dir.lastPathComponent) {
            if readSaveMeta(in: dir)?.saveKey == key {
                entry.saveIdentifier = dir.lastPathComponent
                break
            }
        }
        writeSaveMeta(for: entry, saveKey: key)
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
            coverRelativePath: nil
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
