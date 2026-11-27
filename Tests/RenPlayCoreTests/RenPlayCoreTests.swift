// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import RenPlayCore

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("renplay-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func buildRPA30Archive(entries: [(name: String, content: Data)], key: UInt32 = 0x1234_5678) throws -> Data {
    var body = Data("RPA-3.0 0000000000000000 00000000\n".utf8)
    let headerLen = body.count

    var pickle = Data([0x80, 0x02, 0x7D]) // PROTO 2, EMPTY_DICT
    for item in entries {
        let off = UInt64(body.count) ^ UInt64(key)
        let len = UInt64(item.content.count) ^ UInt64(key)
        body.append(item.content)

        // Key: BINUNICODE
        let nameBytes = Data(item.name.utf8)
        pickle.append(0x58)
        pickle.appendUInt32LE(UInt32(nameBytes.count))
        pickle.append(nameBytes)

        // Value: [(off, len, b"")]
        pickle.append(0x5D) // EMPTY_LIST
        pickle.append(0x28) // MARK
        // INT/LONG off
        pickle.append(0x8A) // LONG1
        pickle.append(8)
        var offLE = off.littleEndian
        withUnsafeBytes(of: &offLE) { pickle.append(contentsOf: $0) }
        // LONG1 len
        pickle.append(0x8A)
        pickle.append(8)
        var lenLE = len.littleEndian
        withUnsafeBytes(of: &lenLE) { pickle.append(contentsOf: $0) }
        // SHORT_BINBYTES ""
        pickle.append(0x43)
        pickle.append(0)
        pickle.append(0x87) // TUPLE3
        pickle.append(0x61) // APPEND
        pickle.append(0x73) // SETITEM
    }
    pickle.append(0x2E) // STOP

    let indexOffset = UInt64(body.count)
    let compressedIndex = try ZlibCodec.deflate(pickle, rawDeflate: false)
    body.append(compressedIndex)

    let headerStr = String(format: "RPA-3.0 %016llx %08x\n", indexOffset, key)
    precondition(headerStr.utf8.count == headerLen)
    body.replaceSubrange(0..<headerLen, with: Data(headerStr.utf8))
    return body
}

@Suite("EngineDetector & EngineSelector Tests")
struct EngineDetectorTests {
    @Test("Detects vc_version.py and script_version.txt accurately")
    func detectVcVersionAndScriptVersion() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let renpyDir = dir.appendingPathComponent("renpy", isDirectory: true)
        try FileManager.default.createDirectory(at: renpyDir, withIntermediateDirectories: true)
        try "version_tuple = (8, 3, 7, 25031702)\n".write(
            to: renpyDir.appendingPathComponent("vc_version.py"),
            atomically: true,
            encoding: .utf8
        )

        let detected = RenPyVersionDetector.detectVersion(in: dir)
        #expect(detected?.version == SemVer(major: 8, minor: 3, patch: 7))
        #expect(detected?.source == .vcVersionPy)

        let dir2 = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir2) }
        try "7.8.7\n".write(
            to: dir2.appendingPathComponent("script_version.txt"),
            atomically: true,
            encoding: .utf8
        )
        let det2 = RenPyVersionDetector.detectVersion(in: dir2)
        #expect(det2?.version == SemVer(major: 7, minor: 8, patch: 7))
        #expect(det2?.source == .scriptVersionTxt)
    }

    @Test("Selects within same major for accurate and latest strategies")
    func selectEngineWithinMajor() {
        let engines = [
            EngineInfo(id: "7.8.7", version: "7.8.7", frameworkName: "renpy7_8_7", pythonVersion: "2.7", sdlVersion: "SDL2", engineArchive: "7.8.7.zip"),
            EngineInfo(id: "8.3.7", version: "8.3.7", frameworkName: "renpy8_3_7", pythonVersion: "3.9", sdlVersion: "SDL2", engineArchive: "8.3.7.zip"),
            EngineInfo(id: "8.4.1", version: "8.4.1", frameworkName: "renpy8_4_1", pythonVersion: "3.12", sdlVersion: "SDL2", engineArchive: "8.4.1.zip"),
            EngineInfo(id: "8.6.1", version: "8.6.1", frameworkName: "renpy8_6_1", pythonVersion: "3.12", sdlVersion: "SDL3", engineArchive: "8.6.1.zip"),
        ]

        let det834 = DetectedVersion(version: SemVer(major: 8, minor: 3, patch: 4), source: .vcVersionPy)
        #expect(EngineSelector.selectEngine(detected: det834, available: engines, strategy: .accurate)?.version == "8.3.7")
        #expect(EngineSelector.selectEngine(detected: det834, available: engines, strategy: .latest)?.version == "8.6.1")

        let det753 = DetectedVersion(version: SemVer(major: 7, minor: 5, patch: 3), source: .scriptVersionTxt)
        #expect(EngineSelector.selectEngine(detected: det753, available: engines, strategy: .accurate)?.version == "7.8.7")
        #expect(EngineSelector.selectEngine(detected: det753, available: engines, strategy: .latest)?.version == "7.8.7")
    }
}

@Suite("RPAArchive Tests")
struct RPAArchiveTests {
    @Test("Reads XOR-obfuscated RPA-3.0 index and extracts entries")
    func parseAndReadRPA30() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let imgPayload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let txtPayload = Data("hello renpy world".utf8)
        let rpaData = try buildRPA30Archive(entries: [
            ("gui/main_menu.png", imgPayload),
            ("scripts/intro.txt", txtPayload),
        ])
        let rpaURL = dir.appendingPathComponent("archive.rpa")
        try rpaData.write(to: rpaURL)

        let archive = try RPAArchive(fileURL: rpaURL)
        #expect(archive.version == "RPA-3.0")
        #expect(archive.listEntries() == ["gui/main_menu.png", "scripts/intro.txt"])
        #expect(try archive.readEntry("gui/main_menu.png") == imgPayload)
        #expect(try archive.readEntry("scripts/intro.txt") == txtPayload)
    }
}

@Suite("ArchiveExtractor Tests")
struct ArchiveExtractorTests {
    @Test("Round-trips ZIP creation and extraction")
    func zipRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("test.zip")
        let files = [
            ("game/script.rpy", Data("label start:\n    \"Hi\"\n".utf8)),
            ("game/gui/icon.bin", Data(repeating: 0xAB, count: 4096)),
        ]
        try ArchiveExtractor.createZip(fromFiles: files, to: zipURL)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try ArchiveExtractor.extractZip(at: zipURL, to: outDir)

        let script = try Data(contentsOf: outDir.appendingPathComponent("game/script.rpy"))
        #expect(script == files[0].1)
        let icon = try Data(contentsOf: outDir.appendingPathComponent("game/gui/icon.bin"))
        #expect(icon == files[1].1)
    }

    @Test("Extracts Ren'Py APK assets and strips x- prefix")
    func extractRenPyAPK() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let apkURL = dir.appendingPathComponent("game.apk")
        try ArchiveExtractor.createZip(
            fromFiles: [
                ("assets/x-game/x-script.rpyc", Data("RPYC".utf8)),
                ("assets/x-renpy/x-vc_version.py", Data("version_tuple = (8, 5, 3, 1)\n".utf8)),
                ("classes.dex", Data("DEX".utf8)),
            ],
            to: apkURL
        )

        let outDir = dir.appendingPathComponent("extracted", isDirectory: true)
        try ArchiveExtractor.extractRenPyAPK(at: apkURL, to: outDir)

        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("game/script.rpyc").path))
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("renpy/vc_version.py").path))
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("classes.dex").path))
    }

    @Test("Rejects path traversal in archive entry names")
    func rejectTraversal() {
        #expect(throws: ArchiveError.self) {
            _ = try ArchiveExtractor.sanitizeRelativePath("../etc/passwd")
        }
        #expect(throws: ArchiveError.self) {
            _ = try ArchiveExtractor.sanitizeRelativePath("/abs/path")
        }
    }

    @Test("Extracts ZIP64 and Zstandard method 93 ZIP entries without full RAM buffering")
    func zip64AndZstdZip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("modern_z64.zip")
        let scriptText = String(repeating: "label start:\n    \"Modern ZIP64 + Zstd test payload.\"\n", count: 64)
        let rawData = Data(scriptText.utf8)
        let zstdCompressed = try ZlibCodec.zstdCompress(rawData)
        let nameData = Data("game/script.rpy".utf8)
        let crc = ZlibCodec.crc32(rawData)

        var archive = Data()
        let localOffset = UInt64(archive.count)
        // Local file header using ZIP64 sentinel sizes
        var localZ64Extra = Data()
        localZ64Extra.appendUInt16LE(0x0001)
        localZ64Extra.appendUInt16LE(16)
        localZ64Extra.appendUInt64LE(UInt64(rawData.count))
        localZ64Extra.appendUInt64LE(UInt64(zstdCompressed.count))

        archive.appendUInt32LE(0x04034B50)
        archive.appendUInt16LE(45)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(93) // Zstandard
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt32LE(crc)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt16LE(UInt16(nameData.count))
        archive.appendUInt16LE(UInt16(localZ64Extra.count))
        archive.append(nameData)
        archive.append(localZ64Extra)
        archive.append(zstdCompressed)

        let cdOffset = UInt64(archive.count)
        var cdZ64Extra = Data()
        cdZ64Extra.appendUInt16LE(0x0001)
        cdZ64Extra.appendUInt16LE(24)
        cdZ64Extra.appendUInt64LE(UInt64(rawData.count))
        cdZ64Extra.appendUInt64LE(UInt64(zstdCompressed.count))
        cdZ64Extra.appendUInt64LE(localOffset)

        archive.appendUInt32LE(0x02014B50)
        archive.appendUInt16LE(45)
        archive.appendUInt16LE(45)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(93) // Zstandard
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt32LE(crc)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt16LE(UInt16(nameData.count))
        archive.appendUInt16LE(UInt16(cdZ64Extra.count))
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt32LE(0)
        archive.appendUInt32LE(UInt32.max)
        archive.append(nameData)
        archive.append(cdZ64Extra)

        let cdSize = UInt64(archive.count) - cdOffset
        let zip64EOCDOffset = UInt64(archive.count)

        // ZIP64 End of Central Directory Record (56 bytes)
        archive.appendUInt32LE(0x06064B50)
        archive.appendUInt64LE(44)
        archive.appendUInt16LE(45)
        archive.appendUInt16LE(45)
        archive.appendUInt32LE(0)
        archive.appendUInt32LE(0)
        archive.appendUInt64LE(1)
        archive.appendUInt64LE(1)
        archive.appendUInt64LE(cdSize)
        archive.appendUInt64LE(cdOffset)

        // ZIP64 End of Central Directory Locator (20 bytes)
        archive.appendUInt32LE(0x07064B50)
        archive.appendUInt32LE(0)
        archive.appendUInt64LE(zip64EOCDOffset)
        archive.appendUInt32LE(1)

        // Classic EOCD (22 bytes)
        archive.appendUInt32LE(0x06054B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16.max)
        archive.appendUInt16LE(UInt16.max)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt32LE(UInt32.max)
        archive.appendUInt16LE(0)

        try archive.write(to: zipURL)

        let listed = try ArchiveExtractor.listZipEntries(at: zipURL)
        #expect(listed.count == 1)
        #expect(listed[0].compressionMethod == 93)
        #expect(listed[0].uncompressedSize == UInt64(rawData.count))
        #expect(try ArchiveExtractor.readZipEntry(named: "game/script.rpy", from: zipURL) == rawData)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try ArchiveExtractor.extractArchive(at: zipURL, to: outDir)
        let extracted = try Data(contentsOf: outDir.appendingPathComponent("game/script.rpy"))
        #expect(extracted == rawData)
    }

    @Test("Rejects encrypted ZIP archives cleanly")
    func rejectEncryptedZip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("encrypted.zip")
        try ArchiveExtractor.createZip(fromFiles: [("game/script.rpy", Data("secret".utf8))], to: zipURL)
        var bytes = try Data(contentsOf: zipURL)
        // Flip bit 0 (encrypted) in both local header flags (+6) and central directory flags.
        bytes[6] |= 0x01
        if let cdIdx = bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound {
            bytes[cdIdx + 8] |= 0x01
        }
        try bytes.write(to: zipURL)

        #expect(throws: ArchiveError.encryptedArchive) {
            try ArchiveExtractor.extractZip(at: zipURL, to: dir.appendingPathComponent("out"))
        }
    }

    @Test("Extracts modern tar variants (.tar.xz, .tar.zst, .tar.bz2) and solid LZMA2+BCJ2 .7z")
    func extractModernHeavilyCompressedArchives() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcRoot = dir.appendingPathComponent("src_root", isDirectory: true)
        let gameDir = srcRoot.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let expectedScript = Data(repeating: 0x41, count: 4096) + Data("\nlabel start:\n    \"Compressed\"\n".utf8)
        try expectedScript.write(to: gameDir.appendingPathComponent("script.rpy"))
        try "8.5.3\n".write(to: srcRoot.appendingPathComponent("script_version.txt"), atomically: true, encoding: .utf8)

        let tarFormats: [(ext: String, flag: String)] = [
            ("tar.xz", "-J"),
            ("tar.bz2", "-j"),
            ("tar.zst", "--zstd"),
        ]
        for fmt in tarFormats {
            let arcURL = dir.appendingPathComponent("NovelTitle.\(fmt.ext)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = [fmt.flag, "-cf", arcURL.path, "-C", srcRoot.path, "."]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)

            let outDir = dir.appendingPathComponent("out-\(fmt.ext)", isDirectory: true)
            try ArchiveExtractor.extractArchive(at: arcURL, to: outDir)
            let actual = try Data(contentsOf: outDir.appendingPathComponent("game/script.rpy"))
            #expect(actual == expectedScript)
            #expect(ArchiveExtractor.stripArchiveExtension(from: arcURL.lastPathComponent) == "NovelTitle")
        }

        let sevenZPath = ["/home/singh/bin/7z", "/usr/bin/7z", "/usr/bin/7zz"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let sevenZPath {
            if let exeData = try? Data(contentsOf: URL(fileURLWithPath: "/bin/ls")) {
                try exeData.write(to: srcRoot.appendingPathComponent("Game.exe"))
            }
            let sevenZURL = dir.appendingPathComponent("Novel7z.7z")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sevenZPath)
            p.currentDirectoryURL = srcRoot
            p.arguments = ["a", "-t7z", "-mx=9", "-ms=on", "-mf=BCJ2", sevenZURL.path, "."]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)

            let outDir = dir.appendingPathComponent("out-7z", isDirectory: true)
            try ArchiveExtractor.extractArchive(at: sevenZURL, to: outDir)
            let actual = try Data(contentsOf: outDir.appendingPathComponent("game/script.rpy"))
            #expect(actual == expectedScript)
        }
    }
}

@Suite("SaveManager & LibraryStore Tests")
struct SaveAndLibraryTests {
    @Test("Parses .save slots, creates rotated backups, and installs demo game")
    func saveManagerAndDemo() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LibraryStore(rootDir: dir)
        let demo = try store.installSmokeTestGame()
        #expect(demo.displayName == "RenPlay Demo")
        #expect(demo.detectedEngineVersion == "8.5.3")

        let saveDir = store.saveDirectory(for: demo)
        let backupDir = store.backupDirectory(for: demo)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let saveFile = saveDir.appendingPathComponent("1-1.save")
        try ArchiveExtractor.createZip(
            fromFiles: [
                ("screenshot.png", Data([0x89, 0x50, 0x4E, 0x47])),
                ("extra_info", Data("Chapter 1: Arrival".utf8)),
            ],
            to: saveFile
        )
        try Data("PERSIST".utf8).write(to: saveDir.appendingPathComponent("persistent"))

        let sm = SaveManager()
        let slots = sm.listSaves(in: saveDir)
        #expect(slots.count == 2)
        let manual = slots.first { $0.filename == "1-1.save" }
        #expect(manual?.kind == .manual)
        #expect(manual?.extraInfo == "Chapter 1: Arrival")
        #expect(manual?.screenshotData == Data([0x89, 0x50, 0x4E, 0x47]))

        let backup = try sm.createBackup(of: saveDir, to: backupDir, maxBackups: 2)
        #expect(backup != nil)
        #expect(sm.listBackups(in: backupDir).count == 1)
    }

    @Test("Seeds visible Documents folder and auto-imports dropzone archives and folders")
    func dropzoneScanAndImport() throws {
        let docsDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: docsDir) }

        let store = LibraryStore(rootDir: docsDir.appendingPathComponent("RenPlay", isDirectory: true))
        store.seedVisibleDocumentsFolderIfNeeded(documentsDir: docsDir)
        #expect(FileManager.default.fileExists(atPath: docsDir.appendingPathComponent("HOW_TO_IMPORT.txt").path))

        let inboxDir = docsDir.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let zipDrop = inboxDir.appendingPathComponent("DropArchive.zip")
        try ArchiveExtractor.createZip(
            fromFiles: [
                ("game/script.rpy", Data("label start:\n    \"Hi\"\n".utf8)),
                ("script_version.txt", Data("8.3.7\n".utf8)),
            ],
            to: zipDrop
        )

        let folderDrop = store.importDropzoneDir.appendingPathComponent("DropFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderDrop.appendingPathComponent("game", isDirectory: true), withIntermediateDirectories: true)
        try Data("label start:\n    \"Hi\"\n".utf8).write(to: folderDrop.appendingPathComponent("game/script.rpy"))
        try "8.5.3\n".write(to: folderDrop.appendingPathComponent("script_version.txt"), atomically: true, encoding: .utf8)

        let count = try store.scanAndImportDropzones(additionalDirs: [docsDir, inboxDir])
        #expect(count == 2)
        #expect(!FileManager.default.fileExists(atPath: zipDrop.path))
        #expect(!FileManager.default.fileExists(atPath: folderDrop.path))

        let games = try store.syncWithDisk()
        #expect(games.count == 2)
        #expect(games.contains(where: { $0.displayName == "DropArchive" && $0.detectedEngineVersion == "8.3.7" }))
        #expect(games.contains(where: { $0.displayName == "DropFolder" && $0.detectedEngineVersion == "8.5.3" }))
    }
}
