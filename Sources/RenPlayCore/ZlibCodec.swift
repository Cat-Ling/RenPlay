// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import CZlib
import Foundation

public enum ZlibError: Error, LocalizedError, Sendable {
    case inflateFailed(Int32)
    case deflateFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .inflateFailed(let code):
            return "zlib inflate failed with status \(code)"
        case .deflateFailed(let code):
            return "zlib deflate failed with status \(code)"
        }
    }
}

public enum ZlibCodec {
    public static func inflate(_ data: Data, rawDeflate: Bool) throws -> Data {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        let rc = data.withUnsafeBytes { rawBuf -> Int32 in
            let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
            return czlib_inflate(ptr, data.count, rawDeflate ? 1 : 0, &outPtr, &outLen)
        }
        guard rc == 0, let outPtr else {
            if let outPtr { czlib_free(outPtr) }
            throw ZlibError.inflateFailed(rc)
        }
        defer { czlib_free(outPtr) }
        return Data(bytes: outPtr, count: outLen)
    }

    public static func gunzip(_ data: Data) throws -> Data {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        let rc = data.withUnsafeBytes { rawBuf -> Int32 in
            let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
            return czlib_gunzip(ptr, data.count, &outPtr, &outLen)
        }
        guard rc == 0, let outPtr else {
            if let outPtr { czlib_free(outPtr) }
            throw ZlibError.inflateFailed(rc)
        }
        defer { czlib_free(outPtr) }
        return Data(bytes: outPtr, count: outLen)
    }

    public static func deflate(_ data: Data, rawDeflate: Bool, level: Int32 = 6) throws -> Data {
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        let rc = data.withUnsafeBytes { rawBuf -> Int32 in
            let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
            return czlib_deflate(ptr, data.count, rawDeflate ? 1 : 0, level, &outPtr, &outLen)
        }
        guard rc == 0, let outPtr else {
            if let outPtr { czlib_free(outPtr) }
            throw ZlibError.deflateFailed(rc)
        }
        defer { czlib_free(outPtr) }
        return Data(bytes: outPtr, count: outLen)
    }

    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
            return czlib_crc32(0, ptr, data.count)
        }
    }
}
