# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Loaded from renpy/common after game options.rpy so RenPlay runtime toggles
# and the in-game bridge command queue apply safely across both Ren'Py 7.x and 8.x.

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

    _renplay_kbd_state = [False]

    def _renplay_poll_bridge():
        if _renplay_bridge_cls is None:
            return
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
            elif cmd == 9:
                try:
                    import pygame_sdl2 as _pg
                except ImportError:
                    import pygame as _pg
                _renplay_kbd_state[0] = not _renplay_kbd_state[0]
                if _renplay_kbd_state[0]:
                    _pg.key.start_text_input()
                else:
                    _pg.key.stop_text_input()
        except Exception:
            pass

    if _renplay_poll_bridge not in config.periodic_callbacks:
        config.periodic_callbacks.append(_renplay_poll_bridge)
