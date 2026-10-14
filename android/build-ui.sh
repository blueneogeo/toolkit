#!/bin/bash
# android-toolkit/build-ui.sh: drive and read the screen, mirroring `ios ui`
# Sourced by build.sh. Coordinates are dp; adb takes pixels, so every
# number is scaled by the device's density (480 dpi is 3 px per dp).

_ui_usage() {
    cat <<'EOF'
Usage: ./build.sh android ui <command> [<args>]

  Drive and inspect the emulator's or phone's screen.
  Interactions auto-capture a screenshot afterwards; the path is printed last.

    tap <x> <y>        Tap at dp (402x874 on the Turn_Parity emulator)
    tap --id <id>      Tap the element with this test tag (resource id)
    tap --label <txt>  Tap the first element whose text or content description matches
    swipe <x1> <y1> <x2> <y2>
                       Drag from one point to another
    swipe <dir>        Full-screen swipe: up | down | left | right
    type <text>        Type into the currently focused field
    press <button>     Press a button: home | back | lock
    describe [name]    Print the view tree (class | label | id | frame in dp)
                       and save it to build/screenshots/<name>-ui.txt

Options:
    --no-shot          Skip the automatic screenshot after the action
    --delay <ms>       Settle time before the screenshot (default: 700)
    --device, -d <serial>
                       Target a specific device. Defaults to the running emulator.

Examples:
    ./build.sh android ui tap --id record-primary-button
    ./build.sh android ui swipe up                        # scroll the feed
    ./build.sh android ui type "Family calls"
    ./build.sh android ui describe feed

Compose test tags show up as ids only when the app sets
testTagsAsResourceId = true on its root.
EOF
}

# Pixels per dp, from the device's density (an override wins over the physical one).
_ui_scale() {
    "$ADB" -s "$SERIAL" shell wm density 2>/dev/null | tr -d '\r' | awk -F': ' '
        /Physical density/ { physical = $2 }
        /Override density/ { override = $2 }
        END { density = override ? override : physical; if (!density) exit 1; printf "%g", density / 160 }'
}

# Prints "W H" in dp.
_ui_screen_size() {
    local scale="$1"
    "$ADB" -s "$SERIAL" shell wm size 2>/dev/null | tr -d '\r' | awk -F': ' -v s="$scale" '
        /Physical size/ { physical = $2 }
        /Override size/ { override = $2 }
        END { size = override ? override : physical; if (!size) exit 1; split(size, p, "x"); printf "%d %d", p[1] / s + 0.5, p[2] / s + 0.5 }'
}

_ui_dump_xml() {
    "$ADB" -s "$SERIAL" exec-out uiautomator dump --compressed /dev/tty 2>/dev/null | sed 's/UI hierchary dumped to.*//'
}

# Formats the uiautomator XML as one line per node, frames in dp.
_ui_tree_format() {
    SCALE="$1" python3 -c '
import os, re, sys
import xml.etree.ElementTree as ET

scale = float(os.environ["SCALE"])
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(1)
lines = []

def frame(node):
    m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", node.get("bounds", ""))
    if not m:
        return "x=0 y=0 w=0 h=0"
    x1, y1, x2, y2 = (int(v) / scale for v in m.groups())
    return "x={:g} y={:g} w={:g} h={:g}".format(round(x1, 1), round(y1, 1), round(x2 - x1, 1), round(y2 - y1, 1))

def walk(node, depth):
    if node.tag == "node":
        parts = [node.get("class", "").split(".")[-1]]
        label = node.get("text") or node.get("content-desc") or ""
        if label:
            parts.append(repr(label))
        ident = (node.get("resource-id") or "").split(":id/")[-1]
        if ident:
            parts.append("id=" + ident)
        parts.append(frame(node))
        lines.append("  " * depth + " | ".join(parts))
        depth += 1
    for child in node:
        walk(child, depth)

walk(root, 0)
print("\n".join(lines))
'
}

# Prints "cx cy" in dp for the element matching --id/--label; exits 3 when not found.
_ui_find_element() {
    local mode="$1" value="$2" scale="$3"
    _ui_dump_xml | MODE="$mode" VALUE="$value" SCALE="$scale" python3 -c '
import os, re, sys
import xml.etree.ElementTree as ET

mode, value, scale = os.environ["MODE"], os.environ["VALUE"], float(os.environ["SCALE"])
root = ET.fromstring(sys.stdin.read())
exact, fuzzy = [], []
for node in root.iter("node"):
    if mode == "id":
        if (node.get("resource-id") or "").split(":id/")[-1] == value:
            exact.append(node)
    else:
        for label in (node.get("text") or "", node.get("content-desc") or ""):
            if label.lower() == value.lower():
                exact.append(node)
                break
            if label and value.lower() in label.lower():
                fuzzy.append(node)
                break
matches = exact or fuzzy
if not matches:
    sys.exit(3)
if len(matches) > 1:
    print("⚠ %d elements match; using the first" % len(matches), file=sys.stderr)
x1, y1, x2, y2 = (int(v) for v in re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", matches[0].get("bounds")).groups())
print("%g %g" % ((x1 + x2) / 2 / scale, (y1 + y2) / 2 / scale))
'
}

_ui_px() {
    awk -v v="$1" -v s="$2" 'BEGIN { printf "%d", v * s + 0.5 }'
}

_ui_is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

_ui_shot() {
    local verb="$1"
    local dir="${PROJECT_ROOT}/build/screenshots"
    mkdir -p "$dir"
    local file="ui_${verb}_$(date +%H%M%S).png"
    _capture_screenshot "$dir/$file" || return 1
    echo "$(cd "$dir" && pwd)/$file"
}

# `input text` treats spaces and shell characters specially: spaces become %s,
# everything else is escaped for the device shell.
_ui_input_text() {
    local text="$1" escaped
    escaped=$(TEXT="$text" python3 -c '
import os, re
text = os.environ["TEXT"].replace(" ", "%s")
print(re.sub(r"([\\\x27\"`$&|;<>()*?~#!\[\]{}])", r"\\\1", text))
')
    "$ADB" -s "$SERIAL" shell input text "$escaped"
}

do_ui() {
    if [[ -z "${1:-}" || "${1:-}" == "help" || "${1:-}" == "--help" ]]; then
        _ui_usage
        return 0
    fi

    local sub="$1"
    shift
    case "$sub" in
        tap|swipe|type|press|describe) ;;
        *)
            echo "✗ Unknown ui command: $sub"
            echo ""
            _ui_usage
            return 1
            ;;
    esac

    local no_shot=false delay_ms=700
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-shot)
                no_shot=true
                shift
                ;;
            --delay)
                if [[ -z "${2:-}" ]]; then
                    echo "✗ --delay requires milliseconds"
                    return 1
                fi
                delay_ms="$2"
                shift 2
                ;;
            --delay=*)
                delay_ms="${1#*=}"
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    _select_android_target "" || return 1
    local scale
    scale=$(_ui_scale) || {
        echo "✗ Could not read the screen density of $SERIAL."
        return 1
    }

    if [[ "$sub" == "describe" ]]; then
        local name="${args[0]:-describe}"
        name="${name//\//_}"
        local text
        text=$(_ui_dump_xml | _ui_tree_format "$scale") || text=""
        if [[ -z "$text" ]]; then
            echo "✗ Could not read the view tree."
            return 1
        fi
        echo "$text"
        local dir="${PROJECT_ROOT}/build/screenshots"
        mkdir -p "$dir"
        printf '%s\n' "$text" > "${dir}/${name}-ui.txt"
        echo "✓ Tree saved"
        echo "$(cd "$dir" && pwd)/${name}-ui.txt"
        return 0
    fi

    local size w h
    size=$(_ui_screen_size "$scale") || {
        echo "✗ Could not read the screen size of $SERIAL."
        return 1
    }
    read -r w h <<<"$size"

    local x1="" y1="" x2="" y2=""
    case "$sub" in
        tap)
            if [[ "${args[0]:-}" == "--id" || "${args[0]:-}" == "--label" ]]; then
                local mode="${args[0]#--}"
                local value="${args[1]:-}"
                if [[ -z "$value" ]]; then
                    echo "✗ tap $mode requires a value"
                    return 1
                fi
                local center
                center=$(_ui_find_element "$mode" "$value" "$scale") || {
                    echo "✗ No element with $mode '$value' on screen."
                    return 1
                }
                read -r x1 y1 <<<"$center"
            else
                if [[ ${#args[@]} -ne 2 ]] || ! _ui_is_number "${args[0]:-}" || ! _ui_is_number "${args[1]:-}"; then
                    echo "✗ tap expects <x> <y> or --id <id> / --label <text>"
                    return 1
                fi
                x1="${args[0]}"
                y1="${args[1]}"
            fi
            if awk -v x="$x1" -v y="$y1" -v w="$w" -v h="$h" 'BEGIN { exit !(x < 0 || x > w || y < 0 || y > h) }'; then
                echo "✗ Tap point ($x1, $y1) is outside the screen (${w}×${h})."
                return 1
            fi
            "$ADB" -s "$SERIAL" shell input tap "$(_ui_px "$x1" "$scale")" "$(_ui_px "$y1" "$scale")" || {
                echo "✗ tap failed."
                return 1
            }
            ;;
        swipe)
            if [[ ${#args[@]} -eq 1 && "${args[0]}" =~ ^(up|down|left|right)$ ]]; then
                case "${args[0]}" in
                    up)    read -r x1 y1 x2 y2 <<<"$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%d %d %d %d", w/2, h*0.70, w/2, h*0.25 }')" ;;
                    down)  read -r x1 y1 x2 y2 <<<"$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%d %d %d %d", w/2, h*0.25, w/2, h*0.70 }')" ;;
                    left)  read -r x1 y1 x2 y2 <<<"$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%d %d %d %d", w*0.80, h/2, w*0.15, h/2 }')" ;;
                    right) read -r x1 y1 x2 y2 <<<"$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%d %d %d %d", w*0.15, h/2, w*0.80, h/2 }')" ;;
                esac
            elif [[ ${#args[@]} -eq 4 ]] && _ui_is_number "${args[0]}" && _ui_is_number "${args[1]}" && _ui_is_number "${args[2]}" && _ui_is_number "${args[3]}"; then
                x1="${args[0]}"
                y1="${args[1]}"
                x2="${args[2]}"
                y2="${args[3]}"
            else
                echo "✗ swipe expects <x1> <y1> <x2> <y2> or a direction (up|down|left|right)"
                return 1
            fi
            "$ADB" -s "$SERIAL" shell input swipe \
                "$(_ui_px "$x1" "$scale")" "$(_ui_px "$y1" "$scale")" \
                "$(_ui_px "$x2" "$scale")" "$(_ui_px "$y2" "$scale")" 300 || {
                echo "✗ swipe failed."
                return 1
            }
            ;;
        type)
            if [[ ${#args[@]} -eq 0 ]]; then
                echo "✗ type expects text, e.g. ./build.sh android ui type \"hello\""
                return 1
            fi
            _ui_input_text "${args[*]}" || {
                echo "✗ type failed."
                return 1
            }
            ;;
        press)
            local keycode
            case "${args[0]:-}" in
                home) keycode=KEYCODE_HOME ;;
                back) keycode=KEYCODE_BACK ;;
                lock) keycode=KEYCODE_POWER ;;
                *)
                    echo "✗ press expects a button: home | back | lock"
                    return 1
                    ;;
            esac
            "$ADB" -s "$SERIAL" shell input keyevent "$keycode" || {
                echo "✗ press failed."
                return 1
            }
            ;;
    esac

    echo "✓ ${sub} sent"
    if ! $no_shot; then
        sleep "$(awk -v ms="$delay_ms" 'BEGIN { print ms / 1000 }')"
        _ui_shot "$sub"
    fi
}
