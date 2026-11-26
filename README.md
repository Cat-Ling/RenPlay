# RenPlay

RenPlay is an iOS and iPadOS player for Ren'Py visual novels built with SwiftUI, xtool, and dynamically loaded per-version Ren'Py engine frameworks.

## Architecture

- `Sources/RenPlayCore`: Pure-Swift library handling Ren'Py version detection, engine selection, RPA archive parsing, ZIP/TAR/APK extraction, save slot management, and library persistence. Tested on Linux with `swift test`.
- `Sources/CRenPlayBridge`: Objective-C/C runtime bridge providing `UIWindowScene` attachment for SDL2/SDL3 windows, `AVPlayer`-based `VideoPlayer` and `Log` classes, `stdout`/`stderr` capture, `dlopen`/`dlsym` engine loading, and synthetic SDL input injection.
- `Sources/RenPlay`: SwiftUI application interface, in-game passthrough HUD overlay, save browser, RPA/loose asset gallery, and log viewer.
- `scripts/build_engine.sh` and `.github/workflows/build-engines.yml`: Build `arm64` iOS dynamic `.framework` bundles and matching Python script packs from official `renpy/renpy` `renios` and `sdk` release archives.

## Building

Fetch prebuilt engine frameworks and script packs from GitHub Releases, run unit tests, and build the unsigned IPA with `xtool`:

```sh
./scripts/fetch_engines.sh
swift test
xtool dev build --ipa -c release
```

## License

GNU General Public License v3.0 or later. See [COPYING](COPYING).
