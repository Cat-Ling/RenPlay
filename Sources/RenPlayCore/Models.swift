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

public enum GameCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case red
    case blue
    case green
    case purple
    case pink
    case yellow

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .yellow: return "Yellow"
        }
    }

    public var hexColor: UInt32 {
        switch self {
        case .red: return 0xFF453A
        case .blue: return 0x0A84FF
        case .green: return 0x30D158
        case .purple: return 0xBF5AF2
        case .pink: return 0xFF375F
        case .yellow: return 0xFFD60A
        }
    }
}

public enum LibraryLayoutMode: String, Codable, Sendable, CaseIterable {
    case list
    case grid
}

public enum ScreenRotationPreference: String, Codable, Sendable, CaseIterable {
    case global
    case auto
    case landscape
    case landscapeLeft
    case landscapeRight
    case portrait

    public var displayName: String {
        switch self {
        case .global: return "Global"
        case .auto: return "All"
        case .landscape: return "Landscape"
        case .landscapeLeft: return "Landscape Left"
        case .landscapeRight: return "Landscape Right"
        case .portrait: return "Portrait"
        }
    }
}

public struct GameSettings: Codable, Sendable, Hashable {
    public var orientation: GameOrientation
    public var allowNetwork: Bool
    public var developerMode: Bool
    public var forceRollback: Bool
    public var forceSkip: Bool
    public var lowMemoryMode: Bool
    public var engineMode: EngineMode
    public var useGlobalSettings: Bool
    public var safeMode: Bool
    public var screenRotation: ScreenRotationPreference
    public var enableConsole: Bool
    public var lessScreenUpdates: Bool
    public var forceUnseenSkip: Bool
    public var transparentTextboxes: Bool
    public var compatibilityPatches: Bool
    public var overrideDeviceVariant: Bool
    public var selectedVariants: [String]
    public var showTitleWithArtwork: Bool
    public var customAccentHex: String?

    public init(
        orientation: GameOrientation = .auto,
        allowNetwork: Bool = false,
        developerMode: Bool = false,
        forceRollback: Bool = true,
        forceSkip: Bool = true,
        lowMemoryMode: Bool = false,
        engineMode: EngineMode = .auto,
        useGlobalSettings: Bool = true,
        safeMode: Bool = false,
        screenRotation: ScreenRotationPreference = .global,
        enableConsole: Bool = false,
        lessScreenUpdates: Bool = false,
        forceUnseenSkip: Bool = false,
        transparentTextboxes: Bool = false,
        compatibilityPatches: Bool = true,
        overrideDeviceVariant: Bool = false,
        selectedVariants: [String] = [],
        showTitleWithArtwork: Bool = true,
        customAccentHex: String? = nil
    ) {
        self.orientation = orientation
        self.allowNetwork = allowNetwork
        self.developerMode = developerMode
        self.forceRollback = forceRollback
        self.forceSkip = forceSkip
        self.lowMemoryMode = lowMemoryMode
        self.engineMode = engineMode
        self.useGlobalSettings = useGlobalSettings
        self.safeMode = safeMode
        self.screenRotation = screenRotation
        self.enableConsole = enableConsole
        self.lessScreenUpdates = lessScreenUpdates
        self.forceUnseenSkip = forceUnseenSkip
        self.transparentTextboxes = transparentTextboxes
        self.compatibilityPatches = compatibilityPatches
        self.overrideDeviceVariant = overrideDeviceVariant
        self.selectedVariants = selectedVariants
        self.showTitleWithArtwork = showTitleWithArtwork
        self.customAccentHex = customAccentHex
    }

    // Custom Codable keeps older library.json entries decodable without migrating on disk.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try c.decodeIfPresent(GameOrientation.self, forKey: .orientation) ?? .auto
        allowNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        forceRollback = try c.decodeIfPresent(Bool.self, forKey: .forceRollback) ?? true
        forceSkip = try c.decodeIfPresent(Bool.self, forKey: .forceSkip) ?? true
        lowMemoryMode = try c.decodeIfPresent(Bool.self, forKey: .lowMemoryMode) ?? false
        engineMode = try c.decodeIfPresent(EngineMode.self, forKey: .engineMode) ?? .auto
        useGlobalSettings = try c.decodeIfPresent(Bool.self, forKey: .useGlobalSettings) ?? true
        safeMode = try c.decodeIfPresent(Bool.self, forKey: .safeMode) ?? false
        screenRotation = try c.decodeIfPresent(ScreenRotationPreference.self, forKey: .screenRotation) ?? .global
        enableConsole = try c.decodeIfPresent(Bool.self, forKey: .enableConsole) ?? false
        lessScreenUpdates = try c.decodeIfPresent(Bool.self, forKey: .lessScreenUpdates) ?? false
        forceUnseenSkip = try c.decodeIfPresent(Bool.self, forKey: .forceUnseenSkip) ?? false
        transparentTextboxes = try c.decodeIfPresent(Bool.self, forKey: .transparentTextboxes) ?? false
        compatibilityPatches = try c.decodeIfPresent(Bool.self, forKey: .compatibilityPatches) ?? true
        overrideDeviceVariant = try c.decodeIfPresent(Bool.self, forKey: .overrideDeviceVariant) ?? false
        selectedVariants = try c.decodeIfPresent([String].self, forKey: .selectedVariants) ?? []
        showTitleWithArtwork = try c.decodeIfPresent(Bool.self, forKey: .showTitleWithArtwork) ?? true
        customAccentHex = try c.decodeIfPresent(String.self, forKey: .customAccentHex)
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
    // Name of the Saves/ and Backups/ subfolder; nil keeps the legacy id-based folder.
    public var saveIdentifier: String?
    public var gameVersion: String?
    public var category: GameCategory?
    public var customCoverPath: String?
    public var customHeroPath: String?
    public var sizeBytes: Int64?
    public var dialogueSeenCount: Int?
    public var dialogueTotalCount: Int?

    public var dialogueProgressFraction: Double? {
        guard let seen = dialogueSeenCount, let total = dialogueTotalCount, total > 0 else { return nil }
        return min(1.0, max(0.0, Double(seen) / Double(total)))
    }

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
        remoteSource: SMBGameSource? = nil,
        saveIdentifier: String? = nil,
        gameVersion: String? = nil,
        category: GameCategory? = nil,
        customCoverPath: String? = nil,
        customHeroPath: String? = nil,
        sizeBytes: Int64? = nil,
        dialogueSeenCount: Int? = nil,
        dialogueTotalCount: Int? = nil
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
        self.saveIdentifier = saveIdentifier
        self.gameVersion = gameVersion
        self.category = category
        self.customCoverPath = customCoverPath
        self.customHeroPath = customHeroPath
        self.sizeBytes = sizeBytes
        self.dialogueSeenCount = dialogueSeenCount
        self.dialogueTotalCount = dialogueTotalCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        folderName = try c.decode(String.self, forKey: .folderName)
        detectedEngineVersion = try c.decodeIfPresent(String.self, forKey: .detectedEngineVersion)
        coverRelativePath = try c.decodeIfPresent(String.self, forKey: .coverRelativePath)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playTimeSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .playTimeSeconds) ?? 0
        settings = try c.decodeIfPresent(GameSettings.self, forKey: .settings) ?? GameSettings()
        remoteSource = try c.decodeIfPresent(SMBGameSource.self, forKey: .remoteSource)
        saveIdentifier = try c.decodeIfPresent(String.self, forKey: .saveIdentifier)
        gameVersion = try c.decodeIfPresent(String.self, forKey: .gameVersion)
        category = try c.decodeIfPresent(GameCategory.self, forKey: .category)
        customCoverPath = try c.decodeIfPresent(String.self, forKey: .customCoverPath)
        customHeroPath = try c.decodeIfPresent(String.self, forKey: .customHeroPath)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        dialogueSeenCount = try c.decodeIfPresent(Int.self, forKey: .dialogueSeenCount)
        dialogueTotalCount = try c.decodeIfPresent(Int.self, forKey: .dialogueTotalCount)
    }
}

public struct SaveFolderSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let slotCount: Int
    public let backupCount: Int
    public let sizeBytes: Int64
    public let modifiedAt: Date
    public let linkedGameID: UUID?
    public let linkedGameTitle: String?

    public init(
        id: String,
        displayName: String,
        slotCount: Int,
        backupCount: Int = 0,
        sizeBytes: Int64,
        modifiedAt: Date,
        linkedGameID: UUID? = nil,
        linkedGameTitle: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.slotCount = slotCount
        self.backupCount = backupCount
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.linkedGameID = linkedGameID
        self.linkedGameTitle = linkedGameTitle
    }
}

public struct SharedPersistentItem: Identifiable, Sendable, Hashable {
    public var id: String { filename }
    public let filename: String
    public let sizeBytes: Int64
    public let modifiedAt: Date

    public init(filename: String, sizeBytes: Int64, modifiedAt: Date) {
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct StorageBreakdown: Sendable {
    public struct GameUsage: Identifiable, Sendable {
        public var id: UUID { game.id }
        public let title: String
        public let isRemote: Bool
        public let bytes: Int64
        public let game: GameEntry

        public init(title: String, isRemote: Bool, bytes: Int64, game: GameEntry) {
            self.title = title
            self.isRemote = isRemote
            self.bytes = bytes
            self.game = game
        }
    }

    public let games: [GameUsage]
    public let totalGamesBytes: Int64
    public let savesBytes: Int64
    public let backupsBytes: Int64
    public let exportsBytes: Int64
    public let engineCacheBytes: Int64

    public var totalBytes: Int64 {
        totalGamesBytes + savesBytes + backupsBytes + exportsBytes + engineCacheBytes
    }

    public init(
        games: [GameUsage],
        totalGamesBytes: Int64,
        savesBytes: Int64,
        backupsBytes: Int64,
        exportsBytes: Int64,
        engineCacheBytes: Int64
    ) {
        self.games = games
        self.totalGamesBytes = totalGamesBytes
        self.savesBytes = savesBytes
        self.backupsBytes = backupsBytes
        self.exportsBytes = exportsBytes
        self.engineCacheBytes = engineCacheBytes
    }
}

// Saves kept after their game was removed from the library.
public struct OrphanedSaveGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let slotCount: Int
    public let modifiedAt: Date

    public init(id: String, displayName: String, slotCount: Int, modifiedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.slotCount = slotCount
        self.modifiedAt = modifiedAt
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

    public var renpySlotName: String? {
        guard kind != .persistent else { return nil }
        if filename.lowercased().hasSuffix(".save") {
            return String(filename.dropLast(5))
        }
        return filename
    }

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
    public var libraryLayoutMode: LibraryLayoutMode
    public var defaultRotation: GameOrientation
    public var renpyMasterVolume: Double
    public var globalDeveloperMode: Bool
    public var globalEnableConsole: Bool
    public var globalLowMemory: Bool
    public var globalLessUpdates: Bool
    public var globalForceRollback: Bool
    public var globalForceSkip: Bool
    public var globalForceUnseenSkip: Bool
    public var globalTransparentTextboxes: Bool
    public var globalCompatibilityPatches: Bool
    public var globalOverrideVariant: Bool
    public var globalSelectedVariants: [String]
    public var showFPSOverlay: Bool
    public var showQuickBar: Bool
    public var virtualMouseSpeed: Double

    private enum CodingKeys: String, CodingKey {
        case defaultEngineStrategy
        case autoBackupCount
        case showOverlayByDefault
        case overlayOpacity
        case globalAllowNetwork
        case libraryLayoutMode
        case defaultRotation
        case renpyMasterVolume
        case globalDeveloperMode
        case globalEnableConsole
        case globalLowMemory
        case globalLessUpdates
        case globalForceRollback
        case globalForceSkip
        case globalForceUnseenSkip
        case globalTransparentTextboxes
        case globalCompatibilityPatches
        case globalOverrideVariant
        case globalSelectedVariants
        case showFPSOverlay
        case showQuickBar = "quickBarVisibleByDefault"
        case virtualMouseSpeed
    }

    public init(
        defaultEngineStrategy: EngineSelectionStrategy = .accurate,
        autoBackupCount: Int = 5,
        showOverlayByDefault: Bool = true,
        overlayOpacity: Double = 0.85,
        globalAllowNetwork: Bool = false,
        libraryLayoutMode: LibraryLayoutMode = .list,
        defaultRotation: GameOrientation = .auto,
        renpyMasterVolume: Double = 1.0,
        globalDeveloperMode: Bool = false,
        globalEnableConsole: Bool = false,
        globalLowMemory: Bool = false,
        globalLessUpdates: Bool = false,
        globalForceRollback: Bool = true,
        globalForceSkip: Bool = true,
        globalForceUnseenSkip: Bool = false,
        globalTransparentTextboxes: Bool = false,
        globalCompatibilityPatches: Bool = true,
        globalOverrideVariant: Bool = false,
        globalSelectedVariants: [String] = [],
        showFPSOverlay: Bool = false,
        showQuickBar: Bool = false,
        virtualMouseSpeed: Double = 1.0
    ) {
        self.defaultEngineStrategy = defaultEngineStrategy
        self.autoBackupCount = autoBackupCount
        self.showOverlayByDefault = showOverlayByDefault
        self.overlayOpacity = overlayOpacity
        self.globalAllowNetwork = globalAllowNetwork
        self.libraryLayoutMode = libraryLayoutMode
        self.defaultRotation = defaultRotation
        self.renpyMasterVolume = renpyMasterVolume
        self.globalDeveloperMode = globalDeveloperMode
        self.globalEnableConsole = globalEnableConsole
        self.globalLowMemory = globalLowMemory
        self.globalLessUpdates = globalLessUpdates
        self.globalForceRollback = globalForceRollback
        self.globalForceSkip = globalForceSkip
        self.globalForceUnseenSkip = globalForceUnseenSkip
        self.globalTransparentTextboxes = globalTransparentTextboxes
        self.globalCompatibilityPatches = globalCompatibilityPatches
        self.globalOverrideVariant = globalOverrideVariant
        self.globalSelectedVariants = globalSelectedVariants
        self.showFPSOverlay = showFPSOverlay
        self.showQuickBar = showQuickBar
        self.virtualMouseSpeed = virtualMouseSpeed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultEngineStrategy = try c.decodeIfPresent(EngineSelectionStrategy.self, forKey: .defaultEngineStrategy) ?? .accurate
        autoBackupCount = try c.decodeIfPresent(Int.self, forKey: .autoBackupCount) ?? 5
        showOverlayByDefault = try c.decodeIfPresent(Bool.self, forKey: .showOverlayByDefault) ?? true
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? 0.85
        globalAllowNetwork = try c.decodeIfPresent(Bool.self, forKey: .globalAllowNetwork) ?? false
        libraryLayoutMode = try c.decodeIfPresent(LibraryLayoutMode.self, forKey: .libraryLayoutMode) ?? .list
        defaultRotation = try c.decodeIfPresent(GameOrientation.self, forKey: .defaultRotation) ?? .auto
        renpyMasterVolume = try c.decodeIfPresent(Double.self, forKey: .renpyMasterVolume) ?? 1.0
        globalDeveloperMode = try c.decodeIfPresent(Bool.self, forKey: .globalDeveloperMode) ?? false
        globalEnableConsole = try c.decodeIfPresent(Bool.self, forKey: .globalEnableConsole) ?? false
        globalLowMemory = try c.decodeIfPresent(Bool.self, forKey: .globalLowMemory) ?? false
        globalLessUpdates = try c.decodeIfPresent(Bool.self, forKey: .globalLessUpdates) ?? false
        globalForceRollback = try c.decodeIfPresent(Bool.self, forKey: .globalForceRollback) ?? true
        globalForceSkip = try c.decodeIfPresent(Bool.self, forKey: .globalForceSkip) ?? true
        globalForceUnseenSkip = try c.decodeIfPresent(Bool.self, forKey: .globalForceUnseenSkip) ?? false
        globalTransparentTextboxes = try c.decodeIfPresent(Bool.self, forKey: .globalTransparentTextboxes) ?? false
        globalCompatibilityPatches = try c.decodeIfPresent(Bool.self, forKey: .globalCompatibilityPatches) ?? true
        globalOverrideVariant = try c.decodeIfPresent(Bool.self, forKey: .globalOverrideVariant) ?? false
        globalSelectedVariants = try c.decodeIfPresent([String].self, forKey: .globalSelectedVariants) ?? []
        showFPSOverlay = try c.decodeIfPresent(Bool.self, forKey: .showFPSOverlay) ?? false
        showQuickBar = try c.decodeIfPresent(Bool.self, forKey: .showQuickBar) ?? false
        virtualMouseSpeed = try c.decodeIfPresent(Double.self, forKey: .virtualMouseSpeed) ?? 1.0
    }
}
