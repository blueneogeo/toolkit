#!/bin/bash
# ── Record ──────────────────────────────────────────────────────────
#
#   ./build.sh ios record [simulator|<name|udid>] [name] [--seconds N]
#                         [--script <names>] [--frames <fps>]
#
# Records the booted simulator's screen to build/recordings/<name>.mp4.
# With --script the app is relaunched running those debug scripts, so a
# scripted interaction is filmed from its first frame. With --frames the
# video is also cut into still frames and contact sheets (8 x 6 frames
# each) that can be read like screenshots, to judge animations frame by
# frame. Simulator only: phones have no scriptable screen recorder.
#
# Provides: do_record
# Depends on: _check_core_tools, _booted_sim_id, _use_named_simulator,
#             _selector_matches_device, _set_mode_sim (sets BUNDLE_ID),
#             _sanitize_script_names (shared/scripts.sh),
#             _record_frames (shared/record-frames.sh)
# Depends on: _require_cmd (shared/build-utils.sh)

RECORD_DEFAULT_SECONDS=10

_record_usage() {
    cat <<'EOF'
Usage: ./build.sh ios record [simulator|<name|udid>] [name] [--seconds N]
                             [--script <names>] [--frames <fps>]

  Record the booted simulator's screen to ios/build/recordings/<name>.mp4
  (simulator only). The path of the video is printed last.

    [name]             File name without extension (default: rec_<timestamp>)
    --seconds N        Length of the recording (default: 10). Ctrl-C stops early
                       and keeps what was recorded.
    --script <names>   Relaunch the app running these debug scripts (comma-
                       separated) as the recording starts, without waiting for
                       the start-up marker. Needs a build with debug scripts.
    --frames <fps>     Also cut the video into frames at this rate, into
                       ios/build/recordings/<name>/frame_NNN.png, plus contact
                       sheets of 48 frames each (sheet_NN.png) to read at once.

Examples:
    ./build.sh ios record simulator lens_switch --seconds 6 --frames 10
    ./build.sh ios record deck_open --script deck_tour --seconds 20 --frames 5
EOF
}

do_record() {
    _check_core_tools
    local target="" name="" seconds="$RECORD_DEFAULT_SECONDS" scripts="" fps=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --seconds) seconds="${2:-}"; shift 2 ;;
            --script) scripts="${2:-}"; shift 2 ;;
            --frames) fps="${2:-}"; shift 2 ;;
            -h|--help|help) _record_usage; return 0 ;;
            -*) echo "✗ Unknown option: $1"; _record_usage; return 1 ;;
            *)
                if [[ -z "$target" && -z "$name" ]] && _record_is_target "$1"; then
                    target="$1"
                elif [[ -z "$name" ]]; then
                    name="$1"
                else
                    echo "✗ Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done
    if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [[ "$seconds" -lt 1 ]]; then
        echo "✗ --seconds needs a whole number of seconds"
        return 1
    fi
    if [[ -n "$fps" ]] && ! [[ "$fps" =~ ^[0-9]+$ && "$fps" -ge 1 ]]; then
        echo "✗ --frames needs a whole number of frames per second"
        return 1
    fi
    [[ -n "$fps" ]] && _require_cmd ffmpeg "Install with: brew install ffmpeg"

    local sim_id
    sim_id=$(_record_sim_id "$target") || return 1

    local dir="${PROJECT_ROOT}/build/recordings"
    mkdir -p "$dir"
    name="${name//\//_}"
    [[ -z "$name" ]] && name="rec_$(date +%Y%m%d-%H%M%S)"
    local video="$dir/$name.mp4"

    echo "→ Recording the simulator for ${seconds}s"
    xcrun simctl io "$sim_id" recordVideo --codec h264 --force "$video" >/dev/null 2>"$dir/.record.err" &
    local recorder=$!
    trap 'kill -INT "$recorder" 2>/dev/null' INT
    _record_wait_started "$dir/.record.err" "$recorder" || { trap - INT; return 1; }

    if [[ -n "$scripts" ]]; then
        _record_launch_scripts "$sim_id" "$scripts" || { kill -INT "$recorder" 2>/dev/null; wait "$recorder" 2>/dev/null; trap - INT; return 1; }
    fi

    local waited=0
    while [[ $waited -lt $seconds ]] && kill -0 "$recorder" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    kill -INT "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true
    trap - INT

    if [[ ! -s "$video" ]]; then
        echo "✗ Recording failed:"
        sed 's/^/  ↳ /' "$dir/.record.err"
        return 1
    fi
    rm -f "$dir/.record.err"

    [[ -n "$fps" ]] && { _record_frames "$video" "$dir/$name" "$fps" "$waited" || return 1; }
    echo "✓ Recorded ${waited}s"
    echo "$(cd "$dir" && pwd)/$name.mp4"
}

# A lone first argument is a target when it names the simulator, a simulator
# or a connected phone (phones are then refused with a clear message).
_record_is_target() {
    case "$1" in
        simulator|device|auto) return 0 ;;
    esac
    _use_named_simulator "$1" || _selector_matches_device "$1"
}

_record_sim_id() {
    local target="${1:-}"
    case "$target" in
        ""|simulator|auto)
            local booted
            booted=$(_booted_sim_id)
            if [[ -z "$booted" ]]; then
                echo "✗ No booted simulator. Run: ./build.sh ios install simulator" >&2
                return 1
            fi
            echo "$booted"
            ;;
        device)
            echo "✗ record works on the simulator only; phones have no scriptable screen recorder." >&2
            return 1
            ;;
        *)
            if _use_named_simulator "$target"; then
                echo "$SIM_ID"
            else
                echo "✗ record works on the simulator only; '$target' is a phone." >&2
                return 1
            fi
            ;;
    esac
}

# simctl prints "Recording started" once the first frame is captured.
_record_wait_started() {
    local log="$1" recorder="$2" ticks=0
    while [[ $ticks -lt 50 ]]; do
        grep -q "Recording started" "$log" 2>/dev/null && return 0
        if ! kill -0 "$recorder" 2>/dev/null; then
            echo "✗ The recorder stopped before it started:"
            sed 's/^/  ↳ /' "$log"
            return 1
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    return 0
}

_record_launch_scripts() {
    local sim_id="$1" names
    if ! names=$(_sanitize_script_names "$2"); then
        echo "$names"
        return 1
    fi
    _set_mode_sim
    local script_var
    for script_var in $(compgen -v SCRIPT_ENV_); do
        export "SIMCTL_CHILD_${script_var#SCRIPT_ENV_}=${!script_var}"
    done
    export SIMCTL_CHILD_TURN_DEBUG_SCRIPT_NAMES="$names" SIMCTL_CHILD_TURN_DEBUG_SCRIPT_NO_MARKER=1
    # A relaunched app can keep the environment of its first launch, so the
    # names also go in the launch file the app reads (as `ios debug` does),
    # and the start-up marker is put down at once.
    local data_dir config
    data_dir=$(xcrun simctl get_app_container "$sim_id" "$BUNDLE_ID" data 2>/dev/null || true)
    if [[ -n "$data_dir" ]]; then
        config=$(mktemp)
        _write_script_config "$config" "$names"
        mkdir -p "$data_dir/Library/Caches"
        mv "$config" "$data_dir/Library/Caches/scriptor-config.json"
        touch "$data_dir/Library/Caches/${DEBUG_MARKER_NAME:-scriptor-ready}"
    fi
    local extra=()
    read -r -a extra <<< "${IOS_LAUNCH_ARGS:-}"
    echo "  running debug script(s): $names"
    if ! xcrun simctl launch --terminate-running-process "$sim_id" "$BUNDLE_ID" ${extra[@]+"${extra[@]}"} > /dev/null; then
        echo "✗ Could not launch $BUNDLE_ID. Install it first: ./build.sh ios install simulator"
        return 1
    fi
}
