# Storage, Save Auto-Load, SMB Streaming, and Screenshots

## 1. Sandbox Layout ([LibraryStore.swift](../Sources/RenPlayCore/LibraryStore.swift))

Visible user directory under `Documents/`:
- `Documents/HOW_TO_IMPORT.txt`: Quick import instructions.
- `Documents/Give-to-AI-with-logs.txt`: Bundled troubleshooting guide installed at startup by [AIHelp.swift](../Sources/RenPlay/AIHelp.swift).
- `Documents/Screenshots/<GameFolder>/`: Default screenshot output directory when `ScreenshotDestination` is `.documents` or `.both`.

Internal library root under `Documents/RenPlay/`:
- `library.json`: Persisted `[GameEntry]` array.
- `settings.json`: Global `AppSettings` (decoded with per-field defaults so schema additions never break older configs).
- `smb_servers.json`: Server profiles (`SMBServerProfile`); passwords live separately in iOS Keychain.
- `Games/<folderName>/`: Extracted or copied game directories (or `.renplay_smb_index.tsv` + cached scripts for SMB games).
- `Saves/<saveIdentifier>/`: Game saves (`*.save`, `persistent`, `.renplay_save_meta.json`, `.renplay_stats.json`). Prefixed internal folders live alongside game save folders:
  - `Saves/_Multipersistent/`: `RENPY_MULTIPERSISTENT` shared storage.
  - `Saves/_tokens/`: `RENPY_SAVE_DIRECTORY` target when `path_to_saves` asks for `"tokens"`.
  - `Saves/_backups/`: `RENPY_SAVE_DIRECTORY` target when `path_to_saves` asks for `"backups"`.
- `Backups/<saveIdentifier>/`: Rotated `saves-yyyyMMdd-HHmmss.zip` archives created before launch or manual backup.
- `Logs/<gameUUID>/`: Per-game `renplay_session.log`.
- `Exports/`, `Import/`: Staging and export folders.
- `Library/Application Support/RenPlay/Engines/<version>/`: Unpacked Ren'Py script packs and cache markers.

## 2. Import & Streaming Extraction ([ArchiveExtractor.swift](../Sources/RenPlayCore/ArchiveExtractor.swift))

- Supports `.zip` (ZIP64, Deflate, BZip2, LZMA, Zstandard method `93`), `.7z`, `.rar`, `.tar.*`, `.apk` (stripping `assets/x-` mobile prefixes automatically), and loose folders (`UIDocumentPickerViewController` copy, in-place coordinated copy, URL download, Files dropzones, and `LocalWiFiUploadServer` HTTP uploads).
- RenPlay inspects archive layouts via `locateGameRoot(inside:)` to find the game directory regardless of archive nesting depth.

## 3. SMBv2 / SMBv3 LAN Streaming ([SMBClient.swift](../Sources/RenPlayCore/SMBClient.swift), [CSMB2](../Sources/CSMB2))

Instead of downloading multi-gigabyte asset packs onto the device:

1. **Indexing (`importRemoteSMBGame`)**: Recursively scans the remote `game/` directory. Script/config files (`.rpy`, `.rpyc`, `.rpymc`, `.txt`, `.json`) are cached locally; `.rpa` archives parse only header + index trailer to emit `.renplay_smb_index.tsv` rows:
   - `L\t<logical>\t<smb_rel>\t<size>`: Loose asset served from byte 0.
   - `R\t<logical>\t<smb_rel>\t<off>:<len>:<hex_prefix>;...`: Multi-segment entry directly indexing RPA byte ranges.
2. **Runtime I/O**: `engine_main.py` registers `_renplay_scandirfiles_smb` and `_renplay_load_from_smb` on `renpy.loader`, backed by `_RenPlaySMBRawIO` calling `renplay_smb_pread` (`csmb_mount_pread` -> `libsmb2` `smb2_pread`). Files `<= 4 MiB` read sequentially into memory buffers; larger media streams lazily via buffered seeks/reads.
3. **Syncing Scripts**: `refreshRemoteSMBGame` updates `.renplay_smb_index.tsv` and small script files if a user modifies scripts on their LAN share.

## 4. Save Management & Deterministic Auto-Load

- **Kept & Unlinked Saves**: Removing a game with `deleteSaves: false` retains `Saves/<saveIdentifier>/` with `.renplay_save_meta.json` (`saveKey` derived from `options.rpy` `config.save_directory` -> SMB path -> normalized title). Re-importing re-adopts the matching folder automatically, and Save Manager allows manual folder creation, renaming, and relinking.
- **Excluding Internal Mobile Snapshots**: Ren'Py's `ios` platform creates `_reload-1.save` / `_reload-2.save` on backgrounding, and `00start.rpy` calls `_load_reload_game` *before* reading `RENPY_AUTO_LOAD`. RenPlay excludes `_reload-*` from `SaveManager.listSaves`, `SaveSlot.renpySlotName`, backups, and exports, and `EngineLauncher.launch` removes stale `_reload-*` files before launch.
- **Guaranteed `RENPY_AUTO_LOAD` Execution**:
  1. When launching via **Resume**, **Library context menu > Resume**, tapping a save in `GameDetailView`, or tapping a save card in `GameSaveManagerView`, `RENPY_AUTO_LOAD` is passed to `renplay_launch_engine`.
  2. `99renplay_overrides.rpy` sets `RENPY_SKIP_SPLASHSCREEN=1` while `_renplay_pending_autoload` is non-empty, authorizes save tokens for user-selected loads (`_renplay_check_load`), and clears auto-load state in `config.after_load_callbacks`.
  3. If a custom startup script bypasses `00start.rpy` or `savelocation` scan timing misses the early check, `_renplay_poll_bridge` triggers `renpy.loadsave.location.scan()` and `FileLoad(slot, confirm=False, slot=True)` (falling back to `renpy.load(slot)`) once `store.main_menu` becomes `True`.
- **Backup Case Normalization**: `SaveManager.importSaves` normalizes uppercase `.SAVE` extensions to lowercase `.save` so APFS case sensitivity never hides imported saves from Ren'Py.

## 5. Screenshots ([Models.swift](../Sources/RenPlayCore/Models.swift), [RenPlayBridge.m](../Sources/CRenPlayBridge/RenPlayBridge.m))

`AppSettings.screenshotDestination` (`ScreenshotDestination`: `.documents`, `.photos`, `.both`) configures `RENPY_SCREENSHOT_PATTERN` at launch and live via `renplay_set_screenshot_destination`. After Ren'Py writes the PNG, `_renplay_screenshot_callback` calls `renplay_bridge_on_screenshot_saved(path, deleteAfterSave)`, which requests `PHAccessLevelAddOnly` permission and saves the PNG asset into Photos when `.photos` or `.both` is active (deleting the temp file when `.photos`-only).
