# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Loaded from renpy/common after game options.rpy so RenPlay runtime toggles,
# native iOS keyboard/mouse hooks, variable tools, and HUD commands apply across 7.x and 8.x.

init 999 python:
    import ctypes as _renplay_ctypes
    import json as _renplay_json
    import os as _renplay_os
    import sys as _renplay_sys
    import time as _renplay_time
    import uuid as _renplay_uuid

    _renplay_safe_mode = _renplay_os.environ.get("RENPY_SAFE_MODE") == "1"

    def _renplay_clear_autoload():
        _renplay_os.environ.pop("RENPY_AUTO_LOAD", None)

    try:
        if _renplay_clear_autoload not in config.after_load_callbacks:
            config.after_load_callbacks.append(_renplay_clear_autoload)
    except Exception:
        pass

    if _renplay_safe_mode:
        try:
            config.image_cache_size_mb = 64
            config.gl_powersave = True
            config.predict_statements = 0
            config.autoreload = False
        except Exception:
            pass
    else:
        if _renplay_os.environ.get("RENPY_DEV_MODE") == "1":
            config.developer = True
        if _renplay_os.environ.get("RENPY_ENABLE_CONSOLE") == "1":
            config.console = True
        if _renplay_os.environ.get("RENPY_FORCE_ROLLBACK") == "1":
            config.rollback_enabled = True
            if getattr(config, "hard_rollback_limit", 0) < 256:
                config.hard_rollback_limit = 256
        if _renplay_os.environ.get("RENPY_FORCE_SKIP") == "1":
            config.allow_skipping = True
            config.skip_indicator = True
        if _renplay_os.environ.get("RENPY_FORCE_UNSEEN_SKIP") == "1":
            preferences.skip_unseen = True

        if _renplay_os.environ.get("RENPY_COMPAT_PATCHES") == "1":
            try:
                config.autoreload = False
                config.quit_on_mobile_background = False
            except Exception:
                pass
            if not hasattr(_renplay_os, "startfile"):
                _renplay_os.startfile = lambda *args, **kwargs: None
            if not hasattr(_renplay_ctypes, "windll"):
                class _RenPlayWinFunc(object):
                    def __init__(self, dll_name, fn_name):
                        self._dll_name = dll_name
                        self._fn_name = fn_name
                    def __call__(self, *args, **kwargs):
                        if self._dll_name == "user32" and self._fn_name == "GetSystemMetrics":
                            idx = args[0] if args else 0
                            if idx == 0:
                                return int(getattr(config, "screen_width", 1920) or 1920)
                            if idx == 1:
                                return int(getattr(config, "screen_height", 1080) or 1080)
                        return 0
                class _RenPlayWinLib(object):
                    def __init__(self, dll_name):
                        self._dll_name = dll_name
                    def __getattr__(self, fn_name):
                        return _RenPlayWinFunc(self._dll_name, fn_name)
                class _RenPlayWinDLL(object):
                    def __getattr__(self, dll_name):
                        return _RenPlayWinLib(dll_name.lower())
                _renplay_ctypes.windll = _RenPlayWinDLL()
            try:
                _loader = renpy.loader
                if not getattr(_loader, "_renplay_compat_hooked", False):
                    _str_types = (str, type(u""))
                    _orig_load = getattr(_loader, "load", None)
                    _orig_loadable = getattr(_loader, "loadable", None)
                    if _orig_load is not None:
                        def _renplay_norm_load(name, *args, **kwargs):
                            if isinstance(name, _str_types) and "\\" in name:
                                name = name.replace("\\", "/")
                            return _orig_load(name, *args, **kwargs)
                        _loader.load = _renplay_norm_load
                    if _orig_loadable is not None:
                        def _renplay_norm_loadable(name, *args, **kwargs):
                            if isinstance(name, _str_types) and "\\" in name:
                                name = name.replace("\\", "/")
                            return _orig_loadable(name, *args, **kwargs)
                        _loader.loadable = _renplay_norm_loadable
                    _loader._renplay_compat_hooked = True
            except Exception:
                pass

    try:
        _vol_str = _renplay_os.environ.get("RENPY_MASTER_VOLUME", "")
        if _vol_str:
            _vol_val = max(0.0, min(1.0, float(_vol_str)))
            if hasattr(preferences, "set_volume"):
                preferences.set_volume("main", _vol_val)
            elif hasattr(preferences, "volumes") and isinstance(preferences.volumes, dict):
                preferences.volumes["main"] = _vol_val
    except Exception:
        pass

    _renplay_saved_textbox_bg = {}

    def _renplay_apply_transparent_textbox(enabled):
        try:
            for _sname in ("say_window", "window"):
                _st = getattr(style, _sname, None)
                if _st is None:
                    continue
                if enabled:
                    if _sname not in _renplay_saved_textbox_bg:
                        try:
                            _renplay_saved_textbox_bg[_sname] = _st.background
                        except Exception:
                            _renplay_saved_textbox_bg[_sname] = None
                    _st.background = Solid((0, 0, 0, 96))
                elif _sname in _renplay_saved_textbox_bg:
                    _st.background = _renplay_saved_textbox_bg[_sname]
            try:
                if enabled:
                    preferences.text_box_opacity = 0.35
                elif hasattr(preferences, "text_box_opacity"):
                    preferences.text_box_opacity = 1.0
            except Exception:
                pass
            renpy.exports.restart_interaction()
        except Exception:
            pass

    if not _renplay_safe_mode and _renplay_os.environ.get("RENPY_TRANSPARENT_TEXTBOX") == "1":
        _renplay_apply_transparent_textbox(True)

    _renplay_c_consume_cmd = None
    _renplay_c_start_input = None
    _renplay_c_stop_input = None
    _renplay_c_is_shown = None
    _renplay_c_reopen = None
    _renplay_c_consume_key = None
    _renplay_c_report_stats = None
    _renplay_c_consume_mouse = None
    _renplay_c_consume_rpc = None
    _renplay_c_post_rpc_reply = None

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

        _renplay_c_report_stats = getattr(_renplay_self_lib, "renplay_bridge_report_stats", None)
        if _renplay_c_report_stats is not None:
            _renplay_c_report_stats.argtypes = [_renplay_ctypes.c_int, _renplay_ctypes.c_int]
            _renplay_c_report_stats.restype = None

        _renplay_c_consume_mouse = getattr(_renplay_self_lib, "renplay_bridge_consume_mouse_event", None)
        if _renplay_c_consume_mouse is not None:
            _renplay_c_consume_mouse.argtypes = [
                _renplay_ctypes.POINTER(_renplay_ctypes.c_float),
                _renplay_ctypes.POINTER(_renplay_ctypes.c_float),
                _renplay_ctypes.POINTER(_renplay_ctypes.c_int),
                _renplay_ctypes.POINTER(_renplay_ctypes.c_int),
            ]
            _renplay_c_consume_mouse.restype = _renplay_ctypes.c_int

        _renplay_c_consume_rpc = getattr(_renplay_self_lib, "renplay_bridge_consume_rpc", None)
        if _renplay_c_consume_rpc is not None:
            _renplay_c_consume_rpc.argtypes = [_renplay_ctypes.c_char_p, _renplay_ctypes.c_size_t]
            _renplay_c_consume_rpc.restype = _renplay_ctypes.c_int

        _renplay_c_post_rpc_reply = getattr(_renplay_self_lib, "renplay_bridge_post_rpc_reply", None)
        if _renplay_c_post_rpc_reply is not None:
            _renplay_c_post_rpc_reply.argtypes = [_renplay_ctypes.c_char_p]
            _renplay_c_post_rpc_reply.restype = None
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

        if not _renplay_safe_mode:
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

    _renplay_mod_mask = 0
    _renplay_session_id = str(_renplay_uuid.uuid4())
    _renplay_session_start = _renplay_time.time()
    _renplay_last_stats_report = 0.0
    _renplay_last_stats_flush = 0.0
    _renplay_frozen_vars = {}

    def _renplay_post_key(vk, scancode, down_unicode, mod=0):
        if _renplay_pg is None:
            return
        _renplay_pg.event.post(_renplay_pg.event.Event(
            _renplay_pg.KEYDOWN,
            key=vk,
            scancode=scancode,
            unicode=down_unicode,
            mod=mod,
            repeat=False,
        ))
        _renplay_pg.event.post(_renplay_pg.event.Event(
            _renplay_pg.KEYUP,
            key=vk,
            scancode=scancode,
            unicode=u"",
            mod=mod,
            repeat=False,
        ))

    def _renplay_post_rpc_reply_obj(obj):
        if _renplay_c_post_rpc_reply is None:
            return
        try:
            raw = _renplay_json.dumps(obj)
            if not isinstance(raw, bytes):
                raw = raw.encode("utf-8")
            _renplay_c_post_rpc_reply(raw)
        except Exception:
            pass

    def _renplay_collect_dialogue_counts():
        try:
            seen = int(renpy.count_seen_dialogue_blocks())
            total = int(renpy.count_dialogue_blocks())
            return seen, total
        except Exception:
            return 0, 0

    def _renplay_write_stats_file(seen, total):
        save_dir = _renplay_os.environ.get("RENPY_SAVE_DIRECTORY", "")
        if not save_dir or not _renplay_os.path.isdir(save_dir):
            return
        payload = {
            "sessionId": _renplay_session_id,
            "elapsedSeconds": max(0.0, float(_renplay_time.time() - _renplay_session_start)),
            "seenBlocks": int(seen),
            "totalBlocks": int(total),
        }
        tmp_path = _renplay_os.path.join(save_dir, ".renplay_stats.tmp")
        dst_path = _renplay_os.path.join(save_dir, ".renplay_stats.json")
        try:
            fp = open(tmp_path, "w")
            try:
                fp.write(_renplay_json.dumps(payload))
            finally:
                fp.close()
            _renplay_os.rename(tmp_path, dst_path)
        except Exception:
            pass

    def _renplay_scope_object(scope_name):
        if scope_name == "persistent":
            return renpy.game.persistent
        return renpy.store

    def _renplay_var_kind_and_preview(val):
        if isinstance(val, bool):
            return "bool", ("true" if val else "false"), True
        if isinstance(val, int):
            return "int", str(val), True
        if isinstance(val, float):
            return "float", str(val), True
        if isinstance(val, type(u"")) or isinstance(val, str):
            s = str(val) if len(val) <= 120 else str(val[:120]) + "..."
            return "str", s, True
        try:
            rep = repr(val)
            if len(rep) > 120:
                rep = rep[:120] + "..."
            return "object", rep, False
        except Exception:
            return "object", "<object>", False

    def _renplay_handle_rpc(req):
        op = req.get("op", "")
        if op == "set_volume":
            val = max(0.0, min(1.0, float(req.get("value", 1.0))))
            if hasattr(preferences, "set_volume"):
                preferences.set_volume("main", val)
            elif hasattr(preferences, "volumes") and isinstance(preferences.volumes, dict):
                preferences.volumes["main"] = val
            return
        if op == "set_transparent_textbox":
            _renplay_apply_transparent_textbox(bool(req.get("enabled", False)))
            return
        if op == "open_console":
            try:
                _console.enter()
            except Exception:
                pass
            return
        if op == "reload_script":
            try:
                renpy.exports.reload_script()
            except Exception:
                pass
            return
        if op == "set_variants":
            variants = req.get("variants", [])
            if isinstance(variants, list) and variants:
                try:
                    clean_vars = [str(v) for v in variants if v]
                    config.variants = clean_vars + [None]
                    try:
                        renpy.display.touch = ("touch" in clean_vars)
                    except Exception:
                        pass
                    try:
                        renpy.style.rebuild()
                    except Exception:
                        pass
                    renpy.exports.restart_interaction()
                    _renplay_post_rpc_reply_obj({"op": "set_variants", "ok": True, "variants": clean_vars})
                except Exception as exc:
                    _renplay_post_rpc_reply_obj({"op": "set_variants", "ok": False, "error": str(exc)})
            return
        if op == "unlock_gallery":
            try:
                p = renpy.game.persistent
                if getattr(p, "_seen_ever", None) is None or not isinstance(p._seen_ever, dict):
                    p._seen_ever = {}
                for k in getattr(renpy.game.script, "namemap", {}).keys():
                    p._seen_ever[k] = True
                if getattr(p, "_seen_images", None) is None:
                    try:
                        p._seen_images = {}
                    except Exception:
                        pass
                imgs = getattr(renpy.display.image, "images", {})
                if isinstance(p._seen_images, dict):
                    for ik in imgs.keys():
                        p._seen_images[ik] = True
                elif isinstance(p._seen_images, set):
                    for ik in imgs.keys():
                        p._seen_images.add(ik)
                _gi_cls = getattr(renpy.store, "__GalleryImage", None)
                if _gi_cls is not None:
                    _gi_cls.check_unlock = lambda self, all_prior: True
                _gb_cls = getattr(renpy.store, "__GalleryButton", None)
                if _gb_cls is not None:
                    _gb_cls.check_unlock = lambda self: True
                _rp_cls = getattr(renpy.store, "Replay", None)
                if _rp_cls is not None:
                    _rp_cls.get_sensitive = lambda self: True
                renpy.exports.seen_image = lambda name: True
                renpy.exports.seen_label = lambda label: True
                if hasattr(renpy, "seen_image"):
                    renpy.seen_image = lambda name: True
                if hasattr(renpy, "seen_label"):
                    renpy.seen_label = lambda label: True
                try:
                    for obj in list(renpy.store.__dict__.values()):
                        if hasattr(obj, "buttons") and hasattr(obj, "make_button"):
                            try:
                                obj.unlocked_advance = True
                            except Exception:
                                pass
                            for _bname, btn in getattr(obj, "buttons", {}).items():
                                try:
                                    btn.conditions = []
                                    for _gimg in getattr(btn, "images", []):
                                        try:
                                            _gimg.conditions = []
                                        except Exception:
                                            pass
                                except Exception:
                                    pass
                except Exception:
                    pass
                renpy.loadsave.save_persistent()
                renpy.exports.restart_interaction()
                _renplay_post_rpc_reply_obj({
                    "op": "unlock_gallery",
                    "ok": True,
                    "images": len(imgs),
                    "blocks": len(getattr(renpy.game.script, "namemap", {})),
                })
            except Exception as exc:
                _renplay_post_rpc_reply_obj({"op": "unlock_gallery", "ok": False, "error": str(exc)})
            return
        if op == "list_vars":
            scope = req.get("scope", "store")
            query = str(req.get("query", "")).strip().lower()
            target = _renplay_scope_object(scope)
            items = []
            skip_names = set(["persistent", "renpy", "config", "store", "preferences", "style", "build", "os", "sys"])
            raw_dict = getattr(target, "__dict__", {})
            for k in sorted(raw_dict.keys()):
                ks = str(k)
                if ks.startswith("_") or ks in skip_names:
                    continue
                if query and query not in ks.lower():
                    continue
                val = raw_dict[k]
                if callable(val) or isinstance(val, type(_renplay_os)):
                    continue
                kind, preview, editable = _renplay_var_kind_and_preview(val)
                items.append({
                    "name": ks,
                    "kind": kind,
                    "value": preview,
                    "editable": editable,
                    "frozen": (scope, ks) in _renplay_frozen_vars,
                })
                if len(items) >= 150:
                    break
            _renplay_post_rpc_reply_obj({"op": "list_vars", "scope": scope, "items": items})
            return
        if op == "set_var":
            scope = req.get("scope", "store")
            name = str(req.get("name", ""))
            kind = str(req.get("kind", "str"))
            raw_val = str(req.get("value", ""))
            freeze = bool(req.get("freeze", False))
            target = _renplay_scope_object(scope)
            try:
                if kind == "bool":
                    parsed = raw_val.strip().lower() in ("1", "true", "yes", "on")
                elif kind == "int":
                    parsed = int(raw_val.strip())
                elif kind == "float":
                    parsed = float(raw_val.strip())
                else:
                    parsed = raw_val
                setattr(target, name, parsed)
                if freeze:
                    _renplay_frozen_vars[(scope, name)] = parsed
                renpy.exports.restart_interaction()
                _renplay_post_rpc_reply_obj({"op": "set_var", "ok": True, "name": name})
            except Exception as exc:
                _renplay_post_rpc_reply_obj({"op": "set_var", "ok": False, "error": str(exc)})
            return
        if op == "toggle_freeze":
            scope = req.get("scope", "store")
            name = str(req.get("name", ""))
            key = (scope, name)
            if key in _renplay_frozen_vars:
                del _renplay_frozen_vars[key]
                frozen = False
            else:
                target = _renplay_scope_object(scope)
                _renplay_frozen_vars[key] = getattr(target, name, None)
                frozen = True
            _renplay_post_rpc_reply_obj({"op": "toggle_freeze", "scope": scope, "name": name, "frozen": frozen})

    _renplay_key_buf = _renplay_ctypes.create_string_buffer(512)
    _renplay_rpc_buf = _renplay_ctypes.create_string_buffer(16384)
    _renplay_mx = _renplay_ctypes.c_float(0.0)
    _renplay_my = _renplay_ctypes.c_float(0.0)
    _renplay_mbtn = _renplay_ctypes.c_int(1)
    _renplay_mtype = _renplay_ctypes.c_int(0)

    def _renplay_poll_bridge():
        global _renplay_mod_mask, _renplay_last_stats_report, _renplay_last_stats_flush
        if _renplay_c_consume_cmd is None:
            return

        if _renplay_frozen_vars:
            for (_fscope, _fname), _fval in list(_renplay_frozen_vars.items()):
                try:
                    setattr(_renplay_scope_object(_fscope), _fname, _fval)
                except Exception:
                    pass

        now = _renplay_time.time()
        if _renplay_c_report_stats is not None and now - _renplay_last_stats_report >= 2.0:
            _renplay_last_stats_report = now
            seen, total = _renplay_collect_dialogue_counts()
            _renplay_c_report_stats(seen, total)
            if now - _renplay_last_stats_flush >= 10.0:
                _renplay_last_stats_flush = now
                _renplay_write_stats_file(seen, total)

        if _renplay_pg is not None and _renplay_c_consume_key is not None:
            try:
                while True:
                    n = int(_renplay_c_consume_key(_renplay_key_buf, 512))
                    if n <= 0:
                        break
                    payload = _renplay_key_buf.raw[:n].decode("utf-8", "replace")
                    if payload.startswith("T:"):
                        text = payload[2:]
                        if _renplay_mod_mask != 0:
                            for ch in text:
                                _renplay_post_key(ord(ch.lower()), 0, ch, mod=_renplay_mod_mask)
                        else:
                            try:
                                _renplay_pg.event.set_allowed(_renplay_pg.TEXTINPUT)
                            except Exception:
                                pass
                            _renplay_pg.event.post(_renplay_pg.event.Event(
                                _renplay_pg.TEXTINPUT,
                                text=text,
                            ))
                    elif payload == "K:BACKSPACE":
                        _renplay_post_key(
                            _renplay_pg.K_BACKSPACE,
                            getattr(_renplay_pg, "KSCAN_BACKSPACE", 42),
                            u"\b",
                            mod=_renplay_mod_mask,
                        )
                    elif payload == "K:RETURN":
                        _renplay_post_key(
                            _renplay_pg.K_RETURN,
                            getattr(_renplay_pg, "KSCAN_RETURN", 40),
                            u"\r",
                            mod=_renplay_mod_mask,
                        )
                    elif payload == "K:ESCAPE":
                        _renplay_post_key(
                            _renplay_pg.K_ESCAPE,
                            getattr(_renplay_pg, "KSCAN_ESCAPE", 41),
                            u"\x1b",
                            mod=_renplay_mod_mask,
                        )
                    elif payload.startswith("M:CTRL:"):
                        _ctrl = getattr(_renplay_pg, "KMOD_LCTRL", 0x0040)
                        if payload.endswith(":1"):
                            _renplay_mod_mask |= _ctrl
                        else:
                            _renplay_mod_mask &= ~_ctrl
                    elif payload.startswith("M:ALT:"):
                        _alt = getattr(_renplay_pg, "KMOD_LALT", 0x0100)
                        if payload.endswith(":1"):
                            _renplay_mod_mask |= _alt
                        else:
                            _renplay_mod_mask &= ~_alt
            except Exception:
                pass

        if _renplay_pg is not None and _renplay_c_consume_mouse is not None:
            try:
                pw, ph = renpy.get_physical_size()
                while int(_renplay_c_consume_mouse(
                    _renplay_ctypes.byref(_renplay_mx),
                    _renplay_ctypes.byref(_renplay_my),
                    _renplay_ctypes.byref(_renplay_mbtn),
                    _renplay_ctypes.byref(_renplay_mtype),
                )) != 0:
                    px = int(max(0.0, min(1.0, float(_renplay_mx.value))) * max(1, int(pw)))
                    py = int(max(0.0, min(1.0, float(_renplay_my.value))) * max(1, int(ph)))
                    etype = int(_renplay_mtype.value)
                    btn = int(_renplay_mbtn.value)
                    if etype == 0:
                        _renplay_pg.event.post(_renplay_pg.event.Event(
                            _renplay_pg.MOUSEMOTION,
                            pos=(px, py),
                            rel=(0, 0),
                            buttons=(0, 0, 0),
                        ))
                    elif etype == 1:
                        _renplay_pg.event.post(_renplay_pg.event.Event(
                            _renplay_pg.MOUSEBUTTONDOWN,
                            pos=(px, py),
                            button=btn,
                        ))
                    elif etype == 2:
                        _renplay_pg.event.post(_renplay_pg.event.Event(
                            _renplay_pg.MOUSEBUTTONUP,
                            pos=(px, py),
                            button=btn,
                        ))
            except Exception:
                pass

        if _renplay_c_consume_rpc is not None:
            try:
                while True:
                    rn = int(_renplay_c_consume_rpc(_renplay_rpc_buf, 16384))
                    if rn <= 0:
                        break
                    raw_req = _renplay_rpc_buf.raw[:rn].decode("utf-8", "replace")
                    _renplay_handle_rpc(_renplay_json.loads(raw_req))
            except Exception:
                pass

        try:
            cmd = int(_renplay_c_consume_cmd())
        except Exception:
            return
        if cmd == 0:
            return
        if cmd == 10:
            seen, total = _renplay_collect_dialogue_counts()
            _renplay_write_stats_file(seen, total)
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
