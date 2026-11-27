# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Launch entrypoint for embedded Ren'Py 7.x (Python 2.7) and 8.x (Python 3.x)
# runtimes inside RenPlay on iOS.

from __future__ import print_function, absolute_import

import os
import socket
import sys
import warnings

os.system = lambda cmd: 0

_ALLOW_NETWORK = os.environ.get("RENPY_ALLOW_NETWORK", "0") == "1"
if not _ALLOW_NETWORK:
    _orig_connect = socket.socket.connect

    def _blocked_connect(self, address, *args, **kwargs):
        host = address[0] if isinstance(address, tuple) and len(address) > 0 else ""
        if host in ("127.0.0.1", "::1", "localhost"):
            return _orig_connect(self, address, *args, **kwargs)
        raise socket.error("Network access disabled by RenPlay")

    socket.socket.connect = _blocked_connect

_GAME_ROOT = os.environ.get("RENPY_GAME_DIRECTORY", "")
if _GAME_ROOT and os.path.isdir(_GAME_ROOT):
    os.chdir(_GAME_ROOT)

_orig_expanduser = os.path.expanduser


def _ios_expanduser(path):
    if path.startswith("~"):
        base = _GAME_ROOT if _GAME_ROOT else os.getcwd()
        rest = path[1:].lstrip("/\\")
        return os.path.join(base, rest) if rest else base
    return _orig_expanduser(path)


os.path.expanduser = _ios_expanduser


def path_to_gamedir(basedir, name):
    if _GAME_ROOT:
        candidate = os.path.join(_GAME_ROOT, "game")
        if os.path.isdir(candidate):
            return candidate
        if os.path.isdir(_GAME_ROOT):
            return _GAME_ROOT

    for sub in (name, "game", "data", "launcher/game"):
        if sub == "renpy":
            continue
        candidate = os.path.join(basedir, sub)
        if os.path.isdir(candidate):
            return candidate

    return basedir


def path_to_common(renpy_base):
    common = os.path.join(renpy_base, "renpy", "common")
    if os.path.isdir(common):
        return common
    return None


def path_to_saves(gamedir, save_directory=None):
    override = os.environ.get("RENPY_SAVE_DIRECTORY", "")
    if override:
        if not os.path.isdir(override):
            try:
                os.makedirs(override)
            except OSError:
                pass
        return override

    fallback = os.path.join(gamedir, "saves")
    if not os.path.isdir(fallback):
        try:
            os.makedirs(fallback)
        except OSError:
            pass
    return fallback


def path_to_logdir(basedir):
    override = os.environ.get("RENPY_LOG_DIRECTORY", "")
    if override:
        if not os.path.isdir(override):
            try:
                os.makedirs(override)
            except OSError:
                pass
        return override
    return basedir


_MP_DIR = os.environ.get("RENPY_MULTIPERSISTENT", "")
if _MP_DIR and not os.path.isdir(_MP_DIR):
    try:
        os.makedirs(_MP_DIR)
    except OSError:
        pass


_SMB_HOOK_INSTALLED = False


def _install_renplay_smb_loader(renpy_mod):
    global _SMB_HOOK_INSTALLED
    if _SMB_HOOK_INSTALLED:
        return
    _SMB_HOOK_INSTALLED = True

    candidates = []
    if _GAME_ROOT:
        candidates.append(os.path.join(_GAME_ROOT, ".renplay_smb_index.tsv"))
    gamedir = getattr(renpy_mod.config, "gamedir", "")
    if gamedir:
        candidates.append(os.path.join(gamedir, ".renplay_smb_index.tsv"))
        candidates.append(os.path.join(os.path.dirname(gamedir), ".renplay_smb_index.tsv"))

    manifest_path = None
    for cand in candidates:
        if cand and os.path.isfile(cand):
            manifest_path = cand
            break
    if manifest_path is None:
        return

    import ctypes
    import io
    import unicodedata

    ssize_t = getattr(ctypes, "c_ssize_t", ctypes.c_long)
    pread_fn = None
    try:
        proc = ctypes.CDLL(None)
        fn = getattr(proc, "renplay_smb_pread", None)
        if fn is not None:
            fn.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
            fn.restype = ssize_t
            pread_fn = fn
    except Exception:
        pread_fn = None

    if pread_fn is None:
        try:
            import pyobjus
            bridge = pyobjus.autoclass("RenPlayRuntimeBridge")
            addr = int(bridge.smbPreadSymbolAddress())
            if addr:
                cft = ctypes.CFUNCTYPE(
                    ssize_t,
                    ctypes.c_char_p,
                    ctypes.c_uint64,
                    ctypes.c_void_p,
                    ctypes.c_size_t,
                )
                pread_fn = cft(addr)
        except Exception:
            pread_fn = None

    if pread_fn is None:
        print("RenPlay SMB loader warning: renplay_smb_pread symbol unavailable")
        return

    entries = {}
    entries_lower = {}
    logical_list = []

    try:
        with io.open(manifest_path, "r", encoding="utf-8") as fp:
            for raw_line in fp:
                line = raw_line.rstrip("\r\n")
                if not line or line.startswith("#"):
                    continue
                cols = line.split("\t")
                if len(cols) < 4:
                    continue
                kind, logical, smb_rel, spec = cols[0], cols[1], cols[2], cols[3]
                smb_rel_bytes = smb_rel.encode("utf-8") if not isinstance(smb_rel, bytes) else smb_rel
                if kind == "L":
                    size = int(spec)
                    record = [(smb_rel_bytes, 0, size, b"")]
                    total_size = size
                elif kind == "R":
                    segs = []
                    total_size = 0
                    for part in spec.split(";"):
                        if not part:
                            continue
                        pfields = part.split(":")
                        if len(pfields) < 2:
                            continue
                        off = int(pfields[0])
                        body_len = int(pfields[1])
                        hex_prefix = pfields[2] if len(pfields) >= 3 else ""
                        if hex_prefix:
                            if hasattr(bytes, "fromhex"):
                                prefix = bytes.fromhex(hex_prefix)
                            else:
                                prefix = hex_prefix.decode("hex")
                        else:
                            prefix = b""
                        segs.append((smb_rel_bytes, off, body_len, prefix))
                        total_size += len(prefix) + body_len
                    if not segs:
                        continue
                    record = segs
                else:
                    continue

                if logical not in entries:
                    logical_list.append(logical)
                entries[logical] = (record, total_size)
                entries_lower[unicodedata.normalize("NFC", logical.lower())] = logical
    except Exception as exc:
        print("RenPlay SMB manifest parse error:", exc)
        return

    loader = renpy_mod.loader
    buffer_factory = getattr(loader, "RWopsIO", None)
    io_buffer_cls = None
    if buffer_factory is None:
        try:
            from renpy.pygame.iostream import IOBuffer as _IOBuffer
            io_buffer_cls = _IOBuffer
        except Exception:
            io_buffer_cls = None

    def _smb_pread_exact(rel_bytes, offset, length):
        if length <= 0:
            return b""
        buf = ctypes.create_string_buffer(length)
        got_total = 0
        base_ptr = ctypes.addressof(buf)
        while got_total < length:
            n = pread_fn(rel_bytes, offset + got_total, base_ptr + got_total, length - got_total)
            if n <= 0:
                break
            got_total += int(n)
        if got_total == length:
            return buf.raw
        return buf.raw[:got_total]

    def _wrap_memory_stream(data, name):
        if buffer_factory is not None:
            return io.BufferedReader(buffer_factory.from_buffer(data, name=name))
        if io_buffer_cls is not None:
            return io.BufferedReader(io_buffer_cls(data, name=name))
        return io.BytesIO(data)

    class _RenPlaySMBRawIO(io.RawIOBase):
        def __init__(self, name, segments, total_size):
            self.name = name
            self._segments = segments
            self._total_size = total_size
            self._pos = 0
            self._closed = False

        def readable(self):
            return True

        def seekable(self):
            return True

        def writable(self):
            return False

        def tell(self):
            return self._pos

        def seek(self, offset, whence=0):
            if whence == 0:
                new_pos = offset
            elif whence == 1:
                new_pos = self._pos + offset
            elif whence == 2:
                new_pos = self._total_size + offset
            else:
                raise ValueError("Invalid whence")
            if new_pos < 0:
                new_pos = 0
            self._pos = new_pos
            return self._pos

        def read(self, size=-1):
            if self._closed or self._pos >= self._total_size:
                return b""
            if size is None or size < 0:
                want = self._total_size - self._pos
            else:
                want = min(size, self._total_size - self._pos)
            if want <= 0:
                return b""

            chunks = []
            cur_voff = 0
            target_start = self._pos
            target_end = self._pos + want

            for rel_bytes, smb_off, body_len, prefix in self._segments:
                plen = len(prefix)
                if plen > 0:
                    p_start = cur_voff
                    p_end = p_start + plen
                    ov_start = max(p_start, target_start)
                    ov_end = min(p_end, target_end)
                    if ov_end > ov_start:
                        chunks.append(prefix[ov_start - p_start : ov_end - p_start])
                    cur_voff = p_end

                if body_len > 0:
                    b_start = cur_voff
                    b_end = b_start + body_len
                    ov_start = max(b_start, target_start)
                    ov_end = min(b_end, target_end)
                    if ov_end > ov_start:
                        read_off = smb_off + (ov_start - b_start)
                        data = _smb_pread_exact(rel_bytes, read_off, ov_end - ov_start)
                        chunks.append(data)
                    cur_voff = b_end

                if cur_voff >= target_end:
                    break

            joined = b"".join(chunks)
            self._pos += len(joined)
            return joined

        def readinto(self, b):
            data = self.read(len(b))
            n = len(data)
            if n > 0:
                view = memoryview(b)
                view[:n] = data
            return n

        def close(self):
            self._closed = True
            super(_RenPlaySMBRawIO, self).close()

    def _renplay_scandirfiles_smb(add, seen):
        files = loader.game_files
        lower_map = loader.lower_map
        for logical in logical_list:
            add(None, logical, files, seen)
            norm_key = unicodedata.normalize("NFC", logical.lower())
            if norm_key not in lower_map:
                lower_map[norm_key] = logical

    def _renplay_load_from_smb(name):
        item = entries.get(name)
        canonical = name
        if item is None:
            mapped = entries_lower.get(unicodedata.normalize("NFC", name.lower()))
            if mapped is not None:
                canonical = mapped
                item = entries.get(mapped)
        if item is None:
            return None

        segments, total_size = item
        if total_size <= 4 * 1024 * 1024:
            parts = []
            for rel_bytes, smb_off, body_len, prefix in segments:
                if prefix:
                    parts.append(prefix)
                if body_len > 0:
                    parts.append(_smb_pread_exact(rel_bytes, smb_off, body_len))
            return _wrap_memory_stream(b"".join(parts), canonical)

        return io.BufferedReader(_RenPlaySMBRawIO(canonical, segments, total_size))

    _orig_loadable_core = getattr(loader, "loadable_core", None)
    if _orig_loadable_core is not None:
        def _renplay_loadable_core(name):
            norm = unicodedata.normalize("NFC", name.lower())
            if name in entries or norm in entries_lower:
                return True
            return _orig_loadable_core(name)
        loader.loadable_core = _renplay_loadable_core

    loader.scandirfiles_callbacks.append(_renplay_scandirfiles_smb)
    loader.file_open_callbacks.append(_renplay_load_from_smb)


def predefined_searchpath(commondir):
    import renpy

    _install_renplay_smb_loader(renpy)

    searchpath = [renpy.config.gamedir]
    if "RENPY_SEARCHPATH" in os.environ:
        searchpath.extend(os.environ["RENPY_SEARCHPATH"].split("::"))
    if commondir and os.path.isdir(commondir):
        searchpath.append(commondir)
    return searchpath


android = False
renpy_base = os.path.dirname(os.path.abspath(__file__))
if renpy_base not in sys.path:
    sys.path.append(renpy_base)

warnings.simplefilter("ignore", DeprecationWarning)

if os.environ.get("RENPY_COMPAT_PATCHES") == "1" and os.environ.get("RENPY_SAFE_MODE") != "1":
    if not hasattr(os, "startfile"):
        os.startfile = lambda *args, **kwargs: None
    try:
        import ctypes as _compat_ctypes
        if not hasattr(_compat_ctypes, "windll"):
            class _DummyWinFunc(object):
                def __init__(self, dll_name, fn_name):
                    self._dll_name = dll_name
                    self._fn_name = fn_name
                def __call__(self, *args, **kwargs):
                    if self._dll_name == "user32" and self._fn_name == "GetSystemMetrics":
                        idx = args[0] if args else 0
                        return 1920 if idx == 0 else (1080 if idx == 1 else 0)
                    return 0
            class _DummyWinLib(object):
                def __init__(self, dll_name):
                    self._dll_name = dll_name
                def __getattr__(self, fn_name):
                    return _DummyWinFunc(self._dll_name, fn_name)
            class _DummyWinDLL(object):
                def __getattr__(self, dll_name):
                    return _DummyWinLib(dll_name.lower())
            _compat_ctypes.windll = _DummyWinDLL()
    except Exception:
        pass

import renpy.bootstrap

renpy.__main__ = sys.modules[__name__]


if __name__ == "__main__":
    try:
        renpy.bootstrap.bootstrap(renpy_base)
    except SystemExit as exc:
        print("RenPlay engine exited with status:", exc.code)
