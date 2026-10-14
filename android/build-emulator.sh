#!/bin/bash
# android-toolkit/build-emulator.sh — starting and stopping the emulator
# Sourced by build.sh.

_emulator_usage() {
    cat <<'EOF'
Usage: ./build.sh android emulator <command>

  start [--window]     Boot the configured AVD (ANDROID_EMULATOR_AVD in build.properties)
                       without a window, or with one, and wait until it has booted
  stop                 Shut down the running emulator
  status               Show the connected emulators and phones
EOF
}

_emulator_wait_for_boot() {
    local serial="$1" seconds=0
    while [[ $seconds -lt 240 ]]; do
        if [[ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
            return 0
        fi
        sleep 2
        seconds=$((seconds + 2))
    done
    return 1
}

do_emulator() {
    _require_adb || return 1
    case "${1:-}" in
        start)
            shift
            local window=false
            [[ "${1:-}" == "--window" ]] && window=true
            if [[ -z "$ANDROID_EMULATOR_AVD" ]]; then
                echo "✗ No AVD configured. Set ANDROID_EMULATOR_AVD in build.properties."
                return 1
            fi
            local running
            running=$(_connected_serials | grep '^emulator-' | head -1 || true)
            if [[ -n "$running" ]]; then
                echo "✓ Emulator already running ($running)"
                return 0
            fi
            local flags=(-avd "$ANDROID_EMULATOR_AVD" -no-snapshot-save -no-audio -no-boot-anim)
            if $window; then
                flags+=(-gpu host)
            else
                flags+=(-no-window -gpu swiftshader_indirect)
            fi
            local log_dir="${PROJECT_ROOT}/build/emulator"
            mkdir -p "$log_dir"
            echo "→ Booting $ANDROID_EMULATOR_AVD"
            nohup "$EMULATOR_BIN" "${flags[@]}" > "$log_dir/emulator.log" 2>&1 &
            "$ADB" wait-for-device
            local serial
            serial=$(_connected_serials | grep '^emulator-' | head -1 || true)
            if [[ -z "$serial" ]] || ! _emulator_wait_for_boot "$serial"; then
                echo "✗ The emulator did not finish booting. Log: $log_dir/emulator.log"
                return 1
            fi
            echo "✓ Emulator booted ($serial)"
            ;;
        stop)
            local serial
            serial=$(_connected_serials | grep '^emulator-' | head -1 || true)
            if [[ -z "$serial" ]]; then
                echo "✓ No emulator running"
                return 0
            fi
            "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
            echo "✓ Emulator stopped ($serial)"
            ;;
        status)
            local serials
            serials=$(_connected_serials)
            if [[ -z "$serials" ]]; then
                echo "No emulator or phone connected."
                return 0
            fi
            local serial
            while read -r serial; do
                SERIAL="$serial"
                echo "$(_target_label)"
            done <<<"$serials"
            ;;
        *)
            _emulator_usage
            ;;
    esac
}
