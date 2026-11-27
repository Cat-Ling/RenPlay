# Third-Party Notices

RenPlay is licensed under **GNU General Public License v3.0 or later** ([COPYING](COPYING); full text also in [LICENSES/GPL-3.0-or-later.txt](LICENSES/GPL-3.0-or-later.txt)). Per-file and per-path license metadata is declared in [REUSE.toml](REUSE.toml).

Each bundled or linked third-party component retains its upstream license:

| Component | Version / Source | License | Where Used |
|---|---|---|---|
| **Ren'Py Engine (`renios` & SDK)** | 7.8.7, 8.3.7, 8.4.1, 8.5.3, 8.6.1 ([renpy/renpy](https://github.com/renpy/renpy)) | Upstream MIT / LGPL / component licenses per Ren'Py distribution notices | Fetched as prebuilt `.framework` and script `.zip` packs into `BundleResources/` via [scripts/fetch_engines.sh](scripts/fetch_engines.sh) |
| **MetalANGLE** | Bundled with upstream Ren'Py `renios` prototype | BSD-3-Clause (ANGLE / MetalANGLE upstream terms) | Linked by `CRenPlayBridge` (`Package.swift`) and preloaded globally before launching an engine framework |
| **libsmb2** | Vendored in [Sources/CSMB2/upstream](Sources/CSMB2/upstream) | **LGPL-2.1-or-later** ([LICENSES/LGPL-2.1-or-later.txt](LICENSES/LGPL-2.1-or-later.txt)) | Compiled into `CSMB2` target (`Package.swift`) for SMBv2/v3 LAN file streaming |
| **Zstandard (`zstd`)** | `1.5.7` pinned in [Package.resolved](Package.resolved) (`facebook/zstd`) | **BSD-3-Clause** (dual-licensed BSD-3-Clause / GPL-2.0 upstream; BSD-3-Clause selected) | Linked as `libzstd` into `CZlib` for ZIP method 93 (`.zip` Zstandard) decompression |
| **System Apple & Host Libraries** | SDK / OS system libraries (`libz`, `libbz2`, `liblzma`, `libarchive`, Apple iOS frameworks) | Upstream system/SDK terms | Linked dynamically via [Package.swift](Package.swift) |

No user game assets, proprietary DRM tools, or third-party cloud SDKs are included in RenPlay. Games imported or streamed by a user remain subject to their own respective licenses.
