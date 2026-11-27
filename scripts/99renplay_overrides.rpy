# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Loaded from renpy/common after game options.rpy so RenPlay runtime toggles,
# native iOS keyboard hooks, and the HUD command queue apply across 7.x and 8.x.

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
