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
source "$SCRIPT_DIR/../shared/sentry.sh"
source "$SCRIPT_DIR/../shared/vision.sh"
source "$SCRIPT_DIR/../shared/logfmt.sh"
source "$SCRIPT_DIR/../shared/scripts.sh"
source "$SCRIPT_DIR/../shared/record-frames.sh"
source "$SCRIPT_DIR/../shared/compare.sh"
source "$SCRIPT_DIR/build-device.sh"
source "$SCRIPT_DIR/build-ui.sh"
source "$SCRIPT_DIR/build-emulator.sh"
source "$SCRIPT_DIR/build-lock.sh"
source "$SCRIPT_DIR/build-gradle.sh"
source "$SCRIPT_DIR/build-lint.sh"
source "$SCRIPT_DIR/build-lifecycle.sh"
source "$SCRIPT_DIR/build-debug.sh"
source "$SCRIPT_DIR/build-record.sh"
source "$SCRIPT_DIR/build-overnight.sh"
source "$SCRIPT_DIR/build-worktree.sh"
source "$SCRIPT_DIR/build-doctor.sh"
source "$SCRIPT_DIR/build-sync.sh"
source "$SCRIPT_DIR/build-setup.sh"
source "$SCRIPT_DIR/build-icons.sh"
source "$SCRIPT_DIR/build-transcription-bench.sh"
source "$SCRIPT_DIR/build-profile.sh"

PID_FILE="$PROJECT_ROOT/.watch/android.pid"
TEST_TIMEOUT=120

# ── Timing constants ────────────────────────────────────────────────

LAUNCH_POLL_INTERVAL=0.5
LAUNCH_TIMEOUT_TICKS=16
REDEPLOY_GAP=0.5
WATCH_COOLDOWN=2.0

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
    # A new AVD's hardware while ANDROID_EMULATOR_AVD doesn't exist yet: the
    # iPhone 17 Pro's canvas, 402x874 dp, no microphone, the test camera.
    ANDROID_EMULATOR_PROFILE="${ANDROID_EMULATOR_PROFILE:-pixel_8}"
    ANDROID_EMULATOR_HARDWARE="${ANDROID_EMULATOR_HARDWARE:-hw.lcd.width=1206 hw.lcd.height=2622 hw.lcd.density=480 hw.ramSize=3072 hw.audioInput=no hw.camera.back=virtualscene hw.camera.front=emulated hw.keyboard=yes PlayStore.enabled=no skin.name=1206x2622 skin.path=_no_skin showDeviceFrame=no}"

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
    setup [--force]    First-time setup: SDK packages and licences, the AVD, local.properties,
                       the Gradle wrapper, then a build. Re-runs do only what is missing;
                       --force builds from clean
    build              Format, lint (ktlint, detekt) and assemble the configured build type
    clean              Gradle clean, and remove build/ (screenshots, recordings)
    install [target] [--quiet|-q] [--no-launch]
                       Build, install, adb reverse the server port, launch. --no-launch
                       installs and compiles as Play does without opening the app, so the
                       next launch is the first after an install
    launch [target] -- [extras...]  Launch the installed app, forwarding am start extras
                       (e.g. --ez turnMuted true); builds first when no APK exists
    uninstall [target] Stop the watcher and the app, and uninstall it. The emulator keeps
                       running; other work shares it ('emulator stop' shuts it down)
    watch [target] [mode]  Build + launch + auto-redeploy (mode: kotlin|build, default: kotlin)
    test [filter] [timeout] [--no-build|--build-only]
                       Run unit tests; filter by class name (or Class/method), several
                       separated by commas, timeout in seconds (default $TEST_TIMEOUT). Gradle builds only what changed,
                       so --no-build is accepted and changes nothing; --build-only builds
                       the tests without running them (and without the local server)
    test instrumented [filter] [timeout] [--build-only] [--keep-installed]
                       Run the tests under src/androidTest on the emulator or a phone;
                       --keep-installed leaves the app and its data for a second run
    lint               ktlint, detekt, the grep gates, the token gate, the parity gate and Android Lint on all sources
    unused             What R8 removes from the profile build, the app's own code only
    analyze            Android Lint with compose-lints, every warning an error
    audit              The lint overrides, then lint, unused and analyze
    format             Auto-format all Kotlin sources with ktlint
    doctor [--quick] [--json] [--watch [minutes]]
                       Check the machine, the SDK, the emulator and the server
                       ('./build.sh android doctor --help')
    logs [target] [--cat <cat>] [--level <level>] [--process <name|all>] [--minutes M] [N]
                 Show the last N lines (default 10) of the last M minutes (default 15),
                 from the app, another process (e.g. system_server) or all of them
    logs [target] [--cat <cat>] [--level <level>] tail  Stream live app logs
    debug [target] [--cat <cat>] [--level <level>] [--script <names>] [--no-build] [--timeout N]
                       Build (or with --no-build, just relaunch), launch, and trace logs
                       (stops when the app goes to the background or a script run ends).
                       A script run prints each script's result and the failed checks,
                       and exits 1 when a check failed or the app stopped first
    signin [emulator|device|<serial|avd name>] [email code]
                       Sign the emulator in with SCRIPT_ENV_TURN_LOGIN_EMAIL / _CODE from
                       build.properties.local, or with the given account and its fixed code
                       (runs the sign_in debug script, no rebuild)
    signout [emulator|device|<serial|avd name>]
                       Sign the emulator out (runs the sign_out debug script)

  Screen:
    emulator <start|stop|status|restart|create|front|contact|text-size|push>
                       Boot an AVD (ANDROID_EMULATOR_AVD by default), shut it down, show
                       what is connected, boot it again from cold, make an AVD, bring the
                       app to the front, add contacts the app may read, set the text size,
                       or hand the app a push ('./build.sh android emulator' shows the full help)
    push <payload.json>
                       Hand a push payload to the app's debug push receiver on the emulator;
                       no FCM is involved
    screenshot [target] [name]
                       Capture the emulator's or phone's screen to build/screenshots/;
                       prints the device it captured from and the absolute path last
    screenshots collect [target]
                       Copy the in-app screenshots of debug scripts into build/screenshots/
    see [target] [--focus "<question>"]
                       Capture the screen and describe it with the vision model
    record [target] [name] [--seconds N] [--script <names>] [--frames <fps>] [--fixture [slot]]
                       Record the screen to build/recordings/<name>.mp4 (at most 180 s);
                       --script films debug scripts from launch, --fixture seeds that
                       launch, --frames cuts frames and contact sheets
                       ('./build.sh android record --help')
    ui <tap|swipe|type|press|describe> [args]
                       Drive the screen and read its view tree ('./build.sh android ui')
    compare <scripts> [target] [--fixture [slot]] [--no-build] [--ios <dir>] [--android <dir>]
                       Run debug scripts, collect their frames and write build/compare/<run>/index.html
                       with the iOS frames beside them per frame name ('./build.sh android compare --help')

  Online (enable via build.properties):
    sentry <cmd>       Sentry queries (TOOLKIT_SENTRY_ENABLED, ANDROID_SENTRY_PROJECT)

  Parity with the leading platform:
    sync <status|diff|mark|map|init|coverage|guide>
                       Compare with iOS and keep the per-unit ledger under sync/
                       ('./build.sh android sync --help')
    icons [generate|check|scan|sheet]
                       Material Symbols drawables from icons.toml ('./build.sh android icons help')

  Performance:
    profile [target] [--script <names>] [--seconds N] [--render] [--name <label>] [--gfxinfo]
            [--main] [--until <seconds>] [--callers <function>] [--trace <file>] [--fixture [slot]]
                       Record a Perfetto trace of the installed app (default 40 s) and print the
                       FrameMonitor lines, CPU per thread, the heaviest functions and the app's
                       own code; --main adds the main thread's busy time per quarter second
                       ('./build.sh android profile --help')
    benchmark [target] [Class[#method]] [--build-only] [--fixture [slot]]
                       Run the Macrobenchmarks (startup, deck swipe) against the profile build

  Quality tests:
    transcription-bench [target] [push|run|report|clean] [--corpus <dir>] [--baseline <file>] [...]
                       Run a corpus of clips through the app's transcription engine and print
                       WER, switching, caption timing, speed, memory and heat per engine and
                       language ('./build.sh android transcription-bench help')

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
                               e.g. "--ez turnMuted true", or
                               "--es TURN_CLOCK 2026-11-17T23:47:43Z" to start
                               the debug build's clock at that instant.

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
        setup)       shift; do_setup "$@" ;;
        build)       do_build ;;
        clean)       do_clean ;;
        install)     shift; do_install "$@" ;;
        launch)      shift; do_launch "$@" ;;
        uninstall)   shift; do_uninstall "$@" ;;
        watch)       shift; do_watch "$@" ;;
        sentry)      shift; _dispatch_sentry "$@" ;;
        test)        shift; do_test "$@" ;;
        lint)        do_lint ;;
        unused)      do_android_unused ;;
        analyze)     do_android_analyze ;;
        audit)       do_android_audit ;;
        format)      do_format ;;
        doctor)      shift; do_doctor "$@" ;;
        logs)        shift; _android_logs "$@" ;;
        debug)       shift; _android_debug "$@" ;;
        signin)      shift; _sign_in_or_out sign_in "$@" ;;
        signout)     shift; _sign_in_or_out sign_out "$@" ;;
        emulator)
            shift
            case "${1:-}" in
                start|stop|restart|front|contact|text-size|push) _lock_take emulator || return 1 ;;
            esac
            do_emulator "$@"
            ;;
        push)        shift; _lock_take emulator && do_push "$@" ;;
        screenshot)  shift; _lock_take emulator && do_screenshot "$@" ;;
        screenshots) shift; do_screenshots_collect "$@" ;;
        see)         shift; _lock_take emulator && do_see "$@" ;;
        record)      shift; do_record "$@" ;;
        compare)     shift; do_compare "$@" ;;
        ui)          shift; _ui_wants_lock "$@" && { _lock_take emulator || return 1; }; do_ui "$@" ;;
        lock)        shift; do_lock "$@" ;;
        blocker)     shift; do_blocker "$@" ;;
        worktree)    shift; do_worktree "$@" ;;
        night)       shift; do_night "$@" ;;
        sync)        shift; do_sync "$@" ;;
        icons)       shift; do_icons "$@" ;;
        transcription-bench) shift; do_transcription_bench "$@" ;;
        profile)     shift; do_profile "$@" ;;
        benchmark)   shift; do_benchmark "$@" ;;
        help|--help|-h|"") usage ;;
        *)
            echo "✗ Unknown android command: $1"
            echo ""
            usage
            return 1
            ;;
    esac
}

_dispatch_sentry() {
    if [[ "${TOOLKIT_SENTRY_ENABLED:-false}" != "true" || -z "${SENTRY_ORG:-}" || -z "${ANDROID_SENTRY_PROJECT:-}" ]]; then
        echo "✗ Sentry not configured. Set TOOLKIT_SENTRY_ENABLED=true, SENTRY_ORG, and ANDROID_SENTRY_PROJECT in build.properties."
        return 1
    fi
    _sentry_dispatch "$ANDROID_SENTRY_PROJECT" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _dispatch "$@"
fi
