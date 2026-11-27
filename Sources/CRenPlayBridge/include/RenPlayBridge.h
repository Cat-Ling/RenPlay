// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef RENPLAY_BRIDGE_H
#define RENPLAY_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    RENPLAY_CMD_NONE = 0,
    RENPLAY_CMD_GAME_MENU = 1,
    RENPLAY_CMD_ROLLBACK = 2,
    RENPLAY_CMD_TOGGLE_SKIP = 3,
    RENPLAY_CMD_AUTO_FORWARD = 4,
    RENPLAY_CMD_HIDE_UI = 5,
    RENPLAY_CMD_SCREENSHOT = 6,
    RENPLAY_CMD_QUICK_SAVE = 7,
    RENPLAY_CMD_QUICK_LOAD = 8,
    RENPLAY_CMD_TOGGLE_KEYBOARD = 9,
    RENPLAY_CMD_QUIT = 10
};

// Swizzles UIWindow presentation so SDL2/SDL3 windows automatically bind to the active UIWindowScene.
void renplay_install_sdl_scene_bridge(void);

// Captures the active foreground UIWindowScene before hiding launcher windows.
void renplay_capture_window_scene(void);

// Enqueues an in-game command for Ren'Py's periodic callback (and triggers a detached _exit(0) watchdog on QUIT).
void renplay_request_command(int command);

// Redirects stdout/stderr to <logDir>/renplay_session.log, loads the Ren'Py framework via dlopen,
// configures RENPY_* environment variables, and launches the engine.
// sdlVersionHint: 2 for SDL2, 3 for SDL3.
int renplay_launch_engine(
    const char *frameworkPath,
    const char *engineBaseDir,
    const char *gameDir,
    const char *saveDir,
    const char *logDir,
    const char *multipersistentDir,
    const char *variant,
    const char *autoloadSaveSlot,
    int sdlVersionHint,
    int allowNetwork,
    int devMode,
    int enableConsole,
    int forceRollback,
    int forceSkip,
    int forceUnseenSkip,
    int lessMemory,
    int lessUpdates,
    int transparentTextboxes,
    int compatPatches,
    int safeMode,
    double masterVolume,
    char *errorBuf,
    size_t errorBufSize
);

// Live orientation lock: 0=all, 1=landscapeLeft, 2=landscapeRight, 3=portrait, 4=landscapeBoth.
void renplay_set_preferred_orientation(int mode);
int renplay_get_preferred_orientation(void);

// Reads latest dialogue progress counters reported by Python.
void renplay_get_dialogue_stats(int *seenOut, int *totalOut);

// Enqueues normalized (0..1) virtual mouse movement or click events for Ren'Py.
// eventType: 0=move, 1=down, 2=up; button: 1=left, 3=right.
void renplay_send_virtual_mouse(float normX, float normY, int button, int eventType);

// Queues a JSON RPC request for Ren'Py and polls replies from Objective-C/Swift.
void renplay_enqueue_rpc(const char *jsonUTF8);
int renplay_poll_rpc_reply(char *buf, size_t bufSize);

// Injects an SDL_QUIT event into the active engine handle.
void renplay_send_sdl_quit(void);

// Injects a key down + key up event into the active engine handle.
void renplay_send_key_press(int sdlKeycode, int sdlScancode);

// Toggles SDL on-screen text input on the active engine handle.
void renplay_toggle_text_input(void);

// Returns 1 if the native iOS keyboard is currently active, 0 otherwise.
int renplay_is_keyboard_visible(void);

// Returns 1 when an in-game text input is active and the user hid the keyboard.
int renplay_should_show_keyboard_pill(void);

// Explicitly shows the native keyboard from the HUD reopen pill.
void renplay_show_keyboard_from_ui(void);

// Returns the path of the active session log file, or NULL if not launched.
const char *renplay_get_log_file_path(void);

// Returns 1 if an active SDL_uikitwindow is currently visible in the foreground scene, 0 otherwise.
int renplay_has_sdl_window(void);

// Configures a persistent SMB2/SMB3 share mount for zero-download in-game streaming.
int renplay_configure_smb_mount(
    const char *host,
    int port,
    const char *share,
    const char *baseRelPath,
    const char *username,
    const char *password,
    const char *domain,
    int isGuest,
    char *errorBuf,
    size_t errorBufSize
);

// Tears down the active SMB mount and releases cached handles and blocks.
void renplay_clear_smb_mount(void);

// Returns 1 if an SMB game mount is active, 0 otherwise.
int renplay_smb_is_active(void);

// Thread-safe byte-range read from the active SMB game mount for Ren'Py's Python ctypes loader.
ssize_t renplay_smb_pread(const char *gameRelPath, uint64_t offset, void *buf, size_t length);

// Pure-C runtime bridge functions called from Python via ctypes across Python 2.7 and 3.x.
int renplay_bridge_consume_command(void);
void renplay_bridge_start_text_input(void);
void renplay_bridge_stop_text_input(void);
int renplay_bridge_is_keyboard_shown(void);
void renplay_bridge_reopen_if_active(void);
int renplay_bridge_consume_key_event(char *buf, size_t bufSize);
void renplay_bridge_report_stats(int seenBlocks, int totalBlocks);
int renplay_bridge_consume_mouse_event(float *normX, float *normY, int *button, int *eventType);
int renplay_bridge_consume_rpc(char *buf, size_t bufSize);
void renplay_bridge_post_rpc_reply(const char *jsonUTF8);

#ifdef __cplusplus
}
#endif

#endif
