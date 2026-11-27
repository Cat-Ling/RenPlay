# SPDX-FileCopyrightText: 2026 RenPlay Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Loaded from renpy/common after game options.rpy so RenPlay runtime toggles
# apply safely across both Ren'Py 7.x and 8.x.

init 999 python:
    import os as _renplay_os

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
