// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Foundation
import Observation
import RenPlayCore

@MainActor
@Observable
public final class AppState {
    public let libraryStore: LibraryStore
    public let saveManager = SaveManager()
    public let launcher: EngineLauncher

    public var games: [GameEntry] = []
    public var appSettings: AppSettings
    public var engines: [EngineInfo] = []
    public var isImporting = false
    public var importProgress: Double = 0
    public var importStatus: String = ""
    public var isLaunching = false
    public var launchStatus: String = ""
    public var activeError: String?

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = docs.appendingPathComponent("RenPlay", isDirectory: true)
        let store = LibraryStore(rootDir: root)
        self.libraryStore = store
        self.appSettings = store.loadSettings()
        self.launcher = EngineLauncher(libraryStore: store, saveManager: SaveManager())
        self.engines = Self.loadBundledManifest().engines
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

    public func refreshLibrary() {
        do {
            games = try libraryStore.syncWithDisk()
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func saveAppSettings() {
        do {
            try libraryStore.saveSettings(appSettings)
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func updateGame(_ updated: GameEntry) {
        if let idx = games.firstIndex(where: { $0.id == updated.id }) {
            games[idx] = updated
        }
        do {
            try libraryStore.saveGames(games)
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func deleteGame(_ game: GameEntry, deleteSaves: Bool = true) {
        do {
            try libraryStore.deleteGame(game, deleteSaves: deleteSaves)
            games.removeAll { $0.id == game.id }
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func installDemoGame() {
        do {
            let entry = try libraryStore.installSmokeTestGame()
            games.append(entry)
        } catch {
            activeError = error.localizedDescription
        }
    }

    public func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importProgress = 0
        importStatus = "Preparing import..."

        Task {
            defer {
                isImporting = false
                importProgress = 0
                importStatus = ""
            }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    let entry: GameEntry
                    if isDir.boolValue {
                        await MainActor.run {
                            self.importStatus = "Copying \(url.lastPathComponent)..."
                        }
                        entry = try libraryStore.importGameFolder(from: url)
                    } else {
                        entry = try libraryStore.importGameArchive(from: url) { frac, name in
                            Task { @MainActor in
                                self.importProgress = frac
                                self.importStatus = name
                            }
                        }
                    }
                    games.append(entry)
                } catch {
                    activeError = "Import failed for \(url.lastPathComponent): \(error.localizedDescription)"
                }
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
        let gameDir = libraryStore.gameDirectory(for: game)
        let detected = RenPyVersionDetector.detectVersion(in: gameDir)
        return EngineSelector.selectEngine(
            detected: detected,
            available: engines,
            strategy: appSettings.defaultEngineStrategy
        )
    }

    public func launch(game: GameEntry) {
        guard let engine = resolvedEngine(for: game) else {
            activeError = "No Ren'Py engine framework is bundled to launch this game."
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
                    appSettings: appSettings
                ) { status in
                    Task { @MainActor in
                        self.launchStatus = status
                    }
                } onFailure: { msg in
                    self.isLaunching = false
                    self.launchStatus = ""
                    self.activeError = msg
                }
            } catch {
                isLaunching = false
                launchStatus = ""
                activeError = error.localizedDescription
            }
        }
    }
}
#endif
