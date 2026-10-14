#!/bin/bash
set -euo pipefail

# android-toolkit/build.sh — generic Android toolkit (drop-in for any project)
# Sourced by a thin project-level build.sh, or run directly.
# Configuration lives in <project>/build.properties. No project names are
# hardcoded; the commands and their output mirror toolkit/ios/build.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${TOOLKIT_PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$TOOLKIT_PROJECT_ROOT"
else
    PROJECT_ROOT="$(pwd)"
fi

source "$SCRIPT_DIR/../shared/build-utils.sh"
source "$SCRIPT_DIR/../shared/vision.sh"
source "$SCRIPT_DIR/build-device.sh"
source "$SCRIPT_DIR/build-ui.sh"
source "$SCRIPT_DIR/build-emulator.sh"

_load_android_config() {
    local props="$PROJECT_ROOT/build.properties"
    if [[ -f "$props" ]]; then
        # shellcheck disable=SC1090
        source "$props"
    fi
    local local_props="$PROJECT_ROOT/build.properties.local"
    if [[ -f "$local_props" ]]; then
        # shellcheck disable=SC1090
        source "$local_props"
    fi
    ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    ADB="$ANDROID_SDK/platform-tools/adb"
    EMULATOR_BIN="$ANDROID_SDK/emulator/emulator"
    ANDROID_EMULATOR_AVD="${ANDROID_EMULATOR_AVD:-}"
}

usage() {
    cat <<EOF
Usage: ./build.sh android <command> [<args>]

Devices:
  emulator <start|stop|status>
                        Boot the configured AVD (ANDROID_EMULATOR_AVD), shut it down,
                        or show what is connected
  screenshot [target] [name]
                        Capture the emulator's or phone's screen to build/screenshots/;
                        prints the device it captured from and the absolute path last
  see [target] [--focus "<question>"]
                        Capture the screen and describe it with the vision model
  ui <tap|swipe|type|press|describe> [args]
                        Drive the screen and read its view tree (see: ui --help)

Targets: emulator | device | <serial>. No target: the running emulator, else the
one connected phone. --device/-d <serial> or ANDROID_DEVICE picks one of several.
Coordinates are dp, the same numbers as iOS points on a 402x874 screen.
EOF
}

_dispatch() {
    _DEVICE_SELECTOR="${ANDROID_DEVICE:-}"
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device|-d)
                _DEVICE_SELECTOR="${2:-}"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    if [[ ${#args[@]} -gt 0 ]]; then
        set -- "${args[@]}"
    else
        set --
    fi

    _load_android_config

    case "${1:-}" in
        emulator)   shift; do_emulator "$@" ;;
        screenshot) shift; do_screenshot "$@" ;;
        see)        shift; do_see "$@" ;;
        ui)         shift; do_ui "$@" ;;
        help|--help|-h|"") usage ;;
        *)
            echo "✗ Unknown android command: $1"
            echo ""
            usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _dispatch "$@"
fi
