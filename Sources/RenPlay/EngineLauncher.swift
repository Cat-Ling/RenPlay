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
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        if appSettings.autoBackupCount > 0 {
            statusUpdate("Backing up saves...")
            _ = try? saveManager.createBackup(of: saveDir, to: backupDir, maxBackups: appSettings.autoBackupCount)
        }

        statusUpdate("Starting \(game.displayName)...")

        if let remote = game.remoteSource {
            statusUpdate("Connecting to SMB share \(remote.host)/\(remote.share)...")
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
                throw LaunchError.engineFailure("Unable to mount SMB share: \(connectError)")
            }
        } else {
            renplay_clear_smb_mount()
        }

        let variant: String
        switch game.settings.orientation {
        case .auto:
            variant = UIDevice.current.userInterfaceIdiom == .pad ? "tablet touch" : "phone touch"
        case .landscape:
            variant = "touch"
        case .portrait:
            variant = "portrait touch"
        }

        let sdlVersion = engine.sdlVersion.uppercased().contains("3") ? 3 : 2
        let allowNetwork = (game.settings.allowNetwork || appSettings.globalAllowNetwork) ? 1 : 0
        let devMode = game.settings.developerMode ? 1 : 0
        let forceRollback = game.settings.forceRollback ? 1 : 0
        let forceSkip = game.settings.forceSkip ? 1 : 0
        let lessMemory = game.settings.lowMemoryMode ? 1 : 0
        let showOverlay = appSettings.showOverlayByDefault
        let overlayOpacity = appSettings.overlayOpacity
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
                                self.installOverlay(gameName: gameTitle, logDir: logDir, opacity: overlayOpacity)
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
                    variant,
                    Int32(sdlVersion),
                    Int32(allowNetwork),
                    Int32(devMode),
                    Int32(forceRollback),
                    Int32(forceSkip),
                    Int32(lessMemory),
                    &errBuf,
                    errBuf.count
                )

                self.overlayPollTimer?.invalidate()
                self.overlayPollTimer = nil
                self.removeOverlay()
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

    private func installOverlay(gameName: String, logDir: URL, opacity: Double) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        let win = GameOverlayWindow(windowScene: scene, gameName: gameName, logDir: logDir, opacity: opacity)
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
    # native iOS keyboard hooks, and the HUD command queue apply across 7.x and 8.x.

    init 999 python:
        import ctypes as _renplay_ctypes
        import os as _renplay_os
        import sys as _renplay_sys

        if _renplay_os.environ.get("RENPY_DEV_MODE") == "1":
            config.developer = True
            config.console = True

        if _renplay_os.environ.get("RENPY_FORCE_ROLLBACK") == "1":
            config.rollback_enabled = True
            if getattr(config, "hard_rollback_limit", 0) < 256:
                config.hard_rollback_limit = 256

        if _renplay_os.environ.get("RENPY_FORCE_SKIP") == "1":
            config.allow_skipping = True
            config.skip_indicator = True

        _renplay_c_consume_cmd = None
        _renplay_c_start_input = None
        _renplay_c_stop_input = None
        _renplay_c_is_shown = None
        _renplay_c_reopen = None
        _renplay_c_consume_key = None

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

        def _renplay_post_key(vk, scancode, down_unicode):
            if _renplay_pg is None:
                return
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYDOWN,
                key=vk,
                scancode=scancode,
                unicode=down_unicode,
                mod=0,
                repeat=False,
            ))
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYUP,
                key=vk,
                scancode=scancode,
                unicode=u"",
                mod=0,
                repeat=False,
            ))

        _renplay_key_buf = _renplay_ctypes.create_string_buffer(512)

        def _renplay_poll_bridge():
            if _renplay_c_consume_cmd is None:
                return

            if _renplay_pg is not None and _renplay_c_consume_key is not None:
                try:
                    while True:
                        n = int(_renplay_c_consume_key(_renplay_key_buf, 512))
                        if n <= 0:
                            break
                        payload = _renplay_key_buf.raw[:n].decode("utf-8", "replace")
                        if payload.startswith("T:"):
                            try:
                                _renplay_pg.event.set_allowed(_renplay_pg.TEXTINPUT)
                            except Exception:
                                pass
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.TEXTINPUT,
                                text=payload[2:],
                            ))
                        elif payload == "K:BACKSPACE":
                            _renplay_post_key(
                                _renplay_pg.K_BACKSPACE,
                                getattr(_renplay_pg, "KSCAN_BACKSPACE", 42),
                                u"\b",
                            )
                        elif payload == "K:RETURN":
                            _renplay_post_key(
                                _renplay_pg.K_RETURN,
                                getattr(_renplay_pg, "KSCAN_RETURN", 40),
                                u"\r",
                            )
                except Exception:
                    pass

            try:
                cmd = int(_renplay_c_consume_cmd())
            except Exception:
                return
            if cmd == 0:
                return
            if cmd == 10:
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
