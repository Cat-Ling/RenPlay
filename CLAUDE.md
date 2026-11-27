# CLAUDE.md

Read [AGENTS.md](AGENTS.md) before modifying code in this repository.

## Quick Commands

```sh
python3 scripts/check_docs_and_ai_guide.py
swift test --filter RenPlayCoreTests
xtool dev build --ipa -c release
```

## Key References

- Architecture and engine launch bridge: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Touch gestures, virtual mouse, keyboard, and overlay HUD: [docs/INPUT_AND_OVERLAY.md](docs/INPUT_AND_OVERLAY.md)
- Sandbox storage, saves, SMB streaming, and screenshots: [docs/STORAGE_SAVES_AND_SMB.md](docs/STORAGE_SAVES_AND_SMB.md)
- Build and CI workflows: [BUILDING.md](BUILDING.md)
- In-app user troubleshooting guide for AI assistants: [Resources/Give-to-AI-with-logs.txt](Resources/Give-to-AI-with-logs.txt)

## Key Reminders

- Keep `scripts/engine_main.py` and `scripts/99renplay_overrides.rpy` byte-identical to their embedded strings in [EngineLauncher.swift](Sources/RenPlay/EngineLauncher.swift) and compatible with both Python 2.7 (Ren'Py 7.8.7) and Python 3.x (Ren'Py 8.x).
- Keep `RenPlayCore` and `CSMB2` testable on Linux without UIKit dependencies.
- Keep `check_docs_and_ai_guide.py` and `swift test --filter RenPlayCoreTests` passing before committing or triggering [build-ipa.yml](.github/workflows/build-ipa.yml).
