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
source "$SCRIPT_DIR/build-upload.sh"

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

    # The leading repository: by default the one this project sits in, when it has shared/.
    if [[ -z "${TURN_ROOT:-}" && -d "$PROJECT_ROOT/../shared" ]]; then
        TURN_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
    fi
    export TURN_ROOT

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

# The list of commands, or the help of the commands the arguments name
# (build-help.txt beside this file, then the project's own build-help.txt).
usage() {
    _help_show "./build.sh android" "$SCRIPT_DIR/build-help.txt" "$PROJECT_ROOT/build-help.txt" -- "$@"
}

# ── Help ────────────────────────────────────────────────────────────

# Every command, as _dispatch knows it. tests/help_test.sh checks both lists agree.
ANDROID_COMMANDS="setup build bundle clean install launch uninstall watch sentry test lint unused analyze audit
    format doctor logs debug signin signout emulator push screenshot screenshots see record compare
    ui lock blocker worktree night sync icons transcription-bench profile benchmark preflight upload promote"

# A command's details: its own usage where it has one, else its rows and
# section in config/README.md.
_command_help() {
    case "$1" in
        doctor) _doctor_usage ;;
        record) _record_usage ;;
        ui) _ui_usage ;;
        sync) _sync_usage ;;
        lock) _lock_usage ;;
        blocker) _blocker_usage ;;
        night) _night_usage ;;
        worktree) _worktree_usage ;;
        icons) _icons_usage ;;
        transcription-bench) _transcription_bench_usage ;;
        profile) _profile_usage ;;
        benchmark) _benchmark_usage ;;
        compare) _compare_usage ;;
        emulator) _emulator_usage ;;
        *) _readme_help "$1" ;;
    esac
}

# After a command's help: its details, without the usage lines the help
# shows already.
_help_more() {
    [[ " $(echo $ANDROID_COMMANDS) " == *" $1 "* ]] || return 0
    echo ""
    echo "Details:"
    _command_help "$1" 2>&1 | awk '
        !started && (/^Usage:/ || /^ +\.\/build\.sh / || /^[ \t]*$/) { next }
        { started = 1; print }'
}

_readme_help() {
    python3 -B - "$1" "$SCRIPT_DIR/config/README.md" <<'PY'
import re, sys, textwrap
cmd, readme = sys.argv[1], sys.argv[2]
starts = re.compile(r"`" + re.escape(cmd) + r"[ `]")
rows, section, heading = [], [], None
for line in open(readme, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("#"):
        heading = line.lstrip("#").strip()
        continue
    if line.startswith("|"):
        cells = [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line)[1:-1]]
        if len(cells) >= 2 and starts.search(cells[0]):
            rows.append(cells[:2])
        continue
    if heading == cmd:
        section.append(line)
if not rows and not section:
    print(f"No help for '{cmd}' in {readme}.")
    sys.exit(1)

def plain(text):
    return text.replace("`", "")

def wrap(text, first, rest):
    return textwrap.fill(text, 88, initial_indent=first, subsequent_indent=rest,
                         break_on_hyphens=False, break_long_words=False)

usages, body = [], []
for usage, does in rows:
    for part in re.split(r"` / `|`, `", usage):
        usages.append(plain(part).strip())
    if does == "Below.":
        continue
    indent = "  "
    if len(rows) > 1:
        body.append(f"  {plain(usage)}")
        indent = "      "
    body.append(wrap(plain(does), indent, indent))
    body.append("")
fenced = False
for line in section:
    if line.startswith("```"):
        fenced = not fenced
        continue
    if fenced:
        body.append("    " + line)
        continue
    if not line.strip():
        if body and body[-1] != "":
            body.append("")
        continue
    item = re.match(r"(\d+\.|-) ", line)
    hang = " " * (len(item.group(0)) if item else 0)
    body.append(wrap(plain(line), "  ", "  " + hang))
while body and body[-1] == "":
    body.pop()
for i, usage in enumerate(usages):
    print(("Usage: " if i == 0 else "       ") + "./build.sh android " + usage)
if usages:
    print()
print("\n".join(body))
PY
}

_dispatch() {
    # Help first: it never builds, uploads or touches a device.
    if _help_asked "$@"; then
        usage "$@"
        return $?
    fi
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
        bundle)      do_bundle ;;
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
        preflight)   do_preflight ;;
        upload)      shift; do_upload "$@" ;;
        promote)     shift; do_promote "$@" ;;
        "") usage ;;
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
