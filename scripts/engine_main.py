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

    def _blocked_connect(self, *args, **kwargs):
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


def predefined_searchpath(commondir):
    import renpy

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

import renpy.bootstrap

renpy.__main__ = sys.modules[__name__]


if __name__ == "__main__":
    try:
        renpy.bootstrap.bootstrap(renpy_base)
    except SystemExit as exc:
        print("RenPlay engine exited with status:", exc.code)
