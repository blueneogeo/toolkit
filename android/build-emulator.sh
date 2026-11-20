#!/bin/bash
# android-toolkit/build-emulator.sh: the emulator, its AVDs, and what iOS does
# with `simulator` (create, front, contact, restart, text-size) and `push`
# Sourced by build.sh.
#
# Provides: do_emulator, do_push, _emulator_text_sizes
# Depends on: _connected_serials, _serials_of_avd, _select_android_target,
#             _target_label (build-device.sh)
# Depends on: _app_id, _app_installed, _main_component, _device_quote (build-lifecycle.sh)
# Depends on: _resolve_java_home (build-gradle.sh)

# The iOS Dynamic Type names and the font_scale each maps to.
_EMULATOR_TEXT_SIZES="extra-small:0.82 small:0.88 medium:0.94 large:1.0 extra-large:1.12 extra-extra-large:1.24 extra-extra-extra-large:1.35 accessibility-medium:1.64 accessibility-large:1.95 accessibility-extra-large:2.35 accessibility-extra-extra-large:2.76 accessibility-extra-extra-extra-large:3.12"

_emulator_text_sizes() {
    local pair names=""
    for pair in $_EMULATOR_TEXT_SIZES; do
        names+="${pair%%:*} "
    done
    echo "${names% }"
}

_emulator_usage() {
    cat <<EOF
Usage: ./build.sh android emulator <command>

  start [avd] [--window]
                       Boot the AVD (default ANDROID_EMULATOR_AVD in build.properties)
                       without a window, or with one, and wait until it has booted
  stop                 Shut down the running emulator
  status               Show the connected emulators and phones
  restart [avd|serial] Shut the running emulator down and boot it again from a cold
                       start, with fresh system services
  create <name> [--image <package>] [--profile <device>]
                       Make an AVD of that name, unless one exists; prints its name.
                       It gets the hardware of ANDROID_EMULATOR_AVD (or, while that AVD
                       doesn't exist, ANDROID_EMULATOR_HARDWARE) and the system image
                       ANDROID_EMULATOR_IMAGE, or the given image and avdmanager device
                       profile (e.g. pixel_8)
  front [avd|serial]   Bring the app back to the front, as a tap on its icon does: the
                       running process carries on, nothing is installed or restarted
  contact [avd|serial] <file.vcf>
                       Add the vCard's contacts (name, email, phone) to the emulator's
                       Contacts and let the app read them, without the system asking
  text-size [size]     Set the emulator's text size (font scale); no size prints the
                       current one. large is the default. Sizes:
                       $(_emulator_text_sizes)
  push <payload.json>  Hand a push payload to the app's debug push receiver, the same
                       as './build.sh android push'
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

# Boots an AVD headless (or with a window) and waits until Android has booted.
# Extra emulator flags come after the window choice.
_emulator_boot() {
    local avd="$1" window="$2"
    shift 2
    local running
    running=$(_serials_of_avd "$avd" | head -1)
    if [[ -n "$running" ]]; then
        echo "✓ Emulator already running ($running)"
        return 0
    fi
    if [[ ! -d "$HOME/.android/avd/$avd.avd" ]]; then
        echo "✗ No AVD called $avd. Make it with: ./build.sh android emulator create $avd"
        return 1
    fi
    local flags=(-avd "$avd" -no-snapshot-save -no-boot-anim)
    # A window is for a person, who hears the Turns; a headless emulator stays silent.
    if $window; then
        flags+=(-gpu host)
    else
        flags+=(-no-window -no-audio -gpu swiftshader_indirect)
    fi
    flags+=("$@")
    local log_dir="${PROJECT_ROOT}/build/emulator"
    mkdir -p "$log_dir"
    echo "→ Booting $avd"
    nohup "$EMULATOR_BIN" "${flags[@]}" > "$log_dir/emulator.log" 2>&1 &
    local serial="" waited=0
    while [[ -z "$serial" && $waited -lt 120 ]]; do
        sleep 2
        waited=$((waited + 2))
        serial=$(_serials_of_avd "$avd" | head -1)
    done
    if [[ -z "$serial" ]] || ! _emulator_wait_for_boot "$serial"; then
        echo "✗ The emulator did not finish booting. Log: $log_dir/emulator.log"
        return 1
    fi
    echo "✓ Emulator booted ($serial)"
}

# The running emulator a command acts on: the given AVD name or serial, the
# --device selector, else the one running emulator.
_emulator_serial() {
    _select_android_target "${1:-}" || return 1
    if ! _is_emulator_serial "$SERIAL"; then
        echo "✗ $SERIAL is a phone; this command works on the emulator."
        return 1
    fi
}

_emulator_restart() {
    _emulator_serial "${1:-}" || return 1
    local serial="$SERIAL" avd waited=0
    avd=$(_avd_name "$serial")
    if [[ -z "$avd" ]]; then
        echo "✗ Could not read the AVD name of $serial."
        return 1
    fi
    echo "→ Shutting down $avd ($serial)"
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
    while _connected_serials | grep -qxF "$serial" && [[ $waited -lt 60 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    # The emulator process can outlive its adb connection by a moment.
    sleep 2
    _emulator_boot "$avd" false -no-snapshot-load || return 1
    echo "✓ $avd started again"
}

_avdmanager() {
    local bin="$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"
    if [[ ! -x "$bin" ]]; then
        echo "✗ avdmanager not found at $bin. Run: ./build.sh android setup" >&2
        return 1
    fi
    local java_home
    java_home=$(_resolve_java_home) || return 1
    JAVA_HOME="$java_home" "$bin" "$@"
}

# Hardware keys an AVD made by `create` takes from ANDROID_EMULATOR_AVD.
_AVD_HARDWARE_KEYS='^(hw\.|PlayStore\.enabled=|skin\.|disk\.dataPartition\.size=|sdcard\.size=|showDeviceFrame=|runtime\.network\.|vm\.heapSize=)'

_emulator_create() {
    local name="" image="${ANDROID_EMULATOR_IMAGE:-}" profile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image | --profile)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                [[ "$1" == "--image" ]] && image="$2" || profile="$2"
                shift 2
                ;;
            -*) echo "✗ Unknown flag: $1"; return 1 ;;
            *)
                if [[ -n "$name" ]]; then
                    echo "✗ emulator create takes one name"
                    return 1
                fi
                name="$1"
                shift
                ;;
        esac
    done
    if [[ -z "$name" ]]; then
        echo "✗ emulator create needs a name, e.g. Turn_Journey"
        return 1
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "✗ An AVD name takes letters, digits, '.', '_' and '-'."
        return 1
    fi
    if [[ -d "$HOME/.android/avd/$name.avd" ]]; then
        echo "✓ $name exists"
        echo "$name"
        return 0
    fi
    if [[ -z "$image" ]]; then
        echo "✗ No system image. Set ANDROID_EMULATOR_IMAGE in build.properties, or pass --image."
        return 1
    fi
    if [[ ! -d "$ANDROID_SDK/$(tr ';' '/' <<<"$image")" ]]; then
        echo "✗ The system image $image is not installed. Run: ./build.sh android setup"
        return 1
    fi
    local source_config="" hardware=""
    if [[ -z "$profile" ]]; then
        source_config="$HOME/.android/avd/${ANDROID_EMULATOR_AVD:-}.avd/config.ini"
        if [[ -n "${ANDROID_EMULATOR_AVD:-}" && -f "$source_config" ]]; then
            profile=$(sed -n 's/^hw\.device\.name=//p' "$source_config" | head -1)
        else
            # The first AVD: the iOS reference phone's canvas.
            source_config=""
            profile="$ANDROID_EMULATOR_PROFILE"
            hardware="$ANDROID_EMULATOR_HARDWARE"
        fi
    fi
    local args=(create avd -n "$name" -k "$image")
    [[ -n "$profile" ]] && args+=(-d "$profile")
    local out
    if ! out=$(echo no | _avdmanager "${args[@]}" 2>&1); then
        echo "✗ Could not make $name:"
        tail -5 <<<"$out" | sed 's/^/  /'
        return 1
    fi
    local config="$HOME/.android/avd/$name.avd/config.ini"
    if [[ -n "$source_config" && -f "$config" ]]; then
        local kept
        kept=$(grep -E "$_AVD_HARDWARE_KEYS" "$source_config" || true)
        {
            grep -vE "$_AVD_HARDWARE_KEYS" "$config" || true
            echo "$kept"
        } > "$config.new"
        mv "$config.new" "$config"
        echo "✓ Made $name with the hardware of $ANDROID_EMULATOR_AVD ($image)"
    elif [[ -n "$hardware" && -f "$config" ]]; then
        local pair keys=""
        for pair in $hardware; do
            keys+="${keys:+|}$(sed 's/[.]/\\./g' <<<"${pair%%=*}")"
        done
        {
            grep -vE "^($keys)=" "$config" || true
            tr ' ' '\n' <<<"$hardware"
        } > "$config.new"
        mv "$config.new" "$config"
        echo "✓ Made $name with the hardware of ANDROID_EMULATOR_HARDWARE ($image)"
    else
        echo "✓ Made $name ($profile, $image)"
    fi
    echo "$name"
}

_emulator_front() {
    _emulator_serial "${1:-}" || return 1
    local app_id component out
    app_id=$(_app_id) || return 1
    component=$(_main_component "$app_id")
    if [[ -z "$component" ]]; then
        echo "✗ $app_id is not installed on $(_target_label)."
        return 1
    fi
    # The launcher's own intent: an existing task comes forward as it is.
    out=$("$ADB" -s "$SERIAL" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
        --activity-reorder-to-front -n "$(_device_quote "$component")" 2>&1 | tr -d '\r')
    if grep -qE "^Error|Exception" <<<"$out"; then
        echo "✗ Could not bring the app forward:"
        grep -E "Error|Exception" <<<"$out" | head -3 | sed 's/^/  /'
        return 1
    fi
    echo "✓ The app is in front on $(_target_label)"
}

# Prints one line per vCard: name, then emails and phones, tab-separated,
# each list joined with commas.
_vcard_rows() {
    VCF="$1" python3 -I -c '
import os, re
text = open(os.environ["VCF"], encoding="utf-8", errors="replace").read()
text = re.sub(r"\r?\n[ \t]", "", text)
for card in re.findall(r"BEGIN:VCARD(.*?)END:VCARD", text, re.S | re.I):
    name, structured, emails, phones = "", "", [], []
    for line in card.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        field = key.split(";")[0].split(".")[-1].upper()
        value = value.strip().replace("\\,", ",").replace("\\;", ";")
        if field == "FN":
            name = value
        elif field == "N":
            parts = [p for p in value.split(";")]
            structured = " ".join(p for p in (parts[1:2] + parts[0:1]) if p)
        elif field == "EMAIL" and value:
            emails.append(value)
        elif field == "TEL" and value:
            phones.append(value)
    name = name or structured
    if name or emails or phones:
        clean = lambda s: s.replace("\x1f", " ").replace(",", " ")
        # A unit separator, not a tab: bash read merges empty tab-separated fields, and a card without a name lost its address.
        print("\x1f".join([clean(name), ",".join(map(clean, emails)), ",".join(map(clean, phones))]))
'
}

_content_insert() {
    local uri="$1" cmd
    shift
    cmd="content insert --uri $uri"
    local bind
    for bind in "$@"; do
        cmd+=" --bind $(_device_quote "$bind")"
    done
    "$ADB" -s "$SERIAL" shell "$cmd" 2>&1 | tr -d '\r'
}

_emulator_contact() {
    local target="" file=""
    if [[ $# -ge 2 ]]; then
        target="$1"
        file="$2"
    else
        file="${1:-}"
    fi
    if [[ "$file" != *.vcf || ! -f "$file" ]]; then
        echo "✗ emulator contact needs a .vcf file"
        return 1
    fi
    _emulator_serial "$target" || return 1
    local rows
    rows=$(_vcard_rows "$file") || return 1
    if [[ -z "$rows" ]]; then
        echo "✗ No contacts in $file"
        return 1
    fi
    "$ADB" -s "$SERIAL" push "$file" /sdcard/Download/ >/dev/null 2>&1 || true
    local name emails phones count=0 out id value
    # The rows come on fd 3: adb shell reads stdin.
    while IFS=$'\x1f' read -r -u 3 name emails phones; do
        out=$(_content_insert content://com.android.contacts/raw_contacts "account_type:n:" "account_name:n:")
        if grep -qiE "error|exception" <<<"$out"; then
            echo "✗ Could not add a contact:"
            head -3 <<<"$out" | sed 's/^/  /'
            return 1
        fi
        id=$("$ADB" -s "$SERIAL" shell content query --uri content://com.android.contacts/raw_contacts --projection _id --sort "'_id DESC'" 2>/dev/null \
            | tr -d '\r' | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)
        if [[ -z "$id" ]]; then
            echo "✗ Could not read the new contact's id."
            return 1
        fi
        [[ -n "$name" ]] && _content_insert content://com.android.contacts/data "raw_contact_id:i:$id" "mimetype:s:vnd.android.cursor.item/name" "data1:s:$name" >/dev/null
        local IFS_SAVED="$IFS"
        IFS=','
        for value in $emails; do
            _content_insert content://com.android.contacts/data "raw_contact_id:i:$id" "mimetype:s:vnd.android.cursor.item/email_v2" "data1:s:$value" "data2:i:1" >/dev/null
        done
        for value in $phones; do
            _content_insert content://com.android.contacts/data "raw_contact_id:i:$id" "mimetype:s:vnd.android.cursor.item/phone_v2" "data1:s:$value" "data2:i:2" >/dev/null
        done
        IFS="$IFS_SAVED"
        count=$((count + 1))
    done 3<<<"$rows"
    local app_id
    app_id=$(_app_id) || return 1
    if ! _app_installed "$app_id"; then
        echo "✓ The contacts are on $(_target_label) ($count added)"
        echo "⚠ $app_id is not installed, so it may not read them yet; run this again after installing."
        return 0
    fi
    "$ADB" -s "$SERIAL" shell pm grant "$app_id" android.permission.READ_CONTACTS >/dev/null 2>&1 || true
    local package_dump
    package_dump=$("$ADB" -s "$SERIAL" shell dumpsys package "$app_id" 2>/dev/null || true)
    if grep -q "android.permission.READ_CONTACTS: granted=true" <<<"$package_dump"; then
        echo "✓ The contacts are on $(_target_label), and the app may read them ($count added)"
    else
        echo "✓ The contacts are on $(_target_label) ($count added)"
        echo "⚠ $app_id does not ask for READ_CONTACTS in its manifest, so it may not read them."
    fi
}

_emulator_text_size() {
    _emulator_serial "" || return 1
    local size="${1:-}" pair scale current
    if [[ -z "$size" ]]; then
        current=$("$ADB" -s "$SERIAL" shell settings get system font_scale 2>/dev/null | tr -d '\r')
        [[ "$current" == "null" || -z "$current" ]] && current="1.0"
        for pair in $_EMULATOR_TEXT_SIZES; do
            if awk -v a="$current" -v b="${pair#*:}" 'BEGIN { exit !(a - b < 0.005 && b - a < 0.005) }'; then
                echo "${pair%%:*} (font scale $current)"
                return 0
            fi
        done
        echo "font scale $current"
        return 0
    fi
    for pair in $_EMULATOR_TEXT_SIZES; do
        [[ "${pair%%:*}" == "$size" ]] && scale="${pair#*:}"
    done
    if [[ -z "${scale:-}" ]]; then
        echo "✗ Unknown text size \"$size\"."
        _emulator_usage
        return 1
    fi
    "$ADB" -s "$SERIAL" shell settings put system font_scale "$scale" || return 1
    echo "✓ Text size $size"
}

# Hands a push payload (the JSON a push would carry) to the app's debug-only
# receiver (ANDROID_PUSH_RECEIVER), which passes it to the code the real
# messaging service calls. No FCM is involved.
do_push() {
    local payload="${1:-}"
    if [[ -z "$payload" || ! -f "$payload" ]]; then
        echo "Usage: ./build.sh android push <payload.json>"
        return 1
    fi
    if ! python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$payload" 2>/dev/null; then
        echo "✗ $payload is not JSON."
        return 1
    fi
    _emulator_serial "" || return 1
    local app_id receiver json out
    app_id=$(_app_id) || return 1
    receiver=$(_push_receiver "$app_id")
    # dumpsys writes a class inside the package's own name space as /.Class.
    local class="${receiver#*/}" short="$receiver"
    [[ "$class" == "${receiver%%/*}".* ]] && short="${receiver%%/*}/.${class#"${receiver%%/*}".}"
    local package_dump
    package_dump=$("$ADB" -s "$SERIAL" shell dumpsys package "$app_id" 2>/dev/null | tr -d '\r' || true)
    if ! grep -qF -e "$receiver" -e "$short" <<<"$package_dump"; then
        echo "✗ $app_id has no receiver ${receiver#*/}. Debug builds need it to take pushes from the toolkit."
        return 1
    fi
    json=$(python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$payload")
    out=$("$ADB" -s "$SERIAL" shell "am broadcast -n $(_device_quote "$receiver") --es payload $(_device_quote "$json")" 2>&1 | tr -d '\r')
    if ! grep -q "Broadcast completed" <<<"$out"; then
        echo "✗ The push was not delivered:"
        tail -3 <<<"$out" | sed 's/^/  /'
        return 1
    fi
    echo "✓ Push delivered to $app_id on the emulator"
}

# The receiver's component: ANDROID_PUSH_RECEIVER as package/class, or a class
# name, where a leading '.' means the module's namespace.
_push_receiver() {
    local app_id="$1" receiver="${ANDROID_PUSH_RECEIVER:-.debug.DebugPushReceiver}" namespace
    if [[ "$receiver" == */* ]]; then
        echo "$receiver"
        return 0
    fi
    if [[ "$receiver" == .* ]]; then
        namespace=$(sed -nE 's/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$PROJECT_ROOT/$ANDROID_MODULE/build.gradle.kts" 2>/dev/null | head -1)
        receiver="${namespace:-$app_id}$receiver"
    fi
    echo "$app_id/$receiver"
}

do_emulator() {
    _require_adb || return 1
    case "${1:-}" in
        start)
            shift
            local window=false avd="$ANDROID_EMULATOR_AVD" arg
            for arg in "$@"; do
                case "$arg" in
                    --window) window=true ;;
                    -*) echo "✗ Unknown flag: $arg"; return 1 ;;
                    *) avd="$arg" ;;
                esac
            done
            if [[ -z "$avd" ]]; then
                echo "✗ No AVD configured. Set ANDROID_EMULATOR_AVD in build.properties."
                return 1
            fi
            _emulator_boot "$avd" "$window"
            ;;
        stop)
            # By AVD name (default ANDROID_EMULATOR_AVD), never whichever emulator comes first.
            local serial avd="${2:-$ANDROID_EMULATOR_AVD}"
            if [[ -z "$avd" ]]; then
                echo "✗ Name the AVD to stop: ./build.sh android emulator stop <avd>"
                return 1
            fi
            serial=$(_serials_of_avd "$avd" | head -1)
            if [[ -z "$serial" ]]; then
                echo "✓ $avd is not running"
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
        restart)   shift; _emulator_restart "$@" ;;
        create)    shift; _emulator_create "$@" ;;
        front)     shift; _emulator_front "$@" ;;
        contact)   shift; _emulator_contact "$@" ;;
        text-size) shift; _emulator_text_size "$@" ;;
        push)      shift; do_push "$@" ;;
        *)
            _emulator_usage
            ;;
    esac
}
