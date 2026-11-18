#!/bin/bash
# android-toolkit/build-lifecycle.sh: install, launch, stop and uninstall the app
# Sourced by build.sh.
#
# Provides: _find_apk, _app_id, _app_running, _terminate_app, _install_app,
#           _launch_app, _am_start, _reverse_server_port, _use_target,
#           _install_without_launch, do_install, do_launch, do_uninstall, do_watch
# Depends on: SERIAL, _select_android_target, _target_label (build-device.sh)
# Depends on: do_emulator (build-emulator.sh), do_build (build-gradle.sh)
# Depends on: _lock_take (build-lock.sh)

# The newest APK of the configured build type.
_find_apk() {
    local dir="$PROJECT_ROOT/$ANDROID_MODULE/build/outputs/apk/$(_build_config)"
    ls -t "$dir"/*.apk 2>/dev/null | head -1 || true
}

_aapt2() {
    ls -d "$ANDROID_SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1
}

# The application id of the configured build type: read from the built APK,
# else ANDROID_APPLICATION_ID plus DEV_APPLICATION_ID_SUFFIX (left off for release).
_app_id() {
    local apk aapt2 id
    apk=$(_find_apk)
    aapt2=$(_aapt2)
    if [[ -n "$apk" && -n "$aapt2" ]]; then
        id=$("$aapt2" dump packagename "$apk" 2>/dev/null | head -1 | tr -d '\r')
        [[ -n "$id" ]] && { echo "$id"; return 0; }
    fi
    if [[ -z "$ANDROID_APPLICATION_ID" ]]; then
        echo "✗ No APK built and no ANDROID_APPLICATION_ID in build.properties." >&2
        return 1
    fi
    if [[ "$(_build_config)" == "release" ]]; then
        echo "$ANDROID_APPLICATION_ID"
    else
        echo "${ANDROID_APPLICATION_ID}${DEV_APPLICATION_ID_SUFFIX}"
    fi
}

_app_pid() {
    "$ADB" -s "$SERIAL" shell pidof "$1" 2>/dev/null | tr -d '\r' || true
}

_app_installed() {
    "$ADB" -s "$SERIAL" shell pm path "$1" 2>/dev/null | grep -q '^package:'
}

_app_running() {
    [[ -n "$(_app_pid "$1")" ]]
}

_wait_for_app() {
    local app_id="$1" waited=0
    while [[ $waited -lt $LAUNCH_TIMEOUT_TICKS ]]; do
        if _app_running "$app_id"; then
            echo "  App running on $(_target_label)."
            return 0
        fi
        sleep "$LAUNCH_POLL_INTERVAL"
        waited=$((waited + 1))
    done
    echo "  App may still be launching on $(_target_label) (timed out)."
    return 0
}

_terminate_app() {
    "$ADB" -s "$SERIAL" shell am force-stop "$1" 2>/dev/null || true
}

# Picks the device for a command, booting ANDROID_EMULATOR_AVD when the
# target allows an emulator and nothing is connected.
_use_target() {
    local target="${1:-}"
    _require_adb || return 1
    case "$target" in
        ""|auto|emulator|simulator)
            if [[ -z "${_DEVICE_SELECTOR:-}" && -z "$(_connected_serials)" && -n "$ANDROID_EMULATOR_AVD" ]]; then
                do_emulator start || return 1
            fi
            ;;
    esac
    _select_android_target "$target"
}

# adb reverse lets the app reach the Mac's server at localhost; it is lost
# whenever the device reconnects, so every launch sets it again.
_reverse_server_port() {
    [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]] || return 0
    if ! "$ADB" -s "$SERIAL" reverse "tcp:$SERVER_PORT" "tcp:$SERVER_PORT" >/dev/null 2>&1; then
        echo "⚠ adb reverse tcp:$SERVER_PORT failed; the app can't reach the local server."
    fi
}

_install_app() {
    local apk
    apk=$(_find_apk)
    if [[ -z "$apk" ]]; then
        echo "✗ No APK for the $(_build_config) build. Build first."
        return 1
    fi
    echo "→ Installing on $(_target_label)"
    local out
    if out=$("$ADB" -s "$SERIAL" install -r -d -t "$apk" 2>&1) && grep -q "Success" <<<"$out"; then
        echo "✓ Installed"
    else
        echo "✗ Install failed:"
        tail -5 <<<"$out" | sed 's/^/  /'
        return 1
    fi
}

# Quotes one argument for the device's shell, which re-parses adb shell's command line.
_device_quote() {
    local quote="'" escaped="'\\''"
    printf "'%s'" "${1//$quote/$escaped}"
}

# The launcher activity: ANDROID_MAIN_ACTIVITY, else what the package manager resolves.
_main_component() {
    local app_id="$1"
    if [[ -n "$ANDROID_MAIN_ACTIVITY" ]]; then
        if [[ "$ANDROID_MAIN_ACTIVITY" == */* ]]; then
            echo "$ANDROID_MAIN_ACTIVITY"
        else
            echo "$app_id/$ANDROID_MAIN_ACTIVITY"
        fi
        return 0
    fi
    "$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$app_id" 2>/dev/null \
        | tr -d '\r' | grep '/' | tail -1
}

# Starts the app fresh (-S stops a running one) with am start extras, plus
# ANDROID_LAUNCH_ARGS.
_am_start() {
    local app_id="$1"
    shift
    local component
    component=$(_main_component "$app_id")
    if [[ -z "$component" ]]; then
        echo "✗ No launcher activity found for $app_id. Is it installed?"
        return 1
    fi
    local extra=()
    read -r -a extra <<< "${ANDROID_LAUNCH_ARGS:-}"
    local cmd="am start -W -S -n $(_device_quote "$component")" arg
    for arg in "$@" ${extra[@]+"${extra[@]}"}; do
        cmd+=" $(_device_quote "$arg")"
    done
    local out tries=0
    out=$("$ADB" -s "$SERIAL" shell "$cmd" 2>&1 | tr -d '\r')
    # Right after an install has killed the running app, the start can land on
    # its dying task: delivered to it, and no process starts. Start it again.
    while grep -q "delivered to currently running top-most instance" <<<"$out" && [[ $tries -lt 3 ]]; do
        tries=$((tries + 1))
        sleep 1
        out=$("$ADB" -s "$SERIAL" shell "$cmd" 2>&1 | tr -d '\r')
    done
    if grep -qE "^Error|Exception" <<<"$out"; then
        echo "✗ Launch failed:"
        grep -E "Error|Exception" <<<"$out" | head -5 | sed 's/^/  /'
        return 1
    fi
}

_launch_app() {
    local app_id
    app_id=$(_app_id) || return 1
    _install_app || return 1
    _reverse_server_port
    echo "→ Launching on $(_target_label)"
    _am_start "$app_id" "$@" || return 1
    _wait_for_app "$app_id"
}

# Reads [--fixture [slot]] out of the arguments into _FIXTURE_SLOT; the rest
# stays in _REST_ARGS.
_take_fixture_arg() {
    _FIXTURE_SLOT=""
    _REST_ARGS=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--fixture" ]]; then
            _FIXTURE_SLOT="${AGENT_SLOT:-1}"
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                _FIXTURE_SLOT="$2"
                shift
            fi
        else
            _REST_ARGS+=("$1")
        fi
        shift
    done
}

_launch_with_fixture() {
    _FIXTURE_EXTRAS=()
    if [[ -n "$_FIXTURE_SLOT" ]]; then
        _fixture_extras "$_FIXTURE_SLOT" || return 1
    fi
    _launch_app "$@" ${_FIXTURE_EXTRAS[@]+"${_FIXTURE_EXTRAS[@]}"}
}

do_install() {
    _take_fixture_arg "$@"
    local target="" no_launch=false arg
    for arg in ${_REST_ARGS[@]+"${_REST_ARGS[@]}"}; do
        case "$arg" in
            --quiet|-q) ;;
            # The next launch is the first after the install, as after an
            # update from Play: for profiling it.
            --no-launch) no_launch=true ;;
            -*) echo "✗ Unknown flag: $arg"; return 1 ;;
            *) target="$arg" ;;
        esac
    done
    if $no_launch && [[ -n "$_FIXTURE_SLOT" ]]; then
        echo "✗ --fixture seeds a launch; --no-launch has none."
        return 1
    fi
    do_build || return 1
    _lock_take emulator || return 1
    _use_target "$target" || return 1
    if $no_launch; then
        _install_without_launch
        return
    fi
    _launch_with_fixture
}

# Installs the built APK and compiles it the way Play leaves an app after an
# install or update (the speed-profile dexopt), without starting it.
_install_without_launch() {
    local app_id
    app_id=$(_app_id) || return 1
    _install_app || return 1
    _reverse_server_port
    local out
    out=$("$ADB" -s "$SERIAL" shell cmd package compile -m speed-profile -f "$app_id" 2>&1 | tr -d '\r' || true)
    if ! grep -q Success <<<"$out"; then
        echo "⚠ The speed-profile compile failed; the first launch runs less optimised code than after a Play install."
    fi
    echo "✓ Installed, not launched"
}

do_launch() {
    local before=() launch_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        before+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    launch_args=("$@")
    _take_fixture_arg ${before[@]+"${before[@]}"}
    local target="${_REST_ARGS[0]:-}"
    if [[ -z "$(_find_apk)" ]]; then
        echo "→ No built app found, building first"
        do_build || return 1
    fi
    _lock_take emulator || return 1
    _use_target "$target" || return 1
    _launch_with_fixture ${launch_args[@]+"${launch_args[@]}"}
}

do_uninstall() {
    _lock_take emulator || return 1
    _select_android_target "${1:-}" || return 1
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -rf "$PROJECT_ROOT/.watch"
        echo "Android watcher stopped."
    fi
    local app_id
    app_id=$(_app_id) || return 1
    _terminate_app "$app_id"
    echo "App stopped."
    if "$ADB" -s "$SERIAL" uninstall "$app_id" 2>/dev/null | grep -q Success; then
        echo "App uninstalled from $(_target_label)."
    else
        echo "App was not installed on $(_target_label)."
    fi
}

# Removes the watcher's folder, stops its fswatch and releases the locks when
# watch ends. Set again after each lock take, which sets its own EXIT trap.
_watch_trap() {
    trap '_lock_release_all; rm -rf "$PROJECT_ROOT/.watch"; pkill -P $$ fswatch 2>/dev/null || true' EXIT
}

# Stops the app, installs the newest APK and launches it, holding the
# emulator lock only meanwhile so other work can use the emulator between.
_watch_deploy() {
    local target="$1" app_id
    _lock_take emulator || return 1
    _watch_trap
    _use_target "$target" || { _lock_release emulator; return 1; }
    app_id=$(_app_id) || { _lock_release emulator; return 1; }
    _terminate_app "$app_id"
    sleep "$REDEPLOY_GAP"
    _launch_app || true
    _lock_release emulator
}

# watch [target] [kotlin|build]: build, launch, then redeploy on every change
# to a .kt file under the module (kotlin), or whenever .watch/build.stamp is
# touched (build), as ios watch does with swift|build.
do_watch() {
    local target="" mode="kotlin"
    if [[ $# -gt 0 ]]; then
        case "$1" in
            emulator|simulator|device|auto)
                target="$1"
                mode="${2:-kotlin}"
                ;;
            kotlin|build)
                mode="$1"
                ;;
            *)
                if _is_target_word "$1"; then
                    target="$1"
                    mode="${2:-kotlin}"
                else
                    mode="$1"
                fi
                ;;
        esac
    fi
    case "$mode" in
        kotlin|build) ;;
        *)
            echo "✗ Unknown watch mode: $mode. Use 'kotlin' or 'build'."
            return 1
            ;;
    esac
    if ! command -v fswatch >/dev/null 2>&1; then
        echo "✗ fswatch not found. Install with: brew install fswatch"
        return 1
    fi

    do_build || return 1
    _watch_deploy "$target" || return 1

    mkdir -p "$(dirname "$PID_FILE")"
    echo "$$" > "$PID_FILE"
    _watch_trap

    case "$mode" in
        kotlin)
            local dir="$PROJECT_ROOT/$ANDROID_MODULE/src"
            echo "Watching for Kotlin changes in $dir/ ..."
            echo ""
            while true; do
                local changed
                changed=$(fswatch --latency 0.5 --one-event "$dir/" 2>/dev/null || true)
                [[ "$changed" == *.kt ]] || continue
                echo "[$(date '+%H:%M:%S')] Change: $(basename "$changed") → rebuilding"
                if _assemble; then
                    _watch_deploy "$target" || true
                fi
                echo "[$(date '+%H:%M:%S')] Done."
                echo ""
                sleep "$WATCH_COOLDOWN"
            done
            ;;
        build)
            local stamp="$PROJECT_ROOT/.watch/build.stamp"
            [[ -f "$stamp" ]] || touch "$stamp"
            echo "Watching for builds via $stamp ..."
            echo ""
            while true; do
                fswatch --latency 0.5 --one-event "$stamp" >/dev/null 2>&1 || true
                echo "[$(date '+%H:%M:%S')] Build detected → redeploying"
                _watch_deploy "$target" || true
                echo "[$(date '+%H:%M:%S')] Done."
                echo ""
                sleep "$WATCH_COOLDOWN"
            done
            ;;
    esac
}
