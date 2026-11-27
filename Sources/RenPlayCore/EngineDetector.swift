// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct DetectedVersion: Sendable, Equatable {
    public enum Source: String, Sendable {
        case vcVersionPy
        case renpyInitPy
        case scriptVersionTxt
        case runtimeLibDir
        case rpycHeader
        case cacheFileName
        case remoteListing
        case stored
    }

    public let version: SemVer?
    public let majorHint: Int?
    public let source: Source

    public init(version: SemVer?, majorHint: Int? = nil, source: Source) {
        self.version = version
        self.majorHint = majorHint ?? version?.major
        self.source = source
    }

    // Parses the label persisted in GameEntry.detectedEngineVersion ("8.3.7" or "8.x").
    public init?(storedDescription raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".x"), let major = Int(trimmed.dropLast(2)) {
            self.init(version: nil, majorHint: major, source: .stored)
            return
        }
        guard let ver = SemVer(parsing: trimmed) else { return nil }
        self.init(version: ver, source: .stored)
    }

    public var libraryLabel: String? {
        version?.description ?? majorHint.map { "\($0).x" }
    }
}

public enum RenPyVersionDetector {
    // Written by SMB sync from remote lib/ and game/cache listings, which are never downloaded.
    public static let remoteHintFileName = ".renplay_engine_hint"
    private static let maxRpycProbes = 40

    public static func detectVersion(in gameRoot: URL) -> DetectedVersion? {
        let fm = FileManager.default

        let vcPath = gameRoot.appendingPathComponent("renpy/vc_version.py")
        if let text = try? String(contentsOf: vcPath, encoding: .utf8),
           let ver = parseVersionTuple(in: text) {
            return DetectedVersion(version: ver, source: .vcVersionPy)
        }

        let initPath = gameRoot.appendingPathComponent("renpy/__init__.py")
        if let text = try? String(contentsOf: initPath, encoding: .utf8),
           let ver = parseVersionTuple(in: text) {
            return DetectedVersion(version: ver, source: .renpyInitPy)
        }

        let scriptVerCandidates = [
            gameRoot.appendingPathComponent("renpy/script_version.txt"),
            gameRoot.appendingPathComponent("script_version.txt"),
            gameRoot.appendingPathComponent("game/script_version.txt"),
        ]
        for candidate in scriptVerCandidates {
            if let text = try? String(contentsOf: candidate, encoding: .utf8),
               let ver = parseScriptVersion(in: text) {
                return DetectedVersion(version: ver, source: .scriptVersionTxt)
            }
        }

        let libDir = gameRoot.appendingPathComponent("lib")
        if let entries = try? fm.contentsOfDirectory(atPath: libDir.path),
           let major = majorHint(fromRuntimeEntries: entries) {
            return DetectedVersion(version: nil, majorHint: major, source: .runtimeLibDir)
        }

        let gameSubdir = gameRoot.appendingPathComponent("game")
        let cacheDir = gameSubdir.appendingPathComponent("cache")
        if let entries = try? fm.contentsOfDirectory(atPath: cacheDir.path),
           let major = majorHint(fromCacheFileNames: entries) {
            return DetectedVersion(version: nil, majorHint: major, source: .cacheFileName)
        }

        let hintURL = gameRoot.appendingPathComponent(remoteHintFileName)
        if let text = try? String(contentsOf: hintURL, encoding: .utf8),
           let major = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return DetectedVersion(version: nil, majorHint: major, source: .remoteListing)
        }

        let scanDir = fm.fileExists(atPath: gameSubdir.path) ? gameSubdir : gameRoot
        if let rpycVer = inferMajorFromRpycDirectory(scanDir) {
            return rpycVer
        }

        return nil
    }

    static func majorHint(fromRuntimeEntries names: [String]) -> Int? {
        if names.contains(where: { $0.hasPrefix("py3-") || $0.hasPrefix("python3") }) {
            return 8
        }
        if names.contains(where: { $0.hasPrefix("py2-") || $0.hasPrefix("python2") || $0.hasPrefix("linux-") || $0.hasPrefix("windows-") || $0.hasPrefix("mac-") }) {
            return 7
        }
        return nil
    }

    // Ren'Py names its bytecode cache after the embedded Python (bytecode-39/311/312 on 8.x, bytecode-27 or unversioned on 7.x).
    static func majorHint(fromCacheFileNames names: [String]) -> Int? {
        let lowered = names.map { $0.lowercased() }
        if lowered.contains(where: { $0 == "py3analysis.rpyb" || ($0.hasPrefix("bytecode-3") && $0.hasSuffix(".rpyb")) }) {
            return 8
        }
        if lowered.contains(where: { $0 == "pyanalysis.rpyb" || $0 == "bytecode.rpyb" || ($0.hasPrefix("bytecode-2") && $0.hasSuffix(".rpyb")) }) {
            return 7
        }
        return nil
    }

    public static func parseGameVersion(in gameRoot: URL) -> String? {
        parseOptionsValue(in: gameRoot, pattern: #"(?m)^\s*(?:define\s+)?config\.version\s*=\s*(?:_\(\s*)?[ru]?["']([^"'\n]+)["']"#)
    }

    public static func parseConfiguredSaveDirName(in gameRoot: URL) -> String? {
        parseOptionsValue(in: gameRoot, pattern: #"(?m)^\s*(?:define\s+)?config\.save_directory\s*=\s*[ru]?["']([^"'\n]+)["']"#)
    }

    private static func parseOptionsValue(in gameRoot: URL, pattern: String) -> String? {
        let optionsURL = gameRoot.appendingPathComponent("game/options.rpy")
        guard let fh = try? FileHandle(forReadingFrom: optionsURL),
              let data = try? fh.read(upToCount: 262_144) else {
            return nil
        }
        try? fh.close()
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let cleaned = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseVersionTuple(in text: String) -> SemVer? {
        // Ren'Py <= 8.1 writes version_tuple; 8.2+ vc_version.py only carries version = '8.x.y.build'.
        let patterns = [
            #"version_tuple\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#,
            #"(?m)^\s*version\s*=\s*u?['"](\d+)\.(\d+)\.(\d+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges >= 4 else {
                continue
            }
            func intAt(_ idx: Int) -> Int? {
                guard let r = Range(match.range(at: idx), in: text) else { return nil }
                return Int(text[r])
            }
            if let maj = intAt(1), let min = intAt(2), let pat = intAt(3) {
                return SemVer(major: maj, minor: min, patch: pat)
            }
        }
        return nil
    }

    static func parseScriptVersion(in text: String) -> SemVer? {
        let tuplePattern = #"\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: tuplePattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 4,
           let r1 = Range(match.range(at: 1), in: text),
           let r2 = Range(match.range(at: 2), in: text),
           let r3 = Range(match.range(at: 3), in: text),
           let maj = Int(text[r1]),
           let min = Int(text[r2]),
           let pat = Int(text[r3]) {
            return SemVer(major: maj, minor: min, patch: pat)
        }

        let dotPattern = #"(\d+\.\d+\.\d+)"#
        if let regex = try? NSRegularExpression(pattern: dotPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(match.range(at: 1), in: text) {
            return SemVer(parsing: String(text[r1]))
        }
        return nil
    }

    private static func inferMajorFromRpycDirectory(_ dir: URL) -> DetectedVersion? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var probed = 0
        while let item = enumerator.nextObject() as? URL {
            let ext = item.pathExtension.lowercased()
            guard ext == "rpyc" || ext == "rpymc" else { continue }
            probed += 1
            if probed > maxRpycProbes { break }
            guard let data = try? Data(contentsOf: item, options: .mappedIfSafe),
                  let compressed = rpycSlotOnePayload(data),
                  let inflated = try? ZlibCodec.inflate(compressed, rawDeflate: false),
                  inflated.count >= 2, inflated[0] == 0x80 else { continue }
            // Pickle protocol 3+ only exists on Python 3 (Ren'Py 8.x); Python 2 tops out at protocol 2 (Ren'Py 7.x).
            let major = inflated[1] >= 3 ? 8 : 7
            return DetectedVersion(version: nil, majorHint: major, source: .rpycHeader)
        }
        return nil
    }

    // RPC2 layout: "RENPY RPC2" then (slot, start, length) uint32 triples terminated by slot 0.
    // Files without the header are legacy single-stream zlib pickles.
    private static func rpycSlotOnePayload(_ data: Data) -> Data? {
        let magic = Data("RENPY RPC2".utf8)
        guard data.starts(with: magic) else {
            return data.count > 2 ? data : nil
        }
        var pos = magic.count
        while pos + 12 <= data.count {
            let slot = data.readUInt32LE(at: pos)
            let start = Int(data.readUInt32LE(at: pos + 4))
            let length = Int(data.readUInt32LE(at: pos + 8))
            if slot == 0 { return nil }
            if slot == 1 {
                guard length > 0, start >= pos + 12, start + length <= data.count else { return nil }
                return data.subdata(in: start..<(start + length))
            }
            pos += 12
        }
        return nil
    }
}

public enum EngineSelector {
    public static func selectEngine(
        detected: DetectedVersion?,
        available: [EngineInfo],
        strategy: EngineSelectionStrategy
    ) -> EngineInfo? {
        let parsed: [(info: EngineInfo, ver: SemVer)] = available.compactMap { info in
            guard let v = SemVer(parsing: info.version) else { return nil }
            return (info, v)
        }.sorted { $0.ver < $1.ver }

        guard !parsed.isEmpty else { return available.first }

        guard let detected else {
            return parsed.last?.info
        }

        let targetMajor = detected.majorHint ?? detected.version?.major
        let majorPool: [(info: EngineInfo, ver: SemVer)]
        if let targetMajor {
            let filtered = parsed.filter { $0.ver.major == targetMajor }
            majorPool = filtered.isEmpty ? parsed : filtered
        } else {
            majorPool = parsed
        }

        switch strategy {
        case .latest:
            return majorPool.last?.info
        case .accurate:
            guard let detVer = detected.version else {
                return majorPool.last?.info
            }
            if let exact = majorPool.first(where: { $0.ver == detVer }) {
                return exact.info
            }
            // Prefer the smallest engine in the same major >= detected minor/patch
            if let upgrade = majorPool.first(where: { $0.ver >= detVer }) {
                return upgrade.info
            }
            return majorPool.last?.info
        }
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset..<(offset + 2))
        }
        return UInt16(littleEndian: value)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dst in
            copyBytes(to: dst, from: offset..<(offset + 8))
        }
        return UInt64(littleEndian: value)
    }
}
