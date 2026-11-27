# Input, Gestures, Keyboard, and Overlay HUD

Gameplay input combines direct touch on the SDL surface, an optional virtual trackpad cursor, multi-finger gesture shortcuts, a native UIKit text bridge, and a passthrough overlay window.

## 1. Passthrough Overlay HUD (`GameOverlayHUD.swift`)

- `GameOverlayWindow` sits above the SDL window (`windowLevel = .statusBar + 10`) with `canBecomeKey == false` so it never steals key-window focus from `SDL_uikitwindow`.
- `hitTest(_:with:)` delegates to `GameOverlayViewController.hitTestableView(at:with:)`, returning `nil` outside visible buttons/panels/trackpad so gameplay touches pass straight through to SDL.
- **Quick Bar**: Hidden by default (`AppSettings.showQuickBar = false`) and toggleable by long-pressing the floating HUD button (0.45s `UILongPressGestureRecognizer`) or from Overlay Settings. Quick actions cover Rollback, Skip, Keyboard toggle, and HUD panels (`Variants`, `Gallery`, `Progress`, `Variables`, `Overlay Settings`, `Touch Gestures`, `Tools`, `Logs`, `Exit`).
- **Two Persistence Scopes**:
  - `Overlay Settings` and `Touch Gestures` persist immediately via `onPersistSettings` / `onPersistGestures` to `settings.json` and `renplay_configure_gestures`.
  - `Session Overrides` (e.g. `Transparent Textbox`, `Device Variants`, `Unlock Gallery`) send JSON RPC commands over `renplay_enqueue_rpc` for the active session without modifying saved per-game defaults.

## 2. Virtual Mouse Mode

Toggling **Virtual Mouse** opens a transparent trackpad layer inside `GameOverlayViewController` plus a `16x22` `CAShapeLayer` vector pointer arrow:

- Dragging translates deltas scaled by `mouseSpeed` (`AppSettings.virtualMouseSpeed`) into normalized `(0..1)` coordinates and queues `MOUSEMOTION` events via `renplay_send_virtual_mouse`.
- Single-tap posts left-click (`button=1`), two-finger tap posts right-click (`button=3`), and dedicated Left/Right pill buttons support explicit clicks (useful for hover-sensitive UI menus).
- Inside `99renplay_overrides.rpy`, posted pygame events are stamped `renplay_virtual=True` and converted from normalized coordinates into `renpy.get_physical_size()` pixels.

## 3. Multi-Touch Gesture System

Gesture bindings live in `GestureProfile` ([Models.swift](../Sources/RenPlayCore/Models.swift)) with 15 assignable `GestureAction` values (`saveMenu`, `loadMenu`, `gameMenu`, `historyMenu`, `preferencesMenu`, `rollback`, `toggleSkip`, `autoForward`, `hideUI`, `quickSave`, `quickLoad`, `screenshot`, `toggleKeyboard`, `toggleHUD`, `none`).

- **Attachment ([RenPlayBridge.m](../Sources/CRenPlayBridge/RenPlayBridge.m))**: When `SDL_uikitwindow` appears, `RenPlayGestureTarget` installs 6 `UIGestureRecognizer`s (`2-finger tap`, `3-finger tap`, and `2-finger swipe Left/Right/Up/Down`) with `delaysTouchesBegan = NO` and `cancelsTouchesInView = YES`.
- **Conflict Prevention**:
  - `twoFingerTap` requires `threeFingerTap` and all 4 swipe recognizers to fail before firing, preventing a swipe or 3-finger tap from double-triggering `twoFingerTap`.
  - Cooldown of `180ms` (`g_last_gesture_fire_ms`) prevents bounce across back-to-back recognitions, with subtle haptic confirmation (`UIImpactFeedbackGenerator`).
- **Touch-Mouse Race Suppression**:
  - Swizzled `-[UIWindow renplay_sendEvent:]` inspects active touch counts on `SDL_uikitwindow`. Whenever `>= 2` touches are active, it raises `g_multitouch_active` and extends `g_multitouch_suppress_until_ms` by `220ms` after lift-off.
  - When Safe Mode is off, `99renplay_overrides.rpy` wraps `renpy.display.controller.event` to drop SDL `MOUSEBUTTONDOWN`/`MOUSEBUTTONUP`/`MOUSEMOTION` events while `renplay_bridge_should_suppress_touch_mouse() != 0`, and cancels Ren'Py's own internal gesture recognizer, preventing two-finger gestures from advancing dialogue. Events tagged `renplay_virtual=True` bypass this filter so Virtual Mouse right-clicks keep working cleanly.
- **In-Game Menu Shortcuts**: `_renplay_open_menu_screen` maps `save`, `load`, `history` (`text_history`), and `preferences` safely via `renpy.Keymap` and `ShowMenu(...)`.

## 4. Native iOS Keyboard Bridge

- `99renplay_overrides.rpy` binds `pygame.key.start_text_input`, `stop_text_input`, `is_screen_keyboard_shown`, and `text_input_active` to `renplay_bridge_*` C exports, and wraps `renpy.display.behavior.Input.render`/`.event` (unless Safe Mode is active) so tapping an editable Ren'Py `Input` field reopens the keyboard if the user dismissed it.
- `RenPlayHiddenTextField` uses a zero-width-space sentinel (`\u{200B}`) to detect Backspace even on an empty buffer, forwards UTF-8 text as `T:<text>` (`TEXTINPUT` or key chords when modifiers are latched), and attaches an accessory toolbar with `Esc`, latching `Ctrl`/`Alt`, `Enter`, and `Close`.
- Keyboard visibility changes execute via `CFRunLoopPerformBlock(..., kCFRunLoopCommonModes)` so presentation works reliably during SDL's nested runloop.
