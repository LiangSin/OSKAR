# Firmware Feature Design

This document records the behavior implemented on top of the base OSKAR firmware. It focuses on the user-facing controls, HID signals, host-side tooling, and implementation choices that make the controls reliable. General board and original firmware setup information belongs in `README.md`.

## Control Map

| Control | Status | Current behavior |
| --- | --- | --- |
| Encoder clockwise | Implemented | Move forward through the operating system window switcher. |
| Encoder counter-clockwise | Implemented | Move backward through the operating system window switcher. |
| Encoder button | Implemented | Toggle window maximize/minimize. |
| Key1 | Implemented | Sends OSKAR custom HID button `1`; its host action is configurable. |
| Key2 | Implemented | Sends OSKAR custom HID button `2`; its host action is configurable. |
| Key3 | Implemented | Sends OSKAR custom HID button `3`; its host action is configurable. |

## HID Action Model

The firmware exposes three HID paths:

- `KeyboardReport` for regular keyboard usage codes and modifier combinations.
- `MediaKeyboardReport` for consumer/media keys, kept available for future mappings even though the current encoder workflow only uses keyboard reports.
- A vendor-defined OSKAR custom HID interface for the three macro keys.

The layout layer uses these action types:

- `Keycode`: a single keyboard usage code.
- `Combo`: one keyboard usage code plus modifier bits.
- `Toggle`: alternates between two `Combo` actions on each press.
- `Media`: a consumer/media usage code.

`KeyCombo` stores a modifier byte and one `KeyboardUsage`, which keeps future mappings compact and avoids duplicating low-level report construction in layout definitions.

The three macro keys are represented as `OskarButton` values in the layout because they are routed to the custom HID interface rather than the standard keyboard/media action path.

## Encoder Controls

### Window Switching

The encoder is designed to behave like a held `Alt+Tab` session rather than many independent `Alt+Tab` taps. This avoids the common Windows behavior where each isolated `Alt+Tab` returns to the previously focused window because the window order changes after every selection.

Clockwise rotation sends:

- Press `LeftAlt + Tab`.
- Release `Tab`.
- Keep `LeftAlt` held.

Counter-clockwise rotation sends:

- Press `LeftAlt + LeftShift + Tab`.
- Release `Tab` and `LeftShift`.
- Keep `LeftAlt` held.

While `LeftAlt` remains held, the operating system window switcher stays open and additional encoder detents move through the same switcher session.

### Selection Commit

The switch session is committed by timeout:

- If no encoder event arrives for `WINDOW_SWITCH_TIMEOUT` (`1s`), the firmware sends an empty `KeyboardReport`, releasing all keyboard modifiers and selecting the highlighted window.

The encoder button is not overloaded as a switch-session confirm control. It always alternates between `LeftGUI + UpArrow` and `LeftGUI + DownArrow`, matching the common Linux and Windows maximize/restore-minimize window shortcuts.

If `Key1`, `Key2`, `Key3`, or the encoder button is pressed while a switch session is active, that non-rotation event ends the internal switch-session state before its normal HID action is handled. The next encoder rotation starts a fresh held-Alt switch session.

### Encoder Decoding

The rotary encoder is decoded as a quadrature state machine, not as a single-edge direction check.

The task listens to any edge on both encoder channels and converts state transitions with a Gray-code transition table:

- Valid clockwise transitions add `+1`.
- Valid counter-clockwise transitions add `-1`.
- No-op repeated states add `0`.
- Invalid transitions reset the accumulated position and resynchronize.

The firmware emits one encoder event only after `ENCODER_STEPS_PER_DETENT` (`4`) valid transition steps have accumulated in one direction. This reduces false direction changes, bounce-induced backtracking, and bursty multi-window jumps during fast rotation.

### Event Queue

Encoder and button events are sent through `KEY_EVENT_QUEUE`. The queue depth is `8`, which gives short bursts of fast encoder motion enough room before the HID task consumes them. This is intentionally larger than the original tiny queue because losing intermediate encoder events can make the window switcher feel inconsistent.

## Macro Keys

`Key1`, `Key2`, and `Key3` use a vendor-defined HID path instead of standard keyboard usage codes. This avoids collisions with operating-system shortcuts that can claim high function keys such as F13-F15.

The custom interface uses:

- Usage page: `0xFF00` (vendor defined).
- Usage: `0x01`.
- Input report size: 2 bytes.
- Byte 0: button id (`1`, `2`, or `3`).
- Byte 1: pressed state (`1` for press, `0` for release).

The firmware only emits custom HID button reports. It does not store user macros or paste text itself. User-specific behavior lives on the host machine.

## Host-Side Tooling

The host-side interface lives in `host-tools/`.

The first supported target runtimes are:

- Linux: `host-tools/linux/oskar-host.py`, using the system Python 3, Tk GUI, `/dev/hidraw*`, and desktop helper commands. `host-tools/linux/START.sh` opens the user-facing GUI.
- Windows: `host-tools/windows/oskar-host.ps1`, using built-in Windows PowerShell plus a small C# Raw Input HID source file loaded only by the daemon. `host-tools/windows/START.cmd` opens the user-facing GUI.

### Host Config

The daemon config is independent for each key. Every `keyN` stores an `action` (`paste`, `url`, or `app`) plus separate `text`, `url`, and `app` values. The GUI only shows the value for the selected action, while retaining the other two values for later use.

Config locations:

- Linux: `~/.config/oskar/config.txt`, unless `OSKAR_CONFIG` is set.
- Windows: `%APPDATA%\OSKAR\config.txt`, unless `OSKAR_CONFIG` is set.

The daemon reloads config on every key press, so changing config does not require restarting the daemon.

### Host Actions

All three keys can paste their configured text, open their configured URL, or focus/launch their configured application. Existing config files retain the original defaults: Key1 paste, Key2 URL, and Key3 app.

### Registration Model

The daemon is expected to run continuously in the background.

- Linux target machines can register it as a `systemd --user` service from the Linux GUI or with `host-tools/linux/oskar-host.py install-startup`.
- Windows target machines can register it at logon for the current user using `host-tools/windows/oskar-host.ps1 install-startup`.

Detailed step-by-step build, copy, registration, and config instructions are in `host-tools/README.md`.
