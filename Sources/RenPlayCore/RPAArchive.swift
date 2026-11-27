// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum RPAError: Error, LocalizedError, Sendable {
    case invalidHeader
    case unsupportedVersion(String)
    case corruptIndex
    case entryNotFound(String)
    case readOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid RPA archive header"
        case .unsupportedVersion(let ver):
            return "Unsupported RPA archive version: \(ver)"
        case .corruptIndex:
            return "Failed to parse RPA archive index"
        case .entryNotFound(let path):
            return "Entry not found in RPA archive: \(path)"
        case .readOutOfBounds:
            return "RPA entry offset exceeds file length"
        }
    }
}

public struct RPAIndexEntry: Sendable, Equatable, Hashable {
    public let offset: UInt64
    public let length: UInt64
    public let prefix: Data

    public init(offset: UInt64, length: UInt64, prefix: Data = Data()) {
        self.offset = offset
        self.length = length
        self.prefix = prefix
    }
}

public final class RPAArchive: @unchecked Sendable {
    public let fileURL: URL
    public let fileSize: UInt64
    public let version: String
    public let entries: [String: [RPAIndexEntry]]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let endOffset = try handle.seekToEnd()
        self.fileSize = endOffset

        let parsed = try Self.parseIndex(fileSize: endOffset) { offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
        self.version = parsed.version
        self.entries = parsed.entries
    }

    public static func parseIndex(
        fileSize: UInt64,
        readSlice: (UInt64, Int) throws -> Data
    ) throws -> (version: String, entries: [String: [RPAIndexEntry]]) {
        guard fileSize > 0 else {
            throw RPAError.invalidHeader
        }
        let headerCount = Int(min(UInt64(128), fileSize))
        let headerData = try readSlice(0, headerCount)
        guard let newlineIdx = headerData.firstIndex(of: 0x0A),
              let headerLine = String(data: headerData.prefix(upTo: newlineIdx), encoding: .utf8) else {
            throw RPAError.invalidHeader
        }

        let parts = headerLine.split(separator: " ")
        guard !parts.isEmpty else {
            throw RPAError.invalidHeader
        }

        let ver = String(parts[0])
        let indexOffset: UInt64
        let key: UInt64

        switch ver {
        case "RPA-3.0":
            guard parts.count >= 3,
                  let off = UInt64(parts[1], radix: 16),
                  let k = UInt64(parts[2], radix: 16) else {
                throw RPAError.invalidHeader
            }
            indexOffset = off
            key = k
        case "RPA-3.2":
            guard parts.count >= 4,
                  let off = UInt64(parts[1], radix: 16),
                  let k = UInt64(parts[3], radix: 16) else {
                throw RPAError.invalidHeader
            }
            indexOffset = off
            key = k
        case "RPA-2.0":
            guard parts.count >= 2,
                  let off = UInt64(parts[1], radix: 16) else {
                throw RPAError.invalidHeader
            }
            indexOffset = off
            key = 0
        default:
            throw RPAError.unsupportedVersion(ver)
        }

        guard indexOffset < fileSize else {
            throw RPAError.corruptIndex
        }
        let indexByteCount = fileSize - indexOffset
        guard indexByteCount > 0, indexByteCount <= 256 * 1024 * 1024 else {
            throw RPAError.corruptIndex
        }
        let compressedIndex = try readSlice(indexOffset, Int(indexByteCount))
        guard !compressedIndex.isEmpty else {
            throw RPAError.corruptIndex
        }

        let rawPickle = try ZlibCodec.inflate(compressedIndex, rawDeflate: false)
        let decoded = try PickleDecoder.decode(rawPickle)
        guard case .dict(let pairs) = decoded else {
            throw RPAError.corruptIndex
        }

        var map: [String: [RPAIndexEntry]] = [:]
        map.reserveCapacity(pairs.count)

        for (kVal, vVal) in pairs {
            guard let name = kVal.asString,
                  case .list(let segments) = vVal else {
                continue
            }
            var parsedSegments: [RPAIndexEntry] = []
            for seg in segments {
                guard case .list(let fields) = seg, fields.count >= 2,
                      let rawOff = fields[0].asUInt64,
                      let rawLen = fields[1].asUInt64 else {
                    continue
                }
                let prefixData: Data
                if fields.count >= 3 {
                    prefixData = fields[2].asData ?? Data()
                } else {
                    prefixData = Data()
                }
                parsedSegments.append(
                    RPAIndexEntry(
                        offset: rawOff ^ key,
                        length: rawLen ^ key,
                        prefix: prefixData
                    )
                )
            }
            if !parsedSegments.isEmpty {
                map[name] = parsedSegments
            }
        }
        return (ver, map)
    }

    public static func assembleEntry(
        segments: [RPAIndexEntry],
        fileSize: UInt64,
        readSlice: (UInt64, Int) throws -> Data
    ) throws -> Data {
        var output = Data()
        for seg in segments {
            output.append(seg.prefix)
            let bodyLen = seg.length > UInt64(seg.prefix.count) ? seg.length - UInt64(seg.prefix.count) : 0
            if bodyLen > 0 {
                guard seg.offset <= fileSize, bodyLen <= fileSize - seg.offset else {
                    throw RPAError.readOutOfBounds
                }
                let chunk = try readSlice(seg.offset, Int(bodyLen))
                guard UInt64(chunk.count) == bodyLen else {
                    throw RPAError.readOutOfBounds
                }
                output.append(chunk)
            }
        }
        return output
    }

    public func listEntries() -> [String] {
        entries.keys.sorted()
    }

    public func readEntry(_ path: String) throws -> Data {
        guard let segments = entries[path] else {
            throw RPAError.entryNotFound(path)
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileEnd = try handle.seekToEnd()
        return try Self.assembleEntry(segments: segments, fileSize: fileEnd) { offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }
}

// Focused Python Pickle decoder (protocols 0-5) covering RPA archive indexes.
enum PickleValue: Sendable {
    case none
    case bool(Bool)
    case int(Int64)
    case string(String)
    case bytes(Data)
    case list([PickleValue])
    case dict([(PickleValue, PickleValue)])

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .bytes(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var asUInt64: UInt64? {
        if case .int(let v) = self, v >= 0 {
            return UInt64(v)
        }
        return nil
    }

    var asData: Data? {
        switch self {
        case .bytes(let d): return d
        case .string(let s): return Data(s.utf8)
        default: return nil
        }
    }
}

enum PickleDecoder {
    static func decode(_ data: Data) throws -> PickleValue {
        var pos = 0
        var stack: [PickleValue] = []
        var markPositions: [Int] = []
        var memo: [Int: PickleValue] = [:]

        func need(_ count: Int) throws {
            guard pos + count <= data.count else { throw RPAError.corruptIndex }
        }

        func readByte() throws -> UInt8 {
            try need(1)
            let b = data[pos]
            pos += 1
            return b
        }

        func readBytes(_ count: Int) throws -> Data {
            guard count >= 0 else { throw RPAError.corruptIndex }
            try need(count)
            let sub = data.subdata(in: pos..<(pos + count))
            pos += count
            return sub
        }

        func readLine() throws -> String {
            guard let nl = data[pos...].firstIndex(of: 0x0A) else {
                throw RPAError.corruptIndex
            }
            let slice = data[pos..<nl]
            pos = nl + 1
            return String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        }

        func readUInt32LE() throws -> UInt32 {
            let d = try readBytes(4)
            return d.readUInt32LE(at: 0)
        }

        func readInt32LE() throws -> Int32 {
            Int32(bitPattern: try readUInt32LE())
        }

        func readUInt64LE() throws -> UInt64 {
            let d = try readBytes(8)
            return d.readUInt64LE(at: 0)
        }

        func popMarkItems() throws -> [PickleValue] {
            guard let m = markPositions.popLast(), m <= stack.count else {
                throw RPAError.corruptIndex
            }
            let items = Array(stack[m...])
            stack.removeSubrange(m...)
            return items
        }

        func decodeSignedLong(_ bytes: Data) -> Int64 {
            if bytes.isEmpty { return 0 }
            var result: Int64 = 0
            let isNeg = (bytes[bytes.count - 1] & 0x80) != 0
            let limit = min(bytes.count, 8)
            for i in 0..<limit {
                result |= Int64(bytes[i]) << (8 * i)
            }
            if isNeg && limit < 8 {
                for i in limit..<8 {
                    result |= Int64(0xFF) << (8 * i)
                }
            }
            return result
        }

        while pos < data.count {
            let op = try readByte()
            switch op {
            case 0x80: // PROTO
                _ = try readByte()
            case 0x95: // FRAME
                _ = try readUInt64LE()
            case 0x2E: // STOP '.'
                guard let top = stack.last else { throw RPAError.corruptIndex }
                return top
            case 0x28: // MARK '('
                markPositions.append(stack.count)
            case 0x4E: // NONE 'N'
                stack.append(.none)
            case 0x88: // NEWTRUE
                stack.append(.bool(true))
            case 0x89: // NEWFALSE
                stack.append(.bool(false))
            case 0x4B: // BININT1 'K'
                stack.append(.int(Int64(try readByte())))
            case 0x4D: // BININT2 'M'
                let d = try readBytes(2)
                stack.append(.int(Int64(d.readUInt16LE(at: 0))))
            case 0x4A: // BININT 'J'
                stack.append(.int(Int64(try readInt32LE())))
            case 0x8A: // LONG1
                let len = Int(try readByte())
                stack.append(.int(decodeSignedLong(try readBytes(len))))
            case 0x8B: // LONG4
                let len = Int(try readInt32LE())
                stack.append(.int(decodeSignedLong(try readBytes(len))))
            case 0x49: // INT 'I'
                let line = try readLine()
                if line == "01" { stack.append(.bool(true)) }
                else if line == "00" { stack.append(.bool(false)) }
                else if let v = Int64(line) { stack.append(.int(v)) }
                else { throw RPAError.corruptIndex }
            case 0x4C: // LONG 'L'
                var line = try readLine()
                if line.hasSuffix("L") { line.removeLast() }
                guard let v = Int64(line) else { throw RPAError.corruptIndex }
                stack.append(.int(v))
            case 0x58: // BINUNICODE 'X'
                let len = Int(try readUInt32LE())
                let d = try readBytes(len)
                stack.append(.string(String(decoding: d, as: UTF8.self)))
            case 0x8C: // SHORT_BINUNICODE
                let len = Int(try readByte())
                let d = try readBytes(len)
                stack.append(.string(String(decoding: d, as: UTF8.self)))
            case 0x8D: // BINUNICODE8
                let len = Int(try readUInt64LE())
                let d = try readBytes(len)
                stack.append(.string(String(decoding: d, as: UTF8.self)))
            case 0x54: // BINSTRING 'T'
                let len = Int(try readInt32LE())
                stack.append(.bytes(try readBytes(len)))
            case 0x55: // SHORT_BINSTRING 'U'
                let len = Int(try readByte())
                stack.append(.bytes(try readBytes(len)))
            case 0x42: // BINBYTES 'B'
                let len = Int(try readUInt32LE())
                stack.append(.bytes(try readBytes(len)))
            case 0x43: // SHORT_BINBYTES 'C'
                let len = Int(try readByte())
                stack.append(.bytes(try readBytes(len)))
            case 0x8E: // BINBYTES8
                let len = Int(try readUInt64LE())
                stack.append(.bytes(try readBytes(len)))
            case 0x53: // STRING 'S'
                var line = try readLine()
                if (line.hasPrefix("'") && line.hasSuffix("'")) || (line.hasPrefix("\"") && line.hasSuffix("\"")) {
                    line = String(line.dropFirst().dropLast())
                }
                stack.append(.string(line))
            case 0x56: // UNICODE 'V'
                stack.append(.string(try readLine()))
            case 0x7D: // EMPTY_DICT '}'
                stack.append(.dict([]))
            case 0x64: // DICT 'd'
                let items = try popMarkItems()
                guard items.count % 2 == 0 else { throw RPAError.corruptIndex }
                var pairs: [(PickleValue, PickleValue)] = []
                for idx in stride(from: 0, to: items.count, by: 2) {
                    pairs.append((items[idx], items[idx + 1]))
                }
                stack.append(.dict(pairs))
            case 0x73: // SETITEM 's'
                guard stack.count >= 3 else { throw RPAError.corruptIndex }
                let val = stack.removeLast()
                let key = stack.removeLast()
                guard case .dict(var pairs) = stack.removeLast() else { throw RPAError.corruptIndex }
                pairs.append((key, val))
                stack.append(.dict(pairs))
            case 0x75: // SETITEMS 'u'
                let items = try popMarkItems()
                guard items.count % 2 == 0, !stack.isEmpty,
                      case .dict(var pairs) = stack.removeLast() else {
                    throw RPAError.corruptIndex
                }
                for idx in stride(from: 0, to: items.count, by: 2) {
                    pairs.append((items[idx], items[idx + 1]))
                }
                stack.append(.dict(pairs))
            case 0x5D: // EMPTY_LIST ']'
                stack.append(.list([]))
            case 0x29: // EMPTY_TUPLE ')'
                stack.append(.list([]))
            case 0x85: // TUPLE1
                guard let a = stack.popLast() else { throw RPAError.corruptIndex }
                stack.append(.list([a]))
            case 0x86: // TUPLE2
                guard stack.count >= 2 else { throw RPAError.corruptIndex }
                let b = stack.removeLast()
                let a = stack.removeLast()
                stack.append(.list([a, b]))
            case 0x87: // TUPLE3
                guard stack.count >= 3 else { throw RPAError.corruptIndex }
                let c = stack.removeLast()
                let b = stack.removeLast()
                let a = stack.removeLast()
                stack.append(.list([a, b, c]))
            case 0x74, 0x6C: // TUPLE 't' / LIST 'l'
                let items = try popMarkItems()
                stack.append(.list(items))
            case 0x61: // APPEND 'a'
                guard stack.count >= 2 else { throw RPAError.corruptIndex }
                let item = stack.removeLast()
                guard case .list(var arr) = stack.removeLast() else { throw RPAError.corruptIndex }
                arr.append(item)
                stack.append(.list(arr))
            case 0x65: // APPENDS 'e'
                let items = try popMarkItems()
                guard !stack.isEmpty, case .list(var arr) = stack.removeLast() else {
                    throw RPAError.corruptIndex
                }
                arr.append(contentsOf: items)
                stack.append(.list(arr))
            case 0x71: // BINPUT 'q'
                let idx = Int(try readByte())
                if let top = stack.last { memo[idx] = top }
            case 0x72: // LONG_BINPUT 'r'
                let idx = Int(try readUInt32LE())
                if let top = stack.last { memo[idx] = top }
            case 0x94: // MEMOIZE
                if let top = stack.last { memo[memo.count] = top }
            case 0x68: // BINGET 'h'
                let idx = Int(try readByte())
                guard let val = memo[idx] else { throw RPAError.corruptIndex }
                stack.append(val)
            case 0x6A: // LONG_BINGET 'j'
                let idx = Int(try readUInt32LE())
                guard let val = memo[idx] else { throw RPAError.corruptIndex }
                stack.append(val)
            case 0x70: // PUT 'p'
                let idx = Int(try readLine()) ?? -1
                if idx >= 0, let top = stack.last { memo[idx] = top }
            case 0x67: // GET 'g'
                guard let idx = Int(try readLine()), let val = memo[idx] else { throw RPAError.corruptIndex }
                stack.append(val)
            case 0x30: // POP '0'
                _ = stack.popLast()
            case 0x32: // DUP '2'
                guard let top = stack.last else { throw RPAError.corruptIndex }
                stack.append(top)
            default:
                throw RPAError.corruptIndex
            }
        }
        throw RPAError.corruptIndex
    }
}
