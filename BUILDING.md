# Building RenPlay

## Prerequisites

- **Swift 6.0+** toolchain (Linux or macOS) for `RenPlayCore` tests and `xtool` cross-builds.
- **System libraries for Linux host tests** (matches [build-ipa.yml](.github/workflows/build-ipa.yml)):
  `zlib1g-dev`, `libarchive-dev`, `p7zip-full`, `xz-utils`, `zstd`, `bzip2`.
- **iOS packaging**: [xtool](https://github.com/xtool-org/xtool) with an iOS SDK installed, plus `python3` for [scripts/check_docs_and_ai_guide.py](scripts/check_docs_and_ai_guide.py).
- **Engine packs**: Prebuilt dynamic `.framework` bundles and runtime script `.zip` packs stored outside Git history on GitHub Releases and fetched via [scripts/fetch_engines.sh](scripts/fetch_engines.sh).

## Fetch Prebuilt Engines and Build the IPA

```sh
./scripts/fetch_engines.sh
python3 scripts/check_docs_and_ai_guide.py
swift test --filter RenPlayCoreTests
xtool dev build --ipa -c release
```

`fetch_engines.sh` downloads `MetalANGLE.framework`, `renpy7_8_7.framework` through `renpy8_6_1.framework`, `7.8.7.zip` through `8.6.1.zip`, and `engines-manifest.json` from the release tag (`engines-v1` by default, or pass a tag argument) into `BundleResources/Frameworks/` and `BundleResources/Engines/`.

`xtool dev build --ipa -c release` packages the app according to [xtool.yml](xtool.yml) (`bundleID: com.catling.RenPlay`, `product: RenPlay`) and writes the IPA under `xtool/RenPlay.ipa`.

## Rebuilding Ren'Py Engine Frameworks

[scripts/build_engine.sh](scripts/build_engine.sh) converts official `renpy/renpy` release archives (`renpy-<ver>-renios.zip` and `renpy-<ver>-sdk.zip`) into a single dynamic iOS `.framework` plus matching pure-Python runtime zip:

1. Downloads `renpy-<ver>-renios.zip` and `renpy-<ver>-sdk.zip` (checking mirror release assets first if present, falling back to upstream `renpy/renpy`).
2. Links upstream prebuilt static archives (`librenpython`, `libpython*`, `libSDL2`/`libSDL3`, `SDL2_image`/`SDL3_image`, `freetype`, FFmpeg libraries, `webp`, etc.) into a dynamic `renpy<major>_<minor>_<patch>.framework` exporting `renplay_launch`.
3. Injects [scripts/engine_main.py](scripts/engine_main.py) (`base/main.py`) and [scripts/99renplay_overrides.rpy](scripts/99renplay_overrides.rpy) (`base/renpy/common/99renplay_overrides.rpy`) into the runtime `.zip`.

At app runtime, [EngineLauncher.swift](Sources/RenPlay/EngineLauncher.swift) also syncs `engineMainScript` and `runtimeOverridesScript` directly into cached unpacked engine folders on first launch, so Python override updates do not wait on rebuilding the binary engine release packs.

## Continuous Integration Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| [.github/workflows/build-engines.yml](.github/workflows/build-engines.yml) | Manual dispatch | Builds dynamic `.framework` + `.zip` archives on `macos-15` for configured Ren'Py tags and publishes the `engines-v*` release. |
| [.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml) | Manual dispatch | Runs `check_docs_and_ai_guide.py` and `swift test --filter RenPlayCoreTests` on `ubuntu-24.04`, fetches engine packs on `macos-15`, builds the release IPA with `xtool`, strips signatures for clean sideloading, and optionally publishes a tagged GitHub Release (`v1.0.0-<short-sha>`). |
