#!/usr/bin/env python3
import argparse
import os
import pathlib
import select
import signal
import shutil
import struct
import subprocess
import sys
import time

EV_KEY = 0x01
KEY_F13 = 183
KEY_F14 = 184
KEY_F15 = 185
KEY_PRESS = 1
HOST_KEY_DEBOUNCE_SECONDS = 0.15
INPUT_EVENT_STRUCT = "llHHI"
INPUT_EVENT_SIZE = struct.calcsize(INPUT_EVENT_STRUCT)

DEFAULTS = {
    "key1_text": "OSKAR key 1",
    "key2_text": "OSKAR key 2",
    "key3_text": "OSKAR key 3",
}

SERVICE_NAME = "oskar-host.service"


def config_path():
    override = os.environ.get("OSKAR_CONFIG")
    if override:
        return pathlib.Path(override)

    config_home = os.environ.get("XDG_CONFIG_HOME")
    if config_home:
        return pathlib.Path(config_home) / "oskar" / "config.txt"

    return pathlib.Path.home() / ".config" / "oskar" / "config.txt"


def state_dir():
    override = os.environ.get("XDG_STATE_HOME")
    if override:
        return pathlib.Path(override) / "oskar"
    return pathlib.Path.home() / ".local" / "state" / "oskar"


def pid_path():
    return state_dir() / "oskar-host.pid"


def log_path():
    return state_dir() / "oskar-host.log"


def service_dir():
    return pathlib.Path.home() / ".config" / "systemd" / "user"


def service_path():
    return service_dir() / SERVICE_NAME


def ensure_state_dir():
    state_dir().mkdir(parents=True, exist_ok=True)


def write_log(message):
    ensure_state_dir()
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with log_path().open("a", encoding="utf-8") as handle:
        handle.write(f"[{stamp}] {message}\n")


def read_pid():
    try:
        return int(pid_path().read_text(encoding="ascii").strip())
    except (FileNotFoundError, ValueError):
        return None


def process_is_running(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def daemon_pid():
    pid = read_pid()
    if pid and process_is_running(pid):
        return pid
    if pid:
        try:
            pid_path().unlink()
        except FileNotFoundError:
            pass
    return None


def systemctl_available():
    return shutil.which("systemctl") is not None


def run_systemctl(*args, check=True):
    return subprocess.run(
        ["systemctl", "--user", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


def import_desktop_environment():
    if not systemctl_available():
        return
    names = [
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XAUTHORITY",
        "XDG_CURRENT_DESKTOP",
        "XDG_RUNTIME_DIR",
        "XDG_SESSION_TYPE",
        "DBUS_SESSION_BUS_ADDRESS",
    ]
    present = [name for name in names if os.environ.get(name)]
    if present:
        subprocess.run(
            ["systemctl", "--user", "import-environment", *present],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def service_installed():
    return service_path().exists()


def service_active():
    if not service_installed() or not systemctl_available():
        return False
    result = run_systemctl("is-active", "--quiet", SERVICE_NAME, check=False)
    return result.returncode == 0


def daemon_status_text():
    lines = []
    pid = daemon_pid()
    if pid:
        lines.append("daemon: running")
        lines.append(f"pid: {pid}")
    else:
        lines.append("daemon: not running")
    if service_installed():
        state = "active" if service_active() else "installed"
        lines.append(f"service: {state}")
    else:
        lines.append("service: not installed")
    lines.append(f"pid file: {pid_path()}")
    lines.append(f"log file: {log_path()}")
    return "\n".join(lines)


def escape_value(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")


def unescape_value(value):
    output = []
    index = 0
    while index < len(value):
        ch = value[index]
        if ch != "\\" or index + 1 >= len(value):
            output.append(ch)
            index += 1
            continue

        nxt = value[index + 1]
        if nxt == "n":
            output.append("\n")
        elif nxt == "r":
            output.append("\r")
        elif nxt == "\\":
            output.append("\\")
        else:
            output.append("\\")
            output.append(nxt)
        index += 2
    return "".join(output)


def load_config():
    path = config_path()
    config = dict(DEFAULTS)
    if not path.exists():
        return config

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key in config:
            config[key] = unescape_value(value.strip())
    return config


def save_config(config):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# OSKAR host configuration"]
    for key in ("key1_text", "key2_text", "key3_text"):
        lines.append(f"{key}={escape_value(config[key])}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def print_config(config):
    print(f"config: {config_path()}")
    print(f"key1/F13 = {config['key1_text']!r}")
    print(f"key2/F14 = {config['key2_text']!r}")
    print(f"key3/F15 = {config['key3_text']!r}")


def prefer_wayland():
    return bool(os.environ.get("WAYLAND_DISPLAY")) or os.environ.get("XDG_SESSION_TYPE") == "wayland"


def run_first_working(candidates, input_text=None):
    errors = []
    for name, command in candidates:
        if not shutil.which(command[0]):
            continue
        try:
            subprocess.run(
                command,
                input=input_text.encode("utf-8") if input_text is not None else None,
                check=True,
            )
            return name
        except subprocess.CalledProcessError as error:
            errors.append(f"{name}: exit {error.returncode}")
        except OSError as error:
            errors.append(f"{name}: {error}")
    if errors:
        raise RuntimeError("; ".join(errors))
    raise RuntimeError("no suitable desktop helper command is installed")


def set_clipboard(text):
    wayland_candidates = [("wl-copy", ["wl-copy"])]
    x11_candidates = [
        ("xclip", ["xclip", "-selection", "clipboard"]),
        ("xsel", ["xsel", "--clipboard", "--input"]),
    ]
    candidates = wayland_candidates + x11_candidates if prefer_wayland() else x11_candidates + wayland_candidates
    run_first_working(candidates, input_text=text)


def send_paste_shortcut():
    wayland_candidates = [("wtype", ["wtype", "-M", "ctrl", "v", "-m", "ctrl"])]
    x11_candidates = [
        ("xdotool", ["xdotool", "key", "ctrl+v"]),
        ("ydotool", ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"]),
    ]
    candidates = wayland_candidates + x11_candidates if prefer_wayland() else x11_candidates + wayland_candidates
    run_first_working(candidates)


def paste_text(text, dry_run):
    if dry_run:
        print(f"paste: {text!r}", flush=True)
        return

    set_clipboard(text)
    send_paste_shortcut()


def button_to_config_key(button):
    return {
        "key1": "key1_text",
        "key2": "key2_text",
        "key3": "key3_text",
    }[button]


def parse_button(value):
    value = value.strip().lower()
    if value in ("1", "key1", "f13"):
        return "key1"
    if value in ("2", "key2", "f14"):
        return "key2"
    if value in ("3", "key3", "f15"):
        return "key3"
    return None


def stdin_events():
    for line in sys.stdin:
        button = parse_button(line)
        if button:
            yield button
        elif line.strip():
            print(f"ignored stdin event: {line.strip()}", file=sys.stderr)


def evdev_events():
    devices = []
    for path in sorted(pathlib.Path("/dev/input").glob("event*")):
        try:
            devices.append(open(path, "rb", buffering=0))
        except PermissionError:
            continue
        except OSError:
            continue

    if not devices:
        raise RuntimeError(
            "no readable /dev/input/event* devices; add this user to the input group "
            "or install a udev rule"
        )

    code_to_button = {
        KEY_F13: "key1",
        KEY_F14: "key2",
        KEY_F15: "key3",
    }

    while True:
        readable, _, _ = select.select(devices, [], [])
        for device in readable:
            data = device.read(INPUT_EVENT_SIZE)
            if len(data) != INPUT_EVENT_SIZE:
                continue
            _, _, event_type, code, value = struct.unpack(INPUT_EVENT_STRUCT, data)
            if event_type == EV_KEY and value == KEY_PRESS and code in code_to_button:
                yield code_to_button[code]


def command_init_config(_args):
    config = load_config()
    save_config(config)
    print_config(config)


def command_print_config(_args):
    print_config(load_config())


def command_set(args):
    config = load_config()
    button = parse_button(args.button)
    if not button:
        raise RuntimeError("button must be key1, key2, key3, f13, f14, or f15")
    config[button_to_config_key(button)] = args.text
    save_config(config)
    print_config(config)


def show_edit_config_dialog(parent, on_saved):
    import tkinter as tk
    from tkinter import ttk

    config = load_config()
    dialog = tk.Toplevel(parent)
    dialog.title("Edit OSKAR Config")
    dialog.resizable(False, False)
    dialog.transient(parent)
    dialog.grab_set()

    frame = ttk.Frame(dialog, padding=14)
    frame.grid(row=0, column=0, sticky="nsew")

    fields = {}
    rows = [
        ("Key 1 / F13", "key1_text"),
        ("Key 2 / F14", "key2_text"),
        ("Key 3 / F15", "key3_text"),
    ]
    for index, (label_text, key) in enumerate(rows):
        ttk.Label(frame, text=label_text).grid(row=index, column=0, sticky="w", pady=6)
        entry = ttk.Entry(frame, width=42)
        entry.insert(0, config[key])
        entry.grid(row=index, column=1, sticky="ew", padx=(12, 0), pady=6)
        fields[key] = entry

    buttons = ttk.Frame(frame)
    buttons.grid(row=3, column=0, columnspan=2, sticky="e", pady=(14, 0))

    def cancel():
        dialog.destroy()

    def save():
        new_config = dict(DEFAULTS)
        for key, entry in fields.items():
            new_config[key] = entry.get()
        save_config(new_config)
        on_saved()
        dialog.destroy()

    ttk.Button(buttons, text="Cancel", command=cancel).grid(row=0, column=0, padx=(0, 8))
    ttk.Button(buttons, text="Save", command=save).grid(row=0, column=1)

    dialog.bind("<Escape>", lambda _event: cancel())
    dialog.bind("<Return>", lambda _event: save())
    fields["key1_text"].focus_set()
    parent.wait_window(dialog)


def command_ui(_args):
    try:
        import tkinter as tk
        from tkinter import messagebox, ttk
    except ImportError as error:
        raise RuntimeError("install python3-tk to use the Linux GUI") from error

    config = load_config()
    save_config(config)

    root = tk.Tk()
    root.title("OSKAR Host Tools")
    root.minsize(520, 410)

    outer = ttk.Frame(root, padding=16)
    outer.grid(row=0, column=0, sticky="nsew")
    root.columnconfigure(0, weight=1)
    root.rowconfigure(0, weight=1)
    outer.columnconfigure(0, weight=1)

    config_frame = ttk.LabelFrame(outer, text="Current config", padding=12)
    config_frame.grid(row=0, column=0, sticky="ew")
    config_frame.columnconfigure(0, weight=1)

    config_path_var = tk.StringVar(value=f"Config: {config_path()}")
    key1_var = tk.StringVar()
    key2_var = tk.StringVar()
    key3_var = tk.StringVar()
    ttk.Label(config_frame, textvariable=config_path_var).grid(row=0, column=0, columnspan=2, sticky="w")
    ttk.Label(config_frame, textvariable=key1_var).grid(row=1, column=0, columnspan=2, sticky="w", pady=(10, 0))
    ttk.Label(config_frame, textvariable=key2_var).grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))
    ttk.Label(config_frame, textvariable=key3_var).grid(row=3, column=0, sticky="w", pady=(6, 0))
    edit_button = ttk.Button(config_frame, text="Edit")
    edit_button.grid(row=3, column=1, sticky="e", padx=(12, 0))

    daemon_frame = ttk.LabelFrame(outer, text="Daemon status", padding=12)
    daemon_frame.grid(row=1, column=0, sticky="ew", pady=(14, 0))
    daemon_frame.columnconfigure(0, weight=1)

    status_text = tk.Text(daemon_frame, height=5, width=48, wrap="word")
    status_text.configure(state="disabled")
    status_text.grid(row=0, column=0, rowspan=2, sticky="ew")
    refresh_button = ttk.Button(daemon_frame, text="Refresh")
    refresh_button.grid(row=0, column=1, sticky="n", padx=(12, 0))
    logs_button = ttk.Button(daemon_frame, text="Logs")
    logs_button.grid(row=1, column=1, sticky="n", padx=(12, 0), pady=(8, 0))
    start_button = ttk.Button(daemon_frame, text="Start Daemon")
    start_button.grid(row=2, column=0, sticky="w", pady=(10, 0))
    stop_button = ttk.Button(daemon_frame, text="Stop Daemon")
    stop_button.grid(row=2, column=0, sticky="w", padx=(120, 0), pady=(10, 0))

    advanced_visible = tk.BooleanVar(value=False)
    advanced_button = ttk.Button(outer, text="Advanced >")
    advanced_button.grid(row=2, column=0, sticky="w", pady=(16, 0))

    advanced_frame = ttk.LabelFrame(outer, text="Advanced", padding=12)
    advanced_frame.columnconfigure(0, weight=1)
    ttk.Label(
        advanced_frame,
        text="Install registers OSKAR to start when you log in. Uninstall removes that logon registration.",
    ).grid(row=0, column=0, columnspan=2, sticky="w")
    install_button = ttk.Button(advanced_frame, text="Install")
    install_button.grid(row=1, column=0, sticky="w", pady=(12, 0))
    uninstall_button = ttk.Button(advanced_frame, text="Uninstall")
    uninstall_button.grid(row=1, column=0, sticky="w", padx=(92, 0), pady=(12, 0))

    def refresh_config():
        current = load_config()
        save_config(current)
        key1_var.set(f"Key1 / F13: {current['key1_text']}")
        key2_var.set(f"Key2 / F14: {current['key2_text']}")
        key3_var.set(f"Key3 / F15: {current['key3_text']}")

    def refresh_status():
        status_text.configure(state="normal")
        status_text.delete("1.0", "end")
        status_text.insert("1.0", daemon_status_text())
        status_text.configure(state="disabled")

    def run_action(action, success_message=None):
        try:
            action()
            refresh_status()
            if success_message:
                messagebox.showinfo("OSKAR Host Tools", success_message, parent=root)
        except Exception as error:
            messagebox.showerror("OSKAR Host Tools", str(error), parent=root)

    def open_logs():
        try:
            ensure_state_dir()
            path = log_path()
            if not path.exists():
                path.write_text("", encoding="utf-8")
            if not shutil.which("xdg-open"):
                raise RuntimeError(f"xdg-open is not available. Log file: {path}")
            subprocess.Popen(["xdg-open", str(path)])
        except Exception as error:
            messagebox.showerror("OSKAR Host Tools", str(error), parent=root)

    def toggle_advanced():
        if advanced_visible.get():
            advanced_frame.grid_remove()
            advanced_button.configure(text="Advanced >")
            advanced_visible.set(False)
        else:
            advanced_frame.grid(row=3, column=0, sticky="ew", pady=(8, 0))
            advanced_button.configure(text="Advanced v")
            advanced_visible.set(True)

    edit_button.configure(command=lambda: show_edit_config_dialog(root, refresh_config))
    refresh_button.configure(command=refresh_status)
    logs_button.configure(command=open_logs)
    start_button.configure(command=lambda: run_action(start_daemon_process))
    stop_button.configure(command=lambda: run_action(stop_daemon_process))
    advanced_button.configure(command=toggle_advanced)
    install_button.configure(
        command=lambda: run_action(
            install_startup,
            "OSKAR is registered to start when you log in.",
        )
    )
    uninstall_button.configure(
        command=lambda: run_action(
            uninstall_startup,
            "OSKAR logon registration was removed.",
        )
    )

    refresh_config()
    refresh_status()
    root.mainloop()


def start_daemon_process():
    if service_installed() and systemctl_available():
        import_desktop_environment()
        result = run_systemctl("start", SERVICE_NAME, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "systemctl start failed")
        return

    pid = daemon_pid()
    if pid:
        return

    ensure_state_dir()
    with log_path().open("ab") as log_file:
        subprocess.Popen(
            [sys.executable, str(pathlib.Path(__file__).resolve()), "daemon"],
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=log_file,
            start_new_session=True,
        )

    for _ in range(10):
        time.sleep(0.5)
        if daemon_pid():
            return


def stop_daemon_process():
    if service_installed() and systemctl_available():
        run_systemctl("stop", SERVICE_NAME, check=False)

    pid = daemon_pid()
    if not pid:
        return

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    for _ in range(10):
        time.sleep(0.2)
        if not process_is_running(pid):
            break
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        pid_path().unlink()
    except FileNotFoundError:
        pass
    write_log("daemon stopped by command")


def service_file_contents():
    script = pathlib.Path(__file__).resolve()
    return f"""[Unit]
Description=OSKAR host daemon

[Service]
ExecStart=/usr/bin/env python3 "{script}" daemon
Restart=on-failure

[Install]
WantedBy=default.target
"""


def install_startup():
    if not systemctl_available():
        raise RuntimeError("systemctl is required to install the Linux user service")
    import_desktop_environment()
    service_dir().mkdir(parents=True, exist_ok=True)
    service_path().write_text(service_file_contents(), encoding="utf-8")
    for args in (
        ("daemon-reload",),
        ("enable", "--now", SERVICE_NAME),
    ):
        result = run_systemctl(*args, check=False)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "systemctl failed")


def uninstall_startup():
    if systemctl_available():
        run_systemctl("disable", "--now", SERVICE_NAME, check=False)
        run_systemctl("daemon-reload", check=False)
    if service_path().exists():
        service_path().unlink()
    stop_daemon_process()


def command_daemon(args):
    existing = daemon_pid()
    if existing and existing != os.getpid() and not args.stdin:
        print(f"oskar-host daemon is already running: {existing}", flush=True)
        return

    ensure_state_dir()
    if not args.stdin:
        pid_path().write_text(f"{os.getpid()}\n", encoding="ascii")
    write_log(f"daemon starting; pid={os.getpid()}")
    write_log(
        "desktop env: "
        f"XDG_SESSION_TYPE={os.environ.get('XDG_SESSION_TYPE', '')!r}, "
        f"WAYLAND_DISPLAY={os.environ.get('WAYLAND_DISPLAY', '')!r}, "
        f"DISPLAY={os.environ.get('DISPLAY', '')!r}"
    )
    save_config(load_config())
    print("oskar-host linux daemon started", flush=True)
    print(f"config: {config_path()}", flush=True)
    events = stdin_events() if args.stdin else evdev_events()
    last_button_time = {}
    try:
        for button in events:
            now = time.monotonic()
            if now - last_button_time.get(button, 0) < HOST_KEY_DEBOUNCE_SECONDS:
                continue
            last_button_time[button] = now

            config = load_config()
            write_log(f"{button} pressed")
            try:
                paste_text(config[button_to_config_key(button)], args.dry_run)
            except Exception as error:
                write_log(f"paste failed: {error}")
                print(f"paste failed: {error}", file=sys.stderr, flush=True)
    finally:
        if not args.stdin and read_pid() == os.getpid():
            try:
                pid_path().unlink()
            except FileNotFoundError:
                pass
        write_log(f"daemon stopped; pid={os.getpid()}")


def command_start_daemon(_args):
    start_daemon_process()
    print(daemon_status_text())


def command_stop_daemon(_args):
    stop_daemon_process()
    print(daemon_status_text())


def command_daemon_status(_args):
    print(daemon_status_text())


def command_show_log(_args):
    path = log_path()
    if not path.exists():
        print(f"log file does not exist yet: {path}")
        return
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines[-80:]:
        print(line)


def command_install_startup(_args):
    install_startup()
    print("Installed and started Linux user service")


def command_uninstall_startup(_args):
    uninstall_startup()
    print("Removed Linux user service")


def main():
    parser = argparse.ArgumentParser(description="OSKAR host tool for Linux")
    sub = parser.add_subparsers(dest="command", required=True)

    init_config = sub.add_parser("init-config")
    init_config.set_defaults(func=command_init_config)

    print_config_cmd = sub.add_parser("print-config")
    print_config_cmd.set_defaults(func=command_print_config)

    set_cmd = sub.add_parser("set")
    set_cmd.add_argument("button")
    set_cmd.add_argument("text")
    set_cmd.set_defaults(func=command_set)

    ui = sub.add_parser("ui")
    ui.set_defaults(func=command_ui)

    daemon = sub.add_parser("daemon")
    daemon.add_argument("--stdin", action="store_true")
    daemon.add_argument("--dry-run", action="store_true")
    daemon.set_defaults(func=command_daemon)

    start_daemon = sub.add_parser("start-daemon")
    start_daemon.set_defaults(func=command_start_daemon)

    stop_daemon = sub.add_parser("stop-daemon")
    stop_daemon.set_defaults(func=command_stop_daemon)

    daemon_status = sub.add_parser("daemon-status")
    daemon_status.set_defaults(func=command_daemon_status)

    show_log = sub.add_parser("show-log")
    show_log.set_defaults(func=command_show_log)

    install_startup_cmd = sub.add_parser("install-startup")
    install_startup_cmd.set_defaults(func=command_install_startup)

    uninstall_startup_cmd = sub.add_parser("uninstall-startup")
    uninstall_startup_cmd.set_defaults(func=command_uninstall_startup)

    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
