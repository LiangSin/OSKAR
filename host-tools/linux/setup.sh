#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUI="$SCRIPT_DIR/START.sh"
UDEV_RULE_PATH="/etc/udev/rules.d/70-oskar-custom-hid.rules"

say() {
    printf '%s\n' "$*"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

detect_session() {
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf 'wayland\n'
        return
    fi
    if [ "${XDG_SESSION_TYPE:-}" = "x11" ] || [ -n "${DISPLAY:-}" ]; then
        printf 'x11\n'
        return
    fi
    if have loginctl && [ -n "${XDG_SESSION_ID:-}" ]; then
        session_type=$(loginctl show-session "$XDG_SESSION_ID" -p Type --value 2>/dev/null || true)
        if [ "$session_type" = "wayland" ] || [ "$session_type" = "x11" ]; then
            printf '%s\n' "$session_type"
            return
        fi
    fi
    printf 'unknown\n'
}

install_apt_packages() {
    packages="$*"
    say "Installing packages: $packages"
    sudo apt update
    # shellcheck disable=SC2086
    sudo apt install -y $packages
}

ensure_input_group() {
    if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
        return 0
    fi

    say "Adding $USER to the input group so the daemon can read /dev/hidraw*."
    sudo usermod -aG input "$USER"
    return 1
}

install_udev_rule() {
    say "Installing udev rule for OSKAR custom HID access."
    printf '%s\n' \
        'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1ced", ATTRS{idProduct}=="c0fe", MODE="0660", GROUP="input", TAG+="uaccess"' |
        sudo tee "$UDEV_RULE_PATH" >/dev/null

    if have udevadm; then
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=hidraw || true
    fi
}

main() {
    say "OSKAR Linux setup"
    say "================="

    if ! have apt; then
        say "ERROR: setup.sh currently supports apt-based Linux distributions."
        say "Install these manually, then open: $GUI"
        say "- python3"
        say "- python3-tk, xdg-utils, libglib2.0-bin"
        say "- Wayland: wl-clipboard wtype xdotool (for XWayland app focus)"
        say "- X11: xclip xdotool"
        exit 1
    fi

    session=$(detect_session)
    say "Detected desktop session: $session"

    packages="python3 python3-tk xdg-utils libglib2.0-bin"
    case "$session" in
        wayland)
            packages="$packages wl-clipboard wtype xdotool"
            ;;
        x11)
            packages="$packages xclip xdotool"
            ;;
        *)
            say "Could not confidently detect Wayland or X11."
            say "Installing both helper sets so either session can work."
            packages="$packages wl-clipboard wtype xclip xdotool"
            ;;
    esac

    install_apt_packages $packages
    install_udev_rule

    relogin_needed=0
    if ! ensure_input_group; then
        relogin_needed=1
    fi

    chmod +x "$GUI"

    say "======================================================"
    say "Setup finished successfully."
    say ""
    if [ "$relogin_needed" -eq 1 ]; then
        say "IMPORTANT: log out and log back in before starting the daemon."
        say "The new input-group permission is not active in this login session yet."
        say ""
    fi
    say "Open the OSKAR GUI with:"
    say "  $GUI"
    say ""
    say "From the GUI:"
    say "- Edit changes the three key text values."
    say "- Start Daemon starts OSKAR for this login session."
    say "- Advanced > Install registers OSKAR as a systemd user service at login."
    say ""
    say "If you switch between Wayland and X11 later, open the GUI from that session"
    say "and use Start Daemon or Advanced > Install again so systemd receives"
    say "the current desktop environment."
}

main "$@"
