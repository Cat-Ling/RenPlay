# Architecture & Runtime Bridge

RenPlay launches unmodified Ren'Py games inside an iOS/iPadOS process without JIT by combining Swift app state, an Objective-C/C runtime bridge, a dynamically loaded Ren'Py `.framework`, and Python runtime hooks.

## 1. Launch Pipeline

1. **Engine Selection ([EngineDetector.swift](../Sources/RenPlayCore/EngineDetector.swift))**:
   - At game import or SMB sync time, `RenPyVersionDetector.detectVersion(in:)` inspects `renpy/vc_version.py`, `renpy/__init__.py`, `script_version.txt`, `lib/` directory prefixes, `game/cache/bytecode-*.rpyb`, or `.rpyc` headers.
   - `EngineSelector.selectEngine(detected:available:strategy:)` matches either the closest bundled version in the same major branch (`.accurate`) or the newest in that branch (`.latest`), unless overridden per game via `GameSettings.engineMode`.
2. **Pre-Launch Setup ([EngineLauncher.swift](../Sources/RenPlay/EngineLauncher.swift))**:
   - Unpacks the selected engine script pack (`BundleResources/Engines/<version>.zip`) into `Library/Application Support/RenPlay/Engines/<version>/` on first run (stamped by `.ready_<sha256>`).
   - Syncs `base/main.py` and `base/renpy/common/99renplay_overrides.rpy` from `engineMainScript` / `runtimeOverridesScript` and deletes stale compiled `.pyc` / `.rpyc` / `.rpyb` files so edits apply cleanly.
   - Creates `Save`, `Log`, and shared `_Multipersistent` directories, removes stale `_reload-1.save` / `_reload-2.save` mobile suspend snapshots, and optionally writes a rotated ZIP backup (`autoBackupCount`).
   - If the game has an `SMBGameSource`, calls `renplay_configure_smb_mount(...)` to initialize `csmb_mount` before entering Python.
   - Applies orientation (`renplay_set_preferred_orientation`) and multi-touch gesture configuration (`renplay_configure_gestures`, skipped/forced off in Safe Mode).
   - Hides SwiftUI windows and schedules `renplay_launch_engine(...)` on `RunLoop.main` (`0.15s` timer) so UIKit keeps draining main-queue services while SDL runs.
3. **Dynamic Framework Loading ([RenPlayBridge.m](../Sources/CRenPlayBridge/RenPlayBridge.m))**:
   - Redirects `stdout` and `stderr` to `<logDir>/renplay_session.log` and redirects stderr from `NSLog`/`os_log` visibility cleanly into the session log.
   - Exports `RENPY_*` environment variables (calling `unsetenv` for `RENPY_LESS_MEMORY` and `RENPY_LESS_UPDATES` when disabled because Ren'Py checks `"KEY" in os.environ`).
   - Preloads `MetalANGLE.framework` with `RTLD_NOW | RTLD_GLOBAL`, then `dlopen`s `renpy<ver>.framework`, resolves `renplay_launch` (or `launcher_main`), sets `SDL_IOS_HIDE_HOME_INDICATOR`, `SDL_IOS_IDLE_TIMER_DISABLED`, and `SDL_ENABLE_SCREEN_KEYBOARD`, and invokes `entry(2, [engineBase/RenPlay, gameDir])`.
4. **Process Exit Rule**:
   - `g_loaded_framework` enforces one framework `dlopen` per iOS process lifetime. When `renplay_launch` returns `0` (or HUD `Exit Game` sends `RENPLAY_CMD_QUIT`), RenPlay flushes dialogue stats and persistent data and calls `Darwin._exit(0)` / `_exit(0)` (guarded by a 300ms watchdog thread) rather than attempting in-process Python interpreter teardown.

## 2. SDL Scene Swizzling & Objective-C Shim Classes

iOS scene-based apps require `UIWindow.windowScene` on newly created SDL windows, and upstream Ren'Py `ios` modules import Obj-C `VideoPlayer` / `Log` classes via `pyobjus`:

- `renplay_install_sdl_scene_bridge()` swizzles `-[UIWindow makeKeyAndVisible]` and `-[UIWindow setHidden:]` via `renplay_attach_window_scene_if_needed`. Whenever SDL creates an `SDL_uikitwindow` without a `windowScene`, RenPlay attaches the captured active `UIWindowScene` and installs the multi-touch gesture recognizers.
- `RenPlayVideoPlayerImpl` (dynamically registered as `VideoPlayer` if absent at runtime) presents a fullscreen borderless `AVPlayerViewController` over the active scene when Ren'Py requests hardware video playback.
- `RenPlayLogImpl` (registered as `Log` if absent) forwards engine log messages through `renplay_log_line`.
- `RenPlayRuntimeBridge` exposes `smbPreadSymbolAddress` for pyobjus fallback lookup alongside `ctypes.CDLL(None)`.

## 3. Bootstrap (`engine_main.py`) & Runtime Overrides (`99renplay_overrides.rpy`)

- [scripts/engine_main.py](../scripts/engine_main.py):
  - Stubs `os.system` (`0`), blocks external `socket.socket.connect` unless `RENPY_ALLOW_NETWORK=1` (allowing loopback), sets `cwd` and `~` expansion inside `_GAME_ROOT`, and overrides `path_to_gamedir`, `path_to_saves`, and `path_to_logdir`.
  - Routes `path_to_saves(..., "tokens")` and `"backups"` to `Saves/_tokens` and `Saves/_backups` so cryptographic save tokens stay outside per-game save slot listings.
  - Installs `_install_renplay_smb_loader(renpy)` during `predefined_searchpath` when `.renplay_smb_index.tsv` exists.
  - Installs Windows compatibility shims (`os.startfile`, `ctypes.windll` + `user32.GetSystemMetrics`) early if `RENPY_COMPAT_PATCHES=1` (and not Safe Mode).
- [scripts/99renplay_overrides.rpy](../scripts/99renplay_overrides.rpy):
  - Runs at `init 999 python` (both Python 2.7 and Python 3.x compatible).
  - Applies Safe Mode (`image_cache_size_mb = 64`, `gl_powersave = True`, `predict_statements = 0`, skipping `_renplay_keymap` underlay shortcuts and touch/input hooks) or normal switches (`developer`, `console`, `rollback_enabled`, `allow_skipping`, `preferences.skip_unseen`, `RENPY_COMPAT_PATCHES` backslash loader normalization, transparent textbox styling, `RENPY_MASTER_VOLUME`).
  - Handles screenshot callbacks (`_renplay_screenshot_callback` -> `renplay_bridge_on_screenshot_saved` when saving to Photos) and user-selected auto-load (`_renplay_check_load` + `main_menu` `FileLoad` fallback).
  - Registers `config.periodic_callbacks` (`_renplay_poll_bridge`) to drain frozen variable assignments, dialogue progress reporting, native key events, virtual mouse events, JSON RPC requests (`set_volume`, `set_transparent_textbox`, `open_console`, `reload_script`, `set_variants`, `unlock_gallery`, `list_vars`, `set_var`, `toggle_freeze`), and HUD/gesture commands.
