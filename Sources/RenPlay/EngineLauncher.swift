// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import CRenPlayBridge
import Darwin
import Foundation
import RenPlayCore
import SwiftUI
import UIKit

public enum LaunchError: Error, LocalizedError, Sendable {
    case missingEngineArchive(String)
    case missingFramework(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingEngineArchive(let name):
            return "Bundled engine archive missing: \(name)"
        case .missingFramework(let name):
            return "Bundled engine framework missing: \(name)"
        case .engineFailure(let detail):
            return detail
        }
    }
}

@MainActor
public final class EngineLauncher {
    private let libraryStore: LibraryStore
    private let saveManager: SaveManager
    private var overlayWindow: GameOverlayWindow?
    private var overlayPollTimer: Timer?

    public init(libraryStore: LibraryStore, saveManager: SaveManager) {
        self.libraryStore = libraryStore
        self.saveManager = saveManager
    }

    public var cachedEnginesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("RenPlay/Engines", isDirectory: true)
    }

    public func clearEngineCache() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedEnginesDirectory.path) {
            try fm.removeItem(at: cachedEnginesDirectory)
        }
    }

    public func engineCacheSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cachedEnginesDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        return total
    }

    public func launch(
        game: GameEntry,
        engine: EngineInfo,
        appSettings: AppSettings,
        autoloadSlot: String? = nil,
        statusUpdate: @escaping @Sendable (String) -> Void,
        onFailure: @MainActor @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let engineRoot = cachedEnginesDirectory.appendingPathComponent(engine.version, isDirectory: true)
        let cacheStamp = engine.engineSha256 ?? engine.releaseTag
        let markerURL = engineRoot.appendingPathComponent(".ready_\(cacheStamp)")

        if !fm.fileExists(atPath: markerURL.path) {
            let zipName = engine.engineArchive.replacingOccurrences(of: ".zip", with: "")
            guard let zipURL = Bundle.main.url(forResource: zipName, withExtension: "zip", subdirectory: "Engines") else {
                throw LaunchError.missingEngineArchive(engine.engineArchive)
            }
            statusUpdate("Unpacking Ren'Py \(engine.version) runtime...")
            try await Task.detached(priority: .userInitiated) {
                let localFM = FileManager.default
                try? localFM.removeItem(at: engineRoot)
                try ArchiveExtractor.extractZip(at: zipURL, to: engineRoot)
                try Data("ok".utf8).write(to: markerURL, options: .atomic)
            }.value
        }

        try Self.syncRuntimeOverrides(into: engineRoot)

        let fwSubpath = "Frameworks/\(engine.frameworkName).framework/\(engine.frameworkName)"
        let fwURL = Bundle.main.bundleURL.appendingPathComponent(fwSubpath)
        guard fm.fileExists(atPath: fwURL.path) else {
            throw LaunchError.missingFramework("\(engine.frameworkName).framework")
        }

        let gameDir = libraryStore.gameDirectory(for: game)
        let saveDir = libraryStore.saveDirectory(for: game)
        let backupDir = libraryStore.backupDirectory(for: game)
        let logDir = libraryStore.logDirectory(for: game)
        let multipersistentDir = libraryStore.multipersistentDir
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: multipersistentDir, withIntermediateDirectories: true)

        if appSettings.autoBackupCount > 0 {
            statusUpdate("Backing up saves...")
            _ = try? saveManager.createBackup(of: saveDir, to: backupDir, maxBackups: appSettings.autoBackupCount)
        }

        statusUpdate("Starting \(game.displayName)...")

        if let remote = game.remoteSource {
            statusUpdate("Connecting to \(remote.host)/\(remote.share)...")
            let password = libraryStore.smbPassword(for: remote.serverID)
            let connectError: String? = await Task.detached(priority: .userInitiated) {
                var errBuf = [CChar](repeating: 0, count: 512)
                let rc: Int32 = remote.host.withCString { cHost in
                    remote.share.withCString { cShare in
                        remote.remotePath.withCString { cBase in
                            remote.username.withCString { cUser in
                                password.withCString { cPass in
                                    remote.domain.withCString { cDomain in
                                        renplay_configure_smb_mount(
                                            cHost,
                                            Int32(remote.port),
                                            cShare,
                                            cBase,
                                            cUser,
                                            cPass,
                                            cDomain,
                                            remote.isGuest ? 1 : 0,
                                            &errBuf,
                                            errBuf.count
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                if rc < 0 {
                    let bytes = errBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    let msg = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return msg.isEmpty ? "SMB connection failed (error \(rc))." : msg
                }
                return nil
            }.value
            if let connectError {
                throw LaunchError.engineFailure("Unable to mount network share: \(connectError)")
            }
        } else {
            renplay_clear_smb_mount()
        }

        let useGlobal = game.settings.useGlobalSettings
        let safeMode = game.settings.safeMode
        let overrideVariants = !safeMode && (useGlobal ? appSettings.globalOverrideVariant : game.settings.overrideDeviceVariant)
        let selectedVariants = useGlobal ? appSettings.globalSelectedVariants : game.settings.selectedVariants

        let orientationMode = Self.resolvedOrientationMode(game: game, appSettings: appSettings)
        renplay_set_preferred_orientation(orientationMode)

        let variant: String
        if overrideVariants && !selectedVariants.isEmpty {
            variant = selectedVariants.joined(separator: " ")
        } else {
            switch orientationMode {
            case 3:
                variant = "portrait touch"
            case 1, 2, 4:
                variant = "touch"
            default:
                variant = UIDevice.current.userInterfaceIdiom == .pad ? "tablet touch" : "phone touch"
            }
        }

        let sdlVersion = engine.sdlVersion.uppercased().contains("3") ? 3 : 2
        let allowNetwork = (game.settings.allowNetwork || appSettings.globalAllowNetwork) ? 1 : 0
        let devMode = (!safeMode && (useGlobal ? appSettings.globalDeveloperMode : game.settings.developerMode)) ? 1 : 0
        let enableConsole = (!safeMode && (useGlobal ? appSettings.globalEnableConsole : game.settings.enableConsole)) ? 1 : 0
        let forceRollback = (!safeMode && (useGlobal ? appSettings.globalForceRollback : game.settings.forceRollback)) ? 1 : 0
        let forceSkip = (!safeMode && (useGlobal ? appSettings.globalForceSkip : game.settings.forceSkip)) ? 1 : 0
        let forceUnseenSkip = (!safeMode && (useGlobal ? appSettings.globalForceUnseenSkip : game.settings.forceUnseenSkip)) ? 1 : 0
        let lessMemory = (safeMode || (useGlobal ? appSettings.globalLowMemory : game.settings.lowMemoryMode)) ? 1 : 0
        let lessUpdates = (useGlobal ? appSettings.globalLessUpdates : game.settings.lessScreenUpdates) ? 1 : 0
        let transparentTextboxes = (!safeMode && (useGlobal ? appSettings.globalTransparentTextboxes : game.settings.transparentTextboxes)) ? 1 : 0
        let compatPatches = (!safeMode && (useGlobal ? appSettings.globalCompatibilityPatches : game.settings.compatibilityPatches)) ? 1 : 0
        let showOverlay = appSettings.showOverlayByDefault
        let overlayOpacity = appSettings.overlayOpacity
        let showFPS = appSettings.showFPSOverlay
        let showQuickBar = appSettings.showQuickBar
        let mouseSpeed = appSettings.virtualMouseSpeed
        let initialVolume = appSettings.renpyMasterVolume
        let gameTitle = game.displayName

        // Schedule engine launch on CFRunLoop rather than GCD main queue so XPC keyboard and UIKit
        // main-queue work continue draining while SDL pumps CFRunLoop during gameplay.
        let launchTimer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                renplay_capture_window_scene()
                var savedWindows: [(UIWindow, UIViewController?)] = []
                for scene in UIApplication.shared.connectedScenes {
                    guard let ws = scene as? UIWindowScene else { continue }
                    for win in ws.windows where win !== self.overlayWindow {
                        savedWindows.append((win, win.rootViewController))
                        win.rootViewController = nil
                        win.isHidden = true
                    }
                }

                if showOverlay {
                    self.overlayPollTimer?.invalidate()
                    let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] timer in
                        guard let self else {
                            timer.invalidate()
                            return
                        }
                        if renplay_has_sdl_window() != 0 {
                            timer.invalidate()
                            MainActor.assumeIsolated {
                                self.overlayPollTimer = nil
                                self.installOverlay(
                                    gameID: game.id,
                                    gameName: gameTitle,
                                    logDir: logDir,
                                    opacity: overlayOpacity,
                                    initialVolume: initialVolume,
                                    showFPS: showFPS,
                                    showQuickBar: showQuickBar,
                                    mouseSpeed: mouseSpeed,
                                    initialTransparentTextboxes: transparentTextboxes != 0,
                                    initialVariants: variant.split(separator: " ").map(String.init)
                                )
                            }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    self.overlayPollTimer = timer
                }

                var errBuf = [CChar](repeating: 0, count: 1024)
                let rc = renplay_launch_engine(
                    fwURL.path,
                    engineRoot.path,
                    gameDir.path,
                    saveDir.path,
                    logDir.path,
                    multipersistentDir.path,
                    variant,
                    autoloadSlot ?? "",
                    Int32(sdlVersion),
                    Int32(allowNetwork),
                    Int32(devMode),
                    Int32(enableConsole),
                    Int32(forceRollback),
                    Int32(forceSkip),
                    Int32(forceUnseenSkip),
                    Int32(lessMemory),
                    Int32(lessUpdates),
                    Int32(transparentTextboxes),
                    Int32(compatPatches),
                    Int32(safeMode ? 1 : 0),
                    initialVolume,
                    &errBuf,
                    errBuf.count
                )

                self.overlayPollTimer?.invalidate()
                self.overlayPollTimer = nil
                self.removeOverlay()
                renplay_set_preferred_orientation(0)
                if rc == 0 {
                    fflush(nil)
                    Darwin._exit(0)
                }

                for (win, rootVC) in savedWindows {
                    win.rootViewController = rootVC
                    win.isHidden = false
                    win.makeKeyAndVisible()
                }

                let utf8Bytes = errBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                let msg = String(decoding: utf8Bytes, as: UTF8.self)
                onFailure(msg.isEmpty ? "Engine exited with code \(rc). Check Session Logs for details." : msg)
            }
        }
        RunLoop.main.add(launchTimer, forMode: .common)
    }

    private static func resolvedOrientationMode(game: GameEntry, appSettings: AppSettings) -> Int32 {
        switch game.settings.screenRotation {
        case .landscapeLeft: return 1
        case .landscapeRight: return 2
        case .portrait: return 3
        case .landscape: return 4
        case .auto: return 0
        case .global:
            let effective = game.settings.orientation == .auto ? appSettings.defaultRotation : game.settings.orientation
            switch effective {
            case .landscape: return 4
            case .portrait: return 3
            case .auto: return 0
            }
        }
    }

    private func installOverlay(
        gameID: UUID,
        gameName: String,
        logDir: URL,
        opacity: Double,
        initialVolume: Double,
        showFPS: Bool,
        showQuickBar: Bool,
        mouseSpeed: Double,
        initialTransparentTextboxes: Bool,
        initialVariants: [String]
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        let store = self.libraryStore
        let win = GameOverlayWindow(
            windowScene: scene,
            gameID: gameID,
            gameName: gameName,
            logDir: logDir,
            opacity: opacity,
            initialVolume: initialVolume,
            showFPS: showFPS,
            showQuickBar: showQuickBar,
            mouseSpeed: mouseSpeed,
            initialTransparentTextboxes: initialTransparentTextboxes,
            initialVariants: initialVariants,
            onPersistSettings: { newOpacity, newFPS, newQuickBar, newMouseSpeed in
                var current = store.loadSettings()
                current.overlayOpacity = newOpacity
                current.showFPSOverlay = newFPS
                current.showQuickBar = newQuickBar
                current.virtualMouseSpeed = newMouseSpeed
                try? store.saveSettings(current)
            }
        )
        win.isHidden = false
        self.overlayWindow = win
    }

    private func removeOverlay() {
        overlayPollTimer?.invalidate()
        overlayPollTimer = nil
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }

    // Keep cached and bundled engine packs in sync with RenPlay's periodic command bridge without waiting for an engine rebuild.
    private static func syncRuntimeOverrides(into engineRoot: URL) throws {
        let fm = FileManager.default
        let baseDir = engineRoot.appendingPathComponent("base", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: baseDir.appendingPathComponent("main.pyc"))
        try? fm.removeItem(at: baseDir.appendingPathComponent("__pycache__"))
        try engineMainScript.write(to: baseDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

        let commonDir = baseDir.appendingPathComponent("renpy/common", isDirectory: true)
        try fm.createDirectory(at: commonDir, withIntermediateDirectories: true)
        let targetURL = commonDir.appendingPathComponent("99renplay_overrides.rpy")
        for stale in ["99renplay_overrides.rpyc", "99renplay_overrides.rpyb"] {
            try? fm.removeItem(at: commonDir.appendingPathComponent(stale))
        }
        try runtimeOverridesScript.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    private static let engineMainScript = #"""
    # SPDX-FileCopyrightText: 2026 RenPlay Contributors
    # SPDX-License-Identifier: GPL-3.0-or-later
    #
    # Launch entrypoint for embedded Ren'Py 7.x (Python 2.7) and 8.x (Python 3.x)
    # runtimes inside RenPlay on iOS.

    from __future__ import print_function, absolute_import

    import os
    import socket
    import sys
    import warnings

    os.system = lambda cmd: 0

    _ALLOW_NETWORK = os.environ.get("RENPY_ALLOW_NETWORK", "0") == "1"
    if not _ALLOW_NETWORK:
        _orig_connect = socket.socket.connect

        def _blocked_connect(self, address, *args, **kwargs):
            host = address[0] if isinstance(address, tuple) and len(address) > 0 else ""
            if host in ("127.0.0.1", "::1", "localhost"):
                return _orig_connect(self, address, *args, **kwargs)
            raise socket.error("Network access disabled by RenPlay")

        socket.socket.connect = _blocked_connect

    _GAME_ROOT = os.environ.get("RENPY_GAME_DIRECTORY", "")
    if _GAME_ROOT and os.path.isdir(_GAME_ROOT):
        os.chdir(_GAME_ROOT)

    _orig_expanduser = os.path.expanduser


    def _ios_expanduser(path):
        if path.startswith("~"):
            base = _GAME_ROOT if _GAME_ROOT else os.getcwd()
            rest = path[1:].lstrip("/\\")
            return os.path.join(base, rest) if rest else base
        return _orig_expanduser(path)


    os.path.expanduser = _ios_expanduser


    def path_to_gamedir(basedir, name):
        if _GAME_ROOT:
            candidate = os.path.join(_GAME_ROOT, "game")
            if os.path.isdir(candidate):
                return candidate
            if os.path.isdir(_GAME_ROOT):
                return _GAME_ROOT

        for sub in (name, "game", "data", "launcher/game"):
            if sub == "renpy":
                continue
            candidate = os.path.join(basedir, sub)
            if os.path.isdir(candidate):
                return candidate

        return basedir


    def path_to_common(renpy_base):
        common = os.path.join(renpy_base, "renpy", "common")
        if os.path.isdir(common):
            return common
        return None


    def path_to_saves(gamedir, save_directory=None):
        override = os.environ.get("RENPY_SAVE_DIRECTORY", "")
        if override:
            if not os.path.isdir(override):
                try:
                    os.makedirs(override)
                except OSError:
                    pass
            return override

        fallback = os.path.join(gamedir, "saves")
        if not os.path.isdir(fallback):
            try:
                os.makedirs(fallback)
            except OSError:
                pass
        return fallback


    def path_to_logdir(basedir):
        override = os.environ.get("RENPY_LOG_DIRECTORY", "")
        if override:
            if not os.path.isdir(override):
                try:
                    os.makedirs(override)
                except OSError:
                    pass
            return override
        return basedir


    _MP_DIR = os.environ.get("RENPY_MULTIPERSISTENT", "")
    if _MP_DIR and not os.path.isdir(_MP_DIR):
        try:
            os.makedirs(_MP_DIR)
        except OSError:
            pass


    _SMB_HOOK_INSTALLED = False


    def _install_renplay_smb_loader(renpy_mod):
        global _SMB_HOOK_INSTALLED
        if _SMB_HOOK_INSTALLED:
            return
        _SMB_HOOK_INSTALLED = True

        candidates = []
        if _GAME_ROOT:
            candidates.append(os.path.join(_GAME_ROOT, ".renplay_smb_index.tsv"))
        gamedir = getattr(renpy_mod.config, "gamedir", "")
        if gamedir:
            candidates.append(os.path.join(gamedir, ".renplay_smb_index.tsv"))
            candidates.append(os.path.join(os.path.dirname(gamedir), ".renplay_smb_index.tsv"))

        manifest_path = None
        for cand in candidates:
            if cand and os.path.isfile(cand):
                manifest_path = cand
                break
        if manifest_path is None:
            return

        import ctypes
        import io
        import unicodedata

        ssize_t = getattr(ctypes, "c_ssize_t", ctypes.c_long)
        pread_fn = None
        try:
            proc = ctypes.CDLL(None)
            fn = getattr(proc, "renplay_smb_pread", None)
            if fn is not None:
                fn.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
                fn.restype = ssize_t
                pread_fn = fn
        except Exception:
            pread_fn = None

        if pread_fn is None:
            try:
                import pyobjus
                bridge = pyobjus.autoclass("RenPlayRuntimeBridge")
                addr = int(bridge.smbPreadSymbolAddress())
                if addr:
                    cft = ctypes.CFUNCTYPE(
                        ssize_t,
                        ctypes.c_char_p,
                        ctypes.c_uint64,
                        ctypes.c_void_p,
                        ctypes.c_size_t,
                    )
                    pread_fn = cft(addr)
            except Exception:
                pread_fn = None

        if pread_fn is None:
            print("RenPlay SMB loader warning: renplay_smb_pread symbol unavailable")
            return

        entries = {}
        entries_lower = {}
        logical_list = []

        try:
            with io.open(manifest_path, "r", encoding="utf-8") as fp:
                for raw_line in fp:
                    line = raw_line.rstrip("\r\n")
                    if not line or line.startswith("#"):
                        continue
                    cols = line.split("\t")
                    if len(cols) < 4:
                        continue
                    kind, logical, smb_rel, spec = cols[0], cols[1], cols[2], cols[3]
                    smb_rel_bytes = smb_rel.encode("utf-8") if not isinstance(smb_rel, bytes) else smb_rel
                    if kind == "L":
                        size = int(spec)
                        record = [(smb_rel_bytes, 0, size, b"")]
                        total_size = size
                    elif kind == "R":
                        segs = []
                        total_size = 0
                        for part in spec.split(";"):
                            if not part:
                                continue
                            pfields = part.split(":")
                            if len(pfields) < 2:
                                continue
                            off = int(pfields[0])
                            body_len = int(pfields[1])
                            hex_prefix = pfields[2] if len(pfields) >= 3 else ""
                            if hex_prefix:
                                if hasattr(bytes, "fromhex"):
                                    prefix = bytes.fromhex(hex_prefix)
                                else:
                                    prefix = hex_prefix.decode("hex")
                            else:
                                prefix = b""
                            segs.append((smb_rel_bytes, off, body_len, prefix))
                            total_size += len(prefix) + body_len
                        if not segs:
                            continue
                        record = segs
                    else:
                        continue

                    if logical not in entries:
                        logical_list.append(logical)
                    entries[logical] = (record, total_size)
                    entries_lower[unicodedata.normalize("NFC", logical.lower())] = logical
        except Exception as exc:
            print("RenPlay SMB manifest parse error:", exc)
            return

        loader = renpy_mod.loader
        buffer_factory = getattr(loader, "RWopsIO", None)
        io_buffer_cls = None
        if buffer_factory is None:
            try:
                from renpy.pygame.iostream import IOBuffer as _IOBuffer
                io_buffer_cls = _IOBuffer
            except Exception:
                io_buffer_cls = None

        def _smb_pread_exact(rel_bytes, offset, length):
            if length <= 0:
                return b""
            buf = ctypes.create_string_buffer(length)
            got_total = 0
            base_ptr = ctypes.addressof(buf)
            while got_total < length:
                n = pread_fn(rel_bytes, offset + got_total, base_ptr + got_total, length - got_total)
                if n <= 0:
                    break
                got_total += int(n)
            if got_total == length:
                return buf.raw
            return buf.raw[:got_total]

        def _wrap_memory_stream(data, name):
            if buffer_factory is not None:
                return io.BufferedReader(buffer_factory.from_buffer(data, name=name))
            if io_buffer_cls is not None:
                return io.BufferedReader(io_buffer_cls(data, name=name))
            return io.BytesIO(data)

        class _RenPlaySMBRawIO(io.RawIOBase):
            def __init__(self, name, segments, total_size):
                self.name = name
                self._segments = segments
                self._total_size = total_size
                self._pos = 0
                self._closed = False

            def readable(self):
                return True

            def seekable(self):
                return True

            def writable(self):
                return False

            def tell(self):
                return self._pos

            def seek(self, offset, whence=0):
                if whence == 0:
                    new_pos = offset
                elif whence == 1:
                    new_pos = self._pos + offset
                elif whence == 2:
                    new_pos = self._total_size + offset
                else:
                    raise ValueError("Invalid whence")
                if new_pos < 0:
                    new_pos = 0
                self._pos = new_pos
                return self._pos

            def read(self, size=-1):
                if self._closed or self._pos >= self._total_size:
                    return b""
                if size is None or size < 0:
                    want = self._total_size - self._pos
                else:
                    want = min(size, self._total_size - self._pos)
                if want <= 0:
                    return b""

                chunks = []
                cur_voff = 0
                target_start = self._pos
                target_end = self._pos + want

                for rel_bytes, smb_off, body_len, prefix in self._segments:
                    plen = len(prefix)
                    if plen > 0:
                        p_start = cur_voff
                        p_end = p_start + plen
                        ov_start = max(p_start, target_start)
                        ov_end = min(p_end, target_end)
                        if ov_end > ov_start:
                            chunks.append(prefix[ov_start - p_start : ov_end - p_start])
                        cur_voff = p_end

                    if body_len > 0:
                        b_start = cur_voff
                        b_end = b_start + body_len
                        ov_start = max(b_start, target_start)
                        ov_end = min(b_end, target_end)
                        if ov_end > ov_start:
                            read_off = smb_off + (ov_start - b_start)
                            data = _smb_pread_exact(rel_bytes, read_off, ov_end - ov_start)
                            chunks.append(data)
                        cur_voff = b_end

                    if cur_voff >= target_end:
                        break

                joined = b"".join(chunks)
                self._pos += len(joined)
                return joined

            def readinto(self, b):
                data = self.read(len(b))
                n = len(data)
                if n > 0:
                    view = memoryview(b)
                    view[:n] = data
                return n

            def close(self):
                self._closed = True
                super(_RenPlaySMBRawIO, self).close()

        def _renplay_scandirfiles_smb(add, seen):
            files = loader.game_files
            lower_map = loader.lower_map
            for logical in logical_list:
                add(None, logical, files, seen)
                norm_key = unicodedata.normalize("NFC", logical.lower())
                if norm_key not in lower_map:
                    lower_map[norm_key] = logical

        def _renplay_load_from_smb(name):
            item = entries.get(name)
            canonical = name
            if item is None:
                mapped = entries_lower.get(unicodedata.normalize("NFC", name.lower()))
                if mapped is not None:
                    canonical = mapped
                    item = entries.get(mapped)
            if item is None:
                return None

            segments, total_size = item
            if total_size <= 4 * 1024 * 1024:
                parts = []
                for rel_bytes, smb_off, body_len, prefix in segments:
                    if prefix:
                        parts.append(prefix)
                    if body_len > 0:
                        parts.append(_smb_pread_exact(rel_bytes, smb_off, body_len))
                return _wrap_memory_stream(b"".join(parts), canonical)

            return io.BufferedReader(_RenPlaySMBRawIO(canonical, segments, total_size))

        _orig_loadable_core = getattr(loader, "loadable_core", None)
        if _orig_loadable_core is not None:
            def _renplay_loadable_core(name):
                norm = unicodedata.normalize("NFC", name.lower())
                if name in entries or norm in entries_lower:
                    return True
                return _orig_loadable_core(name)
            loader.loadable_core = _renplay_loadable_core

        loader.scandirfiles_callbacks.append(_renplay_scandirfiles_smb)
        loader.file_open_callbacks.append(_renplay_load_from_smb)


    def predefined_searchpath(commondir):
        import renpy

        _install_renplay_smb_loader(renpy)

        searchpath = [renpy.config.gamedir]
        if "RENPY_SEARCHPATH" in os.environ:
            searchpath.extend(os.environ["RENPY_SEARCHPATH"].split("::"))
        if commondir and os.path.isdir(commondir):
            searchpath.append(commondir)
        return searchpath


    android = False
    renpy_base = os.path.dirname(os.path.abspath(__file__))
    if renpy_base not in sys.path:
        sys.path.append(renpy_base)

    warnings.simplefilter("ignore", DeprecationWarning)

    if os.environ.get("RENPY_COMPAT_PATCHES") == "1" and os.environ.get("RENPY_SAFE_MODE") != "1":
        if not hasattr(os, "startfile"):
            os.startfile = lambda *args, **kwargs: None
        try:
            import ctypes as _compat_ctypes
            if not hasattr(_compat_ctypes, "windll"):
                class _DummyWinFunc(object):
                    def __init__(self, dll_name, fn_name):
                        self._dll_name = dll_name
                        self._fn_name = fn_name
                    def __call__(self, *args, **kwargs):
                        if self._dll_name == "user32" and self._fn_name == "GetSystemMetrics":
                            idx = args[0] if args else 0
                            return 1920 if idx == 0 else (1080 if idx == 1 else 0)
                        return 0
                class _DummyWinLib(object):
                    def __init__(self, dll_name):
                        self._dll_name = dll_name
                    def __getattr__(self, fn_name):
                        return _DummyWinFunc(self._dll_name, fn_name)
                class _DummyWinDLL(object):
                    def __getattr__(self, dll_name):
                        return _DummyWinLib(dll_name.lower())
                _compat_ctypes.windll = _DummyWinDLL()
        except Exception:
            pass

    import renpy.bootstrap

    renpy.__main__ = sys.modules[__name__]


    if __name__ == "__main__":
        try:
            renpy.bootstrap.bootstrap(renpy_base)
        except SystemExit as exc:
            print("RenPlay engine exited with status:", exc.code)
    """#

    private static let runtimeOverridesScript = #"""
    # SPDX-FileCopyrightText: 2026 RenPlay Contributors
    # SPDX-License-Identifier: GPL-3.0-or-later
    #
    # Loaded from renpy/common after game options.rpy so RenPlay runtime toggles,
    # native iOS keyboard/mouse hooks, variable tools, and HUD commands apply across 7.x and 8.x.

    init 999 python:
        import ctypes as _renplay_ctypes
        import json as _renplay_json
        import os as _renplay_os
        import sys as _renplay_sys
        import time as _renplay_time
        import uuid as _renplay_uuid

        _renplay_safe_mode = _renplay_os.environ.get("RENPY_SAFE_MODE") == "1"

        def _renplay_clear_autoload():
            _renplay_os.environ.pop("RENPY_AUTO_LOAD", None)

        try:
            if _renplay_clear_autoload not in config.after_load_callbacks:
                config.after_load_callbacks.append(_renplay_clear_autoload)
        except Exception:
            pass

        if _renplay_safe_mode:
            try:
                config.image_cache_size_mb = 64
                config.gl_powersave = True
                config.predict_statements = 0
                config.autoreload = False
            except Exception:
                pass
        else:
            if _renplay_os.environ.get("RENPY_DEV_MODE") == "1":
                config.developer = True
            if _renplay_os.environ.get("RENPY_ENABLE_CONSOLE") == "1":
                config.console = True
            if _renplay_os.environ.get("RENPY_FORCE_ROLLBACK") == "1":
                config.rollback_enabled = True
                if getattr(config, "hard_rollback_limit", 0) < 256:
                    config.hard_rollback_limit = 256
            if _renplay_os.environ.get("RENPY_FORCE_SKIP") == "1":
                config.allow_skipping = True
                config.skip_indicator = True
            if _renplay_os.environ.get("RENPY_FORCE_UNSEEN_SKIP") == "1":
                preferences.skip_unseen = True

            if _renplay_os.environ.get("RENPY_COMPAT_PATCHES") == "1":
                try:
                    config.autoreload = False
                    config.quit_on_mobile_background = False
                except Exception:
                    pass
                if not hasattr(_renplay_os, "startfile"):
                    _renplay_os.startfile = lambda *args, **kwargs: None
                if not hasattr(_renplay_ctypes, "windll"):
                    class _RenPlayWinFunc(object):
                        def __init__(self, dll_name, fn_name):
                            self._dll_name = dll_name
                            self._fn_name = fn_name
                        def __call__(self, *args, **kwargs):
                            if self._dll_name == "user32" and self._fn_name == "GetSystemMetrics":
                                idx = args[0] if args else 0
                                if idx == 0:
                                    return int(getattr(config, "screen_width", 1920) or 1920)
                                if idx == 1:
                                    return int(getattr(config, "screen_height", 1080) or 1080)
                            return 0
                    class _RenPlayWinLib(object):
                        def __init__(self, dll_name):
                            self._dll_name = dll_name
                        def __getattr__(self, fn_name):
                            return _RenPlayWinFunc(self._dll_name, fn_name)
                    class _RenPlayWinDLL(object):
                        def __getattr__(self, dll_name):
                            return _RenPlayWinLib(dll_name.lower())
                    _renplay_ctypes.windll = _RenPlayWinDLL()
                try:
                    _loader = renpy.loader
                    if not getattr(_loader, "_renplay_compat_hooked", False):
                        _str_types = (str, type(u""))
                        _orig_load = getattr(_loader, "load", None)
                        _orig_loadable = getattr(_loader, "loadable", None)
                        if _orig_load is not None:
                            def _renplay_norm_load(name, *args, **kwargs):
                                if isinstance(name, _str_types) and "\\" in name:
                                    name = name.replace("\\", "/")
                                return _orig_load(name, *args, **kwargs)
                            _loader.load = _renplay_norm_load
                        if _orig_loadable is not None:
                            def _renplay_norm_loadable(name, *args, **kwargs):
                                if isinstance(name, _str_types) and "\\" in name:
                                    name = name.replace("\\", "/")
                                return _orig_loadable(name, *args, **kwargs)
                            _loader.loadable = _renplay_norm_loadable
                        _loader._renplay_compat_hooked = True
                except Exception:
                    pass

        try:
            _vol_str = _renplay_os.environ.get("RENPY_MASTER_VOLUME", "")
            if _vol_str:
                _vol_val = max(0.0, min(1.0, float(_vol_str)))
                if hasattr(preferences, "set_volume"):
                    preferences.set_volume("main", _vol_val)
                elif hasattr(preferences, "volumes") and isinstance(preferences.volumes, dict):
                    preferences.volumes["main"] = _vol_val
        except Exception:
            pass

        _renplay_saved_textbox_bg = {}

        def _renplay_apply_transparent_textbox(enabled):
            try:
                for _sname in ("say_window", "window"):
                    _st = getattr(style, _sname, None)
                    if _st is None:
                        continue
                    if enabled:
                        if _sname not in _renplay_saved_textbox_bg:
                            try:
                                _renplay_saved_textbox_bg[_sname] = _st.background
                            except Exception:
                                _renplay_saved_textbox_bg[_sname] = None
                        _st.background = Solid((0, 0, 0, 96))
                    elif _sname in _renplay_saved_textbox_bg:
                        _st.background = _renplay_saved_textbox_bg[_sname]
                try:
                    if enabled:
                        preferences.text_box_opacity = 0.35
                    elif hasattr(preferences, "text_box_opacity"):
                        preferences.text_box_opacity = 1.0
                except Exception:
                    pass
                renpy.exports.restart_interaction()
            except Exception:
                pass

        if not _renplay_safe_mode and _renplay_os.environ.get("RENPY_TRANSPARENT_TEXTBOX") == "1":
            _renplay_apply_transparent_textbox(True)

        _renplay_c_consume_cmd = None
        _renplay_c_start_input = None
        _renplay_c_stop_input = None
        _renplay_c_is_shown = None
        _renplay_c_reopen = None
        _renplay_c_consume_key = None
        _renplay_c_report_stats = None
        _renplay_c_consume_mouse = None
        _renplay_c_consume_rpc = None
        _renplay_c_post_rpc_reply = None

        try:
            _renplay_self_lib = _renplay_ctypes.CDLL(None)
            _renplay_c_consume_cmd = _renplay_self_lib.renplay_bridge_consume_command
            _renplay_c_consume_cmd.argtypes = []
            _renplay_c_consume_cmd.restype = _renplay_ctypes.c_int

            _renplay_c_start_input = _renplay_self_lib.renplay_bridge_start_text_input
            _renplay_c_start_input.argtypes = []
            _renplay_c_start_input.restype = None

            _renplay_c_stop_input = _renplay_self_lib.renplay_bridge_stop_text_input
            _renplay_c_stop_input.argtypes = []
            _renplay_c_stop_input.restype = None

            _renplay_c_is_shown = _renplay_self_lib.renplay_bridge_is_keyboard_shown
            _renplay_c_is_shown.argtypes = []
            _renplay_c_is_shown.restype = _renplay_ctypes.c_int

            _renplay_c_reopen = _renplay_self_lib.renplay_bridge_reopen_if_active
            _renplay_c_reopen.argtypes = []
            _renplay_c_reopen.restype = None

            _renplay_c_consume_key = _renplay_self_lib.renplay_bridge_consume_key_event
            _renplay_c_consume_key.argtypes = [_renplay_ctypes.c_char_p, _renplay_ctypes.c_size_t]
            _renplay_c_consume_key.restype = _renplay_ctypes.c_int

            _renplay_c_report_stats = getattr(_renplay_self_lib, "renplay_bridge_report_stats", None)
            if _renplay_c_report_stats is not None:
                _renplay_c_report_stats.argtypes = [_renplay_ctypes.c_int, _renplay_ctypes.c_int]
                _renplay_c_report_stats.restype = None

            _renplay_c_consume_mouse = getattr(_renplay_self_lib, "renplay_bridge_consume_mouse_event", None)
            if _renplay_c_consume_mouse is not None:
                _renplay_c_consume_mouse.argtypes = [
                    _renplay_ctypes.POINTER(_renplay_ctypes.c_float),
                    _renplay_ctypes.POINTER(_renplay_ctypes.c_float),
                    _renplay_ctypes.POINTER(_renplay_ctypes.c_int),
                    _renplay_ctypes.POINTER(_renplay_ctypes.c_int),
                ]
                _renplay_c_consume_mouse.restype = _renplay_ctypes.c_int

            _renplay_c_consume_rpc = getattr(_renplay_self_lib, "renplay_bridge_consume_rpc", None)
            if _renplay_c_consume_rpc is not None:
                _renplay_c_consume_rpc.argtypes = [_renplay_ctypes.c_char_p, _renplay_ctypes.c_size_t]
                _renplay_c_consume_rpc.restype = _renplay_ctypes.c_int

            _renplay_c_post_rpc_reply = getattr(_renplay_self_lib, "renplay_bridge_post_rpc_reply", None)
            if _renplay_c_post_rpc_reply is not None:
                _renplay_c_post_rpc_reply.argtypes = [_renplay_ctypes.c_char_p]
                _renplay_c_post_rpc_reply.restype = None
        except Exception:
            _renplay_c_consume_cmd = None

        _renplay_pg_mods = []
        try:
            _core_pg = getattr(renpy.display.core, "pygame", None)
            if _core_pg is not None:
                _renplay_pg_mods.append(_core_pg)
        except Exception:
            pass
        for _mod_name in ("renpy.pygame", "pygame_sdl2", "pygame"):
            _m = _renplay_sys.modules.get(_mod_name)
            if _m is None:
                try:
                    _m = __import__(_mod_name, fromlist=["key", "event"])
                except Exception:
                    _m = None
            if _m is not None and _m not in _renplay_pg_mods:
                _renplay_pg_mods.append(_m)

        _renplay_pg = _renplay_pg_mods[0] if _renplay_pg_mods else None

        if _renplay_c_start_input is not None and _renplay_pg_mods:
            def _renplay_has_screen_keyboard():
                return True

            def _renplay_is_screen_keyboard_shown():
                try:
                    return int(_renplay_c_is_shown()) != 0
                except Exception:
                    return False

            def _renplay_start_text_input(*args, **kwargs):
                try:
                    _renplay_c_start_input()
                except Exception:
                    pass

            def _renplay_stop_text_input(*args, **kwargs):
                try:
                    _renplay_c_stop_input()
                except Exception:
                    pass

            for _m in _renplay_pg_mods:
                _k = getattr(_m, "key", None)
                if _k is None:
                    continue
                _k.has_screen_keyboard_support = _renplay_has_screen_keyboard
                _k.is_screen_keyboard_shown = _renplay_is_screen_keyboard_shown
                if hasattr(_k, "text_input_active"):
                    _k.text_input_active = _renplay_is_screen_keyboard_shown
                _k.start_text_input = _renplay_start_text_input
                _k.stop_text_input = _renplay_stop_text_input

            if not _renplay_safe_mode:
                try:
                    _input_cls = renpy.display.behavior.Input
                    if not getattr(_input_cls, "_renplay_hooked", False):
                        _orig_input_render = _input_cls.render
                        _orig_input_event = _input_cls.event

                        def _renplay_input_render(self, width, height, st, at):
                            rv = _orig_input_render(self, width, height, st, at)
                            try:
                                self._renplay_wh = (rv.width, rv.height)
                            except Exception:
                                pass
                            return rv

                        def _renplay_input_event(self, ev, x, y, st):
                            if _renplay_pg is not None and getattr(self, "editable", False):
                                try:
                                    if ev.type == _renplay_pg.MOUSEBUTTONDOWN and getattr(ev, "button", 1) == 1:
                                        w, h = getattr(self, "_renplay_wh", (0, 0))
                                        if w > 0 and h > 0 and 0 <= x <= w and 0 <= y <= h:
                                            _renplay_c_reopen()
                                except Exception:
                                    pass
                            return _orig_input_event(self, ev, x, y, st)

                        _input_cls.render = _renplay_input_render
                        _input_cls.event = _renplay_input_event
                        _input_cls._renplay_hooked = True
                except Exception:
                    pass

        _renplay_mod_mask = 0
        _renplay_session_id = str(_renplay_uuid.uuid4())
        _renplay_session_start = _renplay_time.time()
        _renplay_last_stats_report = 0.0
        _renplay_last_stats_flush = 0.0
        _renplay_frozen_vars = {}

        def _renplay_post_key(vk, scancode, down_unicode, mod=0):
            if _renplay_pg is None:
                return
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYDOWN,
                key=vk,
                scancode=scancode,
                unicode=down_unicode,
                mod=mod,
                repeat=False,
            ))
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYUP,
                key=vk,
                scancode=scancode,
                unicode=u"",
                mod=mod,
                repeat=False,
            ))

        def _renplay_post_rpc_reply_obj(obj):
            if _renplay_c_post_rpc_reply is None:
                return
            try:
                raw = _renplay_json.dumps(obj)
                if not isinstance(raw, bytes):
                    raw = raw.encode("utf-8")
                _renplay_c_post_rpc_reply(raw)
            except Exception:
                pass

        def _renplay_collect_dialogue_counts():
            try:
                seen = int(renpy.count_seen_dialogue_blocks())
                total = int(renpy.count_dialogue_blocks())
                return seen, total
            except Exception:
                return 0, 0

        def _renplay_write_stats_file(seen, total):
            save_dir = _renplay_os.environ.get("RENPY_SAVE_DIRECTORY", "")
            if not save_dir or not _renplay_os.path.isdir(save_dir):
                return
            payload = {
                "sessionId": _renplay_session_id,
                "elapsedSeconds": max(0.0, float(_renplay_time.time() - _renplay_session_start)),
                "seenBlocks": int(seen),
                "totalBlocks": int(total),
            }
            tmp_path = _renplay_os.path.join(save_dir, ".renplay_stats.tmp")
            dst_path = _renplay_os.path.join(save_dir, ".renplay_stats.json")
            try:
                fp = open(tmp_path, "w")
                try:
                    fp.write(_renplay_json.dumps(payload))
                finally:
                    fp.close()
                _renplay_os.rename(tmp_path, dst_path)
            except Exception:
                pass

        def _renplay_scope_object(scope_name):
            if scope_name == "persistent":
                return renpy.game.persistent
            return renpy.store

        def _renplay_var_kind_and_preview(val):
            if isinstance(val, bool):
                return "bool", ("true" if val else "false"), True
            if isinstance(val, int):
                return "int", str(val), True
            if isinstance(val, float):
                return "float", str(val), True
            if isinstance(val, type(u"")) or isinstance(val, str):
                s = str(val) if len(val) <= 120 else str(val[:120]) + "..."
                return "str", s, True
            try:
                rep = repr(val)
                if len(rep) > 120:
                    rep = rep[:120] + "..."
                return "object", rep, False
            except Exception:
                return "object", "<object>", False

        def _renplay_handle_rpc(req):
            op = req.get("op", "")
            if op == "set_volume":
                val = max(0.0, min(1.0, float(req.get("value", 1.0))))
                if hasattr(preferences, "set_volume"):
                    preferences.set_volume("main", val)
                elif hasattr(preferences, "volumes") and isinstance(preferences.volumes, dict):
                    preferences.volumes["main"] = val
                return
            if op == "set_transparent_textbox":
                _renplay_apply_transparent_textbox(bool(req.get("enabled", False)))
                return
            if op == "open_console":
                try:
                    _console.enter()
                except Exception:
                    pass
                return
            if op == "reload_script":
                try:
                    renpy.exports.reload_script()
                except Exception:
                    pass
                return
            if op == "set_variants":
                variants = req.get("variants", [])
                if isinstance(variants, list) and variants:
                    try:
                        clean_vars = [str(v) for v in variants if v]
                        config.variants = clean_vars + [None]
                        try:
                            renpy.display.touch = ("touch" in clean_vars)
                        except Exception:
                            pass
                        try:
                            renpy.style.rebuild()
                        except Exception:
                            pass
                        renpy.exports.restart_interaction()
                        _renplay_post_rpc_reply_obj({"op": "set_variants", "ok": True, "variants": clean_vars})
                    except Exception as exc:
                        _renplay_post_rpc_reply_obj({"op": "set_variants", "ok": False, "error": str(exc)})
                return
            if op == "unlock_gallery":
                try:
                    p = renpy.game.persistent
                    if getattr(p, "_seen_ever", None) is None or not isinstance(p._seen_ever, dict):
                        p._seen_ever = {}
                    for k in getattr(renpy.game.script, "namemap", {}).keys():
                        p._seen_ever[k] = True
                    if getattr(p, "_seen_images", None) is None:
                        try:
                            p._seen_images = {}
                        except Exception:
                            pass
                    imgs = getattr(renpy.display.image, "images", {})
                    if isinstance(p._seen_images, dict):
                        for ik in imgs.keys():
                            p._seen_images[ik] = True
                    elif isinstance(p._seen_images, set):
                        for ik in imgs.keys():
                            p._seen_images.add(ik)
                    _gi_cls = getattr(renpy.store, "__GalleryImage", None)
                    if _gi_cls is not None:
                        _gi_cls.check_unlock = lambda self, all_prior: True
                    _gb_cls = getattr(renpy.store, "__GalleryButton", None)
                    if _gb_cls is not None:
                        _gb_cls.check_unlock = lambda self: True
                    _rp_cls = getattr(renpy.store, "Replay", None)
                    if _rp_cls is not None:
                        _rp_cls.get_sensitive = lambda self: True
                    renpy.exports.seen_image = lambda name: True
                    renpy.exports.seen_label = lambda label: True
                    if hasattr(renpy, "seen_image"):
                        renpy.seen_image = lambda name: True
                    if hasattr(renpy, "seen_label"):
                        renpy.seen_label = lambda label: True
                    try:
                        for obj in list(renpy.store.__dict__.values()):
                            if hasattr(obj, "buttons") and hasattr(obj, "make_button"):
                                try:
                                    obj.unlocked_advance = True
                                except Exception:
                                    pass
                                for _bname, btn in getattr(obj, "buttons", {}).items():
                                    try:
                                        btn.conditions = []
                                        for _gimg in getattr(btn, "images", []):
                                            try:
                                                _gimg.conditions = []
                                            except Exception:
                                                pass
                                    except Exception:
                                        pass
                    except Exception:
                        pass
                    renpy.loadsave.save_persistent()
                    renpy.exports.restart_interaction()
                    _renplay_post_rpc_reply_obj({
                        "op": "unlock_gallery",
                        "ok": True,
                        "images": len(imgs),
                        "blocks": len(getattr(renpy.game.script, "namemap", {})),
                    })
                except Exception as exc:
                    _renplay_post_rpc_reply_obj({"op": "unlock_gallery", "ok": False, "error": str(exc)})
                return
            if op == "list_vars":
                scope = req.get("scope", "store")
                query = str(req.get("query", "")).strip().lower()
                target = _renplay_scope_object(scope)
                items = []
                skip_names = set(["persistent", "renpy", "config", "store", "preferences", "style", "build", "os", "sys"])
                raw_dict = getattr(target, "__dict__", {})
                for k in sorted(raw_dict.keys()):
                    ks = str(k)
                    if ks.startswith("_") or ks in skip_names:
                        continue
                    if query and query not in ks.lower():
                        continue
                    val = raw_dict[k]
                    if callable(val) or isinstance(val, type(_renplay_os)):
                        continue
                    kind, preview, editable = _renplay_var_kind_and_preview(val)
                    items.append({
                        "name": ks,
                        "kind": kind,
                        "value": preview,
                        "editable": editable,
                        "frozen": (scope, ks) in _renplay_frozen_vars,
                    })
                    if len(items) >= 150:
                        break
                _renplay_post_rpc_reply_obj({"op": "list_vars", "scope": scope, "items": items})
                return
            if op == "set_var":
                scope = req.get("scope", "store")
                name = str(req.get("name", ""))
                kind = str(req.get("kind", "str"))
                raw_val = str(req.get("value", ""))
                freeze = bool(req.get("freeze", False))
                target = _renplay_scope_object(scope)
                try:
                    if kind == "bool":
                        parsed = raw_val.strip().lower() in ("1", "true", "yes", "on")
                    elif kind == "int":
                        parsed = int(raw_val.strip())
                    elif kind == "float":
                        parsed = float(raw_val.strip())
                    else:
                        parsed = raw_val
                    setattr(target, name, parsed)
                    if freeze:
                        _renplay_frozen_vars[(scope, name)] = parsed
                    renpy.exports.restart_interaction()
                    _renplay_post_rpc_reply_obj({"op": "set_var", "ok": True, "name": name})
                except Exception as exc:
                    _renplay_post_rpc_reply_obj({"op": "set_var", "ok": False, "error": str(exc)})
                return
            if op == "toggle_freeze":
                scope = req.get("scope", "store")
                name = str(req.get("name", ""))
                key = (scope, name)
                if key in _renplay_frozen_vars:
                    del _renplay_frozen_vars[key]
                    frozen = False
                else:
                    target = _renplay_scope_object(scope)
                    _renplay_frozen_vars[key] = getattr(target, name, None)
                    frozen = True
                _renplay_post_rpc_reply_obj({"op": "toggle_freeze", "scope": scope, "name": name, "frozen": frozen})

        _renplay_key_buf = _renplay_ctypes.create_string_buffer(512)
        _renplay_rpc_buf = _renplay_ctypes.create_string_buffer(16384)
        _renplay_mx = _renplay_ctypes.c_float(0.0)
        _renplay_my = _renplay_ctypes.c_float(0.0)
        _renplay_mbtn = _renplay_ctypes.c_int(1)
        _renplay_mtype = _renplay_ctypes.c_int(0)

        def _renplay_poll_bridge():
            global _renplay_mod_mask, _renplay_last_stats_report, _renplay_last_stats_flush
            if _renplay_c_consume_cmd is None:
                return

            if _renplay_frozen_vars:
                for (_fscope, _fname), _fval in list(_renplay_frozen_vars.items()):
                    try:
                        setattr(_renplay_scope_object(_fscope), _fname, _fval)
                    except Exception:
                        pass

            now = _renplay_time.time()
            if _renplay_c_report_stats is not None and now - _renplay_last_stats_report >= 2.0:
                _renplay_last_stats_report = now
                seen, total = _renplay_collect_dialogue_counts()
                _renplay_c_report_stats(seen, total)
                if now - _renplay_last_stats_flush >= 10.0:
                    _renplay_last_stats_flush = now
                    _renplay_write_stats_file(seen, total)

            if _renplay_pg is not None and _renplay_c_consume_key is not None:
                try:
                    while True:
                        n = int(_renplay_c_consume_key(_renplay_key_buf, 512))
                        if n <= 0:
                            break
                        payload = _renplay_key_buf.raw[:n].decode("utf-8", "replace")
                        if payload.startswith("T:"):
                            text = payload[2:]
                            if _renplay_mod_mask != 0:
                                for ch in text:
                                    _renplay_post_key(ord(ch.lower()), 0, ch, mod=_renplay_mod_mask)
                            else:
                                try:
                                    _renplay_pg.event.set_allowed(_renplay_pg.TEXTINPUT)
                                except Exception:
                                    pass
                                _renplay_pg.event.post(_renplay_pg.event.Event(
                                    _renplay_pg.TEXTINPUT,
                                    text=text,
                                ))
                        elif payload == "K:BACKSPACE":
                            _renplay_post_key(
                                _renplay_pg.K_BACKSPACE,
                                getattr(_renplay_pg, "KSCAN_BACKSPACE", 42),
                                u"\b",
                                mod=_renplay_mod_mask,
                            )
                        elif payload == "K:RETURN":
                            _renplay_post_key(
                                _renplay_pg.K_RETURN,
                                getattr(_renplay_pg, "KSCAN_RETURN", 40),
                                u"\r",
                                mod=_renplay_mod_mask,
                            )
                        elif payload == "K:ESCAPE":
                            _renplay_post_key(
                                _renplay_pg.K_ESCAPE,
                                getattr(_renplay_pg, "KSCAN_ESCAPE", 41),
                                u"\x1b",
                                mod=_renplay_mod_mask,
                            )
                        elif payload.startswith("M:CTRL:"):
                            _ctrl = getattr(_renplay_pg, "KMOD_LCTRL", 0x0040)
                            if payload.endswith(":1"):
                                _renplay_mod_mask |= _ctrl
                            else:
                                _renplay_mod_mask &= ~_ctrl
                        elif payload.startswith("M:ALT:"):
                            _alt = getattr(_renplay_pg, "KMOD_LALT", 0x0100)
                            if payload.endswith(":1"):
                                _renplay_mod_mask |= _alt
                            else:
                                _renplay_mod_mask &= ~_alt
                except Exception:
                    pass

            if _renplay_pg is not None and _renplay_c_consume_mouse is not None:
                try:
                    pw, ph = renpy.get_physical_size()
                    while int(_renplay_c_consume_mouse(
                        _renplay_ctypes.byref(_renplay_mx),
                        _renplay_ctypes.byref(_renplay_my),
                        _renplay_ctypes.byref(_renplay_mbtn),
                        _renplay_ctypes.byref(_renplay_mtype),
                    )) != 0:
                        px = int(max(0.0, min(1.0, float(_renplay_mx.value))) * max(1, int(pw)))
                        py = int(max(0.0, min(1.0, float(_renplay_my.value))) * max(1, int(ph)))
                        etype = int(_renplay_mtype.value)
                        btn = int(_renplay_mbtn.value)
                        if etype == 0:
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.MOUSEMOTION,
                                pos=(px, py),
                                rel=(0, 0),
                                buttons=(0, 0, 0),
                            ))
                        elif etype == 1:
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.MOUSEBUTTONDOWN,
                                pos=(px, py),
                                button=btn,
                            ))
                        elif etype == 2:
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.MOUSEBUTTONUP,
                                pos=(px, py),
                                button=btn,
                            ))
                except Exception:
                    pass

            if _renplay_c_consume_rpc is not None:
                try:
                    while True:
                        rn = int(_renplay_c_consume_rpc(_renplay_rpc_buf, 16384))
                        if rn <= 0:
                            break
                        raw_req = _renplay_rpc_buf.raw[:rn].decode("utf-8", "replace")
                        _renplay_handle_rpc(_renplay_json.loads(raw_req))
                except Exception:
                    pass

            try:
                cmd = int(_renplay_c_consume_cmd())
            except Exception:
                return
            if cmd == 0:
                return
            if cmd == 10:
                seen, total = _renplay_collect_dialogue_counts()
                _renplay_write_stats_file(seen, total)
                try:
                    renpy.loadsave.save_persistent()
                except Exception:
                    pass
                try:
                    _renplay_sys.stdout.flush()
                    _renplay_sys.stderr.flush()
                except Exception:
                    pass
                _renplay_os._exit(0)
            try:
                if cmd == 1:
                    renpy.queue_event("game_menu")
                elif cmd == 2:
                    renpy.queue_event("rollback")
                elif cmd == 3:
                    renpy.queue_event("toggle_skip")
                elif cmd == 4:
                    renpy.queue_event("toggle_afm")
                elif cmd == 5:
                    renpy.queue_event("hide_windows")
                elif cmd == 6:
                    renpy.queue_event("screenshot")
                elif cmd == 7:
                    renpy.run(QuickSave())
                elif cmd == 8:
                    renpy.run(QuickLoad(confirm=False))
            except Exception:
                pass

        if _renplay_poll_bridge not in config.periodic_callbacks:
            config.periodic_callbacks.append(_renplay_poll_bridge)
    """#
}
#endif
