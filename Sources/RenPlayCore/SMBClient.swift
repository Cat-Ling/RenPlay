// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CSMB2
import Foundation
#if canImport(Security)
import Security
#endif

public enum SMBError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case connectionFailed(String)
    case operationFailed(String)
    case remoteNotRenPyGame
    case pathTraversal(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg):
            return "Invalid SMB configuration: \(msg)"
        case .connectionFailed(let msg):
            return "SMB connection failed: \(msg)"
        case .operationFailed(let msg):
            return msg
        case .remoteNotRenPyGame:
            return "The selected remote folder does not appear to contain a Ren'Py game."
        case .pathTraversal(let path):
            return "Blocked unsafe SMB path: \(path)"
        }
    }
}

public struct SMBShareInfo: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let remark: String
    public let isHidden: Bool

    public init(name: String, remark: String, isHidden: Bool) {
        self.name = name
        self.remark = remark
        self.isHidden = isHidden
    }
}

public struct SMBRemoteItem: Identifiable, Sendable, Hashable {
    public var id: String { relativePath }
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modifiedAt: Date?

    public init(
        name: String,
        relativePath: String,
        isDirectory: Bool,
        size: UInt64,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SMBIndexEntry: Sendable, Equatable, Hashable {
    public enum Backing: Sendable, Equatable, Hashable {
        case loose(smbRelPath: String, size: UInt64)
        case rpa(rpaRelPath: String, segments: [RPAIndexEntry])
    }

    public let logicalPath: String
    public let backing: Backing

    public init(logicalPath: String, backing: Backing) {
        self.logicalPath = logicalPath
        self.backing = backing
    }

    public var totalSize: UInt64 {
        switch backing {
        case .loose(_, let size):
            return size
        case .rpa(_, let segments):
            return segments.reduce(0) { $0 + $1.length }
        }
    }
}

public struct SMBIndexManifest: Sendable, Equatable {
    public static let manifestFileName = ".renplay_smb_index.tsv"
    private static let headerLine = "# RENPLAY_SMB_INDEX_V1"

    public var entries: [SMBIndexEntry]

    public init(entries: [SMBIndexEntry] = []) {
        self.entries = entries
    }

    public func serialize() -> String {
        var lines: [String] = [Self.headerLine]
        lines.reserveCapacity(entries.count + 1)
        for entry in entries {
            let logical = sanitizeField(entry.logicalPath)
            switch entry.backing {
            case .loose(let smbRelPath, let size):
                lines.append("L\t\(logical)\t\(sanitizeField(smbRelPath))\t\(size)")
            case .rpa(let rpaRelPath, let segments):
                let segSpec = segments.map { seg -> String in
                    let bodyLen = seg.length > UInt64(seg.prefix.count) ? seg.length - UInt64(seg.prefix.count) : 0
                    let hexPrefix = seg.prefix.map { String(format: "%02x", $0) }.joined()
                    return "\(seg.offset):\(bodyLen):\(hexPrefix)"
                }.joined(separator: ";")
                lines.append("R\t\(logical)\t\(sanitizeField(rpaRelPath))\t\(segSpec)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ content: String) -> SMBIndexManifest {
        var parsed: [SMBIndexEntry] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            let kind = cols[0]
            let logical = cols[1]
            let smbPath = cols[2]
            if kind == "L", let size = UInt64(cols[3]) {
                parsed.append(SMBIndexEntry(logicalPath: logical, backing: .loose(smbRelPath: smbPath, size: size)))
            } else if kind == "R" {
                var segments: [RPAIndexEntry] = []
                for part in cols[3].split(separator: ";", omittingEmptySubsequences: true) {
                    let fields = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 2,
                          let offset = UInt64(fields[0]),
                          let bodyLen = UInt64(fields[1]) else {
                        continue
                    }
                    let prefixData = fields.count >= 3 ? decodeHex(fields[2]) : Data()
                    let totalLen = UInt64(prefixData.count) + bodyLen
                    segments.append(RPAIndexEntry(offset: offset, length: totalLen, prefix: prefixData))
                }
                if !segments.isEmpty {
                    parsed.append(SMBIndexEntry(logicalPath: logical, backing: .rpa(rpaRelPath: smbPath, segments: segments)))
                }
            }
        }
        return SMBIndexManifest(entries: parsed)
    }

    private func sanitizeField(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func decodeHex(_ hex: String) -> Data {
        guard hex.count % 2 == 0, !hex.isEmpty else { return Data() }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data
    }
}

// Stores SMB server passwords in iOS Keychain when available and falls back to a protected local file
// so sideloaded installs without keychain-access-groups retain credentials reliably.
public final class SMBCredentialStore: @unchecked Sendable {
    private let fallbackFileURL: URL
    private let lock = NSLock()
    private static let serviceName = "com.renplay.app.smb"

    public init(storageDir: URL) {
        self.fallbackFileURL = storageDir.appendingPathComponent("smb_credentials.json")
    }

    public func setPassword(_ password: String, forServerID id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security)
        let account = id.uuidString
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        if !password.isEmpty {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.serviceName,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(password.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        #endif

        var map = loadFallbackMap()
        if password.isEmpty {
            map.removeValue(forKey: id.uuidString)
        } else {
            map[id.uuidString] = password
        }
        saveFallbackMap(map)
    }

    public func password(forServerID id: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        #endif

        let map = loadFallbackMap()
        return map[id.uuidString] ?? ""
    }

    public func deletePassword(forServerID id: UUID) {
        setPassword("", forServerID: id)
    }

    private func loadFallbackMap() -> [String: String] {
        guard let data = try? Data(contentsOf: fallbackFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveFallbackMap(_ map: [String: String]) {
        let dir = fallbackFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: fallbackFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackFileURL.path)
        var url = fallbackFileURL
        var vals = URLResourceValues()
        vals.isExcludedFromBackup = true
        try? url.setResourceValues(vals)
    }
}

public enum SMBClient {
    private static let scriptExtensions: Set<String> = [
        "rpy", "rpyc", "rpym", "rpymc", "rpyb", "py", "rpe",
    ]
    private static let coverCandidatePaths: [String] = [
        "gui/main_menu.png",
        "gui/game_menu.png",
        "gui/window_icon.png",
        "images/bg.png",
        "gui/main_menu.jpg",
    ]
    private static let maxSyncedScriptBytes = 32 * 1024 * 1024
    private static let maxExtractedRPAScriptBytes = 16 * 1024 * 1024
    private static let maxCoverBytes = 16 * 1024 * 1024

    public static func listShares(server: SMBServerProfile, password: String) throws -> [SMBShareInfo] {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMBError.invalidConfiguration("Host cannot be empty.")
        }

        var list = csmb_share_list_t()
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = withCredentials(server, password: password) { creds in
            csmb_list_shares(creds, &list, &errBuf, errBuf.count)
        }
        defer { csmb_free_share_list(&list) }

        if rc < 0 {
            throw SMBError.connectionFailed(decodeError(errBuf, fallback: "Unable to enumerate shares (error \(rc))."))
        }

        var shares: [SMBShareInfo] = []
        shares.reserveCapacity(list.count)
        if let base = list.items {
            for idx in 0..<list.count {
                let item = base[idx]
                let name = item.name.map { String(cString: $0) } ?? ""
                let remark = item.remark.map { String(cString: $0) } ?? ""
                if !name.isEmpty {
                    shares.append(SMBShareInfo(name: name, remark: remark, isHidden: item.is_hidden != 0))
                }
            }
        }
        return shares.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func listDirectory(
        server: SMBServerProfile,
        password: String,
        share: String,
        path: String
    ) throws -> [SMBRemoteItem] {
        let conn = try openConnection(server: server, password: password, share: share)
        defer { csmb_disconnect(conn) }
        return try listDirectory(on: conn, path: path)
    }

    public static func looksLikeRenPyGame(items: [SMBRemoteItem]) -> Bool {
        for item in items {
            let lower = item.name.lowercased()
            if item.isDirectory && (lower == "game" || lower == "renpy") {
                return true
            }
            if !item.isDirectory {
                if lower == "script_version.txt" || lower.hasSuffix(".rpa") || lower.hasSuffix(".rpy") || lower.hasSuffix(".rpyc") {
                    return true
                }
            }
        }
        return false
    }

    public static func prepareStreamedGame(
        server: SMBServerProfile,
        password: String,
        share: String,
        remoteGamePath: String,
        localGameDir: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> String {
        let cleanRoot = normalizeRelativePath(remoteGamePath)
        progress?(0.05, "Connecting to \(server.host)/\(share)...")
        let conn = try openConnection(server: server, password: password, share: share)
        defer { csmb_disconnect(conn) }

        let rootItems = try listDirectory(on: conn, path: cleanRoot)
        let hasGameSubdir = rootItems.contains { $0.isDirectory && $0.name.lowercased() == "game" }
        guard looksLikeRenPyGame(items: rootItems) else {
            throw SMBError.remoteNotRenPyGame
        }

        let fm = FileManager.default
        let localScriptGameDir = localGameDir.appendingPathComponent("game", isDirectory: true)
        try fm.createDirectory(at: localScriptGameDir, withIntermediateDirectories: true)

        var manifestEntries: [SMBIndexEntry] = []
        var seenLogicalLower = Set<String>()
        var rpaFiles: [(rpaRelFromGameRoot: String, smbFullRel: String, size: UInt64)] = []
        var coverData: Data?

        func joinSMB(_ base: String, _ rel: String) -> String {
            let a = normalizeRelativePath(base)
            let b = normalizeRelativePath(rel)
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            return "\(a)/\(b)"
        }

        // Sync small top-level metadata files used by RenPyVersionDetector.
        if rootItems.contains(where: { !$0.isDirectory && $0.name.lowercased() == "script_version.txt" }) {
            let rel = joinSMB(cleanRoot, "script_version.txt")
            if let data = try? readWholeFile(on: conn, relPath: rel, maxBytes: 4096) {
                try data.write(to: localGameDir.appendingPathComponent("script_version.txt"), options: .atomic)
            }
        }
        if let renpyDirItem = rootItems.first(where: { $0.isDirectory && $0.name.lowercased() == "renpy" }) {
            let renpySub = (try? listDirectory(on: conn, path: renpyDirItem.relativePath)) ?? []
            if let vcItem = renpySub.first(where: { !$0.isDirectory && $0.name.lowercased() == "vc_version.py" }) {
                if let data = try? readWholeFile(on: conn, relPath: vcItem.relativePath, maxBytes: 16384) {
                    let localRenpyDir = localGameDir.appendingPathComponent("renpy", isDirectory: true)
                    try fm.createDirectory(at: localRenpyDir, withIntermediateDirectories: true)
                    try data.write(to: localRenpyDir.appendingPathComponent("vc_version.py"), options: .atomic)
                }
            }
        }

        progress?(0.15, "Scanning remote game directory...")
        let scanSMBRoot: String
        let gameRelPrefix: String
        if hasGameSubdir, let gameDirItem = rootItems.first(where: { $0.isDirectory && $0.name.lowercased() == "game" }) {
            scanSMBRoot = gameDirItem.relativePath
            gameRelPrefix = "\(gameDirItem.name)/"
        } else {
            scanSMBRoot = cleanRoot
            gameRelPrefix = ""
        }

        var collectedLoose: [(logical: String, relFromGameRoot: String, smbFullRel: String, size: UInt64)] = []
        var queue: [(smbPath: String, relSub: String, depth: Int)] = [(scanSMBRoot, "", 0)]
        let skipDirs: Set<String> = ["cache", "saves", "save", ".git", ".hg", "__pycache__"]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let items = try listDirectory(on: conn, path: current.smbPath)
            for item in items {
                let relInGame = current.relSub.isEmpty ? item.name : "\(current.relSub)/\(item.name)"
                if item.isDirectory {
                    if current.depth == 0 && (item.name.lowercased() == "lib" || item.name.lowercased() == "renpy") {
                        continue
                    }
                    if skipDirs.contains(item.name.lowercased()) {
                        continue
                    }
                    if current.depth < 8 {
                        queue.append((item.relativePath, relInGame, current.depth + 1))
                    }
                } else {
                    let lower = item.name.lowercased()
                    let relFromGameRoot = "\(gameRelPrefix)\(relInGame)"
                    if lower.hasSuffix(".rpa") {
                        rpaFiles.append((relFromGameRoot, item.relativePath, item.size))
                    } else {
                        collectedLoose.append((relInGame, relFromGameRoot, item.relativePath, item.size))
                    }
                }
            }
        }

        let totalWork = max(1, collectedLoose.count + rpaFiles.count * 4)
        var doneWork = 0

        for file in collectedLoose {
            doneWork += 1
            let ext = URL(fileURLWithPath: file.logical).pathExtension.lowercased()
            let lowerName = file.logical.lowercased()
            let isScript = Self.scriptExtensions.contains(ext) || lowerName.hasSuffix(".rpe.py")

            if isScript && file.size <= UInt64(Self.maxSyncedScriptBytes) {
                progress?(0.2 + 0.45 * Double(doneWork) / Double(totalWork), "Syncing script: \(file.logical)")
                let data = try readWholeFile(on: conn, relPath: file.smbFullRel, maxBytes: Self.maxSyncedScriptBytes)
                let dest = try safeResolve(baseDir: localScriptGameDir, relativePath: file.logical)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                seenLogicalLower.insert(lowerName)
            } else {
                if seenLogicalLower.insert(lowerName).inserted {
                    manifestEntries.append(
                        SMBIndexEntry(
                            logicalPath: file.logical,
                            backing: .loose(smbRelPath: file.relFromGameRoot, size: file.size)
                        )
                    )
                }
                if coverData == nil && Self.coverCandidatePaths.contains(lowerName) && file.size <= UInt64(Self.maxCoverBytes) {
                    coverData = try? readWholeFile(on: conn, relPath: file.smbFullRel, maxBytes: Self.maxCoverBytes)
                }
            }
        }

        // Index remote .rpa archives in reverse alphabetical order so patch archives shadow base archives.
        rpaFiles.sort { $0.rpaRelFromGameRoot > $1.rpaRelFromGameRoot }
        for rpa in rpaFiles {
            doneWork += 4
            progress?(0.65 + 0.3 * min(1.0, Double(doneWork) / Double(totalWork)), "Indexing \(URL(fileURLWithPath: rpa.rpaRelFromGameRoot).lastPathComponent)...")
            let (_, entries) = try RPAArchive.parseIndex(fileSize: rpa.size) { offset, count in
                try preadSlice(on: conn, relPath: rpa.smbFullRel, offset: offset, count: count)
            }

            let sortedNames = entries.keys.sorted()
            for entryName in sortedNames {
                guard let segments = entries[entryName], !segments.isEmpty else { continue }
                let normLogical = normalizeRelativePath(entryName)
                guard !normLogical.isEmpty else { continue }
                let lowerLogical = normLogical.lowercased()
                let ext = URL(fileURLWithPath: normLogical).pathExtension.lowercased()
                let isScript = Self.scriptExtensions.contains(ext) || lowerLogical.hasSuffix(".rpe.py")
                let totalBytes = segments.reduce(UInt64(0)) { $0 + $1.length }

                if isScript && totalBytes <= UInt64(Self.maxExtractedRPAScriptBytes) {
                    let localDest = try safeResolve(baseDir: localScriptGameDir, relativePath: normLogical)
                    if !fm.fileExists(atPath: localDest.path),
                       let scriptData = try? RPAArchive.assembleEntry(segments: segments, fileSize: rpa.size, readSlice: { off, cnt in
                           try preadSlice(on: conn, relPath: rpa.smbFullRel, offset: off, count: cnt)
                       }) {
                        try fm.createDirectory(at: localDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try scriptData.write(to: localDest, options: .atomic)
                        seenLogicalLower.insert(lowerLogical)
                    }
                    continue
                }

                if seenLogicalLower.insert(lowerLogical).inserted {
                    manifestEntries.append(
                        SMBIndexEntry(
                            logicalPath: normLogical,
                            backing: .rpa(rpaRelPath: rpa.rpaRelFromGameRoot, segments: segments)
                        )
                    )
                }

                if coverData == nil && Self.coverCandidatePaths.contains(lowerLogical) && totalBytes <= UInt64(Self.maxCoverBytes) {
                    coverData = try? RPAArchive.assembleEntry(segments: segments, fileSize: rpa.size) { off, cnt in
                        try preadSlice(on: conn, relPath: rpa.smbFullRel, offset: off, count: cnt)
                    }
                }
            }
        }

        if let coverData {
            try? coverData.write(to: localGameDir.appendingPathComponent(".renplay_cover.png"), options: .atomic)
        }

        let manifestText = SMBIndexManifest(entries: manifestEntries).serialize()
        let manifestURL = localGameDir.appendingPathComponent(SMBIndexManifest.manifestFileName)
        try manifestText.write(to: manifestURL, atomically: true, encoding: .utf8)

        progress?(1.0, "Ready to stream")
        return hasGameSubdir ? cleanRoot : (cleanRoot.isEmpty ? "" : cleanRoot)
    }

    public static func readManifestEntry(
        _ entry: SMBIndexEntry,
        source: SMBGameSource,
        password: String
    ) throws -> Data {
        let server = SMBServerProfile(
            id: source.serverID,
            displayName: source.host,
            host: source.host,
            port: source.port,
            username: source.username,
            domain: source.domain,
            isGuest: source.isGuest
        )
        let conn = try openConnection(server: server, password: password, share: source.share)
        defer { csmb_disconnect(conn) }

        let base = normalizeRelativePath(source.remotePath)
        func fullSMBPath(_ gameRel: String) -> String {
            base.isEmpty ? normalizeRelativePath(gameRel) : "\(base)/\(normalizeRelativePath(gameRel))"
        }

        switch entry.backing {
        case .loose(let smbRelPath, let size):
            return try readWholeFile(on: conn, relPath: fullSMBPath(smbRelPath), maxBytes: Int(min(size, 64 * 1024 * 1024)))
        case .rpa(let rpaRelPath, let segments):
            let fullRPA = fullSMBPath(rpaRelPath)
            var fileSize: UInt64 = 0
            var isDir: Int32 = 0
            var errBuf = [CChar](repeating: 0, count: 512)
            let rc = fullRPA.withCString { cPath in
                csmb_conn_stat(conn, cPath, &fileSize, &isDir, &errBuf, errBuf.count)
            }
            if rc < 0 {
                throw SMBError.operationFailed(decodeError(errBuf, fallback: "Failed to stat remote RPA archive."))
            }
            return try RPAArchive.assembleEntry(segments: segments, fileSize: fileSize) { off, count in
                try preadSlice(on: conn, relPath: fullRPA, offset: off, count: count)
            }
        }
    }

    private static func openConnection(
        server: SMBServerProfile,
        password: String,
        share: String
    ) throws -> OpaquePointer {
        var errBuf = [CChar](repeating: 0, count: 512)
        let connOpt = withCredentials(server, password: password) { creds in
            share.withCString { cShare in
                csmb_connect(creds, cShare, &errBuf, errBuf.count)
            }
        }
        guard let conn = connOpt else {
            throw SMBError.connectionFailed(decodeError(errBuf, fallback: "Unable to open SMB share \(share)."))
        }
        return conn
    }

    private static func listDirectory(on conn: OpaquePointer, path: String) throws -> [SMBRemoteItem] {
        let clean = normalizeRelativePath(path)
        var list = csmb_dir_list_t()
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = clean.withCString { cPath in
            csmb_conn_list_dir(conn, cPath, &list, &errBuf, errBuf.count)
        }
        defer { csmb_free_dir_list(&list) }
        if rc < 0 {
            throw SMBError.operationFailed(decodeError(errBuf, fallback: "Failed to read remote directory."))
        }

        var result: [SMBRemoteItem] = []
        result.reserveCapacity(list.count)
        if let base = list.items {
            for idx in 0..<list.count {
                let raw = base[idx]
                guard let cName = raw.name else { continue }
                let name = String(cString: cName)
                if name.isEmpty || name == "." || name == ".." { continue }
                let rel = clean.isEmpty ? name : "\(clean)/\(name)"
                let mtime: Date? = raw.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(raw.mtime)) : nil
                result.append(
                    SMBRemoteItem(
                        name: name,
                        relativePath: rel,
                        isDirectory: raw.is_dir != 0,
                        size: raw.size,
                        modifiedAt: mtime
                    )
                )
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func readWholeFile(on conn: OpaquePointer, relPath: String, maxBytes: Int) throws -> Data {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = relPath.withCString { cPath in
            csmb_conn_read_file(conn, cPath, maxBytes, &outPtr, &outLen, &errBuf, errBuf.count)
        }
        defer { csmb_free_buffer(outPtr) }
        if rc < 0 {
            throw SMBError.operationFailed(decodeError(errBuf, fallback: "Failed reading remote file \(relPath)."))
        }
        guard let outPtr, outLen > 0 else {
            return Data()
        }
        return Data(bytes: outPtr, count: outLen)
    }

    private static func preadSlice(
        on conn: OpaquePointer,
        relPath: String,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        if count <= 0 { return Data() }
        var buf = Data(count: count)
        var errBuf = [CChar](repeating: 0, count: 512)
        let got: Int = buf.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            return relPath.withCString { cPath in
                csmb_conn_pread(conn, cPath, offset, base, count, &errBuf, errBuf.count)
            }
        }
        if got < 0 {
            throw SMBError.operationFailed(decodeError(errBuf, fallback: "Failed reading remote slice from \(relPath)."))
        }
        if got < count {
            buf.removeSubrange(got..<count)
        }
        return buf
    }

    private static func safeResolve(baseDir: URL, relativePath: String) throws -> URL {
        let components = normalizeRelativePath(relativePath)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if components.contains(".") || components.contains("..") || components.isEmpty {
            throw SMBError.pathTraversal(relativePath)
        }
        var target = baseDir
        for comp in components {
            target = target.appendingPathComponent(comp, isDirectory: false)
        }
        return target
    }

    public static func normalizeRelativePath(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    private static func withCredentials<T>(
        _ server: SMBServerProfile,
        password: String,
        body: (UnsafePointer<csmb_credentials_t>) throws -> T
    ) rethrows -> T {
        let port = Int32(server.port > 0 && server.port <= 65535 ? server.port : 445)
        let guestFlag: Int32 = server.isGuest ? 1 : 0
        return try server.host.withCString { cHost in
            try server.username.withCString { cUser in
                try password.withCString { cPass in
                    try server.domain.withCString { cDomain in
                        var creds = csmb_credentials_t(
                            host: cHost,
                            port: port,
                            username: cUser,
                            password: cPass,
                            domain: cDomain,
                            is_guest: guestFlag
                        )
                        return try body(&creds)
                    }
                }
            }
        }
    }

    private static func decodeError(_ buf: [CChar], fallback: String) -> String {
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s
    }
}
