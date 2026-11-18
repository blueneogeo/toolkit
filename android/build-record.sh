#!/bin/bash
# ── Record ──────────────────────────────────────────────────────────
#
#   ./build.sh android record [target] [name] [--seconds N]
#                             [--script <names>] [--frames <fps>]
#                             [--fixture [slot]]
#
# Records the emulator's or phone's screen with screenrecord to
# build/recordings/<name>.mp4. With --script the app is relaunched running
# those debug scripts once the recording runs; --fixture seeds that launch
# with a fixture slot's session and clock, as debug does. With --frames the
# video is also cut into frames and contact sheets (8 x 6 frames each).
#
# Provides: do_record
# Depends on: _use_target, _target_label, _is_target_word, _app_id,
#             _app_installed, _am_start (build-device.sh, build-lifecycle.sh)
# Depends on: _script_extras, _fixture_extras (build-debug.sh),
#             _lock_take (build-lock.sh)
# Depends on: _sanitize_script_names (shared/scripts.sh),
#             _record_frames (shared/record-frames.sh)

RECORD_DEFAULT_SECONDS=10
RECORD_MAX_SECONDS=180
RECORD_DEVICE_FILE=/sdcard/toolkit_rec.mp4
RECORD_MAX_SIDE=1920

_record_usage() {
    cat <<'EOF'
Usage: ./build.sh android record [emulator|device|<serial>] [name] [--seconds N]
                                 [--script <names>] [--frames <fps>]
                                 [--fixture [slot]]

  Record the emulator's or phone's screen to build/recordings/<name>.mp4,
  at most 1920 pixels on the long side (884x1920 on Turn_Parity). The path
  of the video is printed last.

    [name]             File name without extension (default: rec_<timestamp>)
    --seconds N        Length of the recording (default: 10, at most 180, the
                       limit of Android's screenrecord). Ctrl-C stops early and
                       keeps what was recorded.
    --script <names>   Relaunch the app running these debug scripts (comma-
                       separated) as the recording starts, without waiting for
                       the start-up marker. Needs a build with debug scripts.
    --frames <fps>     Also cut the video into frames at this rate, into
                       build/recordings/<name>/frame_NNN.png, plus contact
                       sheets of 48 frames each (sheet_NN.png) to read at once.
    --fixture [slot]   With --script: seed the launch with a new session of the
                       fixture slot (default AGENT_SLOT, else 1) and its reset
                       instant as TURN_CLOCK, as debug --fixture does.

  ANDROID_LAUNCH_ARGS reaches the scripted launch too, for example
  "--es TURN_CLOCK 2026-11-17T23:47:43Z" for the clock of iOS's reference films.

Examples:
    ./build.sh android record emulator lens_switch --seconds 6 --frames 10
    ./build.sh android record deck_open --script deck_tour --seconds 20 --frames 5
    ./build.sh android record motion_deck --script motion_tour --fixture 8 --seconds 30
EOF
}

_record_device_size() {
    "$ADB" -s "$SERIAL" shell "stat -c %s $RECORD_DEVICE_FILE 2>/dev/null" | tr -d '\r' || true
}

# screenrecord prints nothing when it starts; it has started once its file has data.
_record_wait_started() {
    local recorder="$1" ticks=0 size
    while [[ $ticks -lt 50 ]]; do
        size=$(_record_device_size)
        [[ -n "$size" && "$size" -gt 0 ]] && return 0
        if ! kill -0 "$recorder" 2>/dev/null; then
            echo "✗ The recorder stopped before it started:"
            sed 's/^/  ↳ /' "$2"
            return 1
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    return 0
}

# The screen's size, scaled down to at most RECORD_MAX_SIDE on the long side:
# encoders refuse a full 1206x2622 screen, and screenrecord's own fallback
# (720x1280) squashes it.
_record_size() {
    "$ADB" -s "$SERIAL" shell wm size 2>/dev/null | tr -d '\r' | awk -F': ' -v max="$RECORD_MAX_SIDE" '
        /Physical size/ { physical = $2 }
        /Override size/ { override = $2 }
        END {
            size = override ? override : physical
            split(size, p, "x"); w = p[1]; h = p[2]
            long = w > h ? w : h
            if (long > max) { w = w * max / long; h = h * max / long }
            w = int(w / 2 + 0.5) * 2; h = int(h / 2 + 0.5) * 2
            printf "%dx%d", w, h
        }'
}

# Ctrl-C ends the recording early; screenrecord still finishes the file.
_record_interrupt() {
    _RECORD_INTERRUPTED=true
    _record_stop
}

_record_stop() {
    "$ADB" -s "$SERIAL" shell pkill -INT screenrecord >/dev/null 2>&1 || true
}

_record_launch_scripts() {
    local names
    if ! names=$(_sanitize_script_names "$1"); then
        echo "$names"
        return 1
    fi
    local app_id
    app_id=$(_app_id) || return 1
    if ! _app_installed "$app_id"; then
        echo "✗ $app_id is not installed. Install it first: ./build.sh android install emulator"
        return 1
    fi
    _reverse_server_port
    _script_extras "$names" true
    echo "  running debug script(s): $names"
    _am_start "$app_id" "${_SCRIPT_EXTRAS[@]}" ${_FIXTURE_EXTRAS[@]+"${_FIXTURE_EXTRAS[@]}"}
}

do_record() {
    local target="" name="" seconds="$RECORD_DEFAULT_SECONDS" scripts="" fps="" fixture=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --seconds | --script | --frames)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --seconds) seconds="$2" ;;
                    --script) scripts="$2" ;;
                    --frames) fps="$2" ;;
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
            -h|--help|help) _record_usage; return 0 ;;
            -*) echo "✗ Unknown option: $1"; _record_usage; return 1 ;;
            *)
                if [[ -z "$target" && -z "$name" ]] && _is_target_word "$1"; then
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
    if [[ "$seconds" -gt $RECORD_MAX_SECONDS ]]; then
        echo "✗ --seconds is at most $RECORD_MAX_SECONDS; Android's screenrecord stops there."
        return 1
    fi
    if [[ -n "$fps" ]] && ! [[ "$fps" =~ ^[0-9]+$ && "$fps" -ge 1 ]]; then
        echo "✗ --frames needs a whole number of frames per second"
        return 1
    fi
    [[ -n "$fps" ]] && _require_cmd ffmpeg "Install with: brew install ffmpeg"
    if [[ -n "$scripts" && "${TOOLKIT_DEBUG_SCRIPTS:-false}" != "true" ]]; then
        echo "⚠ --script ignored: set TOOLKIT_DEBUG_SCRIPTS=true in build.properties to enable debug scripts."
        scripts=""
    fi
    if [[ -n "$fixture" && -z "$scripts" ]]; then
        echo "✗ --fixture seeds the scripted launch; it needs --script."
        return 1
    fi

    _lock_take emulator || return 1
    _use_target "$target" || return 1

    # The session is fetched before the recording starts: it takes a few seconds.
    _FIXTURE_EXTRAS=()
    if [[ -n "$fixture" ]]; then
        _fixture_extras "$fixture" || return 1
    fi

    local dir="${PROJECT_ROOT}/build/recordings"
    mkdir -p "$dir"
    name="${name//\//_}"
    [[ -z "$name" ]] && name="rec_$(date +%Y%m%d-%H%M%S)"
    local video="$dir/$name.mp4"
    local kind="phone"
    _is_emulator_serial "$SERIAL" && kind="emulator"

    "$ADB" -s "$SERIAL" shell rm -f "$RECORD_DEVICE_FILE" >/dev/null 2>&1 || true
    echo "→ Recording the $kind for ${seconds}s"
    "$ADB" -s "$SERIAL" shell screenrecord --size "$(_record_size)" --time-limit "$seconds" --bit-rate 8000000 "$RECORD_DEVICE_FILE" >"$dir/.record.err" 2>&1 &
    local recorder=$!
    _RECORD_INTERRUPTED=false
    trap '_record_interrupt' INT
    _record_wait_started "$recorder" "$dir/.record.err" || { trap - INT; return 1; }

    if [[ -n "$scripts" ]]; then
        _record_launch_scripts "$scripts" || { _record_stop; wait "$recorder" 2>/dev/null; trap - INT; return 1; }
    fi

    local waited=0
    while [[ $waited -lt $((seconds + 5)) ]] && kill -0 "$recorder" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    kill -0 "$recorder" 2>/dev/null && _record_stop
    wait "$recorder" 2>/dev/null || true
    if [[ $waited -gt $seconds ]] || ! $_RECORD_INTERRUPTED; then
        waited=$seconds
    fi
    trap - INT

    rm -f "$video"
    "$ADB" -s "$SERIAL" pull "$RECORD_DEVICE_FILE" "$video" >/dev/null 2>>"$dir/.record.err" || true
    "$ADB" -s "$SERIAL" shell rm -f "$RECORD_DEVICE_FILE" >/dev/null 2>&1 || true
    if [[ ! -s "$video" ]]; then
        echo "✗ Recording failed:"
        sed 's/^/  ↳ /' "$dir/.record.err"
        return 1
    fi
    rm -f "$dir/.record.err"

    if [[ -n "$fps" ]]; then
        local steady="$dir/.${name}_cfr.mp4"
        if ! ffmpeg -y -loglevel error -i "$video" -vf "tpad=stop_mode=clone:stop_duration=${waited}" -r 30 -t "$waited" "$steady"; then
            echo "✗ Could not read $video"
            return 1
        fi
        _record_frames "$steady" "$dir/$name" "$fps" "$waited" || { rm -f "$steady"; return 1; }
        rm -f "$steady"
    fi
    echo "✓ Recorded ${waited}s from $(_target_label)"
    echo "$(cd "$dir" && pwd)/$name.mp4"
}
