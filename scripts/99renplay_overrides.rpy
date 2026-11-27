# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Loaded from renpy/common after game options.rpy so RenPlay runtime toggles,
# native iOS keyboard hooks, and the HUD command queue apply across 7.x and 8.x.

init 999 python:
    import ctypes as _renplay_ctypes
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

    _renplay_c_consume_cmd = None
    _renplay_c_start_input = None
    _renplay_c_stop_input = None
    _renplay_c_is_shown = None
    _renplay_c_reopen = None
    _renplay_c_consume_key = None

    try:
        _renplay_self_lib = _renplay_ctypes.CDLL(None)
        _renplay_c_consume_cmd = _renplay_self_lib.renplay_bridge_consume_command
        _renplay_c_consume_cmd.argtypes = []
        _renplay_c_consume_cmd.restype = _renplay_ctypes.c_int

        _renplay_c_start_input = _renplay_self_lib.renplay_bridge_start_text_input
        _renplay_c_start_input.argtypes = []
        _renplay_c_start_input.restype = None

        _renplay_c_stop_input = _renplay_self_lib.renplay_bridge_stop_text_input
        _renplay_c_stop_input.argtypes = []
        _renplay_c_stop_input.restype = None

        _renplay_c_is_shown = _renplay_self_lib.renplay_bridge_is_keyboard_shown
        _renplay_c_is_shown.argtypes = []
        _renplay_c_is_shown.restype = _renplay_ctypes.c_int

        _renplay_c_reopen = _renplay_self_lib.renplay_bridge_reopen_if_active
        _renplay_c_reopen.argtypes = []
        _renplay_c_reopen.restype = None

        _renplay_c_consume_key = _renplay_self_lib.renplay_bridge_consume_key_event
        _renplay_c_consume_key.argtypes = [_renplay_ctypes.c_char_p, _renplay_ctypes.c_size_t]
        _renplay_c_consume_key.restype = _renplay_ctypes.c_int
    except Exception:
        _renplay_c_consume_cmd = None

    _renplay_pg_mods = []
    try:
        _core_pg = getattr(renpy.display.core, "pygame", None)
        if _core_pg is not None:
            _renplay_pg_mods.append(_core_pg)
    except Exception:
        pass
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

    if _renplay_c_start_input is not None and _renplay_pg_mods:
        def _renplay_has_screen_keyboard():
            return True

        def _renplay_is_screen_keyboard_shown():
            try:
                return int(_renplay_c_is_shown()) != 0
            except Exception:
                return False

        def _renplay_start_text_input(*args, **kwargs):
            try:
                _renplay_c_start_input()
            except Exception:
                pass

        def _renplay_stop_text_input(*args, **kwargs):
            try:
                _renplay_c_stop_input()
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
                                    _renplay_c_reopen()
                        except Exception:
                            pass
                    return _orig_input_event(self, ev, x, y, st)

                _input_cls.render = _renplay_input_render
                _input_cls.event = _renplay_input_event
                _input_cls._renplay_hooked = True
        except Exception:
            pass

    def _renplay_post_key(vk, scancode, down_unicode):
        if _renplay_pg is None:
            return
        _renplay_pg.event.post(_renplay_pg.event.Event(
            _renplay_pg.KEYDOWN,
            key=vk,
            scancode=scancode,
            unicode=down_unicode,
            mod=0,
            repeat=False,
        ))
        _renplay_pg.event.post(_renplay_pg.event.Event(
            _renplay_pg.KEYUP,
            key=vk,
            scancode=scancode,
            unicode=u"",
            mod=0,
            repeat=False,
        ))

    _renplay_key_buf = _renplay_ctypes.create_string_buffer(512)

    def _renplay_poll_bridge():
        if _renplay_c_consume_cmd is None:
            return

        if _renplay_pg is not None and _renplay_c_consume_key is not None:
            try:
                while True:
                    n = int(_renplay_c_consume_key(_renplay_key_buf, 512))
                    if n <= 0:
                        break
                    payload = _renplay_key_buf.raw[:n].decode("utf-8", "replace")
                    if payload.startswith("T:"):
                        try:
                            _renplay_pg.event.set_allowed(_renplay_pg.TEXTINPUT)
                        except Exception:
                            pass
                        _renplay_pg.event.post(_renplay_pg.event.Event(
                            _renplay_pg.TEXTINPUT,
                            text=payload[2:],
                        ))
                    elif payload == "K:BACKSPACE":
                        _renplay_post_key(
                            _renplay_pg.K_BACKSPACE,
                            getattr(_renplay_pg, "KSCAN_BACKSPACE", 42),
                            u"\b",
                        )
                    elif payload == "K:RETURN":
                        _renplay_post_key(
                            _renplay_pg.K_RETURN,
                            getattr(_renplay_pg, "KSCAN_RETURN", 40),
                            u"\r",
                        )
            except Exception:
                pass

        try:
            cmd = int(_renplay_c_consume_cmd())
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
