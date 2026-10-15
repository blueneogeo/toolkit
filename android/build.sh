#!/bin/bash
set -euo pipefail

# android-toolkit/build.sh: generic Android toolkit (drop-in for any project)
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
source "$SCRIPT_DIR/../shared/logfmt.sh"
source "$SCRIPT_DIR/../shared/scripts.sh"
source "$SCRIPT_DIR/../shared/record-frames.sh"
source "$SCRIPT_DIR/build-device.sh"
source "$SCRIPT_DIR/build-ui.sh"
source "$SCRIPT_DIR/build-emulator.sh"
source "$SCRIPT_DIR/build-lock.sh"
source "$SCRIPT_DIR/build-gradle.sh"
source "$SCRIPT_DIR/build-lifecycle.sh"
source "$SCRIPT_DIR/build-debug.sh"
source "$SCRIPT_DIR/build-record.sh"
source "$SCRIPT_DIR/build-overnight.sh"
source "$SCRIPT_DIR/build-worktree.sh"
source "$SCRIPT_DIR/build-doctor.sh"
source "$SCRIPT_DIR/build-sync.sh"

PID_FILE="$PROJECT_ROOT/.watch/android.pid"
TEST_TIMEOUT=120

# ── Timing constants ────────────────────────────────────────────────

LAUNCH_POLL_INTERVAL=0.5
LAUNCH_TIMEOUT_TICKS=16

# ── Config ──────────────────────────────────────────────────────────

_load_android_config() {
    local file
    for file in "$PROJECT_ROOT/../build.properties" "$PROJECT_ROOT/build.properties" "$PROJECT_ROOT/build.properties.local"; do
        if [[ -f "$file" ]]; then
            set -a
            # shellcheck disable=SC1090
            source "$file"
            set +a
        fi
    done

    TOOLKIT_SERVER_ENABLED="${TOOLKIT_SERVER_ENABLED:-false}"
    TOOLKIT_UPLOAD_ENABLED="${TOOLKIT_UPLOAD_ENABLED:-false}"
    TOOLKIT_SENTRY_ENABLED="${TOOLKIT_SENTRY_ENABLED:-false}"
    TOOLKIT_LOGS_ENABLED="${TOOLKIT_LOGS_ENABLED:-true}"
    TOOLKIT_DEBUG_SCRIPTS="${TOOLKIT_DEBUG_SCRIPTS:-false}"
    TOOLKIT_ARCH_CHECKS="${TOOLKIT_ARCH_CHECKS:-true}"

    ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    ADB="$ANDROID_SDK/platform-tools/adb"
    EMULATOR_BIN="$ANDROID_SDK/emulator/emulator"
    ANDROID_EMULATOR_AVD="${ANDROID_EMULATOR_AVD:-}"

    ANDROID_MODULE="${ANDROID_MODULE:-app}"
    ANDROID_APPLICATION_ID="${ANDROID_APPLICATION_ID:-}"
    DEV_APPLICATION_ID_SUFFIX="${DEV_APPLICATION_ID_SUFFIX:-}"
    ANDROID_APP_NAME="${ANDROID_APP_NAME:-$(basename "$PROJECT_ROOT")}"
    ANDROID_MAIN_ACTIVITY="${ANDROID_MAIN_ACTIVITY:-}"
    ANDROID_LOG_TAG="${ANDROID_LOG_TAG:-$ANDROID_APP_NAME}"
    SERVER_PORT="${SERVER_PORT:-8080}"
    SERVER_HEALTH_URL="${SERVER_HEALTH_URL:-http://localhost:$SERVER_PORT/api/health}"
    SERVER_START_CMD="${SERVER_START_CMD:-}"
}

# debug (default), profile or release; ANDROID_CONFIG sets a default.
_build_config() {
    echo "${_BUILD_CONFIG:-debug}"
}

# The Gradle variant name: Debug, Profile, Release.
_build_variant() {
    local cfg
    cfg="$(_build_config)"
    echo "$(tr '[:lower:]' '[:upper:]' <<<"${cfg:0:1}")${cfg:1}"
}

usage() {
    cat <<EOF
Usage: ./build.sh android [--device <serial>] [--config <name>] <command> [<args>]

  Target selection (install/launch/uninstall/debug/logs/record/screenshot/see/ui):
    The optional target after the command is: emulator | device | <serial|avd name>.
    'simulator' means the emulator. No target: the running emulator, else the one
    connected phone; install, launch, debug and record boot ANDROID_EMULATOR_AVD
    when nothing is connected. --device or ANDROID_DEVICE picks one of several.

  Local dev:
    build              Format, lint (ktlint, detekt) and assemble the configured build type
    clean              Gradle clean, and remove build/ (screenshots, recordings)
    install [target] [--quiet|-q]   Build, install, adb reverse the server port, launch
    launch [target] -- [extras...]  Launch the installed app, forwarding am start extras
                       (e.g. --ez turnMuted true); builds first when no APK exists
    uninstall [target] Stop the watcher and the app, and uninstall it. The emulator keeps
                       running; other work shares it ('emulator stop' shuts it down)
    test [filter] [timeout] [--no-build]
                       Run unit tests; filter by class name (or Class/method), timeout
                       in seconds (default $TEST_TIMEOUT). Gradle builds only what changed,
                       so --no-build is accepted and changes nothing
    lint               ktlint, detekt, the parity gate and Android Lint on all sources
    format             Auto-format all Kotlin sources with ktlint
    doctor [--quick] [--json] [--watch [minutes]]
                       Check the machine, the SDK, the emulator and the server
                       ('./build.sh android doctor --help')
    logs [target] [--cat <cat>] [--level <level>] [N]  Show the app's last N log lines (default 10)
    logs [target] [--cat <cat>] [--level <level>] tail Stream the app's logs
    debug [target] [--cat <cat>] [--level <level>] [--script <names>] [--no-build] [--timeout N]
                       Build (or with --no-build, just relaunch), launch, and trace logs
                       (stops when the app goes to the background or a script run ends)
    signin [email code]  Sign the emulator in with SCRIPT_ENV_TURN_LOGIN_EMAIL / _CODE from
                       build.properties.local, or with the given login (runs sign_in)
    signout            Sign the emulator out (runs the sign_out script)

  Screen:
    emulator <start|stop|status>
                       Boot the configured AVD (ANDROID_EMULATOR_AVD), shut it down,
                       or show what is connected
    screenshot [target] [name]
                       Capture the emulator's or phone's screen to build/screenshots/;
                       prints the device it captured from and the absolute path last
    screenshots collect [target]
                       Copy the in-app screenshots of debug scripts into build/screenshots/
    see [target] [--focus "<question>"]
                       Capture the screen and describe it with the vision model
    record [target] [name] [--seconds N] [--script <names>] [--frames <fps>]
                       Record the screen to build/recordings/<name>.mp4 (at most 180 s);
                       --script films debug scripts from launch, --frames cuts frames
                       and contact sheets ('./build.sh android record --help')
    ui <tap|swipe|type|press|describe> [args]
                       Drive the screen and read its view tree ('./build.sh android ui')

  Parity with the leading platform:
    sync <status|diff|mark|map|init|coverage|guide>
                       Compare with iOS and keep the per-unit ledger under sync/
                       ('./build.sh android sync --help')

  Overnight work:
    lock <gradle|emulator> -- <command...>
                       Run a command holding a shared lock ('./build.sh android lock --help')
    lock status        Show who holds each lock
    blocker add --kind <kind> --summary "<text>" [...]
                       Append a line to the night's blockers.jsonl ('blocker --help')
    worktree new <package> | remove <package> [--force] | list
                       Package worktrees with toolkit/ filled in ('worktree --help')
    night init <date>  Create the night's folder and queue.json ('night --help')

Options:
    --device, -d <serial>      Pick which connected device a command uses when several
                               are connected. ANDROID_DEVICE sets a default.

    --config, -c <name>        Build type for build, install, launch, debug, test and lint:
                               debug (default), profile (optimised, still the development
                               app and server) or release. ANDROID_CONFIG sets a default.
                               Example: ./build.sh android --config profile install

    ANDROID_LAUNCH_ARGS="<extras>"
                               am start extras added to every launch,
                               e.g. "--ez turnMuted true".

Coordinates are dp, the same numbers as iOS points on a 402x874 screen.
EOF
}

_dispatch() {
    _INVOCATION="android $*"
    _DEVICE_SELECTOR="${ANDROID_DEVICE:-}"
    _BUILD_CONFIG=""
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)
                args+=("$@")
                break
                ;;
            --device|-d)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "✗ --device requires a serial or an AVD name"
                    return 1
                fi
                _DEVICE_SELECTOR="$2"
                shift 2
                ;;
            --config|-c)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "✗ --config requires a build type (debug, profile, release)"
                    return 1
                fi
                _BUILD_CONFIG="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
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

    if [[ -z "$_BUILD_CONFIG" && -n "${ANDROID_CONFIG:-}" ]]; then
        _BUILD_CONFIG="$(tr '[:upper:]' '[:lower:]' <<<"$ANDROID_CONFIG")"
    fi
    case "$(_build_config)" in
        debug|profile|release) ;;
        *)
            echo "✗ Unknown build type '$(_build_config)'. Use debug, profile or release."
            return 1
            ;;
    esac

    case "${1:-}" in
        build)       do_build ;;
        clean)       do_clean ;;
        install)     shift; do_install "$@" ;;
        launch)      shift; do_launch "$@" ;;
        uninstall)   shift; do_uninstall "$@" ;;
        test)        shift; do_test "$@" ;;
        lint)        do_lint ;;
        format)      do_format ;;
        doctor)      shift; do_doctor "$@" ;;
        logs)        shift; _android_logs "$@" ;;
        debug)       shift; _android_debug "$@" ;;
        signin)
            shift
            if [[ $# -ge 2 ]]; then
                _SIGNIN_EMAIL="$1"
                _SIGNIN_CODE="$2"
            fi
            _android_debug emulator --no-build --script sign_in
            ;;
        signout)     _android_debug emulator --no-build --script sign_out ;;
        emulator)
            shift
            case "${1:-}" in
                start|stop) _lock_take emulator || return 1 ;;
            esac
            do_emulator "$@"
            ;;
        screenshot)  shift; _lock_take emulator && do_screenshot "$@" ;;
        screenshots) shift; do_screenshots_collect "$@" ;;
        see)         shift; _lock_take emulator && do_see "$@" ;;
        record)      shift; do_record "$@" ;;
        ui)          shift; _ui_wants_lock "$@" && { _lock_take emulator || return 1; }; do_ui "$@" ;;
        lock)        shift; do_lock "$@" ;;
        blocker)     shift; do_blocker "$@" ;;
        worktree)    shift; do_worktree "$@" ;;
        night)       shift; do_night "$@" ;;
        sync)        shift; do_sync "$@" ;;
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
