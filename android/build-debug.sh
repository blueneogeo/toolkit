#!/bin/bash
# android-toolkit/build-debug.sh: app logs and debug sessions with scripts
# Sourced by build.sh. The app logs with tag ANDROID_LOG_TAG and messages
# "<LEVEL> [<cat>] <msg>"; logcat lines are shown as
# "HH:MM:SS.mmm  LEVEL [cat] msg", the same as on iOS.
#
# Provides: _android_logs, _android_debug
# Depends on: _use_target, _app_id, _app_pid, _install_app, _am_start,
#             _reverse_server_port, _find_apk (build-lifecycle.sh)
# Depends on: do_build (build-gradle.sh), _lock_take (build-lock.sh)
# Depends on: _level_grep (shared/logfmt.sh), _sanitize_script_names (shared/scripts.sh)

DEBUG_MARKER_NAME="${DEBUG_MARKER_NAME:-scriptor-ready}"
DEBUG_RUNNER_WAIT=40

# Formats logcat -v time lines. Lines of the app's own tag become
# "time  LEVEL [cat] msg"; other tags (--cat all) keep "P/Tag: msg".
_logcat_format() {
    local tag="$1"
    sed -u -E \
        -e "s/^[0-9]{2}-[0-9]{2} ([0-9:.]+) [VDIWEF]\/${tag} *\( *[0-9]+\): /\1  /" \
        -e 's/^[0-9]{2}-[0-9]{2} ([0-9:.]+) ([VDIWEF])\/([^(]*[^ (]) *\( *[0-9]+\): /\1  \2\/\3: /'
}

# True when a formatted line passes --level.
_level_keep() {
    local level="$1" line="$2" token
    [[ -z "$level" ]] && return 0
    token="${line#*  }"
    token="${token%% *}"
    case "$level" in
        info)    [[ "$token" != "DEBUG" ]] ;;
        warning) [[ "$token" != "DEBUG" && "$token" != "INFO" ]] ;;
        error)   [[ "$token" == "WARNING" || "$token" == "ERROR" ]] ;;
        *)       return 0 ;;
    esac
}

_android_logs() {
    if [[ "${TOOLKIT_LOGS_ENABLED:-true}" != "true" ]]; then
        echo "✗ Logs disabled. Set TOOLKIT_LOGS_ENABLED=true in build.properties."
        return 1
    fi
    local target=""
    if [[ -n "${1:-}" && "$1" != --* && "$1" != "tail" && ! "$1" =~ ^[0-9]+$ ]]; then
        target="$1"
        shift
    fi
    _select_android_target "$target" || return 1
    local cat_filter="" level_filter="" cmd=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cat) cat_filter="${2:-}"; shift 2 ;;
            --level) level_filter="${2:-}"; shift 2 ;;
            *) cmd="$1"; shift ;;
        esac
    done
    [[ -z "$cmd" ]] && cmd=10

    local source_args=(-s "$ANDROID_LOG_TAG:V")
    if [[ "$cat_filter" == "all" ]]; then
        local app_id pid
        app_id=$(_app_id) || return 1
        pid=$(_app_pid "$app_id")
        if [[ -z "$pid" ]]; then
            echo "✗ $app_id is not running; --cat all reads the running app's process."
            return 1
        fi
        source_args=("--pid=$pid")
        cat_filter=""
    fi

    if [[ "$cmd" == "tail" ]]; then
        if [[ -n "$cat_filter" ]]; then
            echo "→ Streaming app logs (filter: $cat_filter, Ctrl-C to stop)..."
        else
            echo "→ Streaming app logs (Ctrl-C to stop)..."
        fi
        local line
        local since
        since=$(_device_now)
        "$ADB" -s "$SERIAL" logcat -v time -T "$since" "${source_args[@]}" 2>/dev/null | tr -u -d '\r' | _logcat_format "$ANDROID_LOG_TAG" | while IFS= read -r line; do
            [[ "$line" == "--------- beginning of"* ]] && continue
            [[ -n "$cat_filter" && "$line" != *"[${cat_filter}]"* ]] && continue
            _level_keep "$level_filter" "$line" && echo "$line"
        done
        return 0
    fi

    local lines="$cmd"
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=10
    if [[ -n "$cat_filter" ]]; then
        echo "→ Last $lines app logs (filter: $cat_filter):"
    else
        echo "→ Last $lines app logs:"
    fi
    "$ADB" -s "$SERIAL" logcat -d -v time "${source_args[@]}" 2>/dev/null | tr -d '\r' \
        | { grep -v '^--------- beginning of' || true; } \
        | { if [[ -n "$cat_filter" ]]; then grep -F "[${cat_filter}]" || true; else cat; fi; } \
        | _logcat_format "$ANDROID_LOG_TAG" | _level_grep "$level_filter" | tail -n "$lines"
}

# The device's clock in logcat's -T format.
_device_now() {
    "$ADB" -s "$SERIAL" shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r'
}

# Only debuggable builds can be reached with run-as.
_debuggable_config() {
    [[ "$(_build_config)" == "debug" ]]
}

_run_as() {
    local app_id="$1" cmd="$2"
    "$ADB" -s "$SERIAL" shell "run-as $app_id sh -c $(_device_quote "$cmd")" >/dev/null 2>&1
}

_clear_scriptor_marker() {
    _run_as "$1" "rm -f cache/$DEBUG_MARKER_NAME" || true
}

_write_scriptor_marker() {
    _run_as "$1" "mkdir -p cache && touch cache/$DEBUG_MARKER_NAME" || echo "⚠ Could not write the start marker with run-as."
}

# am start extras for a script run: the names, every SCRIPT_ENV_<NAME> as
# <NAME>, and the login of `signin <email> <code>`.
_script_extras() {
    local names="$1" no_marker="$2"
    _SCRIPT_EXTRAS=(--es TURN_DEBUG_SCRIPT_NAMES "$names")
    $no_marker && _SCRIPT_EXTRAS+=(--es TURN_DEBUG_SCRIPT_NO_MARKER 1)
    local script_var
    for script_var in $(compgen -v SCRIPT_ENV_ || true); do
        _SCRIPT_EXTRAS+=(--es "${script_var#SCRIPT_ENV_}" "${!script_var}")
    done
    if [[ -n "${_SIGNIN_EMAIL:-}" ]]; then
        _SCRIPT_EXTRAS+=(--es TURN_LOGIN_EMAIL "$_SIGNIN_EMAIL" --es TURN_LOGIN_CODE "$_SIGNIN_CODE")
    fi
}

# A fresh session of the agent fixture's slot: runs the project's fixture
# session command (refresh tokens work once), then reads the slot's token and
# clock from build.properties.local into _FIXTURE_EXTRAS.
_fixture_extras() {
    local slot="${1:-${AGENT_SLOT:-1}}"
    _FIXTURE_EXTRAS=()
    if ! [[ "$slot" =~ ^[0-9]+$ ]]; then
        echo "✗ --fixture takes a slot number: $slot"
        return 1
    fi
    local cmd="${TOOLKIT_FIXTURE_SESSION_CMD:-./build.sh fixture session}" out
    echo "→ New session for fixture slot $slot"
    if ! out=$(cd "$PROJECT_ROOT" && $cmd "$slot" 2>&1); then
        echo "✗ Fixture session failed:"
        sed 's/^/  /' <<<"$out"
        return 1
    fi
    local token clock
    token=$(sed -n "s/^FIXTURE_SLOT_${slot}_REFRESH_TOKEN=//p" "$PROJECT_ROOT/build.properties.local" 2>/dev/null | tail -1 | tr -d '"')
    clock=$(sed -n "s/^FIXTURE_SLOT_${slot}_CLOCK=//p" "$PROJECT_ROOT/build.properties.local" 2>/dev/null | tail -1 | tr -d '"')
    if [[ -z "$token" ]]; then
        echo "✗ No FIXTURE_SLOT_${slot}_REFRESH_TOKEN in build.properties.local after the session."
        return 1
    fi
    _FIXTURE_EXTRAS=(--es TURN_DEBUG_REFRESH_TOKEN "$token")
    [[ -n "$clock" ]] && _FIXTURE_EXTRAS+=(--es TURN_CLOCK "$clock")
    return 0
}

_android_debug() {
    if [[ "${TOOLKIT_LOGS_ENABLED:-true}" != "true" ]]; then
        echo "✗ Logs disabled. Set TOOLKIT_LOGS_ENABLED=true in build.properties."
        return 1
    fi
    local target=""
    if [[ -n "${1:-}" && "$1" != --* ]]; then
        target="$1"
        shift
    fi
    local cat_filter="" level_filter="" script_names="" no_build=false timeout="" fixture=""
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --fixture)
                fixture="${AGENT_SLOT:-1}"
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    fixture="$2"
                    shift
                fi
                shift
                ;;
            --cat) cat_filter="${2:-}"; shift 2 ;;
            --level) level_filter="${2:-}"; shift 2 ;;
            --script) script_names="${2:-}"; shift 2 ;;
            --no-build) no_build=true; shift ;;
            --timeout) timeout="${2:-}"; shift 2 ;;
            *) echo "⚠ Unknown flag: $1" >&2; shift ;;
        esac
    done
    if [[ -n "$timeout" && ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "✗ --timeout needs a whole number of seconds"
        return 1
    fi
    if [[ -n "$script_names" && "${TOOLKIT_DEBUG_SCRIPTS:-false}" != "true" ]]; then
        echo "⚠ --script ignored: set TOOLKIT_DEBUG_SCRIPTS=true in build.properties to enable debug scripts."
        script_names=""
    fi
    if [[ -n "$script_names" ]]; then
        script_names=$(_sanitize_script_names "$script_names") || { echo "$script_names"; return 1; }
        timeout="${timeout:-${TOOLKIT_DEBUG_TIMEOUT:-600}}"
    fi

    if ! $no_build || [[ -z "$(_find_apk)" ]]; then
        $no_build && echo "→ No built app found, building first"
        do_build || return 1
    fi
    _lock_take emulator || return 1
    _use_target "$target" || return 1
    "$ADB" -s "$SERIAL" wait-for-device
    local app_id
    app_id=$(_app_id) || return 1
    _install_app || return 1
    _reverse_server_port

    local use_marker=false
    _SCRIPT_EXTRAS=()
    if [[ -n "$script_names" ]]; then
        if _debuggable_config; then
            use_marker=true
            _clear_scriptor_marker "$app_id"
            _script_extras "$script_names" false
        else
            _script_extras "$script_names" true
        fi
    fi

    _FIXTURE_EXTRAS=()
    if [[ -n "$fixture" ]]; then
        _fixture_extras "$fixture" || return 1
    fi

    local since fifo logcat_pid
    since=$(_device_now)
    fifo=$(mktemp -u)
    mkfifo "$fifo"
    "$ADB" -s "$SERIAL" logcat -v time -T "$since" "*:V" > "$fifo" 2>/dev/null &
    logcat_pid=$!

    echo "→ Launching on $(_target_label)"
    if ! _am_start "$app_id" ${_SCRIPT_EXTRAS[@]+"${_SCRIPT_EXTRAS[@]}"} ${_FIXTURE_EXTRAS[@]+"${_FIXTURE_EXTRAS[@]}"}; then
        kill "$logcat_pid" 2>/dev/null || true
        rm -f "$fifo"
        return 1
    fi
    local pid=""
    local waited=0
    while [[ -z "$pid" && $waited -lt $LAUNCH_TIMEOUT_TICKS ]]; do
        pid=$(_app_pid "$app_id")
        [[ -z "$pid" ]] && { sleep "$LAUNCH_POLL_INTERVAL"; waited=$((waited + 1)); }
    done

    echo ""
    if [[ "$cat_filter" == "all" ]]; then
        echo "→ Debug session started (all logs). Go to home screen to stop."
    elif [[ -n "$cat_filter" ]]; then
        echo "→ Debug session started (filter: $cat_filter). Go to home screen to stop."
    else
        echo "→ Debug session started ($ANDROID_LOG_TAG logger only). Go to home screen to stop."
    fi
    echo ""

    $use_marker && ( sleep 1; _write_scriptor_marker "$app_id" ) &

    local started=$SECONDS heard_runner=false ended=false outcome="ended" line formatted
    while true; do
        if IFS= read -r -t 2 line; then
            line="${line%$'\r'}"
            [[ "$line" == "--------- beginning of"* ]] && continue
            local own=false
            [[ "$line" =~ ^[0-9-]+\ [0-9:.]+\ [VDIWEF]/${ANDROID_LOG_TAG}\ *\( ]] && own=true
            if ! $own && [[ "$cat_filter" == "all" && -n "$pid" ]]; then
                [[ "$line" =~ \(\ *${pid}\): ]] || continue
            elif ! $own; then
                continue
            fi
            [[ "$line" == *"[scriptor]"* ]] && heard_runner=true
            local show=false
            if [[ "$cat_filter" == "all" || -z "$cat_filter" ]]; then
                show=true
            elif [[ "$line" == *"[${cat_filter}]"* ]]; then
                show=true
            fi
            [[ "$line" == *"DEBUG_SESSION_ENDED"* ]] && show=true
            if $show; then
                formatted=$(_logcat_format "$ANDROID_LOG_TAG" <<<"$line")
                _level_keep "$level_filter" "$formatted" && echo "$formatted"
            fi
            if [[ "$line" == *"DEBUG_SESSION_ENDED"* ]]; then
                ended=true
                break
            fi
        else
            if [[ -n "$pid" ]] && ! _app_running "$app_id"; then
                break
            fi
        fi
        if [[ -n "$script_names" ]] && ! $heard_runner && (( SECONDS - started >= DEBUG_RUNNER_WAIT )); then
            outcome="no-runner"
            break
        fi
        if [[ -n "$timeout" ]] && (( SECONDS - started >= timeout )); then
            outcome="timeout"
            break
        fi
    done < "$fifo"
    kill "$logcat_pid" 2>/dev/null || true
    { wait "$logcat_pid"; } 2>/dev/null || true
    rm -f "$fifo"

    echo ""
    case "$outcome" in
        no-runner)
            echo "✗ No [scriptor] line in ${DEBUG_RUNNER_WAIT}s: this build has no script runner, or it did not start."
            return 1
            ;;
        timeout)
            echo "✗ Session timed out after ${timeout}s without DEBUG_SESSION_ENDED."
            return 1
            ;;
    esac
    if $ended; then
        echo "✓ App backgrounded, session ended."
    else
        echo "✓ App stopped, session ended."
    fi
}
