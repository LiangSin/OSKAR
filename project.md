# Firmware Feature Design

This document records the behavior implemented on top of the base OSKAR firmware. It focuses on the user-facing controls, HID signals, and implementation choices that make the controls reliable. General board and firmware setup information belongs in `README.md`.

## Control Map

| Control | Status | Current behavior |
| --- | --- | --- |
| Encoder clockwise | Implemented | Move forward through the operating system window switcher. |
| Encoder counter-clockwise | Implemented | Move backward through the operating system window switcher. |
| Encoder button | Implemented | Confirm the current window-switch selection when switching is active; otherwise toggle window maximize/minimize. |
| Key1 | Planned | Reserved for future workflow behavior. |
| Key2 | Planned | Reserved for future workflow behavior. |
| Key3 | Planned | Reserved for future workflow behavior. |

## HID Action Model

The firmware exposes two HID paths:

- `KeyboardReport` for regular keyboard usage codes and modifier combinations.
- `MediaKeyboardReport` for consumer/media keys, kept available for future mappings even though the current encoder workflow only uses keyboard reports.

The layout layer uses these action types:

- `Keycode`: a single keyboard usage code.
- `Combo`: one keyboard usage code plus modifier bits.
- `Toggle`: alternates between two `Combo` actions on each press.
- `Media`: a consumer/media usage code.

`KeyCombo` stores a modifier byte and one `KeyboardUsage`, which keeps future mappings compact and avoids duplicating low-level report construction in layout definitions.

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

The switch session is committed in two ways:

- If no encoder event arrives for `WINDOW_SWITCH_TIMEOUT` (`1s`), the firmware sends an empty `KeyboardReport`, releasing all keyboard modifiers and selecting the highlighted window.
- If the encoder button is pressed while a switch session is active, the firmware immediately sends the same empty keyboard report and commits the highlighted window.

When no switch session is active, the encoder button keeps its normal behavior: it alternates between `LeftGUI + UpArrow` and `LeftGUI + DownArrow`, matching the common Linux and Windows maximize/restore-minimize window shortcuts.

If `Key1`, `Key2`, or `Key3` is pressed while a switch session is active, the firmware first releases the keyboard report to commit the selected window, then handles the key event. This prevents accidental `Alt+<key>` combinations.

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

## Future Key Workflows

`Key1`, `Key2`, and `Key3` still use placeholder keyboard mappings. Future work should add their behavior as separate sections under this heading instead of folding them into the encoder section.

Suggested structure for each key:

```text
### Key1

- User workflow:
- HID signals:
- Interaction with active encoder/window-switch state:
- Timing or debounce considerations:
```

When adding new key behavior, keep these rules in mind:

- If a key can be pressed during an active window-switch session, decide whether it should commit the session first, cancel it, or be ignored until the session ends.
- Prefer `Combo` or `Toggle` mappings for OS-level shortcuts so the layout remains readable.
- Release modifiers explicitly after any synthetic chord unless the behavior intentionally holds a modifier for a stateful interaction.
