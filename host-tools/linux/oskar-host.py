#!/usr/bin/env python3
import argparse
import os
import pathlib
import select
import shlex
import signal
import shutil
import subprocess
import sys
import time

HOST_KEY_DEBOUNCE_SECONDS = 0.15
OSKAR_CUSTOM_HID_REPORT_DESCRIPTOR = bytes(
    [
        0x06, 0x00, 0xFF,
        0x09, 0x01,
        0xA1, 0x01,
        0x09, 0x10,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x02,
        0x81, 0x02,
        0xC0,
    ]
)
OSKAR_CUSTOM_HID_REPORT_SIZE = 2

DEFAULTS = {
    "key1_action": "paste",
    "key1_text": "OSKAR key 1",
    "key1_url": "https://www.arm.com/",
    "key1_app": "",
    "key2_action": "url",
    "key2_text": "OSKAR key 2",
    "key2_url": "https://www.arm.com/",
    "key2_app": "",
    "key3_action": "app",
    "key3_text": "OSKAR key 3",
    "key3_url": "https://www.arm.com/",
    "key3_app": "",
}
ACTIONS = ("paste", "url", "app")
ACTION_LABELS = {"paste": "Paste text", "url": "Open URL", "app": "Open app"}
CONFIG_KEYS = tuple(
    f"key{number}_{field}"
    for number in range(1, 4)
    for field in ("action", "text", "url", "app")
)
APP_WINDOW_CACHE = {}

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
    for number in range(1, 4):
        action_key = f"key{number}_action"
        if config[action_key] not in ACTIONS:
            config[action_key] = DEFAULTS[action_key]
    return config


def save_config(config):
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# OSKAR host configuration"]
    for key in CONFIG_KEYS:
        lines.append(f"{key}={escape_value(config[key])}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def print_config(config):
    print(f"config: {config_path()}")
    for number in range(1, 4):
        button = f"key{number}"
        action = config[f"{button}_action"]
        print(f"{button} action = {action!r}")
        print(f"{button} value = {config[action_config_key(button, action)]!r}")


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


def open_url(url, dry_run):
    if not url.strip():
        raise RuntimeError("Key2 URL is empty")
    if dry_run:
        print(f"open URL: {url!r}", flush=True)
        return
    if not shutil.which("xdg-open"):
        raise RuntimeError("xdg-open is required to open Key2 URL")
    subprocess.Popen(
        ["xdg-open", url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def xdotool_available():
    # Native Wayland windows are intentionally unavailable to xdotool, but many
    # IDEs (including Java/SWT apps) run through XWayland and remain discoverable.
    return bool(os.environ.get("DISPLAY")) and shutil.which("xdotool") is not None


def process_snapshot():
    processes = {}
    for proc in pathlib.Path("/proc").glob("[0-9]*"):
        try:
            executable = (proc / "exe").resolve()
            stat = (proc / "stat").read_text(encoding="utf-8", errors="replace")
            fields = stat[stat.rfind(")") + 2 :].split()
            parent_pid = int(fields[1])
            command_line = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", errors="replace"
            )
            processes[int(proc.name)] = {
                "executable": executable,
                "parent_pid": parent_pid,
                "command_line": command_line,
            }
        except (FileNotFoundError, PermissionError, OSError, ValueError, IndexError):
            continue
    return processes


def related_app_pids(path):
    wanted = path.resolve()
    app_directory = str(wanted.parent)
    processes = process_snapshot()
    candidates = {
        pid for pid, process in processes.items() if process["executable"] == wanted
    }

    # Eclipse-style launchers commonly host their actual window in a Java child
    # process. Restrict the fallback to Java runtimes whose command line names
    # this app's installation directory.
    for pid, process in processes.items():
        if (
            process["executable"].name in ("java", "javaw")
            and app_directory in process["command_line"]
        ):
            candidates.add(pid)

    while True:
        descendants = {
            pid
            for pid, process in processes.items()
            if process["parent_pid"] in candidates
        }
        previous_size = len(candidates)
        candidates.update(descendants)
        if len(candidates) == previous_size:
            break
    return candidates


def visible_x11_windows(pid):
    result = subprocess.run(
        ["xdotool", "search", "--onlyvisible", "--pid", str(pid)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]


def activate_x11_window(window_id):
    result = subprocess.run(
        ["xdotool", "windowactivate", "--sync", str(window_id)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def focus_existing_app(path, cache_key):
    if not xdotool_available():
        return False

    cached = APP_WINDOW_CACHE.get(cache_key)
    if cached:
        result = subprocess.run(
            ["xdotool", "getwindowpid", cached["window_id"]],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip() == str(cached["pid"]):
            if activate_x11_window(cached["window_id"]):
                return True
        APP_WINDOW_CACHE.pop(cache_key, None)

    for pid in related_app_pids(path):
        for window_id in visible_x11_windows(pid):
            if activate_x11_window(window_id):
                APP_WINDOW_CACHE[cache_key] = {"pid": pid, "window_id": window_id}
                write_log(f"key3 focusing existing window; pid={pid}; window={window_id}")
                return True
    return False


def desktop_launcher_executable(path):
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if not line.startswith("Exec="):
            continue
        try:
            words = shlex.split(line[5:])
        except ValueError:
            return None
        if not words:
            return None
        if words[0] == "env":
            words = [word for word in words[1:] if "=" not in word]
        if not words:
            return None
        executable = pathlib.Path(words[0])
        if not executable.is_absolute():
            resolved = shutil.which(words[0])
            if not resolved:
                return None
            executable = pathlib.Path(resolved)
        return executable
    return None


def open_app(value, dry_run):
    if not value.strip():
        if dry_run:
            print("open app: not configured", flush=True)
        return

    path = pathlib.Path(value).expanduser()
    if not path.exists():
        raise RuntimeError(f"Key3 app does not exist: {path}")
    if dry_run:
        print(f"open app: {str(path)!r}", flush=True)
        return

    if path.suffix.lower() == ".desktop":
        if not shutil.which("gio"):
            raise RuntimeError("gio is required to launch a .desktop application")
        executable = desktop_launcher_executable(path)
        if executable and focus_existing_app(executable, str(path.resolve())):
            return
        command = ["gio", "launch", str(path)]
    else:
        if not path.is_file() or not os.access(path, os.X_OK):
            raise RuntimeError(f"Key3 app is not executable: {path}")
        if focus_existing_app(path, str(path.resolve())):
            return
        command = [str(path)]

    # Launching a single-instance/GApplication app also asks it to focus its
    # existing window. This is the portable fallback where the compositor does
    # not permit other processes to force-focus a window (notably Wayland).
    write_log(f"key3 found no existing window; launching: {path}")
    subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def perform_button_action(button, config, dry_run):
    action = config[f"{button}_action"]
    value = config[action_config_key(button, action)]
    if action == "paste":
        paste_text(value, dry_run)
    elif action == "url":
        open_url(value, dry_run)
    elif action == "app":
        open_app(value, dry_run)
    else:
        raise RuntimeError(f"unsupported action for {button}: {action}")


def action_config_key(button, action):
    suffix = {"paste": "text", "url": "url", "app": "app"}[action]
    return f"{button}_{suffix}"


def button_to_config_key(button, config):
    return action_config_key(button, config[f"{button}_action"])


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


def oskar_hidraw_paths():
    for sys_path in sorted(pathlib.Path("/sys/class/hidraw").glob("hidraw*")):
        descriptor_path = sys_path / "device" / "report_descriptor"
        try:
            descriptor = descriptor_path.read_bytes()
        except OSError:
            continue
        if descriptor == OSKAR_CUSTOM_HID_REPORT_DESCRIPTOR:
            yield pathlib.Path("/dev") / sys_path.name


def hidraw_events():
    devices = []
    permission_denied = []
    for path in oskar_hidraw_paths():
        try:
            devices.append(open(path, "rb", buffering=0))
        except PermissionError:
            permission_denied.append(path)
            continue
        except OSError:
            continue

    if not devices:
        if permission_denied:
            raise RuntimeError(
                "found the OSKAR custom HID interface but cannot read it; run setup.sh "
                "or install a udev rule that grants this user access to /dev/hidraw*"
            )
        raise RuntimeError(
            "no OSKAR custom HID interface found; flash the custom-HID firmware and reconnect OSKAR"
        )

    while True:
        readable, _, _ = select.select(devices, [], [])
        for device in readable:
            data = device.read(OSKAR_CUSTOM_HID_REPORT_SIZE)
            if len(data) != OSKAR_CUSTOM_HID_REPORT_SIZE:
                continue
            button_id, pressed = data
            if pressed != 1:
                continue
            if button_id == 1:
                yield "key1"
            elif button_id == 2:
                yield "key2"
            elif button_id == 3:
                yield "key3"


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
        raise RuntimeError("button must be key1, key2, or key3")
    config[button_to_config_key(button, config)] = args.text
    save_config(config)
    print_config(config)


def desktop_entry_details(path):
    values = {}
    section = None
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line
            continue
        if section != "[Desktop Entry]" or not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value

    if (
        values.get("Type", "Application") != "Application"
        or values.get("Hidden", "false").lower() == "true"
        or values.get("NoDisplay", "false").lower() == "true"
        or not values.get("Exec")
    ):
        return None

    locale_name = os.environ.get("LC_MESSAGES") or os.environ.get("LANG", "")
    locale_name = locale_name.split(".", 1)[0]
    localized_keys = []
    if locale_name:
        localized_keys.append(f"Name[{locale_name}]")
        if "_" in locale_name:
            localized_keys.append(f"Name[{locale_name.split('_', 1)[0]}]")
    name = next((values[key] for key in localized_keys if values.get(key)), values.get("Name"))
    if not name:
        return None
    return {"name": name, "command": values["Exec"], "path": str(path)}


def installed_desktop_apps():
    data_home = pathlib.Path(
        os.environ.get("XDG_DATA_HOME", pathlib.Path.home() / ".local" / "share")
    )
    data_dirs = [
        pathlib.Path(value)
        for value in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
        if value
    ]
    applications = {}
    for root in [data_home, *data_dirs]:
        directory = root / "applications"
        if not directory.is_dir():
            continue
        for path in directory.rglob("*.desktop"):
            details = desktop_entry_details(path)
            if details:
                applications.setdefault(details["name"].casefold(), details)
    return sorted(applications.values(), key=lambda app: app["name"].casefold())


def show_app_picker_dialog(parent, current):
    import tkinter as tk
    from tkinter import filedialog, ttk

    apps = installed_desktop_apps()
    result = {"path": None}
    visible_apps = {}

    dialog = tk.Toplevel(parent)
    dialog.title("Choose an installed application")
    dialog.geometry("760x500")
    dialog.minsize(620, 400)
    dialog.transient(parent)
    dialog.grab_set()
    dialog.columnconfigure(0, weight=1)
    dialog.rowconfigure(1, weight=1)

    search_frame = ttk.Frame(dialog, padding=(16, 16, 16, 8))
    search_frame.grid(row=0, column=0, sticky="ew")
    search_frame.columnconfigure(1, weight=1)
    ttk.Label(search_frame, text="Search installed apps").grid(row=0, column=0, padx=(0, 10))
    search_var = tk.StringVar()
    search_entry = ttk.Entry(search_frame, textvariable=search_var)
    search_entry.grid(row=0, column=1, sticky="ew")

    list_frame = ttk.Frame(dialog, padding=(16, 0, 16, 8))
    list_frame.grid(row=1, column=0, sticky="nsew")
    list_frame.columnconfigure(0, weight=1)
    list_frame.rowconfigure(0, weight=1)
    tree = ttk.Treeview(list_frame, columns=("name", "command"), show="headings", selectmode="browse")
    tree.heading("name", text="Application")
    tree.heading("command", text="Launch command")
    tree.column("name", width=230, minwidth=140)
    tree.column("command", width=470, minwidth=220)
    tree.grid(row=0, column=0, sticky="nsew")
    scrollbar = ttk.Scrollbar(list_frame, orient="vertical", command=tree.yview)
    scrollbar.grid(row=0, column=1, sticky="ns")
    tree.configure(yscrollcommand=scrollbar.set)

    button_frame = ttk.Frame(dialog, padding=(16, 8, 16, 16))
    button_frame.grid(row=2, column=0, sticky="ew")
    button_frame.columnconfigure(1, weight=1)

    def close():
        dialog.destroy()

    def choose_selected():
        selection = tree.selection()
        if selection:
            result["path"] = visible_apps[selection[0]]["path"]
            dialog.destroy()

    def browse_executable():
        current_path = pathlib.Path(current).expanduser() if current else None
        initial_dir = current_path.parent if current_path and current_path.exists() else pathlib.Path("/usr/bin")
        selected = filedialog.askopenfilename(
            parent=dialog,
            title="Choose an application executable",
            initialdir=str(initial_dir),
            filetypes=(("All files", "*"),),
        )
        if selected:
            result["path"] = selected
            dialog.destroy()

    select_button = ttk.Button(button_frame, text="Select", command=choose_selected, state="disabled")
    ttk.Button(button_frame, text="Browse executable...", command=browse_executable).grid(
        row=0, column=0, sticky="w"
    )
    ttk.Button(button_frame, text="Cancel", command=close).grid(row=0, column=2, padx=(8, 0))
    select_button.grid(row=0, column=3, padx=(8, 0))

    def refresh(*_args):
        query = search_var.get().strip().casefold()
        children = tree.get_children()
        if children:
            tree.delete(*children)
        visible_apps.clear()
        for index, app in enumerate(apps):
            if query and query not in app["name"].casefold() and query not in app["command"].casefold():
                continue
            item_id = f"app-{index}"
            tree.insert("", "end", iid=item_id, values=(app["name"], app["command"]))
            visible_apps[item_id] = app
            if app["path"] == current:
                tree.selection_set(item_id)
                tree.see(item_id)
        select_button.configure(state="normal" if tree.selection() else "disabled")

    tree.bind("<<TreeviewSelect>>", lambda _event: select_button.configure(state="normal"))
    tree.bind("<Double-1>", lambda _event: choose_selected())
    dialog.bind("<Escape>", lambda _event: close())
    dialog.bind("<Return>", lambda _event: choose_selected())
    search_var.trace_add("write", refresh)
    refresh()
    search_entry.focus_set()
    parent.wait_window(dialog)
    parent.grab_set()
    return result["path"]


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
    frame.columnconfigure(0, weight=1)

    action_vars = {}
    value_vars = {}
    entries = {}
    config_labels = {}
    browse_buttons = {}
    label_to_action = {label: action for action, label in ACTION_LABELS.items()}

    def refresh_row(number):
        button = f"key{number}"
        action = label_to_action[action_vars[button].get()]
        entries[button].configure(textvariable=value_vars[button][action])
        config_labels[button].configure(
            text={"paste": "Text", "url": "URL", "app": "Application"}[action]
        )
        if action == "app":
            browse_buttons[button].grid()
        else:
            browse_buttons[button].grid_remove()

    def browse_app(number):
        button = f"key{number}"
        selected = show_app_picker_dialog(dialog, value_vars[button]["app"].get())
        if selected:
            value_vars[button]["app"].set(selected)

    for number in range(1, 4):
        button = f"key{number}"
        group = ttk.LabelFrame(frame, text=f"Key {number}", padding=10)
        group.grid(row=number - 1, column=0, sticky="ew", pady=(0, 10))
        group.columnconfigure(1, weight=1)

        ttk.Label(group, text="Action").grid(row=0, column=0, sticky="w", padx=(0, 10))
        action_vars[button] = tk.StringVar(value=ACTION_LABELS[config[f"{button}_action"]])
        action_box = ttk.Combobox(
            group,
            textvariable=action_vars[button],
            values=tuple(ACTION_LABELS.values()),
            state="readonly",
            width=18,
        )
        action_box.grid(row=0, column=1, sticky="w")

        value_vars[button] = {
            action: tk.StringVar(value=config[f"{button}_{suffix}"])
            for action, suffix in (("paste", "text"), ("url", "url"), ("app", "app"))
        }
        config_labels[button] = ttk.Label(group)
        config_labels[button].grid(row=1, column=0, sticky="w", padx=(0, 10), pady=(8, 0))
        entries[button] = ttk.Entry(group, width=52)
        entries[button].grid(row=1, column=1, sticky="ew", pady=(8, 0))
        browse_buttons[button] = ttk.Button(
            group, text="Choose...", command=lambda n=number: browse_app(n)
        )
        browse_buttons[button].grid(row=1, column=2, padx=(8, 0), pady=(8, 0))
        action_box.bind("<<ComboboxSelected>>", lambda _event, n=number: refresh_row(n))
        refresh_row(number)

    buttons = ttk.Frame(frame)
    buttons.grid(row=3, column=0, sticky="e", pady=(4, 0))

    def cancel():
        dialog.destroy()

    def save():
        new_config = dict(DEFAULTS)
        for number in range(1, 4):
            button = f"key{number}"
            new_config[f"{button}_action"] = label_to_action[action_vars[button].get()]
            for action, suffix in (("paste", "text"), ("url", "url"), ("app", "app")):
                new_config[f"{button}_{suffix}"] = value_vars[button][action].get()
        save_config(new_config)
        on_saved()
        dialog.destroy()

    ttk.Button(buttons, text="Cancel", command=cancel).grid(row=0, column=0, padx=(0, 8))
    ttk.Button(buttons, text="Save", command=save).grid(row=0, column=1)

    dialog.bind("<Escape>", lambda _event: cancel())
    dialog.bind("<Return>", lambda _event: save())
    entries["key1"].focus_set()
    parent.wait_window(dialog)


def command_ui(_args):
    try:
        import tkinter as tk
        from tkinter import font as tkfont
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
    config_path_label = ttk.Label(
        config_frame, textvariable=config_path_var, wraplength=350, justify="left"
    )
    config_path_label.grid(row=0, column=0, sticky="ew")
    edit_button = ttk.Button(config_frame, text="Edit")
    edit_button.grid(row=0, column=1, sticky="ne", padx=(12, 0))

    bold_font = tkfont.nametofont("TkDefaultFont").copy()
    bold_font.configure(weight="bold")
    preview_action_vars = []
    preview_value_texts = []
    for number in range(1, 4):
        group = ttk.LabelFrame(config_frame, text=f"Key {number}", padding=10)
        group.grid(row=number, column=0, columnspan=2, sticky="ew", pady=(10, 0))
        group.columnconfigure(1, weight=1)

        action_var = tk.StringVar()
        preview_action_vars.append(action_var)

        ttk.Label(group, text="Action", font=bold_font).grid(row=0, column=0, sticky="nw")
        ttk.Label(group, textvariable=action_var).grid(
            row=0, column=1, sticky="nw", padx=(14, 0)
        )
        ttk.Label(group, text="Config", font=bold_font).grid(
            row=1, column=0, sticky="nw", pady=(7, 0)
        )
        value_frame = ttk.Frame(group)
        value_frame.grid(row=1, column=1, sticky="ew", padx=(14, 0), pady=(7, 0))
        value_frame.columnconfigure(0, weight=1)
        value_text = tk.Text(
            value_frame,
            height=3,
            wrap="word",
            relief="solid",
            borderwidth=1,
            padx=5,
            pady=4,
        )
        value_text.grid(row=0, column=0, sticky="ew")
        value_scrollbar = ttk.Scrollbar(
            value_frame, orient="vertical", command=value_text.yview
        )
        value_scrollbar.grid(row=0, column=1, sticky="ns")
        value_text.configure(yscrollcommand=value_scrollbar.set, state="disabled")
        preview_value_texts.append(value_text)

    def resize_config_labels(event):
        config_path_label.configure(wraplength=max(220, event.width - 120))

    config_frame.bind("<Configure>", resize_config_labels)

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
        for number in range(1, 4):
            button = f"key{number}"
            action = current[f"{button}_action"]
            value = current[action_config_key(button, action)] or "(not configured)"
            preview_action_vars[number - 1].set(ACTION_LABELS[action])
            value_text = preview_value_texts[number - 1]
            value_text.configure(state="normal")
            value_text.delete("1.0", "end")
            value_text.insert("1.0", value)
            value_text.yview_moveto(0)
            value_text.configure(state="disabled")

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
    events = stdin_events() if args.stdin else hidraw_events()
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
                perform_button_action(button, config, args.dry_run)
            except Exception as error:
                write_log(f"{button} action failed: {error}")
                print(f"{button} action failed: {error}", file=sys.stderr, flush=True)
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
