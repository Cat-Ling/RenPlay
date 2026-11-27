// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CZlib
import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable, Sendable {
    case invalidZip
    case unsupportedCompression(UInt16)
    case unsafePath(String)
    case entryNotFound(String)
    case unsupportedArchiveFormat(String)
    case encryptedArchive
    case extractionFailed(String)

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
        case .encryptedArchive:
            return "Password-protected archives are not supported"
        case .extractionFailed(let detail):
            return "Archive extraction failed: \(detail)"
        }
    }
}

public struct ZipEntryHeader: Sendable {
    public let name: String
    public let compressionMethod: UInt16
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
    public let isDirectory: Bool
    public let isEncrypted: Bool
}

private final class ArchiveCallbackContext {
    let apkMode: Bool
    let progress: (@Sendable (Double, String) -> Void)?
    var unsafePath: String?

    init(apkMode: Bool, progress: (@Sendable (Double, String) -> Void)?) {
        self.apkMode = apkMode
        self.progress = progress
    }
}

private func cArchiveTransformCallback(
    rawPathPtr: UnsafePointer<CChar>?,
    isDir: Int32,
    outRelPtr: UnsafeMutablePointer<CChar>?,
    outCap: Int,
    ctxPtr: UnsafeMutableRawPointer?
) -> Int32 {
    guard let rawPathPtr, let outRelPtr, outCap > 1, let ctxPtr else {
        return -2
    }
    let ctx = Unmanaged<ArchiveCallbackContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let raw = String(cString: rawPathPtr)

    var normalized = raw.replacingOccurrences(of: "\\", with: "/")
    while normalized.hasPrefix("./") {
        normalized.removeFirst(2)
    }
    if normalized == "." || normalized.isEmpty {
        return 1
    }

    let clean: String
    do {
        clean = try ArchiveExtractor.sanitizeRelativePath(normalized)
    } catch {
        ctx.unsafePath = raw
        return -1
    }
    guard !clean.isEmpty else {
        return 1
    }

    let finalRel: String
    if ctx.apkMode {
        if isDir != 0 {
            return 1
        }
        guard clean.hasPrefix("assets/") else {
            return 1
        }
        let rel = String(clean.dropFirst("assets/".count))
        let unprefixedParts = rel.split(separator: "/", omittingEmptySubsequences: true).map { part -> String in
            let s = String(part)
            return s.hasPrefix("x-") ? String(s.dropFirst(2)) : s
        }
        finalRel = unprefixedParts.joined(separator: "/")
        guard !finalRel.isEmpty else {
            return 1
        }
    } else {
        finalRel = clean
    }

    let utf8 = Array(finalRel.utf8)
    guard utf8.count < outCap else {
        return -2
    }
    utf8.withUnsafeBufferPointer { buf in
        if let base = buf.baseAddress {
            outRelPtr.withMemoryRebound(to: UInt8.self, capacity: outCap) { dst in
                dst.initialize(from: base, count: utf8.count)
                dst[utf8.count] = 0
            }
        }
    }
    outRelPtr[utf8.count] = 0
    return 0
}

private func cArchiveProgressCallback(
    fraction: Double,
    relPathPtr: UnsafePointer<CChar>?,
    ctxPtr: UnsafeMutableRawPointer?
) {
    guard let ctxPtr else { return }
    let ctx = Unmanaged<ArchiveCallbackContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let path = relPathPtr.map { String(cString: $0) } ?? ""
    ctx.progress?(fraction, path)
}

public enum ArchiveExtractor {
    public static let supportedArchiveExtensions: Set<String> = [
        "zip", "apk", "7z", "rar",
        "tar", "tgz", "gz", "tbz", "tbz2", "bz2",
        "txz", "xz", "tzst", "zst", "tlz", "lzma", "lz4",
        "cab", "iso", "lha", "lzh", "xar",
    ]

    public static let compoundArchiveExtensions: [String] = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.lz4",
    ]

    public static func isSupportedArchive(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        if compoundArchiveExtensions.contains(where: { lower.hasSuffix($0) }) {
            return true
        }
        return supportedArchiveExtensions.contains(url.pathExtension.lowercased())
    }

    public static func stripArchiveExtension(from filename: String) -> String {
        let lower = filename.lowercased()
        for suffix in compoundArchiveExtensions where lower.hasSuffix(suffix) {
            let endIdx = filename.index(filename.endIndex, offsetBy: -suffix.count)
            return String(filename[..<endIdx])
        }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty && supportedArchiveExtensions.contains(ext.lowercased()) {
            return (filename as NSString).deletingPathExtension
        }
        return (filename as NSString).deletingPathExtension
    }

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
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        return try parseZipCentralDirectory(from: handle)
    }

    public static func readZipEntry(named target: String, from zipURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        let entries = try parseZipCentralDirectory(from: handle)
        guard let entry = entries.first(where: { $0.name == target }) else {
            throw ArchiveError.entryNotFound(target)
        }
        return try extractZipEntryData(entry, from: handle)
    }

    public static func extractZip(
        at zipURL: URL,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        do {
            try streamExtractWithLibarchive(at: zipURL, to: destination, apkMode: false, progress: progress)
        } catch let err as ArchiveError {
            switch err {
            case .unsafePath, .encryptedArchive:
                throw err
            default:
                if hasPKZipSignature(at: zipURL) {
                    try extractZipStreamingFallback(at: zipURL, to: destination, apkMode: false, progress: progress)
                } else {
                    throw err
                }
            }
        }
    }

    // Extract a Ren'Py Android APK by keeping assets/x-game (or assets/game) and stripping "x-" prefixes.
    public static func extractRenPyAPK(
        at apkURL: URL,
        to destination: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws {
        do {
            try streamExtractWithLibarchive(at: apkURL, to: destination, apkMode: true, progress: progress)
        } catch let err as ArchiveError {
            switch err {
            case .unsafePath, .encryptedArchive:
                throw err
            default:
                if hasPKZipSignature(at: apkURL) {
                    try extractZipStreamingFallback(at: apkURL, to: destination, apkMode: true, progress: progress)
                } else {
                    throw err
                }
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

            if typeFlag == UInt8(ascii: "L") {
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
        guard isSupportedArchive(archiveURL) else {
            throw ArchiveError.unsupportedArchiveFormat(archiveURL.pathExtension)
        }
        let lower = archiveURL.lastPathComponent.lowercased()
        if lower.hasSuffix(".apk") {
            try extractRenPyAPK(at: archiveURL, to: destination, progress: progress)
            return
        }
        if lower.hasSuffix(".zip") {
            try extractZip(at: archiveURL, to: destination, progress: progress)
            return
        }
        try streamExtractWithLibarchive(at: archiveURL, to: destination, apkMode: false, progress: progress)
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

        // Normalize APK layout if an APK was renamed to .zip before extraction.
        let assetsDir = extractedDir.appendingPathComponent("assets", isDirectory: true)
        let xGameDir = assetsDir.appendingPathComponent("x-game", isDirectory: true)
        if fm.fileExists(atPath: xGameDir.path),
           let children = try? fm.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil) {
            for child in children {
                stripXPrefixesRecursively(at: child)
                let name = child.lastPathComponent
                let cleanName = name.hasPrefix("x-") ? String(name.dropFirst(2)) : name
                let target = assetsDir.appendingPathComponent(cleanName)
                if cleanName != name && !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: child, to: target)
                }
            }
            if fm.fileExists(atPath: assetsDir.appendingPathComponent("game").path) {
                return assetsDir
            }
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

    private static func stripXPrefixesRecursively(at url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for child in children {
            stripXPrefixesRecursively(at: child)
            let name = child.lastPathComponent
            if name.hasPrefix("x-") {
                let target = url.appendingPathComponent(String(name.dropFirst(2)))
                if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: child, to: target)
                }
            }
        }
    }

    private static func streamExtractWithLibarchive(
        at archiveURL: URL,
        to destination: URL,
        apkMode: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        let cbCtx = ArchiveCallbackContext(apkMode: apkMode, progress: progress)
        let unmanaged = Unmanaged.passRetained(cbCtx)
        defer { unmanaged.release() }

        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = czlib_extract_archive(
            archiveURL.path,
            destination.path,
            cArchiveTransformCallback,
            cArchiveProgressCallback,
            unmanaged.toOpaque(),
            &errBuf,
            errBuf.count
        )

        if rc == CZLIB_ARCHIVE_OK {
            return
        }

        let msgBytes = errBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let msg = String(decoding: msgBytes, as: UTF8.self)
        if rc == CZLIB_ARCHIVE_ERR_UNSAFE_PATH {
            throw ArchiveError.unsafePath(cbCtx.unsafePath ?? msg)
        }
        if rc == CZLIB_ARCHIVE_ERR_ENCRYPTED {
            throw ArchiveError.encryptedArchive
        }
        if hasPKZipSignature(at: archiveURL) && rc == CZLIB_ARCHIVE_ERR_FORMAT {
            throw ArchiveError.invalidZip
        }
        throw ArchiveError.extractionFailed(msg.isEmpty ? "status \(rc)" : msg)
    }

    private static func hasPKZipSignature(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 4) else {
            try? FileHandle(forReadingFrom: url).close()
            return false
        }
        try? handle.close()
        guard header.count >= 4 else { return false }
        return header[0] == 0x50 && header[1] == 0x4B && (
            (header[2] == 0x03 && header[3] == 0x04) ||
            (header[2] == 0x05 && header[3] == 0x06)
        )
    }

    private static func extractZipStreamingFallback(
        at zipURL: URL,
        to destination: URL,
        apkMode: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws {
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        let entries = try parseZipCentralDirectory(from: handle)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = max(entries.count, 1)
        for (idx, entry) in entries.enumerated() {
            if entry.isEncrypted {
                throw ArchiveError.encryptedArchive
            }
            var raw = entry.name.replacingOccurrences(of: "\\", with: "/")
            while raw.hasPrefix("./") {
                raw.removeFirst(2)
            }
            let clean = try sanitizeRelativePath(raw)
            guard !clean.isEmpty else { continue }

            let outRel: String
            if apkMode {
                if entry.isDirectory { continue }
                guard clean.hasPrefix("assets/") else { continue }
                let rel = String(clean.dropFirst("assets/".count))
                let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map { part -> String in
                    let s = String(part)
                    return s.hasPrefix("x-") ? String(s.dropFirst(2)) : s
                }
                outRel = parts.joined(separator: "/")
                guard !outRel.isEmpty else { continue }
            } else {
                outRel = clean
            }

            let targetURL = destination.appendingPathComponent(outRel)
            if entry.isDirectory {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try streamZipEntryToFile(entry, from: handle, sourceURL: zipURL, to: targetURL)
            }

            if idx % 20 == 0 || idx == entries.count - 1 {
                progress?(Double(idx + 1) / Double(total), outRel)
            }
        }
    }

    private static func streamZipEntryToFile(
        _ entry: ZipEntryHeader,
        from handle: FileHandle,
        sourceURL: URL,
        to targetURL: URL
    ) throws {
        let payloadOffset = try resolveZipPayloadOffset(entry, from: handle)
        let fm = FileManager.default

        switch entry.compressionMethod {
        case 0:
            _ = fm.createFile(atPath: targetURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: targetURL)
            defer { try? out.close() }
            try handle.seek(toOffset: payloadOffset)
            var remaining = entry.compressedSize
            while remaining > 0 {
                let want = Int(min(remaining, 65_536))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    throw ArchiveError.invalidZip
                }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        case 8:
            let rc = czlib_inflate_stream_slice(sourceURL.path, payloadOffset, entry.compressedSize, 1, targetURL.path)
            if rc != 0 {
                throw ArchiveError.extractionFailed("Deflate stream error (\(rc)) on \(entry.name)")
            }
        case 93:
            let rc = czlib_zstd_stream_slice(sourceURL.path, payloadOffset, entry.compressedSize, targetURL.path)
            if rc != 0 {
                throw ArchiveError.extractionFailed("Zstandard stream error (\(rc)) on \(entry.name)")
            }
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private static func resolveZipPayloadOffset(_ entry: ZipEntryHeader, from handle: FileHandle) throws -> UInt64 {
        let fileSize = try handle.seekToEnd()
        guard entry.localHeaderOffset + 30 <= fileSize else {
            throw ArchiveError.invalidZip
        }
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let localHdr = try handle.read(upToCount: 30),
              localHdr.count == 30,
              localHdr.readUInt32LE(at: 0) == 0x04034B50 else {
            throw ArchiveError.invalidZip
        }
        let nameLen = UInt64(localHdr.readUInt16LE(at: 26))
        let extraLen = UInt64(localHdr.readUInt16LE(at: 28))
        let payloadStart = entry.localHeaderOffset + 30 + nameLen + extraLen
        guard payloadStart <= fileSize, entry.compressedSize <= fileSize - payloadStart else {
            throw ArchiveError.invalidZip
        }
        return payloadStart
    }

    private static func readTarString(_ header: Data, offset: Int, length: Int) -> String {
        let slice = header.subdata(in: offset..<(offset + length))
        let end = slice.firstIndex(of: 0) ?? slice.count
        return String(decoding: slice.prefix(end), as: UTF8.self)
    }

    private static func parseZipCentralDirectory(from handle: FileHandle) throws -> [ZipEntryHeader] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.invalidZip }

        let tailSize = min(fileSize, 65_557 + 20)
        let tailBase = fileSize - tailSize
        try handle.seek(toOffset: tailBase)
        guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22 else {
            throw ArchiveError.invalidZip
        }

        var eocdLocalIdx: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 {
                eocdLocalIdx = i
                break
            }
            if i == 0 { break }
            i -= 1
        }
        guard let eocdIdx = eocdLocalIdx else { throw ArchiveError.invalidZip }

        var totalEntries = UInt64(tail.readUInt16LE(at: eocdIdx + 10))
        var cdSize = UInt64(tail.readUInt32LE(at: eocdIdx + 12))
        var cdOffset = UInt64(tail.readUInt32LE(at: eocdIdx + 16))

        // Check for ZIP64 EOCD Locator immediately preceding EOCD.
        if eocdIdx >= 20, tail.readUInt32LE(at: eocdIdx - 20) == 0x07064B50 {
            let zip64EOCDOffset = tail.readUInt64LE(at: eocdIdx - 20 + 8)
            if zip64EOCDOffset + 56 <= fileSize {
                try handle.seek(toOffset: zip64EOCDOffset)
                if let z64 = try handle.read(upToCount: 56),
                   z64.count == 56,
                   z64.readUInt32LE(at: 0) == 0x06064B50 {
                    totalEntries = z64.readUInt64LE(at: 32)
                    cdSize = z64.readUInt64LE(at: 40)
                    cdOffset = z64.readUInt64LE(at: 48)
                }
            }
        }

        guard cdOffset <= fileSize, cdSize <= fileSize - cdOffset else {
            throw ArchiveError.invalidZip
        }

        try handle.seek(toOffset: cdOffset)
        guard let cd = try handle.read(upToCount: Int(cdSize)), UInt64(cd.count) == cdSize else {
            throw ArchiveError.invalidZip
        }

        var cursor = 0
        var result: [ZipEntryHeader] = []
        if totalEntries < 1_000_000 {
            result.reserveCapacity(Int(totalEntries))
        }

        for _ in 0..<totalEntries {
            guard cursor + 46 <= cd.count,
                  cd.readUInt32LE(at: cursor) == 0x02014B50 else {
                throw ArchiveError.invalidZip
            }
            let flags = cd.readUInt16LE(at: cursor + 8)
            let method = cd.readUInt16LE(at: cursor + 10)
            let compSize32 = cd.readUInt32LE(at: cursor + 20)
            let uncompSize32 = cd.readUInt32LE(at: cursor + 24)
            let nameLen = Int(cd.readUInt16LE(at: cursor + 28))
            let extraLen = Int(cd.readUInt16LE(at: cursor + 30))
            let commentLen = Int(cd.readUInt16LE(at: cursor + 32))
            let localOffset32 = cd.readUInt32LE(at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else {
                throw ArchiveError.invalidZip
            }

            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)

            var compSize = UInt64(compSize32)
            var uncompSize = UInt64(uncompSize32)
            var localOffset = UInt64(localOffset32)

            if compSize32 == UInt32.max || uncompSize32 == UInt32.max || localOffset32 == UInt32.max {
                let extraStart = nameStart + nameLen
                let extraEnd = extraStart + extraLen
                var ec = extraStart
                while ec + 4 <= extraEnd {
                    let tag = cd.readUInt16LE(at: ec)
                    let blockLen = Int(cd.readUInt16LE(at: ec + 2))
                    let dataStart = ec + 4
                    guard dataStart + blockLen <= extraEnd else { break }
                    if tag == 0x0001 {
                        var zc = dataStart
                        if uncompSize32 == UInt32.max, zc + 8 <= dataStart + blockLen {
                            uncompSize = cd.readUInt64LE(at: zc)
                            zc += 8
                        }
                        if compSize32 == UInt32.max, zc + 8 <= dataStart + blockLen {
                            compSize = cd.readUInt64LE(at: zc)
                            zc += 8
                        }
                        if localOffset32 == UInt32.max, zc + 8 <= dataStart + blockLen {
                            localOffset = cd.readUInt64LE(at: zc)
                        }
                        break
                    }
                    ec = dataStart + blockLen
                }
            }

            result.append(
                ZipEntryHeader(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset,
                    isDirectory: name.hasSuffix("/"),
                    isEncrypted: (flags & 0x0001) != 0
                )
            )
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func extractZipEntryData(_ entry: ZipEntryHeader, from handle: FileHandle) throws -> Data {
        if entry.isEncrypted {
            throw ArchiveError.encryptedArchive
        }
        let payloadStart = try resolveZipPayloadOffset(entry, from: handle)
        try handle.seek(toOffset: payloadStart)
        guard let rawPayload = try handle.read(upToCount: Int(entry.compressedSize)),
              UInt64(rawPayload.count) == entry.compressedSize else {
            throw ArchiveError.invalidZip
        }
        switch entry.compressionMethod {
        case 0:
            return rawPayload
        case 8:
            return try ZlibCodec.inflate(rawPayload, rawDeflate: true)
        case 93:
            return try ZlibCodec.zstdDecompress(rawPayload)
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

    mutating func appendUInt64LE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
