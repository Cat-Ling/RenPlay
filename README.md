# RenPlay

**RenPlay** is an open-source native iOS and iPadOS player for Ren'Py visual novels. It bundles dynamic `arm64` iOS builds of multiple Ren'Py runtime versions and renders OpenGL ES over Metal using MetalANGLE—**no JIT required**.

## How it works

| Layer | Role |
|---|---|
| **[RenPlayCore](Sources/RenPlayCore)** | Pure-Swift game library store, streaming multi-format archive extractor, RPA reader, Ren'Py version detector/selector, SMB manifest indexer, and save manager. |
| **[CRenPlayBridge](Sources/CRenPlayBridge)** | Objective-C/C bridge handling `dlopen` engine loading, `MetalANGLE` GLES-on-Metal preload, SDL2/SDL3 `UIWindowScene` swizzling, native keyboard input, multi-touch gesture recognizers, `AVPlayer` video hooks, and `PHPhotoLibrary` screenshot export. |
| **[CSMB2](Sources/CSMB2)** | Vendored `libsmb2` client providing range-read (`renplay_smb_pread`) streaming over SMBv2/v3 LAN shares without downloading game assets ahead of time. |
| **[RenPlay App](Sources/RenPlay)** | SwiftUI interface, game library, fullscreen asset gallery, Wi-Fi HTTP uploader, passthrough in-game HUD overlay, and privacy-scrubbed AI diagnostics export. |
| **[Engine Packs](BundleResources/Engines/engines-manifest.json)** | Prebuilt `renpy7_8_7` (Py 2.7/SDL2), `renpy8_3_7` (Py 3.9/SDL2), `renpy8_4_1` (Py 3.12/SDL2), `renpy8_5_3` (Py 3.12/SDL2), and `renpy8_6_1` (Py 3.12/SDL3). |

## Features

- **Multi-version engine matching**: Automatic Ren'Py version detection from `vc_version.py`, `__init__.py`, `script_version.txt`, `lib/`, `cache/*.rpyb`, or `.rpyc` headers, with per-game engine pinning.
- **Direct archive & folder import**: Supports `.zip` (including ZIP64 and Deflate/Zstandard/LZMA), `.7z`, `.rar`, `.tar.*`, `.apk`, folder import, Files app dropzone scanning, HTTP URL download, and browser-based Wi-Fi upload.
- **LAN SMB streaming**: Browse SMBv2/v3 shares, index loose assets and `.rpa` byte ranges into `.renplay_smb_index.tsv`, and play directly over Wi-Fi.
- **Direct save launch & Save Manager**: Resume the newest save slot from a game page or tap any save card to launch directly into that save; keep orphaned saves across delete/re-import, manage ZIP backups, and relink save folders.
- **Mobile controls & multi-touch gestures**: Passthrough floating HUD, toggleable quick bar, virtual mouse trackpad with vector pointer, native iOS keyboard bridge with Esc/Ctrl/Alt modifiers, and customizable multi-finger tap/swipe gestures.
- **Runtime tools & diagnostics**: Live variable inspector/freezer, dialogue progress tracker, gallery unlocker, device variant overrides, safe mode, configurable screenshot destination (`Documents` / `Photos`), and **Share Diagnostics for AI**.

## Requirements & Sideloading

- iPhone or iPad running **iOS / iPadOS 17.0 or later**.
- Standard sideloading with a free or paid Apple Developer account (e.g. SideStore, AltStore, Sideloadly, or `xtool`). **No JIT** or debugger attachment is needed.

## Building from Source

```sh
./scripts/fetch_engines.sh
python3 scripts/check_docs_and_ai_guide.py
swift test --filter RenPlayCoreTests
xtool dev build --ipa -c release
```

See [BUILDING.md](BUILDING.md) for prerequisites, rebuilding engine frameworks with [scripts/build_engine.sh](scripts/build_engine.sh), and GitHub Actions workflows.

## Repository Map & Documentation

| File | Contents |
|---|---|
| [AGENTS.md](AGENTS.md) | Engineering architecture, target graph, and invariants for coding agents |
| [CLAUDE.md](CLAUDE.md) | Quick agent reference and verification commands |
| [BUILDING.md](BUILDING.md) | Build prerequisites, engine pack builds, and CI release pipeline |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Process lifecycle, `dlopen` runtime bridge, and Python override hooks |
| [docs/INPUT_AND_OVERLAY.md](docs/INPUT_AND_OVERLAY.md) | Virtual mouse, multi-touch gesture filtering, keyboard bridge, and overlay HUD |
| [docs/STORAGE_SAVES_AND_SMB.md](docs/STORAGE_SAVES_AND_SMB.md) | Sandbox storage, save auto-load mechanics, SMBv2 streaming, and screenshots |
| [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) | Third-party dependencies, licenses, and notice pointers |
| [Resources/Give-to-AI-with-logs.txt](Resources/Give-to-AI-with-logs.txt) | Bundled troubleshooting reference attached by **Share Diagnostics for AI** |

## License

GNU General Public License v3.0 or later ([COPYING](COPYING)). Bundled third-party components keep their respective upstream licenses ([THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)).
