// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Foundation
import RenPlayCore
import SwiftUI
import UIKit

enum AIHelp {
    static let fileName = "Give-to-AI-with-logs.txt"

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "Give-to-AI-with-logs", withExtension: "txt")
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
    static func stagedFiles(appState: AppState, game: GameEntry?) -> [URL] {
        install(documentsDir: appState.documentsDir)
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("RenPlayAIHelp", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var output: [URL] = []
        let docsGuide = appState.documentsDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: docsGuide.path) {
            output.append(docsGuide)
        } else if let bundled = bundledURL {
            output.append(bundled)
        }

        let targetGame = game ?? appState.games
            .filter { $0.lastPlayedAt != nil }
            .max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) })
            ?? appState.games.first

        let settingsURL = stagingDir.appendingPathComponent(
            targetGame.map { "\(safeFilename($0.displayName))-settings.txt" } ?? "renplay-settings.txt"
        )
        let summaryText = buildSettingsSummary(appState: appState, game: targetGame)
        if (try? summaryText.write(to: settingsURL, atomically: true, encoding: .utf8)) != nil {
            output.append(settingsURL)
        }

        guard let targetGame else { return output }

        let containerRoot = appState.documentsDir.deletingLastPathComponent().path
        let bundlePath = Bundle.main.bundleURL.path
        let searchDirs = [
            appState.libraryStore.logDirectory(for: targetGame),
            appState.libraryStore.gameDirectory(for: targetGame),
        ]
        var addedLogs = Set<String>()
        for dir in searchDirs {
            for name in ["renplay_session.log", "traceback.txt", "log.txt"] where !addedLogs.contains(name) {
                let src = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path),
                      let raw = try? String(contentsOf: src, encoding: .utf8) else { continue }
                let trimmed = raw.count > 256_000 ? String(raw.suffix(256_000)) : raw
                let scrubbed = DiagnosticScrubber.scrub(
                    trimmed,
                    containerRoot: containerRoot,
                    bundlePath: bundlePath,
                    smbSource: targetGame.remoteSource
                )
                let dst = stagingDir.appendingPathComponent(name)
                if (try? scrubbed.write(to: dst, atomically: true, encoding: .utf8)) != nil {
                    output.append(dst)
                    addedLogs.insert(name)
                }
            }
        }
        return output
    }

    @MainActor
    private static func buildSettingsSummary(appState: AppState, game: GameEntry?) -> String {
        var lines = [
            "# RenPlay Diagnostics Summary (privacy-scrubbed)",
            "# Bundle ID: \(Bundle.main.bundleIdentifier ?? "RenPlay")",
            "# App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "# Bundled Engines: \(appState.engines.map { "\($0.version) (\($0.sdlVersion)/Py\($0.pythonVersion))" }.joined(separator: ", "))",
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

private struct AIHelpActivityItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct AIHelpActivitySheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AIHelpButton: View {
    let appState: AppState
    let game: GameEntry?
    var label = "Share Diagnostics for AI"
    var systemImage = "questionmark.bubble"
    @State private var staged: AIHelpActivityItem?

    var body: some View {
        Button(label, systemImage: systemImage) {
            let urls = AIHelp.stagedFiles(appState: appState, game: game)
            if !urls.isEmpty {
                staged = AIHelpActivityItem(urls: urls)
            }
        }
        .sheet(item: $staged) { item in
            AIHelpActivitySheet(items: item.urls)
        }
    }
}
#endif
