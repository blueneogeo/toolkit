#!/bin/bash
# android-toolkit/build-device.sh: picking the device, screenshots, see
# Sourced by build.sh. Sets SERIAL for the commands that follow.

_require_adb() {
    if [[ ! -x "$ADB" ]]; then
        echo "✗ adb not found at $ADB. Install the SDK's platform-tools, or set ANDROID_HOME."
        return 1
    fi
}

# Serials of connected devices in the "device" state, one per line.
_connected_serials() {
    "$ADB" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}

_is_emulator_serial() {
    [[ "$1" == emulator-* ]]
}

# Serials of running emulators whose AVD has this name.
_serials_of_avd() {
    local serial
    for serial in $(_connected_serials | grep '^emulator-' || true); do
        if [[ "$("$ADB" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')" == "$1" ]]; then
            echo "$serial"
        fi
    done
}

# True when the argument names something to capture from rather than a file name.
_is_target_word() {
    local word="$1"
    case "$word" in
        emulator|simulator|device|auto) return 0 ;;
    esac
    _connected_serials | grep -qxF "$word" || [[ -n "$(_serials_of_avd "$word")" ]]
}

# Resolves a target (emulator | device | <serial> | <avd name> | empty) to SERIAL.
# simulator means emulator, for scripts written for iOS.
# Empty: the selector if one is set, else the running emulator, else the one phone.
_select_android_target() {
    local target="${1:-}"
    _require_adb || return 1
    if [[ -z "$target" || "$target" == "auto" ]]; then
        target="${_DEVICE_SELECTOR:-}"
    fi
    local serials emulators phones
    serials=$(_connected_serials)
    emulators=$(grep '^emulator-' <<<"$serials" || true)
    phones=$(grep -v '^emulator-' <<<"$serials" || true)

    case "$target" in
        emulator|simulator)
            _pick_one "$emulators" "emulator" "Run: ./build.sh android emulator start" ;;
        device)
            _pick_one "$phones" "phone" "Connect a phone with USB debugging on." ;;
        "")
            if [[ -n "$emulators" ]]; then
                _pick_one "$emulators" "emulator" ""
            elif [[ -n "$phones" ]]; then
                _pick_one "$phones" "phone" ""
            else
                echo "✗ No emulator or phone connected. Run: ./build.sh android emulator start"
                return 1
            fi
            ;;
        *)
            local by_avd
            by_avd=$(_serials_of_avd "$target")
            if grep -qxF "$target" <<<"$serials"; then
                SERIAL="$target"
            elif [[ -n "$by_avd" ]]; then
                _pick_one "$by_avd" "emulator of $target" ""
            else
                echo "✗ No connected device or running AVD named '$target'. Connected:"
                "$ADB" devices | tail -n +2
                return 1
            fi
            ;;
    esac
}

# Picks the one serial in a list; refuses when there are none or several.
_pick_one() {
    local list="$1" kind="$2" hint="$3"
    local count
    count=$(grep -c . <<<"$list" || true)
    if [[ "$count" -eq 0 ]]; then
        echo "✗ No $kind connected.${hint:+ $hint}"
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        echo "✗ Several ${kind}s connected; pick one with --device <serial>:"
        echo "$list" | sed 's/^/    /'
        return 1
    fi
    SERIAL="$list"
}

_target_label() {
    if _is_emulator_serial "$SERIAL"; then
        local avd
        avd=$("$ADB" -s "$SERIAL" emu avd name 2>/dev/null | head -1 | tr -d '\r')
        echo "emulator${avd:+ $avd} ($SERIAL)"
    else
        local model
        model=$("$ADB" -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
        echo "${model:-phone} ($SERIAL)"
    fi
}

_capture_screenshot() {
    local out="$1"
    if ! "$ADB" -s "$SERIAL" exec-out screencap -p > "$out" 2>/dev/null || [[ ! -s "$out" ]]; then
        rm -f "$out"
        echo "✗ Screenshot failed on $SERIAL."
        return 1
    fi
}

do_screenshot() {
    local target="" name=""
    if [[ $# -gt 0 ]]; then
        if _is_target_word "$1"; then
            target="$1"
            name="${2:-}"
        else
            name="$1"
        fi
    fi
    _select_android_target "$target" || return 1
    local dir="${PROJECT_ROOT}/build/screenshots"
    mkdir -p "$dir"
    local file="turn_$(date +%Y%m%d-%H%M%S).png"
    name="${name//\//_}"
    [[ -n "$name" ]] && file="${name}.png"
    _capture_screenshot "$dir/$file" || return 1
    echo "✓ Screenshot saved from $(_target_label)"
    echo "$(cd "$dir" && pwd)/$file"
}

do_see() {
    local target=""
    if [[ $# -gt 0 && "$1" != -* ]]; then
        target="$1"
        shift
    fi
    local focus=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --focus) focus="${2:-}"; shift 2 ;;
            *) echo "✗ Unknown argument: $1" >&2; return 1 ;;
        esac
    done

    _select_android_target "$target" || return 1
    local dir="${PROJECT_ROOT}/build/screenshots"
    mkdir -p "$dir"
    local file="see_$(date +%Y%m%d-%H%M%S).png"
    _capture_screenshot "$dir/$file" || return 1
    local path
    path="$(cd "$dir" && pwd)/$file"
    echo "Screenshot: $path"
    echo "From: $(_target_label)"
    echo ""

    local prompt="$focus"
    if [[ -z "$prompt" ]]; then
        prompt="Describe what is currently on screen: what screen or feature is the app showing, and what are the main visible UI elements, from top to bottom?"
    fi

    if _do_vision "$path" --focus "$prompt"; then
        echo ""
        echo "─ For fine detail: ./build.sh android see --focus \"<focused question about a region or element>\""
    fi
}

# Copies the PNGs that debug scripts saved in the app's files/DebugScreenshots.
# Debuggable builds are read with run-as; others write to the app's external
# files folder, which adb can pull.
do_screenshots_collect() {
    [[ "${1:-}" == "collect" ]] && shift
    _lock_take emulator || return 1
    _select_android_target "${1:-}" || return 1
    local app_id
    app_id=$(_app_id) || return 1
    local dest="${PROJECT_ROOT}/build/screenshots" tmp
    mkdir -p "$dest"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/x"
    "$ADB" -s "$SERIAL" exec-out "run-as $app_id sh -c 'cd files/DebugScreenshots 2>/dev/null && tar -cf - *.png 2>/dev/null'" > "$tmp/shots.tar" 2>/dev/null || true
    if [[ -s "$tmp/shots.tar" ]]; then
        tar -xf "$tmp/shots.tar" -C "$tmp/x" 2>/dev/null || true
    else
        "$ADB" -s "$SERIAL" pull "/sdcard/Android/data/$app_id/files/DebugScreenshots" "$tmp/x" >/dev/null 2>&1 || true
    fi
    local count=0 p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        cp "$p" "$dest/"
        echo "$(cd "$dest" && pwd)/$(basename "$p")"
        count=$((count + 1))
    done < <(find "$tmp/x" -name '*.png' -type f | sort)
    rm -rf "$tmp"
    if [[ $count -eq 0 ]]; then
        echo "⚠ No scripted screenshots found in the app's files."
        return 0
    fi
    echo "✓ Collected $count screenshot(s)"
}
