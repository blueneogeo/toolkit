#!/bin/bash
# android-toolkit/build-debug.sh: app logs and debug sessions with scripts
# Sourced by build.sh. The app logs with tag ANDROID_LOG_TAG and messages
# "<LEVEL> [<cat>] <msg>"; logcat lines are shown as
# "HH:MM:SS.mmm  LEVEL [cat] msg", the same as on iOS.
#
# Provides: _android_logs, _android_debug, _sign_in_or_out
# Depends on: _use_target, _app_id, _app_pid, _install_app, _am_start,
#             _app_installed, _reverse_server_port, _find_apk (build-lifecycle.sh)
# Depends on: do_build (build-gradle.sh), _lock_take (build-lock.sh)
# Depends on: _level_grep (shared/logfmt.sh), _sanitize_script_names,
#             _note_script_line, _script_summary (shared/scripts.sh)

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
    local cat_filter="" level_filter="" process="" minutes=15 cmd=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cat | --level | --process | --minutes)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --cat) cat_filter="$2" ;;
                    --level) level_filter="$2" ;;
                    --process) process="$2" ;;
                    --minutes) minutes="$2" ;;
                esac
                shift 2
                ;;
            *) cmd="$1"; shift ;;
        esac
    done
    if ! [[ "$minutes" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ --minutes takes a whole number of minutes, from 1."
        return 1
    fi
    if [[ "$cmd" == "tail" && ( -n "$process" || "$minutes" != 15 ) ]]; then
        echo "✗ tail follows the app's own lines; --process and --minutes are for the last N lines."
        return 1
    fi
    _select_android_target "$target" || return 1

    # The app's own tag; --cat all, every line of the app's process;
    # --process <name>, every line of that process; --process all, every line.
    local source_args=(-s "$ANDROID_LOG_TAG:V") source_name="app logs"
    if [[ "$process" == "all" ]]; then
        source_args=("*:V")
        source_name="logs of all"
        cat_filter="${cat_filter#all}"
    elif [[ -n "$process" || "$cat_filter" == "all" ]]; then
        local name="$process" pid
        if [[ -z "$name" ]]; then
            name=$(_app_id) || return 1
        else
            source_name="logs of $process"
        fi
        pid=$("$ADB" -s "$SERIAL" shell pidof "$name" 2>/dev/null | tr -d '\r' | awk '{ print $1 }' || true)
        if [[ -z "$pid" ]]; then
            if [[ -z "$process" ]]; then
                echo "✗ $name is not running; --cat all reads the running app's process."
            else
                echo "✗ No process called $process is running."
            fi
            return 1
        fi
        source_args=("--pid=$pid" "*:V")
        [[ "$cat_filter" == "all" ]] && cat_filter=""
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
        echo "→ Last $lines ${source_name} (filter: $cat_filter):"
    else
        echo "→ Last $lines ${source_name}:"
    fi
    local since
    since=$(_device_minutes_ago "$minutes")
    "$ADB" -s "$SERIAL" logcat -d -v time ${since:+-T "$since"} "${source_args[@]}" 2>/dev/null | tr -d '\r' \
        | { grep -v '^--------- beginning of' || true; } \
        | { if [[ -n "$cat_filter" ]]; then grep -F "[${cat_filter}]" || true; else cat; fi; } \
        | _logcat_format "$ANDROID_LOG_TAG" | _level_grep "$level_filter" | tail -n "$lines"
}

# The device's clock M minutes ago, in logcat's -T format; nothing when the
# device's date can't count back.
_device_minutes_ago() {
    local minutes="$1"
    "$ADB" -s "$SERIAL" shell "date -d @\$((\$(date +%s) - $minutes * 60)) '+%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r' \
        | grep -E '^[0-9]{2}-[0-9]{2} [0-9:.]+$' || true
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
    _fixture_clear_stale_app "$slot" "$clock"
    return 0
}

# The slot and reset instant the app was last seeded with. The stamp lives in
# the app's own data, so pm clear and uninstall remove it with the rest.
FIXTURE_STAMP_FILE="${FIXTURE_STAMP_FILE:-files/toolkit-fixture-seed}"

_fixture_seeded() {
    "$ADB" -s "$SERIAL" shell "run-as $1 cat $FIXTURE_STAMP_FILE 2>/dev/null" 2>/dev/null | tr -d '\r' || true
}

# Runtime permissions the app holds, one per line.
_granted_runtime_permissions() {
    "$ADB" -s "$SERIAL" shell dumpsys package "$1" 2>/dev/null | tr -d '\r' | awk '
        /runtime permissions:/ { inside = 1; next }
        inside && /^ *[A-Za-z0-9_.]+: granted=/ {
            if ($0 ~ /granted=true/) { line = $0; sub(/^ */, "", line); sub(/:.*/, "", line); print line }
            next
        }
        inside { inside = 0 }'
}

# A slot reset since the app last ran leaves the app holding the old account's
# keys, and another slot's session leaves another account's. Either way the
# app's data is cleared before the new session is seeded; the permissions it
# had are granted again. Only debuggable builds can be read with run-as; an app
# that isn't installed yet has nothing to clear.
_fixture_clear_stale_app() {
    local slot="$1" clock="$2" app_id seeded wanted
    _debuggable_config || return 0
    app_id=$(_app_id 2>/dev/null) || return 0
    _app_installed "$app_id" || return 0
    wanted="$slot $clock"
    seeded=$(_fixture_seeded "$app_id")
    if [[ "$seeded" != "$wanted" ]]; then
        if [[ -z "$seeded" ]]; then
            echo "→ The app wasn't seeded from a fixture slot: clearing its data"
        else
            echo "→ The app holds slot ${seeded%% *} as reset at ${seeded#* }: clearing its data"
        fi
        local granted permission
        granted=$(_granted_runtime_permissions "$app_id")
        if ! "$ADB" -s "$SERIAL" shell pm clear "$app_id" 2>/dev/null | tr -d '\r' | grep -q Success; then
            echo "⚠ pm clear failed; the app keeps its data."
            return 0
        fi
        for permission in $granted; do
            "$ADB" -s "$SERIAL" shell pm grant "$app_id" "$permission" >/dev/null 2>&1 || true
        done
    fi
    _run_as "$app_id" "mkdir -p files && echo $(_device_quote "$wanted") > $FIXTURE_STAMP_FILE" \
        || echo "⚠ Could not write the fixture stamp with run-as."
}

_android_debug() {
    if [[ "${TOOLKIT_LOGS_ENABLED:-true}" != "true" ]]; then
        echo "✗ Logs disabled. Set TOOLKIT_LOGS_ENABLED=true in build.properties."
        return 1
    fi
    # The target and the flags come in any order; a second target or an
    # unknown flag stops the run, so it never falls back to another device.
    local target="" cat_filter="" level_filter="" script_names="" no_build=false timeout="" fixture=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fixture)
                fixture="${AGENT_SLOT:-1}"
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    fixture="$2"
                    shift
                fi
                shift
                ;;
            --cat | --level | --script | --timeout)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --cat) cat_filter="$2" ;;
                    --level) level_filter="$2" ;;
                    --script) script_names="$2" ;;
                    --timeout) timeout="$2" ;;
                esac
                shift 2
                ;;
            --no-build) no_build=true; shift ;;
            --quiet|-q) shift ;;
            -*) echo "✗ Unknown flag: $1" >&2; return 1 ;;
            *)
                if [[ -n "$target" ]]; then
                    echo "✗ Two targets: $target and $1" >&2
                    return 1
                fi
                target="$1"
                shift
                ;;
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

    # The fixture first: a stale app's data is cleared before the marker is.
    _FIXTURE_EXTRAS=()
    if [[ -n "$fixture" ]]; then
        _fixture_extras "$fixture" || return 1
    fi

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

    $use_marker && ( sleep 1; _write_scriptor_marker "$app_id" ) >/dev/null 2>&1 &

    local results
    results=$(mktemp)
    _debug_follow "$app_id" "$pid" "$cat_filter" "$level_filter" "$script_names" "$timeout" "$results" "$logcat_pid" < "$fifo"
    kill "$logcat_pid" 2>/dev/null || true
    { wait "$logcat_pid"; } 2>/dev/null || true
    rm -f "$fifo"

    local code=0
    _debug_outcome "$script_names" "$timeout" "$results" || code=$?
    rm -f "$results"
    return "$code"
}

# Reads logcat -v time lines from stdin and shows the app's own, filtered by
# --cat and --level, keeping the script lines in the results file. Stops on
# DEBUG_SESSION_ENDED, when the launched process is gone, when the stream
# ends, without a [scriptor] line in DEBUG_RUNNER_WAIT seconds of a scripted
# run, or at the timeout. Sets _DEBUG_OUTCOME: ended, stopped, no-runner or
# timeout. Without a stream pid (recorded lines), the end of input ends it.
_debug_follow() {
    local app_id="$1" pid="$2" cat_filter="$3" level_filter="$4" script_names="$5" timeout="$6" results="$7" stream_pid="${8:-}"
    local started=$SECONDS heard_runner=false line formatted
    _DEBUG_OUTCOME="stopped"
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
            $own && _note_script_line "$line" "$results" _logcat_format_own
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
                _DEBUG_OUTCOME="ended"
                break
            fi
        else
            # bash 3.2 returns 1 both at a timeout and at the end of input.
            if [[ -z "$stream_pid" ]] || ! kill -0 "$stream_pid" 2>/dev/null; then
                break
            fi
            if [[ -n "$pid" ]] && [[ "$(_app_pid "$app_id")" != "$pid" ]]; then
                break
            fi
        fi
        if [[ -n "$script_names" ]] && ! $heard_runner && (( SECONDS - started >= DEBUG_RUNNER_WAIT )); then
            _DEBUG_OUTCOME="no-runner"
            break
        fi
        if [[ -n "$timeout" ]] && (( SECONDS - started >= timeout )); then
            _DEBUG_OUTCOME="timeout"
            break
        fi
    done
    return 0
}

_logcat_format_own() {
    _logcat_format "$ANDROID_LOG_TAG"
}

# Prints how the session ended and, for a script run, each script's result
# and the failed checks. Fails when a check failed, the app stopped before
# its scripts ended, no runner answered, or the run timed out.
_debug_outcome() {
    local script_names="$1" timeout="$2" results="$3"
    echo ""
    case "$_DEBUG_OUTCOME" in
        no-runner)
            echo "✗ No [scriptor] line in ${DEBUG_RUNNER_WAIT}s: this build has no script runner, or it did not start."
            return 1
            ;;
        timeout)
            echo "✗ Session timed out after ${timeout}s without DEBUG_SESSION_ENDED."
            # What the scripts reported before the time ran out.
            grep -E "SCRIPT_RESULT|CHECK_FAILED" "$results" | sed -E 's/.*(SCRIPT_RESULT|CHECK_FAILED) /  /' || true
            return 1
            ;;
        ended) echo "✓ App backgrounded, session ended." ;;
        *) echo "✓ App stopped, session ended." ;;
    esac
    if [[ -n "$script_names" ]]; then
        _script_summary "$results" || return 1
    fi
    return 0
}

# signin|signout [emulator|device|<serial|avd name>] [email code]: runs the
# project's sign_in or sign_out debug script without rebuilding. Another
# account than build.properties.local's comes as <email> <code>.
_sign_in_or_out() {
    local script="$1" target="emulator"
    shift
    if [[ $# -gt 0 && "$1" != *@* ]]; then
        target="$1"
        shift
    fi
    if [[ "$script" == "sign_in" && $# -ge 2 ]]; then
        _SIGNIN_EMAIL="$1"
        _SIGNIN_CODE="$2"
    fi
    _android_debug "$target" --no-build --script "$script"
}
