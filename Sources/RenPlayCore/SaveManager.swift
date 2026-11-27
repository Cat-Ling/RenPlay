// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public final class SaveManager: Sendable {
    public init() {}

    private func normalizedSaveFilename(for url: URL) -> String? {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower == "persistent" {
            return "persistent"
        }
        if lower.hasSuffix(".save"), !lower.hasPrefix("_reload-") {
            return name.hasSuffix(".save") ? name : String(name.dropLast(5)) + ".save"
        }
        return nil
    }

    public func listSaves(in saveDir: URL) -> [SaveSlot] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var slots: [SaveSlot] = []
        for url in urls {
            guard normalizedSaveFilename(for: url) != nil else { continue }
            let name = url.lastPathComponent
            let lower = name.lowercased()

            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = attrs?.contentModificationDate ?? Date.distantPast
            let size = Int64(attrs?.fileSize ?? 0)

            let kind: SaveKind
            let label: String
            if lower == "persistent" {
                kind = .persistent
                label = "Persistent Data"
            } else if lower.hasPrefix("auto-") {
                kind = .auto
                label = "Auto " + name.dropFirst(5).replacingOccurrences(of: ".save", with: "")
            } else if lower.hasPrefix("quick-") {
                kind = .quick
                label = "Quick " + name.dropFirst(6).replacingOccurrences(of: ".save", with: "")
            } else {
                kind = .manual
                label = name.replacingOccurrences(of: ".save", with: "")
            }

            var extraInfo: String?
            var screenshot: Data?
            if lower.hasSuffix(".save") {
                if let entries = try? ArchiveExtractor.listZipEntries(at: url) {
                    if entries.contains(where: { $0.name == "screenshot.png" }) {
                        screenshot = try? ArchiveExtractor.readZipEntry(named: "screenshot.png", from: url)
                    }
                    if entries.contains(where: { $0.name == "extra_info" }) {
                        if let raw = try? ArchiveExtractor.readZipEntry(named: "extra_info", from: url) {
                            extraInfo = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } else if entries.contains(where: { $0.name == "json" }) {
                        if let raw = try? ArchiveExtractor.readZipEntry(named: "json", from: url),
                           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                           let saveName = obj["_save_name"] as? String, !saveName.isEmpty {
                            extraInfo = saveName
                        }
                    }
                }
            }

            slots.append(
                SaveSlot(
                    filename: name,
                    kind: kind,
                    slotLabel: label,
                    modifiedAt: modDate,
                    fileSize: size,
                    extraInfo: extraInfo,
                    screenshotData: screenshot
                )
            )
        }

        return slots.sorted { lhs, rhs in
            if lhs.kind == .persistent { return false }
            if rhs.kind == .persistent { return true }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    @discardableResult
    public func createBackup(of saveDir: URL, to backupDir: URL, maxBackups: Int) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: saveDir.path) else { return nil }
        let items = (try? fm.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let saveFiles = items.filter { normalizedSaveFilename(for: $0) != nil }
        guard !saveFiles.isEmpty else { return nil }

        var payload: [(String, Data)] = []
        for file in saveFiles {
            if let data = try? Data(contentsOf: file) {
                payload.append((file.lastPathComponent, data))
            }
        }
        guard !payload.isEmpty else { return nil }

        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = backupDir.appendingPathComponent("saves-\(fmt.string(from: Date())).zip")
        try ArchiveExtractor.createZip(fromFiles: payload, to: backupURL)

        if maxBackups > 0 {
            let existing = listBackups(in: backupDir)
            if existing.count > maxBackups {
                for stale in existing.dropFirst(maxBackups) {
                    try? fm.removeItem(at: stale.url)
                }
            }
        }
        return backupURL
    }

    public func listBackups(in backupDir: URL) -> [BackupEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "zip" }
            .compactMap { url in
                let vals = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                let date = vals?.contentModificationDate ?? vals?.creationDate ?? Date.distantPast
                let size = Int64(vals?.fileSize ?? 0)
                return BackupEntry(url: url, createdAt: date, fileSize: size)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func importSaves(from sourceURL: URL, into saveDir: URL, backupDir: URL?) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.lowercased()
        if let normalizedName = normalizedSaveFilename(for: sourceURL) {
            let dst = saveDir.appendingPathComponent(normalizedName)
            if fm.fileExists(atPath: dst.path) {
                if let backupDir {
                    _ = try? createBackup(of: saveDir, to: backupDir, maxBackups: 10)
                }
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: sourceURL, to: dst)
            return 1
        }

        if ArchiveExtractor.isSupportedArchive(sourceURL) {
            if let backupDir {
                _ = try? createBackup(of: saveDir, to: backupDir, maxBackups: 10)
            }
            let tempDir = fm.temporaryDirectory.appendingPathComponent("renplay-save-import-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempDir) }
            try ArchiveExtractor.extractArchive(at: sourceURL, to: tempDir)

            var imported = 0
            if let enumerator = fm.enumerator(at: tempDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    if let normalizedName = normalizedSaveFilename(for: url) {
                        let dst = saveDir.appendingPathComponent(normalizedName)
                        if fm.fileExists(atPath: dst.path) {
                            try fm.removeItem(at: dst)
                        }
                        try fm.copyItem(at: url, to: dst)
                        imported += 1
                    }
                }
            }
            return imported
        }

        throw ArchiveError.unsupportedArchiveFormat(ext)
    }

    public func exportSavesZip(from saveDir: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let payload: [(String, Data)] = items.compactMap { url in
            guard normalizedSaveFilename(for: url) != nil,
                  let data = try? Data(contentsOf: url) else { return nil }
            return (url.lastPathComponent, data)
        }
        try ArchiveExtractor.createZip(fromFiles: payload, to: zipURL)
    }
}

public enum DiagnosticScrubber {
    public static func scrub(
        _ text: String,
        containerRoot: String? = nil,
        bundlePath: String? = nil,
        smbSource: SMBGameSource? = nil
    ) -> String {
        var result = text
        if let bundlePath, !bundlePath.isEmpty {
            result = result.replacingOccurrences(of: bundlePath, with: "<AppBundle>")
        }
        if let containerRoot, !containerRoot.isEmpty {
            result = result.replacingOccurrences(of: containerRoot, with: "<AppContainer>")
        }
        let patternReplacements: [(String, String)] = [
            (#"(?:/private)?/var/mobile/Containers/(?:Data|Bundle)/Application/[0-9A-Fa-f-]{36}"#, "<AppContainer>"),
            (#"/Users/[^/\s"'<>]+"#, "/Users/<User>"),
            (#"/home/[^/\s"'<>]+"#, "/home/<User>"),
            (#"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@"#, "$1<User>@"),
            (#"smb://[^/\s"']+/[^/\s"']+"#, "smb://<SMBHost>/<SMBShare>"),
        ]
        for (pattern, replacement) in patternReplacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if let smbSource {
            if !smbSource.host.isEmpty {
                result = result.replacingOccurrences(of: smbSource.host, with: "<SMBHost>")
            }
            if !smbSource.share.isEmpty {
                result = result.replacingOccurrences(of: smbSource.share, with: "<SMBShare>")
            }
            if !smbSource.username.isEmpty {
                result = result.replacingOccurrences(of: smbSource.username, with: "<SMBUser>")
            }
            if !smbSource.domain.isEmpty {
                result = result.replacingOccurrences(of: smbSource.domain, with: "<SMBDomain>")
            }
        }
        return result
    }
}
