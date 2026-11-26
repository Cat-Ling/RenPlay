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
    }

    public let version: SemVer?
    public let majorHint: Int?
    public let source: Source

    public init(version: SemVer?, majorHint: Int? = nil, source: Source) {
        self.version = version
        self.majorHint = majorHint ?? version?.major
        self.source = source
    }
}

public enum RenPyVersionDetector {
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
        if let entries = try? fm.contentsOfDirectory(atPath: libDir.path) {
            if entries.contains(where: { $0.hasPrefix("py3-") || $0.hasPrefix("python3") }) {
                return DetectedVersion(version: nil, majorHint: 8, source: .runtimeLibDir)
            }
            if entries.contains(where: { $0.hasPrefix("py2-") || $0.hasPrefix("python2") || $0.hasPrefix("linux-") || $0.hasPrefix("windows-") || $0.hasPrefix("mac-") }) {
                return DetectedVersion(version: nil, majorHint: 7, source: .runtimeLibDir)
            }
        }

        let gameSubdir = gameRoot.appendingPathComponent("game")
        let scanDir = fm.fileExists(atPath: gameSubdir.path) ? gameSubdir : gameRoot
        if let rpycVer = inferMajorFromRpycDirectory(scanDir) {
            return rpycVer
        }

        return nil
    }

    static func parseVersionTuple(in text: String) -> SemVer? {
        let pattern = #"version_tuple\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 4 else {
            return nil
        }
        func intAt(_ idx: Int) -> Int? {
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return Int(text[r])
        }
        guard let maj = intAt(1), let min = intAt(2), let pat = intAt(3) else { return nil }
        return SemVer(major: maj, minor: min, patch: pat)
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
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for item in items where item.pathExtension.lowercased() == "rpyc" {
            guard let data = try? Data(contentsOf: item, options: .mappedIfSafe),
                  data.count >= 22 else { continue }
            if data.starts(with: Data("RENPY RPC2".utf8)) {
                // Slot 1 starts at byte 10: uint32 offset, uint32 length
                let slotOffset = Int(data.readUInt32LE(at: 10))
                let slotLength = Int(data.readUInt32LE(at: 14))
                if slotOffset >= 22, slotLength > 4, slotOffset + slotLength <= data.count {
                    let compressed = data.subdata(in: slotOffset..<(slotOffset + slotLength))
                    if let inflated = try? ZlibCodec.inflate(compressed, rawDeflate: false) {
                        // Pickle protocol >= 4 (0x80 0x04 / 0x05) is Python 3 (Ren'Py 8.x); protocol 2 (0x80 0x02) is typically Ren'Py 7.x
                        if inflated.count >= 2 && inflated[0] == 0x80 {
                            let proto = inflated[1]
                            if proto >= 4 {
                                return DetectedVersion(version: nil, majorHint: 8, source: .rpycHeader)
                            }
                            if proto <= 2 {
                                return DetectedVersion(version: nil, majorHint: 7, source: .rpycHeader)
                            }
                        }
                    }
                }
            }
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
