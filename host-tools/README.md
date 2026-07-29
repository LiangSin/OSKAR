# OSKAR Host Tools

This directory contains the user-side control interface for the OSKAR macro-key behavior.

The firmware sends the three macro keys through a vendor-defined custom HID interface:

- Key1 sends custom HID button `1`
- Key2 sends custom HID button `2`
- Key3 sends custom HID button `3`

The host daemon watches the custom HID reports. Each key can independently paste text, open a URL in the default browser, or activate/launch an application. Because the macro keys are no longer standard keyboard keys, they should not collide with operating-system shortcuts.

- Linux target machine: use `host-tools/linux/` with the system Python 3.
- Windows target machine: use `host-tools/windows/` with built-in Windows PowerShell.

## Step 1: Build The Firmware

Do this on the Linux build machine where Rust and the embedded firmware dependencies are installed.

```sh
cd /path/to/OSKAR
cargo run --release
```

Expected result:

```text
target/thumbv6m-none-eabi/release/oskar.uf2
```

This firmware is what changes the physical OSKAR macro keys to send custom HID button reports.

## Step 2: Flash The Firmware

Do this on the machine connected to the Raspberry Pi Pico.

1. Hold the Pico `BOOTSEL` button while plugging it in.
2. Copy the UF2 file to the Pico USB drive.

Linux example:

```sh
cp target/thumbv6m-none-eabi/release/oskar.uf2 /path/to/RPI-RP2/
```

After the copy finishes, the Pico reboots automatically.

## Step 3: Copy Host Tools To The Target Machine

Do this from the Linux build machine to the machine where the keyboard will be used.

For a Linux target machine, copy this directory:

```text
host-tools/linux/
```

For a Windows target machine, copy this directory:

```text
host-tools/windows/
```

## Step 4A: Install On A Linux Target Machine

Do this on the Linux target machine.

Run the Linux setup helper:

```sh
cd /path/to/host-tools/linux
sh setup.sh
```

The setup script installs dependencies with `apt`, installs a udev rule for the OSKAR custom HID interface, and adds the user to the `input` group so the daemon can read `/dev/hidraw*`.
If setup adds you to the `input` group, log out and log back before starting the daemon. The group `input` should appear in the group list when running `id`.
Run `newgrp input` as a temporary solution if needed.

Open `START.sh` from your file manager, or run it from a terminal:

```sh
cd /path/to/host-tools/linux
./START.sh
```

The GUI opens with the current config at the top. If the config file does not exist, the GUI creates it automatically.

Use `Edit` to choose each key's action from its dropdown and configure the corresponding text, URL, or application. When `Open app` is selected, `Choose...` searches installed desktop applications by name or launch command.

The daemon section shows whether the host daemon is running. Use `Refresh`, `Logs`, `Start Daemon`, and `Stop Daemon` from the GUI. When starting or installing the Linux daemon from the GUI, the tool imports the current desktop environment into the user service so clipboard helpers can find Wayland or X11.

Open `Advanced` to install or uninstall the logon registration. Install creates and starts a `systemd --user` service.

Optional command-line diagnostics are still available:

```sh
python3 oskar-host.py daemon-status
python3 oskar-host.py show-log
printf 'key1\nkey2\nkey3\n' | python3 oskar-host.py daemon --stdin --dry-run
```

The Linux config file is normally here:

```text
~/.config/oskar/config.txt
```

You can override it with `OSKAR_CONFIG=/path/to/config.txt`.

## Step 4B: Install On A Windows Target Machine

Do this on the Windows target machine. 

Open PowerShell in the copied `windows` directory.

If Windows blocks the copied script, unblock it:

```powershell
Unblock-File .\oskar-host.ps1
Unblock-File .\oskar-keyboard-hook.cs
```

Double-click `START.cmd` from File Explorer, or open it from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\oskar-host.ps1 ui
```

The GUI opens with the current config at the top. If the config file does not exist, the GUI creates it automatically.

Use `Edit` to choose each key's action from its dropdown and configure the corresponding text, URL, or application. When `Open app` is selected, `Choose...` searches Start Menu and Microsoft Store apps; `Browse EXE...` remains available for portable apps.

The daemon section shows whether the host daemon is running. Use `Refresh`, `Logs`, `Start Daemon`, and `Stop Daemon` from the GUI.

Open `Advanced` to install or uninstall the logon registration. Install first tries to create a limited, current-user Scheduled Task. If Windows policy denies that, it falls back to the current user's `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` startup key. After registering startup, it also tries to start the daemon immediately.

Optional command-line diagnostics are still available:

```powershell
powershell -ExecutionPolicy Bypass -File .\oskar-host.ps1 daemon-status
powershell -ExecutionPolicy Bypass -File .\oskar-host.ps1 show-log
```

The Windows config file is normally here:

```text
%APPDATA%\OSKAR\config.txt
```

You can override it with the `OSKAR_CONFIG` environment variable.

## Step 5: Change Config Later

Linux target machine:

```sh
cd /path/to/host-tools/linux
./START.sh
```

Windows target machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\oskar-host.ps1 ui
```

Or double-click `START.cmd`.

The daemon reloads the config every time a key is pressed, so changing config does not require restarting the daemon.

The generated config contains:

```text
key1_action=paste
key1_text=OSKAR key 1
key1_url=https://www.arm.com/
key1_app=
key2_action=url
key2_text=OSKAR key 2
key2_url=https://www.arm.com/
key2_app=
key3_action=app
key3_text=OSKAR key 3
key3_url=https://www.arm.com/
key3_app=
```

Each key retains all three values when its action changes, so switching away from an action and back does not discard its previous config. Existing config files without `keyN_action` keep the original default mapping: Key1 paste, Key2 URL, and Key3 app.

## Current Limitations

- Linux support reads the OSKAR `/dev/hidraw*` interface. This requires the setup udev rule or equivalent local device permissions.
- Linux paste and window-focus support depends on desktop helper commands because shell/Python alone cannot portably control arbitrary GUI applications.
- Windows support uses PowerShell plus a small C# Raw Input HID source file. It should not require installing anything extra on a normal Windows desktop.
- macOS is not implemented in this first pass.
