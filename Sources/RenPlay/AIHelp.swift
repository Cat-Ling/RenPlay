// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Foundation
import RenPlayCore
import SwiftUI
import UIKit

@MainActor
enum SharePresenter {
    private static var retainedFolder: URL?

    static func present(urls: [URL], retainFolder: URL? = nil, delay: TimeInterval = 0.15) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }
        retainedFolder = retainFolder
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            presentNow(urls: validURLs)
        }
    }

    private static func presentNow(urls: [URL]) {
        guard let topVC = topViewController() else { return }
        let activityVC = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = topVC.view
            pop.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 1,
                height: 1
            )
            pop.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let candidateWindows = activeScene?.windows.filter {
            !$0.isHidden && $0.rootViewController != nil && !($0 is GameOverlayWindow)
        } ?? []
        let window = candidateWindows.first(where: { $0.isKeyWindow }) ?? candidateWindows.first
        guard var current = window?.rootViewController else { return nil }
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
}

enum AIHelp {
    static let fileName = "Give-to-AI-with-logs.txt"

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "Give-to-AI-with-logs", withExtension: "txt")
            ?? {
                let direct = Bundle.main.bundleURL.appendingPathComponent(fileName)
                return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
            }()
    }

    static func install(documentsDir: URL) {
        DispatchQueue.global(qos: .utility).async {
            guard let source = bundledURL,
                  let data = try? Data(contentsOf: source) else { return }
            let target = documentsDir.appendingPathComponent(fileName)
            if (try? Data(contentsOf: target)) == data { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    @MainActor
    static func share(appState: AppState, game: GameEntry?, delay: TimeInterval = 0.15) {
        do {
            let result = try stagedFiles(appState: appState, game: game)
            guard !result.urls.isEmpty else {
                appState.showError("No diagnostic files could be prepared for sharing.", title: "Share Unavailable")
                return
            }
            SharePresenter.present(urls: result.urls, retainFolder: result.folder, delay: delay)
        } catch {
            appState.showError(error.localizedDescription, title: "Share Diagnostics Failed")
        }
    }

    @MainActor
    static func stagedFiles(appState: AppState, game: GameEntry?) throws -> (folder: URL, urls: [URL]) {
        install(documentsDir: appState.documentsDir)
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("RenPlayDiagnostics", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var output: [URL] = []
        let guideDst = stagingDir.appendingPathComponent(fileName)
        let docsGuide = appState.documentsDir.appendingPathComponent(fileName)
        if let src = bundledURL ?? (fm.fileExists(atPath: docsGuide.path) ? docsGuide : nil),
           let data = try? Data(contentsOf: src) {
            try data.write(to: guideDst, options: .atomic)
            output.append(guideDst)
        }

        let targetGame = game ?? appState.games
            .filter { $0.lastPlayedAt != nil }
            .max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) })
            ?? appState.games.first

        var includedLogs: [String] = []
        if let targetGame {
            let containerRoot = appState.documentsDir.deletingLastPathComponent().path
            let bundlePath = Bundle.main.bundleURL.path
            let searchDirs = [
                appState.libraryStore.logDirectory(for: targetGame),
                appState.libraryStore.gameDirectory(for: targetGame),
            ]
            let candidates: [(source: String, dest: String)] = [
                ("renplay_session.log", "renplay_session.log.txt"),
                ("traceback.txt", "traceback.txt"),
                ("log.txt", "log.txt"),
            ]
            var seenSources = Set<String>()
            for dir in searchDirs {
                for candidate in candidates where !seenSources.contains(candidate.source) {
                    let src = dir.appendingPathComponent(candidate.source)
                    guard fm.fileExists(atPath: src.path),
                          let raw = try? String(contentsOf: src, encoding: .utf8) else { continue }
                    let trimmed = raw.count > 256_000 ? String(raw.suffix(256_000)) : raw
                    let scrubbed = DiagnosticScrubber.scrub(
                        trimmed,
                        containerRoot: containerRoot,
                        bundlePath: bundlePath,
                        smbSource: targetGame.remoteSource
                    )
                    let dst = stagingDir.appendingPathComponent(candidate.dest)
                    try scrubbed.write(to: dst, atomically: true, encoding: .utf8)
                    output.append(dst)
                    seenSources.insert(candidate.source)
                    includedLogs.append(candidate.dest)
                }
            }
        }

        let settingsURL = stagingDir.appendingPathComponent(
            targetGame.map { "\(safeFilename($0.displayName))-settings.txt" } ?? "renplay-settings.txt"
        )
        let summaryText = buildSettingsSummary(appState: appState, game: targetGame, includedLogs: includedLogs)
        try summaryText.write(to: settingsURL, atomically: true, encoding: .utf8)
        output.insert(settingsURL, at: min(1, output.count))

        return (stagingDir, output)
    }

    @MainActor
    private static func buildSettingsSummary(
        appState: AppState,
        game: GameEntry?,
        includedLogs: [String]
    ) -> String {
        var lines = [
            "# RenPlay Diagnostics Summary (privacy-scrubbed)",
            "# Bundle ID: \(Bundle.main.bundleIdentifier ?? "RenPlay")",
            "# App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "# Bundled Engines: \(appState.engines.map { "\($0.version) (\($0.sdlVersion)/Py\($0.pythonVersion))" }.joined(separator: ", "))",
            "# Logs Included: \(includedLogs.isEmpty ? "none recorded yet" : includedLogs.joined(separator: ", "))",
            "",
        ]

        if let game {
            let resolved = appState.resolvedEngine(for: game)
            let saveCount = appState.saveManager.listSaves(in: appState.libraryStore.saveDirectory(for: game))
                .filter { $0.renpySlotName != nil }
                .count
            lines.append("## Game")
            lines.append("Title: \(game.displayName)")
            lines.append("Game Version: \(game.gameVersion ?? "unknown")")
            lines.append("Detected Ren'Py Version: \(game.detectedEngineVersion ?? "unknown")")
            lines.append("Resolved Engine: \(resolved.map { "\($0.version) (\($0.sdlVersion), Python \($0.pythonVersion))" } ?? "none")")
            lines.append("Storage Mode: \(game.remoteSource != nil ? "network-share" : "local")")
            lines.append("Save Slots: \(saveCount)")
            lines.append("Safe Mode: \(game.settings.safeMode)")
            lines.append("Engine Mode: \(describeEngineMode(game.settings.engineMode))")
            lines.append("Screen Rotation: \(game.settings.screenRotation.rawValue)")
            lines.append("Use Global Settings: \(game.settings.useGlobalSettings)")
            if let encoded = try? JSONEncoder.prettySorted.encode(game.settings),
               let json = String(data: encoded, encoding: .utf8) {
                lines.append("")
                lines.append("## Effective GameSettings JSON")
                lines.append(json)
            }
            lines.append("")
        }

        if let encodedApp = try? JSONEncoder.prettySorted.encode(appState.appSettings),
           let appJSON = String(data: encodedApp, encoding: .utf8) {
            lines.append("## Global AppSettings JSON")
            lines.append(appJSON)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describeEngineMode(_ mode: EngineMode) -> String {
        switch mode {
        case .auto: return "auto"
        case .pinned(let id): return "pinned(\(id))"
        }
    }

    private static func safeFilename(_ raw: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = raw.unicodeScalars.map { disallowed.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(48))
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}

struct AIHelpButton: View {
    let appState: AppState
    let game: GameEntry?
    var label = "Share Diagnostics for AI"
    var systemImage = "questionmark.bubble"
    var delay: TimeInterval = 0.15

    var body: some View {
        Button(label, systemImage: systemImage) {
            AIHelp.share(appState: appState, game: game, delay: delay)
        }
    }
}
#endif
