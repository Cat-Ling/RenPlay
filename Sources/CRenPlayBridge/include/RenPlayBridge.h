// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef RENPLAY_BRIDGE_H
#define RENPLAY_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Swizzles UIWindow presentation so SDL2/SDL3 windows automatically bind to the active UIWindowScene.
void renplay_install_sdl_scene_bridge(void);

// Captures the active foreground UIWindowScene before hiding launcher windows.
void renplay_capture_window_scene(void);

// Redirects stdout/stderr to <logDir>/renplay_session.log, loads the Ren'Py framework via dlopen,
// configures RENPY_* environment variables, and launches the engine.
// sdlVersionHint: 2 for SDL2, 3 for SDL3.
int renplay_launch_engine(
    const char *frameworkPath,
    const char *engineBaseDir,
    const char *gameDir,
    const char *saveDir,
    const char *logDir,
    const char *variant,
    int sdlVersionHint,
    int allowNetwork,
    int devMode,
    int forceRollback,
    int forceSkip,
    int lessMemory,
    char *errorBuf,
    size_t errorBufSize
);

// Injects an SDL_QUIT event into the active engine handle.
void renplay_send_sdl_quit(void);

// Injects a key down + key up event into the active engine handle.
void renplay_send_key_press(int sdlKeycode, int sdlScancode);

// Toggles SDL on-screen text input on the active engine handle.
void renplay_toggle_text_input(void);

// Returns the path of the active session log file, or NULL if not launched.
const char *renplay_get_log_file_path(void);

// Returns 1 if an active SDL_uikitwindow is currently visible in the foreground scene, 0 otherwise.
int renplay_has_sdl_window(void);

#ifdef __cplusplus
}
#endif

#endif
