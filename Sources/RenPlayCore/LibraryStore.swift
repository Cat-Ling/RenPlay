// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public final class LibraryStore: @unchecked Sendable {
    public let rootDir: URL
    public let gamesDir: URL
    public let savesDir: URL
    public let backupsDir: URL
    public let logsDir: URL
    private let libraryFileURL: URL
    private let settingsFileURL: URL

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
        self.libraryFileURL = rootDir.appendingPathComponent("library.json")
        self.settingsFileURL = rootDir.appendingPathComponent("settings.json")
        ensureDirectories()
    }

    public func ensureDirectories() {
        let fm = FileManager.default
        for dir in [rootDir, gamesDir, savesDir, backupsDir, logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func gameDirectory(for game: GameEntry) -> URL {
        gamesDir.appendingPathComponent(game.folderName, isDirectory: true)
    }

    public func saveDirectory(for game: GameEntry) -> URL {
        savesDir.appendingPathComponent(game.id.uuidString, isDirectory: true)
    }

    public func backupDirectory(for game: GameEntry) -> URL {
        backupsDir.appendingPathComponent(game.id.uuidString, isDirectory: true)
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
                let entry = GameEntry(
                    displayName: folder,
                    folderName: folder,
                    detectedEngineVersion: detected?.version?.description ?? detected?.majorHint.map { "\($0).x" },
                    coverRelativePath: cover
                )
                games.append(entry)
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

        let rawTitle = preferredName ?? archiveURL.deletingPathExtension().lastPathComponent
        let folderName = uniqueFolderName(base: sanitizeFolderName(rawTitle))
        let finalDir = gamesDir.appendingPathComponent(folderName, isDirectory: true)
        try fm.moveItem(at: gameRoot, to: finalDir)

        let detected = RenPyVersionDetector.detectVersion(in: finalDir)
        let cover = extractCoverIfNeeded(in: finalDir)
        let entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.version?.description ?? detected?.majorHint.map { "\($0).x" },
            coverRelativePath: cover
        )

        var games = loadGames()
        games.append(entry)
        try saveGames(games)
        return entry
    }

    public func importGameFolder(from sourceFolder: URL) throws -> GameEntry {
        ensureDirectories()
        let fm = FileManager.default
        let rawTitle = sourceFolder.lastPathComponent
        let folderName = uniqueFolderName(base: sanitizeFolderName(rawTitle))
        let finalDir = gamesDir.appendingPathComponent(folderName, isDirectory: true)

        let gameRoot = ArchiveExtractor.locateGameRoot(inside: sourceFolder)
        try fm.copyItem(at: gameRoot, to: finalDir)

        let detected = RenPyVersionDetector.detectVersion(in: finalDir)
        let cover = extractCoverIfNeeded(in: finalDir)
        let entry = GameEntry(
            displayName: rawTitle,
            folderName: folderName,
            detectedEngineVersion: detected?.version?.description ?? detected?.majorHint.map { "\($0).x" },
            coverRelativePath: cover
        )

        var games = loadGames()
        games.append(entry)
        try saveGames(games)
        return entry
    }

    public func deleteGame(_ game: GameEntry, deleteSaves: Bool = true) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: gameDirectory(for: game))
        if deleteSaves {
            try? fm.removeItem(at: saveDirectory(for: game))
        }
        var games = loadGames()
        games.removeAll { $0.id == game.id }
        try saveGames(games)
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

        let entry = GameEntry(
            displayName: "RenPlay Demo",
            folderName: folderName,
            detectedEngineVersion: "8.5.3",
            coverRelativePath: nil
        )
        var games = loadGames()
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
