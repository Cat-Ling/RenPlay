// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum ArchiveError: Error, LocalizedError, Sendable {
    case invalidZip
    case unsupportedCompression(UInt16)
    case unsafePath(String)
    case entryNotFound(String)
    case unsupportedArchiveFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidZip:
            return "Invalid or corrupted ZIP archive"
        case .unsupportedCompression(let method):
            return "Unsupported ZIP compression method: \(method)"
        case .unsafePath(let path):
            return "Rejected unsafe archive entry path: \(path)"
        case .entryNotFound(let name):
            return "Archive entry not found: \(name)"
        case .unsupportedArchiveFormat(let ext):
            return "Unsupported archive format: \(ext)"
        }
    }
}

public struct ZipEntryHeader: Sendable {
    public let name: String
    public let compressionMethod: UInt16
    public let compressedSize: UInt32
    public let uncompressedSize: UInt32
    public let localHeaderOffset: UInt32
    public let isDirectory: Bool
}

public enum ArchiveExtractor {
    public static func sanitizeRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            throw ArchiveError.unsafePath(rawPath)
        }
        var cleanParts: [String] = []
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                throw ArchiveError.unsafePath(rawPath)
            }
            cleanParts.append(String(part))
        }
        return cleanParts.joined(separator: "/")
    }

    public static func listZipEntries(at zipURL: URL) throws -> [ZipEntryHeader] {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        return try parseZipCentralDirectory(data)
    }

    public static func readZipEntry(named target: String, from zipURL: URL) throws -> Data {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let entries = try parseZipCentralDirectory(data)
        guard let entry = entries.first(where: { $0.name == target }) else {
            throw ArchiveError.entryNotFound(target)
        }
        return try extractZipEntryData(entry, from: data)
    }

    public static func extractZip(
        at zipURL: URL,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let entries = try parseZipCentralDirectory(data)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = max(entries.count, 1)
        for (idx, entry) in entries.enumerated() {
            let clean = try sanitizeRelativePath(entry.name)
            guard !clean.isEmpty else { continue }
            let targetURL = destination.appendingPathComponent(clean)

            if entry.isDirectory {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let payload = try extractZipEntryData(entry, from: data)
                try payload.write(to: targetURL, options: .atomic)
            }
            if idx % 20 == 0 || idx == entries.count - 1 {
                progress?(Double(idx + 1) / Double(total), clean)
            }
        }
    }

    // Extract a Ren'Py Android APK by keeping assets/x-game (or assets/game) and stripping "x-" prefixes.
    public static func extractRenPyAPK(
        at apkURL: URL,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let data = try Data(contentsOf: apkURL, options: .mappedIfSafe)
        let entries = try parseZipCentralDirectory(data)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let assetEntries = entries.filter {
            $0.name.hasPrefix("assets/") && !$0.isDirectory
        }
        let total = max(assetEntries.count, 1)
        for (idx, entry) in assetEntries.enumerated() {
            let clean = try sanitizeRelativePath(entry.name)
            guard clean.hasPrefix("assets/") else { continue }
            let rel = String(clean.dropFirst("assets/".count))
            // Strip Ren'Py APK's leading "x-" on path segments
            let unprefixedParts = rel.split(separator: "/").map { part -> String in
                let s = String(part)
                return s.hasPrefix("x-") ? String(s.dropFirst(2)) : s
            }
            let outRel = unprefixedParts.joined(separator: "/")
            guard !outRel.isEmpty else { continue }

            let targetURL = destination.appendingPathComponent(outRel)
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = try extractZipEntryData(entry, from: data)
            try payload.write(to: targetURL, options: .atomic)

            if idx % 20 == 0 || idx == assetEntries.count - 1 {
                progress?(Double(idx + 1) / Double(total), outRel)
            }
        }
    }

    public static func extractTar(
        data tarData: Data,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var offset = 0
        var paxPathOverride: String?
        let total = max(tarData.count, 1)

        while offset + 512 <= tarData.count {
            let header = tarData.subdata(in: offset..<(offset + 512))
            offset += 512

            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            let rawName = readTarString(header, offset: 0, length: 100)
            let prefix = readTarString(header, offset: 345, length: 155)
            let sizeStr = readTarString(header, offset: 124, length: 12)
            let typeFlag = header[156]
            let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 8) ?? 0

            let combined = prefix.isEmpty ? rawName : "\(prefix)/\(rawName)"
            let entryName = paxPathOverride ?? combined
            paxPathOverride = nil

            let paddedSize = ((size + 511) / 512) * 512
            guard offset + paddedSize <= tarData.count else { break }
            let payload = tarData.subdata(in: offset..<(offset + size))
            offset += paddedSize

            if typeFlag == UInt8(ascii: "L") { // GNU longname
                paxPathOverride = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\n"))
                continue
            }
            if typeFlag == UInt8(ascii: "x") || typeFlag == UInt8(ascii: "g") {
                continue
            }

            let clean = try sanitizeRelativePath(entryName)
            guard !clean.isEmpty else { continue }
            let targetURL = destination.appendingPathComponent(clean)

            if typeFlag == UInt8(ascii: "5") {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if typeFlag == 0 || typeFlag == UInt8(ascii: "0") {
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try payload.write(to: targetURL, options: .atomic)
            }
            progress?(Double(offset) / Double(total), clean)
        }
    }

    public static func extractArchive(
        at archiveURL: URL,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        let lower = archiveURL.lastPathComponent.lowercased()
        if lower.hasSuffix(".apk") {
            try extractRenPyAPK(at: archiveURL, to: destination, progress: progress)
        } else if lower.hasSuffix(".zip") {
            try extractZip(at: archiveURL, to: destination, progress: progress)
        } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            let gz = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            let tar = try ZlibCodec.gunzip(gz)
            try extractTar(data: tar, to: destination, progress: progress)
        } else if lower.hasSuffix(".tar") {
            let tar = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            try extractTar(data: tar, to: destination, progress: progress)
        } else {
            throw ArchiveError.unsupportedArchiveFormat(archiveURL.pathExtension)
        }
    }

    public static func createZip(fromFiles files: [(relativePath: String, data: Data)], to destination: URL) throws {
        var archive = Data()
        var centralDir = Data()

        for item in files {
            let nameData = Data(item.relativePath.utf8)
            let crc = ZlibCodec.crc32(item.data)
            let compressed = try ZlibCodec.deflate(item.data, rawDeflate: true)
            let useDeflate = compressed.count < item.data.count
            let body = useDeflate ? compressed : item.data
            let method: UInt16 = useDeflate ? 8 : 0
            let localOffset = UInt32(archive.count)

            // Local file header (30 bytes)
            archive.appendUInt32LE(0x04034B50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(method)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(UInt32(body.count))
            archive.appendUInt32LE(UInt32(item.data.count))
            archive.appendUInt16LE(UInt16(nameData.count))
            archive.appendUInt16LE(0)
            archive.append(nameData)
            archive.append(body)

            // Central directory header (46 bytes)
            centralDir.appendUInt32LE(0x02014B50)
            centralDir.appendUInt16LE(20)
            centralDir.appendUInt16LE(20)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(method)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt32LE(crc)
            centralDir.appendUInt32LE(UInt32(body.count))
            centralDir.appendUInt32LE(UInt32(item.data.count))
            centralDir.appendUInt16LE(UInt16(nameData.count))
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt16LE(0)
            centralDir.appendUInt32LE(0)
            centralDir.appendUInt32LE(localOffset)
            centralDir.append(nameData)
        }

        let cdOffset = UInt32(archive.count)
        let cdSize = UInt32(centralDir.count)
        archive.append(centralDir)

        // End of central directory (22 bytes)
        archive.appendUInt32LE(0x06054B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt32LE(cdSize)
        archive.appendUInt32LE(cdOffset)
        archive.appendUInt16LE(0)

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: destination, options: .atomic)
    }

    // Normalize extracted layout so the directory containing `game/` becomes root.
    public static func locateGameRoot(inside extractedDir: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: extractedDir.appendingPathComponent("game").path) {
            return extractedDir
        }

        // Handle macOS .app bundle: *.app/Contents/Resources/autorun/game
        if let enumerator = fm.enumerator(at: extractedDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            var candidates: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent == "game",
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    candidates.append(url.deletingLastPathComponent())
                }
            }
            if let best = candidates.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }).first {
                return best
            }
        }
        return extractedDir
    }

    private static func readTarString(_ header: Data, offset: Int, length: Int) -> String {
        let slice = header.subdata(in: offset..<(offset + length))
        let end = slice.firstIndex(of: 0) ?? slice.count
        return String(decoding: slice.prefix(end), as: UTF8.self)
    }

    private static func parseZipCentralDirectory(_ data: Data) throws -> [ZipEntryHeader] {
        guard data.count >= 22 else { throw ArchiveError.invalidZip }
        let searchStart = max(0, data.count - 65557)
        var eocdOffset: Int?
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            if i == 0 { break }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ArchiveError.invalidZip }

        let totalEntries = Int(data.readUInt16LE(at: eocd + 10))
        let cdOffset = Int(data.readUInt32LE(at: eocd + 16))
        guard cdOffset >= 0, cdOffset <= data.count else { throw ArchiveError.invalidZip }

        var cursor = cdOffset
        var result: [ZipEntryHeader] = []
        result.reserveCapacity(totalEntries)

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  data.readUInt32LE(at: cursor) == 0x02014B50 else {
                throw ArchiveError.invalidZip
            }
            let method = data.readUInt16LE(at: cursor + 10)
            let compSize = data.readUInt32LE(at: cursor + 20)
            let uncompSize = data.readUInt32LE(at: cursor + 24)
            let nameLen = Int(data.readUInt16LE(at: cursor + 28))
            let extraLen = Int(data.readUInt16LE(at: cursor + 30))
            let commentLen = Int(data.readUInt16LE(at: cursor + 32))
            let localOffset = data.readUInt32LE(at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLen + extraLen + commentLen <= data.count else {
                throw ArchiveError.invalidZip
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            result.append(
                ZipEntryHeader(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset,
                    isDirectory: name.hasSuffix("/")
                )
            )
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func extractZipEntryData(_ entry: ZipEntryHeader, from data: Data) throws -> Data {
        let local = Int(entry.localHeaderOffset)
        guard local + 30 <= data.count,
              data.readUInt32LE(at: local) == 0x04034B50 else {
            throw ArchiveError.invalidZip
        }
        let nameLen = Int(data.readUInt16LE(at: local + 26))
        let extraLen = Int(data.readUInt16LE(at: local + 28))
        let payloadStart = local + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadStart >= 0, payloadEnd <= data.count else {
            throw ArchiveError.invalidZip
        }
        let rawPayload = data.subdata(in: payloadStart..<payloadEnd)
        switch entry.compressionMethod {
        case 0:
            return rawPayload
        case 8:
            return try ZlibCodec.inflate(rawPayload, rawDeflate: true)
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }
}

extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
