// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct EngineManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var engines: [EngineInfo]

    public init(schemaVersion: Int = 1, engines: [EngineInfo]) {
        self.schemaVersion = schemaVersion
        self.engines = engines
    }
}

public struct EngineInfo: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var version: String
    public var releaseTag: String
    public var frameworkName: String
    public var pythonVersion: String
    public var sdlVersion: String
    public var engineArchive: String
    public var frameworkSha256: String?
    public var engineSha256: String?

    public init(
        id: String,
        version: String,
        releaseTag: String = "",
        frameworkName: String,
        pythonVersion: String,
        sdlVersion: String,
        engineArchive: String,
        frameworkSha256: String? = nil,
        engineSha256: String? = nil
    ) {
        self.id = id
        self.version = version
        self.releaseTag = releaseTag
        self.frameworkName = frameworkName
        self.pythonVersion = pythonVersion
        self.sdlVersion = sdlVersion
        self.engineArchive = engineArchive
        self.frameworkSha256 = frameworkSha256
        self.engineSha256 = engineSha256
    }
}

public struct SemVer: Comparable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count >= 3 ? parts[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum EngineSelectionStrategy: String, Codable, Sendable, CaseIterable {
    case accurate
    case latest
}

public enum EngineMode: Codable, Sendable, Hashable {
    case auto
    case pinned(String)
}

public enum GameOrientation: String, Codable, Sendable, CaseIterable {
    case auto
    case landscape
    case portrait
}

public struct GameSettings: Codable, Sendable, Hashable {
    public var orientation: GameOrientation
    public var allowNetwork: Bool
    public var developerMode: Bool
    public var forceRollback: Bool
    public var forceSkip: Bool
    public var lowMemoryMode: Bool
    public var engineMode: EngineMode

    public init(
        orientation: GameOrientation = .auto,
        allowNetwork: Bool = false,
        developerMode: Bool = false,
        forceRollback: Bool = true,
        forceSkip: Bool = true,
        lowMemoryMode: Bool = false,
        engineMode: EngineMode = .auto
    ) {
        self.orientation = orientation
        self.allowNetwork = allowNetwork
        self.developerMode = developerMode
        self.forceRollback = forceRollback
        self.forceSkip = forceSkip
        self.lowMemoryMode = lowMemoryMode
        self.engineMode = engineMode
    }
}

public struct SMBServerProfile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String
    public var isGuest: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 445,
        username: String = "",
        domain: String = "",
        isGuest: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.isGuest = isGuest
        self.createdAt = createdAt
    }
}

public struct SMBGameSource: Codable, Sendable, Equatable, Hashable {
    public var serverID: UUID
    public var host: String
    public var port: Int
    public var share: String
    public var remotePath: String
    public var username: String
    public var domain: String
    public var isGuest: Bool
    public var lastSyncedAt: Date

    public init(
        serverID: UUID,
        host: String,
        port: Int = 445,
        share: String,
        remotePath: String,
        username: String = "",
        domain: String = "",
        isGuest: Bool = true,
        lastSyncedAt: Date = Date()
    ) {
        self.serverID = serverID
        self.host = host
        self.port = port
        self.share = share
        self.remotePath = remotePath
        self.username = username
        self.domain = domain
        self.isGuest = isGuest
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct GameEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var displayName: String
    public var folderName: String
    public var detectedEngineVersion: String?
    public var coverRelativePath: String?
    public var importedAt: Date
    public var lastPlayedAt: Date?
    public var playTimeSeconds: TimeInterval
    public var settings: GameSettings
    public var remoteSource: SMBGameSource?

    public init(
        id: UUID = UUID(),
        displayName: String,
        folderName: String,
        detectedEngineVersion: String? = nil,
        coverRelativePath: String? = nil,
        importedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        playTimeSeconds: TimeInterval = 0,
        settings: GameSettings = GameSettings(),
        remoteSource: SMBGameSource? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.folderName = folderName
        self.detectedEngineVersion = detectedEngineVersion
        self.coverRelativePath = coverRelativePath
        self.importedAt = importedAt
        self.lastPlayedAt = lastPlayedAt
        self.playTimeSeconds = playTimeSeconds
        self.settings = settings
        self.remoteSource = remoteSource
    }
}

public enum SaveKind: String, Codable, Sendable, Hashable {
    case manual
    case quick
    case auto
    case persistent
}

public struct SaveSlot: Identifiable, Sendable, Hashable {
    public var id: String { filename }
    public var filename: String
    public var kind: SaveKind
    public var slotLabel: String
    public var modifiedAt: Date
    public var fileSize: Int64
    public var extraInfo: String?
    public var screenshotData: Data?

    public init(
        filename: String,
        kind: SaveKind,
        slotLabel: String,
        modifiedAt: Date,
        fileSize: Int64,
        extraInfo: String? = nil,
        screenshotData: Data? = nil
    ) {
        self.filename = filename
        self.kind = kind
        self.slotLabel = slotLabel
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.extraInfo = extraInfo
        self.screenshotData = screenshotData
    }
}

public struct BackupEntry: Identifiable, Sendable, Hashable {
    public var id: String { url.lastPathComponent }
    public var url: URL
    public var createdAt: Date
    public var fileSize: Int64

    public init(url: URL, createdAt: Date, fileSize: Int64) {
        self.url = url
        self.createdAt = createdAt
        self.fileSize = fileSize
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var defaultEngineStrategy: EngineSelectionStrategy
    public var autoBackupCount: Int
    public var showOverlayByDefault: Bool
    public var overlayOpacity: Double
    public var globalAllowNetwork: Bool

    public init(
        defaultEngineStrategy: EngineSelectionStrategy = .accurate,
        autoBackupCount: Int = 5,
        showOverlayByDefault: Bool = true,
        overlayOpacity: Double = 0.85,
        globalAllowNetwork: Bool = false
    ) {
        self.defaultEngineStrategy = defaultEngineStrategy
        self.autoBackupCount = autoBackupCount
        self.showOverlayByDefault = showOverlayByDefault
        self.overlayOpacity = overlayOpacity
        self.globalAllowNetwork = globalAllowNetwork
    }
}
