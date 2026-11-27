// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import CRenPlayBridge
import Darwin
import Foundation
import RenPlayCore
import SwiftUI
import UIKit

public enum LaunchError: Error, LocalizedError, Sendable {
    case missingEngineArchive(String)
    case missingFramework(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingEngineArchive(let name):
            return "Bundled engine archive missing: \(name)"
        case .missingFramework(let name):
            return "Bundled engine framework missing: \(name)"
        case .engineFailure(let detail):
            return detail
        }
    }
}

@MainActor
public final class EngineLauncher {
    private let libraryStore: LibraryStore
    private let saveManager: SaveManager
    private var overlayWindow: GameOverlayWindow?

    public init(libraryStore: LibraryStore, saveManager: SaveManager) {
        self.libraryStore = libraryStore
        self.saveManager = saveManager
    }

    public var cachedEnginesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("RenPlay/Engines", isDirectory: true)
    }

    public func clearEngineCache() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedEnginesDirectory.path) {
            try fm.removeItem(at: cachedEnginesDirectory)
        }
    }

    public func engineCacheSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cachedEnginesDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    public func launch(
        game: GameEntry,
        engine: EngineInfo,
        appSettings: AppSettings,
        statusUpdate: @escaping @Sendable (String) -> Void,
        onFailure: @MainActor @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let engineRoot = cachedEnginesDirectory.appendingPathComponent(engine.version, isDirectory: true)
        let cacheStamp = engine.engineSha256 ?? engine.releaseTag
        let markerURL = engineRoot.appendingPathComponent(".ready_\(cacheStamp)")

        if !fm.fileExists(atPath: markerURL.path) {
            let zipName = engine.engineArchive.replacingOccurrences(of: ".zip", with: "")
            guard let zipURL = Bundle.main.url(forResource: zipName, withExtension: "zip", subdirectory: "Engines") else {
                throw LaunchError.missingEngineArchive(engine.engineArchive)
            }
            statusUpdate("Unpacking Ren'Py \(engine.version) runtime...")
            try await Task.detached(priority: .userInitiated) {
                let localFM = FileManager.default
                try? localFM.removeItem(at: engineRoot)
                try ArchiveExtractor.extractZip(at: zipURL, to: engineRoot)
                try Data("ok".utf8).write(to: markerURL, options: .atomic)
            }.value
        }

        let fwSubpath = "Frameworks/\(engine.frameworkName).framework/\(engine.frameworkName)"
        let fwURL = Bundle.main.bundleURL.appendingPathComponent(fwSubpath)
        guard fm.fileExists(atPath: fwURL.path) else {
            throw LaunchError.missingFramework("\(engine.frameworkName).framework")
        }

        let gameDir = libraryStore.gameDirectory(for: game)
        let saveDir = libraryStore.saveDirectory(for: game)
        let backupDir = libraryStore.backupDirectory(for: game)
        let logDir = libraryStore.logDirectory(for: game)
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        if appSettings.autoBackupCount > 0 {
            statusUpdate("Backing up saves...")
            _ = try? saveManager.createBackup(of: saveDir, to: backupDir, maxBackups: appSettings.autoBackupCount)
        }

        statusUpdate("Starting \(game.displayName)...")

        let variant: String
        switch game.settings.orientation {
        case .auto:
            variant = UIDevice.current.userInterfaceIdiom == .pad ? "tablet touch" : "phone touch"
        case .landscape:
            variant = "touch"
        case .portrait:
            variant = "portrait touch"
        }

        let sdlVersion = engine.sdlVersion.uppercased().contains("3") ? 3 : 2
        let allowNetwork = (game.settings.allowNetwork || appSettings.globalAllowNetwork) ? 1 : 0
        let devMode = game.settings.developerMode ? 1 : 0
        let forceRollback = game.settings.forceRollback ? 1 : 0
        let forceSkip = game.settings.forceSkip ? 1 : 0
        let lessMemory = game.settings.lowMemoryMode ? 1 : 0
        let showOverlay = appSettings.showOverlayByDefault
        let overlayOpacity = appSettings.overlayOpacity
        let gameTitle = game.displayName

        // Capture foreground UIWindowScene before hiding SwiftUI windows, then enter SDL outside Swift Task context.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            renplay_capture_window_scene()
            if showOverlay {
                self.installOverlay(gameName: gameTitle, logDir: logDir, opacity: overlayOpacity)
            }
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for win in ws.windows where win !== self.overlayWindow {
                    win.isHidden = true
                }
            }

            var errBuf = [CChar](repeating: 0, count: 1024)
            let rc = renplay_launch_engine(
                fwURL.path,
                engineRoot.path,
                gameDir.path,
                saveDir.path,
                logDir.path,
                variant,
                Int32(sdlVersion),
                Int32(allowNetwork),
                Int32(devMode),
                Int32(forceRollback),
                Int32(forceSkip),
                Int32(lessMemory),
                &errBuf,
                errBuf.count
            )

            self.removeOverlay()
            if rc == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Darwin.exit(0)
                }
                return
            }

            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for win in ws.windows {
                    win.isHidden = false
                    win.makeKeyAndVisible()
                }
            }

            let utf8Bytes = errBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let msg = String(decoding: utf8Bytes, as: UTF8.self)
            onFailure(msg.isEmpty ? "Engine exited with code \(rc). Check Session Logs for details." : msg)
        }
    }

    private func installOverlay(gameName: String, logDir: URL, opacity: Double) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        let win = GameOverlayWindow(windowScene: scene, gameName: gameName, logDir: logDir, opacity: opacity)
        win.isHidden = false
        self.overlayWindow = win
    }

    private func removeOverlay() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
#endif
