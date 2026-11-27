# RenPlay Engineering Guide for AI Agents

This document describes the architecture, build commands, and hard invariants of **RenPlay**, a native iOS/iPadOS multi-engine player for Ren'Py visual novels licensed under `GPL-3.0-or-later`.

## Repository Layout and Target Graph

Swift Package targets are declared in [Package.swift](Package.swift) (Swift tools 6.0, iOS 17 deployment target):

- `CSMB2` ([Sources/CSMB2](Sources/CSMB2)): Vendored `libsmb2` (`upstream/`) with iOS `config_shim/` and `csmb_mount_*` wrapper for SMBv2/v3 LAN reads.
- `CZlib` ([Sources/CZlib](Sources/CZlib)): Thin C shim linking system `zlib`, `bz2`, `lzma`, `archive` (iOS/macOS), and `zstd` (`Package.resolved`).
- `RenPlayCore` ([Sources/RenPlayCore](Sources/RenPlayCore)): Platform-independent Swift 6 library (builds and runs tests natively on Linux and macOS/iOS). Owns models, JSON stores, save management, version detection, RPA/archive extraction, SMB indexing, and diagnostic scrubbing.
- `CRenPlayBridge` ([Sources/CRenPlayBridge](Sources/CRenPlayBridge)): Objective-C/C runtime bridge compiled for iOS only (`#if TARGET_OS_IOS`). Links `MetalANGLE.framework`, `UIKit`, `AVFoundation`, `Photos`, `QuartzCore`, `StoreKit`, and `CSMB2`.
- `RenPlay` ([Sources/RenPlay](Sources/RenPlay)): SwiftUI/UIKit application target owning `AppState`, `EngineLauncher`, in-game passthrough HUD (`GameOverlayHUD`), Wi-Fi upload server, AI diagnostics sharing (`AIHelp`), and views.
- `RenPlayCoreTests` ([Tests/RenPlayCoreTests](Tests/RenPlayCoreTests)): Swift Testing suite covering archive extraction, RPA parsing, engine detection/selection, SMB manifests, save management, gesture defaults, and privacy scrubbing.

Companion runtime scripts live in [scripts/](scripts/) and detailed design notes live in [docs/](docs/):

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): Process lifecycle, `dlopen` ordering, SDL `UIWindowScene` swizzling, `engine_main.py`, and `99renplay_overrides.rpy` bridge.
- [docs/INPUT_AND_OVERLAY.md](docs/INPUT_AND_OVERLAY.md): Virtual mouse, multi-touch gesture recognizers and touch-mouse suppression, sentinel keyboard bridge, and passthrough overlay window.
- [docs/STORAGE_SAVES_AND_SMB.md](docs/STORAGE_SAVES_AND_SMB.md): App sandbox layout, archive extraction, SMB LAN streaming, save slot auto-load / `savetoken`, and screenshot destinations.
- [BUILDING.md](BUILDING.md): Prerequisites, local builds, engine rebuilds, and CI workflows.
- [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md): Dependency provenance and licenses.

## Verification and Build Commands

Run from the repository root:

```sh
python3 scripts/check_docs_and_ai_guide.py
swift test --filter RenPlayCoreTests
xtool dev build --ipa -c release
```

To fetch the prebuilt dynamic Ren'Py `.framework` bundles (`7.8.7`, `8.3.7`, `8.4.1`, `8.5.3`, `8.6.1`), `MetalANGLE.framework`, and Python script archives into `BundleResources/`:

```sh
./scripts/fetch_engines.sh
```

## Non-Negotiable Invariants

1. **Linux Test Portability**: Keep all `RenPlayCore` and `CSMB2` sources free of UIKit imports. Gate iOS-only code in `CRenPlayBridge` with `#if TARGET_OS_IOS` and in `RenPlay` with `#if canImport(UIKit)` (or `#if canImport(UIKit) && canImport(SwiftUI)`).
2. **Embedded Script Parity**: [scripts/engine_main.py](scripts/engine_main.py) and [scripts/99renplay_overrides.rpy](scripts/99renplay_overrides.rpy) are duplicated inside triple-quoted raw strings (`engineMainScript` and `runtimeOverridesScript`) in [EngineLauncher.swift](Sources/RenPlay/EngineLauncher.swift). Any edit to either script must update both copies identically; `scripts/check_docs_and_ai_guide.py` enforces byte parity.
3. **Python 2.7 + 3.12 Compatibility**: `99renplay_overrides.rpy` and `engine_main.py` execute inside both Ren'Py 7.8.7 (Python 2.7) and Ren'Py 8.x (Python 3.9/3.12). Avoid f-strings, type annotations, `pathlib` assumptions, or Python 3-only standard library modules in those two files.
4. **C Symbol Visibility for `ctypes`**: Functions looked up dynamically by Python via `ctypes.CDLL(None)` (`renplay_bridge_*` and `renplay_smb_pread` in [RenPlayBridge.m](Sources/CRenPlayBridge/RenPlayBridge.m)) MUST carry `__attribute__((visibility("default"), used))` so LTO/dead-strip in `-c release` retains them in the `RenPlay` Mach-O binary.
5. **Single Engine Per Process & CFRunLoop Dispatch**: `renplay_launch_engine` `dlopen`s one framework per process lifetime (`g_loaded_framework`). Clean game exits call `Darwin._exit(0)`. Game launch and keyboard presentation must schedule via `RunLoop.main` / `CFRunLoopPerformBlock` so UIKit and XPC keyboard services continue draining while SDL owns the event loop.
6. **Environment Presence Semantics**: Ren'Py checks key membership for `RENPY_LESS_MEMORY` and `RENPY_LESS_UPDATES` (`"RENPY_LESS_MEMORY" in os.environ`), not `"0"` vs `"1"`. Call `unsetenv(...)` when disabled in [RenPlayBridge.m](Sources/CRenPlayBridge/RenPlayBridge.m).
7. **Direct Save Loading & `_reload-*` Hygiene**: Ren'Py mobile writes `_reload-1.save` / `_reload-2.save` on backgrounding, and `00start.rpy` loads `_reload-1` before checking `RENPY_AUTO_LOAD`. `SaveManager.listSaves(in:)` filters out `_reload-*`, `EngineLauncher.launch` removes stale `_reload-*` files before launch, `engine_main.py` isolates `"tokens"`/`"backups"` into `Saves/_tokens` and `Saves/_backups`, and `99renplay_overrides.rpy` clears `RENPY_AUTO_LOAD` only via `config.after_load_callbacks` with a `main_menu` fallback and user-triggered `savetoken.check_load` trust.
8. **Gesture Touch Suppression & Safe Mode**: Multi-touch gesture recognizers on `SDL_uikitwindow` suppress single-finger SDL touch-mouse events (`renplay_bridge_should_suppress_touch_mouse`) in `renpy.display.controller.event`, while preserving synthetic events tagged `renplay_virtual=True` from the Virtual Mouse trackpad. Safe Mode (`g_safe_mode_active = 1`) disables native gesture recognizers, `UIWindow` multi-touch tracking, `_renplay_keymap` underlay bindings, and the touch-mouse suppression filter completely.
9. **Screenshot Routing**: `RENPY_SCREENSHOT_PATTERN` directs native PNG capture to `Documents/Screenshots/<Game>/` or temporary storage before `renplay_bridge_on_screenshot_saved` writes to `PHPhotoLibrary` (`NSPhotoLibraryAddUsageDescription` in [RenPlay-Info.plist](RenPlay-Info.plist)).
10. **Privacy & Licensing**: All original Swift, Objective-C, C, Python, and shell files carry GPL-3.0-or-later SPDX headers; [REUSE.toml](REUSE.toml) covers documentation and data assets. Keep player logs shared through [AIHelp.swift](Sources/RenPlay/AIHelp.swift) scrubbed through `DiagnosticScrubber`, and never commit local paths or credentials.
