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

        // Capture foreground UIWindowScene and tear down SwiftUI windows before SDL creates its window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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
        let commonDir = engineRoot.appendingPathComponent("base/renpy/common", isDirectory: true)
        try fm.createDirectory(at: commonDir, withIntermediateDirectories: true)
        let targetURL = commonDir.appendingPathComponent("99renplay_overrides.rpy")
        for stale in ["99renplay_overrides.rpyc", "99renplay_overrides.rpyb"] {
            try? fm.removeItem(at: commonDir.appendingPathComponent(stale))
        }
        try runtimeOverridesScript.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    private static let runtimeOverridesScript = """
    init 999 python:
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

        _renplay_bridge_cls = None
        try:
            import pyobjus as _renplay_pyobjus
            _renplay_bridge_cls = _renplay_pyobjus.autoclass("RenPlayRuntimeBridge")
        except Exception:
            _renplay_bridge_cls = None

        _renplay_pg_mods = []
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

        if _renplay_bridge_cls is not None and _renplay_pg_mods:
            def _renplay_has_screen_keyboard():
                return True

            def _renplay_is_screen_keyboard_shown():
                try:
                    return int(_renplay_bridge_cls.isScreenKeyboardShown()) != 0
                except Exception:
                    return False

            def _renplay_start_text_input(*args, **kwargs):
                try:
                    _renplay_bridge_cls.startTextInput()
                except Exception:
                    pass

            def _renplay_stop_text_input(*args, **kwargs):
                try:
                    _renplay_bridge_cls.stopTextInput()
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
                                        _renplay_bridge_cls.reopenIfEngineTextInputActive()
                            except Exception:
                                pass
                        return _orig_input_event(self, ev, x, y, st)

                    _input_cls.render = _renplay_input_render
                    _input_cls.event = _renplay_input_event
                    _input_cls._renplay_hooked = True
            except Exception:
                pass

        def _renplay_decode_nsstring(ns_obj):
            if ns_obj is None:
                return u""
            raw = ns_obj.UTF8String()
            if isinstance(raw, bytes):
                return raw.decode("utf-8", "replace")
            return raw

        def _renplay_post_key(vk):
            if _renplay_pg is None:
                return
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYDOWN,
                key=vk,
                scancode=vk,
                unicode=u"",
                mod=0,
                repeat=False,
            ))
            _renplay_pg.event.post(_renplay_pg.event.Event(
                _renplay_pg.KEYUP,
                key=vk,
                scancode=vk,
                unicode=u"",
                mod=0,
                repeat=False,
            ))

        def _renplay_poll_bridge():
            if _renplay_bridge_cls is None:
                return

            if _renplay_pg is not None:
                try:
                    while int(_renplay_bridge_cls.hasPendingKeyEvent()) != 0:
                        payload = _renplay_decode_nsstring(_renplay_bridge_cls.consumeKeyEvent())
                        if not payload:
                            break
                        if payload.startswith("T:"):
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.TEXTINPUT,
                                text=payload[2:],
                            ))
                        elif payload == "K:BACKSPACE":
                            _renplay_post_key(_renplay_pg.K_BACKSPACE)
                        elif payload == "K:RETURN":
                            _renplay_post_key(_renplay_pg.K_RETURN)
                except Exception:
                    pass

            try:
                cmd = int(_renplay_bridge_cls.consumeCommand())
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
    """
}
#endif
