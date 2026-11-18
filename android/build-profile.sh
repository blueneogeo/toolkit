#!/bin/bash
# android-toolkit/build-profile.sh: Perfetto traces and Macrobenchmarks
# Sourced by build.sh.
#
#   ./build.sh android profile [target] [--script <names>] [--seconds N]
#                              [--render] [--name <label>] [--gfxinfo]
#                              [--callers <function>] [--trace <file>]
#                              [--main] [--until <seconds>] [--fixture [slot]]
#
# Records a Perfetto trace of the installed app on the emulator or a phone,
# then prints a summary: the frame lines a debug script's FrameMonitor marked,
# the heaviest functions by their own time, and the app's own heaviest code.
# With --script the app is launched with those debug scripts running at once,
# so a scripted interaction is measured end to end. The trace is kept in
# build/traces/ to open in ui.perfetto.dev. --callers lists what was on the
# stack whenever the named function ran; --trace reads a trace already
# recorded instead of a new one. --main keeps only the main thread and adds its
# busy time per quarter second; --until keeps only the first seconds of the
# trace (a launch). The summary runs trace_processor_shell on the device, the
# one androidx.benchmark ships, so --trace needs a device too. A minified
# build's names are read back through R8's mapping.txt.
#
#   ./build.sh android benchmark [target] [Class[#method]] [--build-only] [--fixture [slot]]
#
# Runs the Macrobenchmarks of the benchmark module against the profile build.
#
# Provides: do_profile, do_benchmark
# Depends on: _use_target, _app_id, _app_installed, _am_start, _find_apk,
#             _install_app, _reverse_server_port, _device_quote (build-lifecycle.sh)
# Depends on: _script_extras, _fixture_extras, _granted_runtime_permissions,
#             _debuggable_config (build-debug.sh), _lock_take (build-lock.sh)
# Depends on: _gradle_require, _gradle_run, _gradle_log, _gradle_failure (build-gradle.sh)

PROFILE_DEVICE_DIR=/data/local/tmp
PROFILE_TRACE_DIR=/data/misc/perfetto-traces
PROFILE_SAMPLE_HZ="${PROFILE_SAMPLE_HZ:-1000}"
BENCHMARK_MODULE="${BENCHMARK_MODULE:-benchmark}"

_profile_usage() {
    cat <<'EOF'
Usage: ./build.sh android profile [target] [--script <names>] [--seconds N] [--render]
                                  [--name <label>] [--gfxinfo] [--main] [--until <seconds>]
                                  [--callers <function>] [--trace <file>] [--fixture [slot]]

  Records a Perfetto trace of the installed app for N seconds (default 40) and
  prints the FrameMonitor lines, CPU time per thread, the heaviest functions
  and the app's own code. The trace stays in build/traces/.

    --script <names>   launch with these debug scripts running at once
    --fixture [slot]   seed that launch with a fresh session of the fixture slot
    --render           add the frame timeline: frame times and missed deadlines
    --gfxinfo          add the frame counts of dumpsys gfxinfo after the run
    --main             only the main thread, with its busy time per quarter second
    --until <seconds>  only the first seconds of the trace (a launch)
    --callers <fn>     what was on the stack whenever a function matching fn ran
    --trace <file>     summarise a recorded .pftrace again, without recording
    --name <label>     the trace file's name (default profile)

  Callstacks need a profile build (--config profile) or a debug build, and start
  once the launched app runs under its own name, about a second in. Build it
  first; profile installs only when the built APK differs from the installed
  one. For a first launch after an install:
    ./build.sh android --config profile install --no-launch
    ./build.sh android --config profile profile --until 5

  The summary runs trace_processor_shell on the device, from androidx.benchmark's
  benchmark-common in the Gradle cache (ANDROID_TRACE_PROCESSOR sets another).
EOF
}

do_profile() {
    local target="" seconds=40 scripts="" name="profile" render=false callers="" existing="" main=false until="" gfxinfo=false fixture=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --callers|--trace|--seconds|--script|--name|--until|--template)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --callers) callers="$2" ;;
                    --trace) existing="$2" ;;
                    --seconds) seconds="$2" ;;
                    --script) scripts="$2" ;;
                    --name) name="$2" ;;
                    --until) until="$2" ;;
                    --template) echo "⚠ --template is for Instruments; Perfetto records one config." ;;
                esac
                shift 2
                ;;
            --fixture)
                fixture="${AGENT_SLOT:-1}"
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    fixture="$2"
                    shift
                fi
                shift
                ;;
            --render) render=true; shift ;;
            --main) main=true; shift ;;
            --gfxinfo) gfxinfo=true; shift ;;
            --help|-h) _profile_usage; return 0 ;;
            -*) echo "✗ Unknown flag: $1"; _profile_usage; return 1 ;;
            *)
                if [[ -n "$target" ]]; then
                    echo "✗ Two targets: $target and $1"
                    return 1
                fi
                target="$1"
                shift
                ;;
        esac
    done
    if ! [[ "$seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "✗ --seconds takes a whole number of seconds."
        return 1
    fi
    if [[ -n "$until" && ! "$until" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "✗ --until takes seconds, like 5 or 2.5."
        return 1
    fi
    if [[ -n "$scripts" ]]; then
        if [[ "${TOOLKIT_DEBUG_SCRIPTS:-false}" != "true" ]]; then
            echo "⚠ --script ignored: set TOOLKIT_DEBUG_SCRIPTS=true in build.properties to enable debug scripts."
            scripts=""
        else
            scripts=$(_sanitize_script_names "$scripts") || { echo "$scripts"; return 1; }
        fi
    fi

    if [[ -n "$existing" ]]; then
        [[ -f "$existing" ]] || { echo "✗ No trace at $existing"; return 1; }
        [[ -n "$fixture$scripts" ]] && echo "⚠ --trace reads a recorded trace; --script and --fixture are ignored."
        _lock_take emulator || return 1
        _select_android_target "$target" || return 1
        local app_id
        app_id=$(_app_id) || return 1
        local device_trace="$PROFILE_DEVICE_DIR/turn-profile-reread.pftrace"
        "$ADB" -s "$SERIAL" push "$existing" "$device_trace" >/dev/null || { echo "✗ Could not copy the trace to $(_target_label)."; return 1; }
        local code=0
        _profile_summary "$device_trace" "$app_id" "$callers" "$main" "$until" "$render" || code=$?
        "$ADB" -s "$SERIAL" shell rm -f "$device_trace" >/dev/null 2>&1 || true
        return "$code"
    fi

    _lock_take emulator || return 1
    _use_target "$target" || return 1
    "$ADB" -s "$SERIAL" wait-for-device
    local app_id
    app_id=$(_app_id) || return 1
    _profile_install_if_changed "$app_id" || return 1
    _reverse_server_port

    _FIXTURE_EXTRAS=()
    if [[ -n "$fixture" ]]; then
        _profile_fresh_data "$app_id" || return 1
        _fixture_extras "$fixture" || return 1
    fi
    _SCRIPT_EXTRAS=()
    [[ -n "$scripts" ]] && _script_extras "$scripts" true

    local dir="$PROJECT_ROOT/build/traces" stamp
    mkdir -p "$dir"
    stamp=$(date +%Y%m%d-%H%M%S)
    local trace="$dir/${name}_${stamp}.pftrace"
    # Perfetto writes only into its own folder, and the shell can't create files there.
    local device_trace="$PROFILE_DEVICE_DIR/turn-${name}_${stamp}.pftrace"

    echo "→ Profiling $app_id on $(_target_label) for ${seconds}s (Perfetto, $(_build_config) build)"
    [[ -n "$scripts" ]] && echo "  running debug script(s): $scripts"
    $gfxinfo && "$ADB" -s "$SERIAL" shell dumpsys gfxinfo "$app_id" reset >/dev/null 2>&1

    # The main session runs from before the launch. traced_perf decides once per
    # process, at its first sample, whether to unwind it, and a launching app
    # still has the zygote's name then, so the callstack samples are a second
    # session started once the app has its own name. The two files are joined.
    local main_pid sampling_pid="" main_part="$PROFILE_TRACE_DIR/turn-${name}_${stamp}.main" sampling_part="$PROFILE_TRACE_DIR/turn-${name}_${stamp}.samples"
    main_pid=$(_profile_start "$main_part" < <(_profile_config "$app_id" "$seconds")) || return 1
    local started=$SECONDS launch_log
    launch_log=$(mktemp)
    _am_start "$app_id" ${_SCRIPT_EXTRAS[@]+"${_SCRIPT_EXTRAS[@]}"} ${_FIXTURE_EXTRAS[@]+"${_FIXTURE_EXTRAS[@]}"} > "$launch_log" 2>&1 &
    local launch_job=$!
    if _profile_wait_for_name "$app_id"; then
        local left=$(( seconds - (SECONDS - started) ))
        (( left < 1 )) && left=1
        sampling_pid=$(_profile_start "$sampling_part" < <(_profile_sampling_config "$app_id" "$left")) || sampling_pid=""
    fi
    local launched=0
    wait "$launch_job" || launched=$?
    cat "$launch_log"
    rm -f "$launch_log"
    [[ $launched -ne 0 ]] && echo "  Waiting for the trace to end before removing it."
    _profile_wait_for "$main_pid" "$seconds"
    [[ -n "$sampling_pid" ]] && _profile_wait_for "$sampling_pid" "$seconds"
    local parts="$main_part"
    [[ -n "$sampling_pid" ]] && parts+=" $sampling_part"
    "$ADB" -s "$SERIAL" shell "cat $parts > $device_trace; rm -f $main_part $sampling_part" >/dev/null 2>&1 || true
    if [[ $launched -ne 0 ]]; then
        "$ADB" -s "$SERIAL" shell rm -f "$device_trace" >/dev/null 2>&1 || true
        return 1
    fi

    if ! "$ADB" -s "$SERIAL" pull "$device_trace" "$trace" >/dev/null 2>&1 || [[ ! -s "$trace" ]]; then
        echo "✗ Recording failed: no trace at $device_trace on $(_target_label) after ${_PROFILE_WAITED}s."
        "$ADB" -s "$SERIAL" shell rm -f "$device_trace" >/dev/null 2>&1 || true
        return 1
    fi
    echo "✓ Trace saved: $trace"
    [[ -z "$sampling_pid" ]] && echo "⚠ No callstack samples: $app_id never ran under its own name."

    if $gfxinfo; then
        echo ""
        echo "Frames (dumpsys gfxinfo):"
        "$ADB" -s "$SERIAL" shell dumpsys gfxinfo "$app_id" 2>/dev/null | tr -d '\r' \
            | grep -E '^(Total frames rendered|Janky frames|[0-9]+th percentile|Number [A-Za-z ]+):' | sed 's/^/  /'
    fi

    local code=0
    _profile_summary "$device_trace" "$app_id" "$callers" "$main" "$until" "$render" || code=$?
    "$ADB" -s "$SERIAL" shell rm -f "$device_trace" >/dev/null 2>&1 || true
    return "$code"
}

# Starts a Perfetto session in the background with the config on stdin and
# prints its pid once its data sources run.
_profile_start() {
    local output="$1" out pid
    out=$("$ADB" -s "$SERIAL" shell perfetto --txt -c - -o "$output" --background-wait 2>&1 | tr -d '\r')
    pid=$(grep -Eo '^[0-9]+$' <<<"$out" | tail -1 || true)
    if [[ -z "$pid" ]]; then
        echo "✗ Perfetto did not start:" >&2
        sed 's/^/  /' <<<"$out" | tail -10 >&2
        return 1
    fi
    echo "$pid"
}

# Waits up to 10 seconds for the app's process to carry its own name.
_profile_wait_for_name() {
    local app_id="$1" tries=0 pid cmdline
    while (( tries < 100 )); do
        pid=$("$ADB" -s "$SERIAL" shell pidof "$app_id" 2>/dev/null | tr -d '\r' | awk '{ print $1 }' || true)
        if [[ -n "$pid" ]]; then
            cmdline=$("$ADB" -s "$SERIAL" shell cat "/proc/$pid/cmdline" 2>/dev/null | tr -d '\0\r' || true)
            [[ "$cmdline" == "$app_id" ]] && return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# Waits for Perfetto to stop itself after the duration and write the file.
# The shell can't signal the traced process, so /proc tells whether it runs.
_profile_wait_for() {
    local pid="$1" seconds="$2"
    _PROFILE_WAITED=0
    while "$ADB" -s "$SERIAL" shell "test -d /proc/$pid" >/dev/null 2>&1; do
        sleep 1
        _PROFILE_WAITED=$((_PROFILE_WAITED + 1))
        if (( _PROFILE_WAITED > seconds + 60 )); then
            echo "⚠ Perfetto is still running $((_PROFILE_WAITED - seconds))s after the time limit."
            break
        fi
    done
}

# Installs the built APK when it differs from the installed one. An unchanged
# app keeps how it was compiled, so a launch after install --no-launch stays
# the first after an install.
_profile_install_if_changed() {
    local app_id="$1" apk installed host_sum device_sum
    apk=$(_find_apk)
    if [[ -z "$apk" ]]; then
        if _app_installed "$app_id"; then
            echo "⚠ No $(_build_config) APK built here; profiling the installed $app_id."
            return 0
        fi
        echo "✗ $app_id is not installed and no $(_build_config) APK is built. Run: ./build.sh android --config $(_build_config) install --no-launch"
        return 1
    fi
    installed=$("$ADB" -s "$SERIAL" shell pm path "$app_id" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | grep 'base.apk$' | head -1 || true)
    if [[ -n "$installed" ]]; then
        host_sum=$(md5 -q "$apk" 2>/dev/null || md5sum "$apk" | awk '{ print $1 }')
        device_sum=$("$ADB" -s "$SERIAL" shell md5sum "$installed" 2>/dev/null | awk '{ print $1 }' | tr -d '\r')
        [[ -n "$host_sum" && "$host_sum" == "$device_sum" ]] && return 0
    fi
    _install_app
}

# A fixture session in a build that run-as can't read: the app's data is
# cleared first, so no other account's keys stay behind. The permissions it
# had are granted again.
_profile_fresh_data() {
    local app_id="$1" granted permission
    _debuggable_config && return 0
    _app_installed "$app_id" || return 0
    echo "→ Clearing the app's data for the fixture session ($(_build_config) builds can't be read with run-as)"
    granted=$(_granted_runtime_permissions "$app_id")
    if ! "$ADB" -s "$SERIAL" shell pm clear "$app_id" 2>/dev/null | tr -d '\r' | grep -q Success; then
        echo "⚠ pm clear failed; the app keeps its data."
        return 0
    fi
    for permission in $granted; do
        "$ADB" -s "$SERIAL" shell pm grant "$app_id" "$permission" >/dev/null 2>&1 || true
    done
}

# The main session: scheduling, the app's trace sections and counters, the
# frame timeline and the app's log lines.
_profile_config() {
    local app_id="$1" seconds="$2"
    cat <<EOF
buffers { size_kb: 65536 fill_policy: DISCARD }
buffers { size_kb: 8192 fill_policy: DISCARD }
duration_ms: $((seconds * 1000))
data_sources {
  config {
    name: "linux.ftrace"
    target_buffer: 0
    ftrace_config {
      ftrace_events: "sched/sched_switch"
      ftrace_events: "sched/sched_waking"
      ftrace_events: "power/cpu_frequency"
      ftrace_events: "ftrace/print"
      ftrace_events: "task/task_newtask"
      ftrace_events: "task/task_rename"
      atrace_categories: "gfx"
      atrace_categories: "view"
      atrace_categories: "input"
      atrace_categories: "am"
      atrace_categories: "wm"
      atrace_categories: "dalvik"
      atrace_apps: "$app_id"
      compact_sched { enabled: true }
    }
  }
}
data_sources {
  config {
    name: "linux.process_stats"
    target_buffer: 1
    process_stats_config { scan_all_processes_on_start: true }
  }
}
data_sources { config { name: "android.surfaceflinger.frametimeline" target_buffer: 1 } }
data_sources {
  config {
    name: "android.log"
    target_buffer: 1
    android_log_config { filter_tags: "$ANDROID_LOG_TAG" }
  }
}
EOF
}

# The sampling session: the app's callstacks, PROFILE_SAMPLE_HZ times a second.
_profile_sampling_config() {
    local app_id="$1" seconds="$2"
    cat <<EOF
buffers { size_kb: 32768 fill_policy: DISCARD }
duration_ms: $((seconds * 1000))
data_sources {
  config {
    name: "linux.perf"
    perf_event_config {
      timebase { frequency: $PROFILE_SAMPLE_HZ counter: SW_CPU_CLOCK timestamp_clock: PERF_CLOCK_MONOTONIC }
      callstack_sampling { scope { target_cmdline: "$app_id" } }
      ring_buffer_pages: 1024
      ring_buffer_read_period_ms: 100
    }
  }
}
EOF
}

# The device's trace_processor_shell: ANDROID_TRACE_PROCESSOR, else the one in
# the newest androidx.benchmark benchmark-common in the Gradle cache. Copied to
# the device once per change. Sets _TRACE_PROCESSOR to its path there.
_profile_trace_processor() {
    local abi asset host="${ANDROID_TRACE_PROCESSOR:-}"
    abi=$("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
    case "$abi" in
        arm64-v8a) asset=trace_processor_shell_aarch64 ;;
        armeabi-v7a) asset=trace_processor_shell_arm ;;
        x86_64) asset=trace_processor_shell_x86_64 ;;
        x86) asset=trace_processor_shell_x86 ;;
        *) echo "✗ No trace_processor_shell for the device's ABI '$abi'."; return 1 ;;
    esac
    local cache="$PROJECT_ROOT/build/traces/.tools"
    if [[ -z "$host" ]]; then
        local aar
        aar=$(find "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/androidx.benchmark/benchmark-common" -name 'benchmark-common-*.aar' 2>/dev/null \
            | awk -F/ '{ print $(NF-2) "\t" $0 }' | sort -V | tail -1 | cut -f2)
        if [[ -z "$aar" ]]; then
            echo "✗ No trace_processor_shell: androidx.benchmark isn't in the Gradle cache. Run: ./build.sh android benchmark --build-only"
            return 1
        fi
        host="$cache/$(basename "$aar" .aar)/$asset"
        if [[ ! -s "$host" ]]; then
            mkdir -p "$(dirname "$host")"
            unzip -o -q -j "$aar" "assets/$asset" -d "$(dirname "$host")" || { echo "✗ Could not unpack $asset from $aar"; return 1; }
        fi
    fi
    [[ -s "$host" ]] || { echo "✗ No trace_processor_shell at $host"; return 1; }
    _TRACE_PROCESSOR="$PROFILE_DEVICE_DIR/trace_processor_shell"
    local host_sum device_sum
    host_sum=$(md5 -q "$host" 2>/dev/null || md5sum "$host" | awk '{ print $1 }')
    device_sum=$("$ADB" -s "$SERIAL" shell md5sum "$_TRACE_PROCESSOR" 2>/dev/null | awk '{ print $1 }' | tr -d '\r')
    if [[ "$host_sum" != "$device_sum" ]]; then
        "$ADB" -s "$SERIAL" push "$host" "$_TRACE_PROCESSOR" >/dev/null && "$ADB" -s "$SERIAL" shell chmod 755 "$_TRACE_PROCESSOR" \
            || { echo "✗ Could not copy trace_processor_shell to $(_target_label)."; return 1; }
    fi
}

# Prints the frame lines, the main thread's quarter seconds, the heaviest
# functions and the app's hot code, from a trace on the device.
_profile_summary() {
    local device_trace="$1" app_id="$2" callers="${3:-}" main="${4:-false}" until="${5:-}" render="${6:-false}"
    _profile_trace_processor || return 1
    local args=(--adb "$ADB" --serial "$SERIAL" --tp "$_TRACE_PROCESSOR" --trace "$device_trace" --app "$app_id"
        --tag "$ANDROID_LOG_TAG" --work "$PROFILE_DEVICE_DIR")
    local code="${ANDROID_CODE_PACKAGE:-}" mapping
    if [[ -z "$code" ]]; then
        code="${ANDROID_APPLICATION_ID:-$app_id}"
        [[ -n "${DEV_APPLICATION_ID_SUFFIX:-}" ]] && code="${code%"$DEV_APPLICATION_ID_SUFFIX"}"
        code="${code%.dev}"
        code="${code%.debug}"
    fi
    args+=(--code "$code.")
    mapping="$PROJECT_ROOT/$ANDROID_MODULE/build/outputs/mapping/$(_build_config)/mapping.txt"
    [[ -f "$mapping" ]] && args+=(--mapping "$mapping")
    [[ -n "$callers" ]] && args+=(--callers "$callers")
    [[ -n "$until" ]] && args+=(--until "$until")
    [[ "$main" == true ]] && args+=(--main)
    [[ "$render" == true ]] && args+=(--render)
    local code=0
    python3 -I "$SCRIPT_DIR/profile_summary.py" "${args[@]}" || code=$?
    "$ADB" -s "$SERIAL" shell rm -f "$PROFILE_DEVICE_DIR/turn-profile-query.sql" >/dev/null 2>&1 || true
    return "$code"
}

# ── Benchmark ───────────────────────────────────────────────────────

_benchmark_usage() {
    cat <<'EOF'
Usage: ./build.sh android benchmark [target] [Class[#method]] [--build-only] [--fixture [slot]]

  Builds the app's profile build and the benchmark module, and runs the
  Macrobenchmarks on the emulator or a phone: StartupBenchmark (cold launch)
  and DeckSwipeBenchmark (deck_swipe_perf's frames). Without a class, all of
  them. --fixture hands the benchmarks a fresh session of the fixture slot.
  --build-only builds without a device (it also fills the Gradle cache with
  the trace_processor_shell that profile uses). Numbers from the emulator
  only show regressions; measure on a phone.
EOF
}

do_benchmark() {
    local target="" filter="" build_only=false fixture=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build-only) build_only=true; shift ;;
            --fixture)
                fixture="${AGENT_SLOT:-1}"
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    fixture="$2"
                    shift
                fi
                shift
                ;;
            --help|-h) _benchmark_usage; return 0 ;;
            -*) echo "✗ Unknown flag: $1"; _benchmark_usage; return 1 ;;
            *)
                if [[ -z "$target" ]] && _is_target_word "$1"; then
                    target="$1"
                elif [[ -z "$filter" ]]; then
                    filter="$1"
                else
                    echo "✗ Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done
    _gradle_require || return 1
    if [[ ! -f "$PROJECT_ROOT/$BENCHMARK_MODULE/build.gradle.kts" ]]; then
        echo "✗ No benchmark module at $BENCHMARK_MODULE/."
        return 1
    fi
    echo "→ Building the profile build and the benchmarks"
    if ! _gradle_run benchmark-build ":$ANDROID_MODULE:assembleProfile" ":$BENCHMARK_MODULE:assembleProfile"; then
        echo "✗ Build failed:"
        _gradle_failure "$(_gradle_log benchmark-build)"
        return 1
    fi
    echo "✓ Build complete"
    $build_only && return 0

    _lock_take emulator || return 1
    _use_target "$target" || return 1
    _reverse_server_port
    local args=()
    if [[ -n "$filter" ]]; then
        [[ "$filter" == *.* ]] || filter="com.sendaturn.benchmark.$filter"
        args+=("-Pandroid.testInstrumentationRunnerArguments.class=$filter")
    fi
    if [[ -n "$fixture" ]]; then
        _fixture_extras "$fixture" || return 1
        local i
        for ((i = 0; i < ${#_FIXTURE_EXTRAS[@]}; i += 3)); do
            case "${_FIXTURE_EXTRAS[i+1]}" in
                TURN_DEBUG_REFRESH_TOKEN) args+=("-Pandroid.testInstrumentationRunnerArguments.turnRefreshToken=${_FIXTURE_EXTRAS[i+2]}") ;;
                TURN_CLOCK) args+=("-Pandroid.testInstrumentationRunnerArguments.turnClock=${_FIXTURE_EXTRAS[i+2]}") ;;
            esac
        done
    fi
    # The emulator gives numbers only for regressions; androidx.benchmark refuses it unless told.
    _is_emulator_serial "$SERIAL" && args+=("-Pandroid.testInstrumentationRunnerArguments.androidx.benchmark.suppressErrors=EMULATOR")
    echo "→ Running the benchmarks on $(_target_label)"
    local code=0
    ANDROID_SERIAL="$SERIAL" _gradle_run benchmark ":$BENCHMARK_MODULE:connectedProfileAndroidTest" "${args[@]}" || code=$?
    local log
    log=$(_gradle_log benchmark)
    local json
    json=$(find "$PROJECT_ROOT/$BENCHMARK_MODULE/build/outputs/connected_android_test_additional_output" -name '*benchmarkData.json' -newer "$log" 2>/dev/null | head -1)
    if [[ -z "$json" ]]; then
        json=$(find "$PROJECT_ROOT/$BENCHMARK_MODULE/build/outputs/connected_android_test_additional_output" -name '*benchmarkData.json' -mmin -60 2>/dev/null | head -1)
    fi
    if [[ -n "$json" ]]; then
        JSON="$json" python3 -I -c '
import json, os
data = json.load(open(os.environ["JSON"]))
for bench in data.get("benchmarks", []):
    print("  %s.%s" % (bench.get("className", "").split(".")[-1], bench.get("name", "")))
    for name, m in sorted(bench.get("metrics", {}).items()):
        print("    %-26s median %8.1f, min %8.1f, max %8.1f" % (name, m["median"], m["minimum"], m["maximum"]))
    for name, m in sorted(bench.get("sampledMetrics", {}).items()):
        print("    %-26s P50 %8.1f, P90 %8.1f, P99 %8.1f" % (name, m["P50"], m["P90"], m["P99"]))
'
        echo "  Results: $json"
    fi
    if [[ $code -ne 0 ]]; then
        echo "✗ Benchmarks failed:"
        _gradle_failure "$log"
        return 1
    fi
    echo "✓ Benchmarks done"
}
