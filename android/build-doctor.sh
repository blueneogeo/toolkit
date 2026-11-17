#!/bin/bash
# android-toolkit/build-doctor.sh: checks of the machine, SDK, emulator and server
# Sourced by build.sh. Read-only: never installs, prompts, starts the server or
# reads the keychain. --watch is the one mode that writes: the night's
# watch.log and its down/ flags.
#
# Provides: do_doctor
# Depends on: _resolve_java_home, _java_major (build-gradle.sh)
# Depends on: _night_dir, _overnight_root (build-overnight.sh), _connected_serials (build-device.sh)

DOCTOR_DISK_OK_GB=30
DOCTOR_DISK_LOW_GB=12
DOCTOR_DISK_STOP_GB=5
DOCTOR_MEMORY_OK_PERCENT=40
DOCTOR_MEMORY_LOW_PERCENT=15
DOCTOR_SWAP_LOW_MB=8192

_doctor_usage() {
    cat <<'EOF'
Usage: ./build.sh android doctor [--quick] [--json] [--watch [minutes]]

  Check what an Android build needs on this Mac. Each check prints ✓, ⚠ (works,
  but a risk) or ✗ (blocks), with the fix. Exits 1 when any check fails.

    --quick            Only the live checks: power, disk, memory, emulator,
                       local server and network
    --json             One JSON object per line: {"check","status","detail","fix"}
    --watch [minutes]  Run --quick every N minutes (default 5) until stopped.
                       Appends to <overnight>/<night>/watch.log and sets or clears
                       the flags in down/: disk (below 12 GB free; below 5 GB it
                       also writes STOP), memory (below 15 % free or swap above
                       8 GB), server, emulator, network.
EOF
}

_DOCTOR_FAILED=0
_DOCTOR_JSON=false
_DOCTOR_RESULTS=()

# _doctor_report <ok|warn|fail> <check> <detail> [fix]
_doctor_report() {
    local status="$1" check="$2" detail="$3" fix="${4:-}"
    [[ "$status" == "fail" ]] && _DOCTOR_FAILED=1
    _DOCTOR_RESULTS+=("$status|$check")
    if $_DOCTOR_JSON; then
        D_STATUS="$status" D_CHECK="$check" D_DETAIL="$detail" D_FIX="$fix" python3 -I -c '
import json, os
e = os.environ
print(json.dumps({"check": e["D_CHECK"], "status": e["D_STATUS"], "detail": e["D_DETAIL"], "fix": e["D_FIX"]}, ensure_ascii=False))'
        return 0
    fi
    local mark="✓"
    [[ "$status" == "warn" ]] && mark="⚠"
    [[ "$status" == "fail" ]] && mark="✗"
    echo "  $mark $check: $detail"
    [[ -n "$fix" && "$status" != "ok" ]] && echo "      fix: $fix"
    return 0
}

_doctor_section() {
    $_DOCTOR_JSON || { echo ""; echo "$1:"; }
}

_doctor_power() {
    local source caffeinated
    source=$(pmset -g batt 2>/dev/null | head -1 | sed -n "s/.*'\(.*\)'.*/\1/p")
    caffeinated=$(pmset -g assertions 2>/dev/null | grep -c "caffeinate" || true)
    if [[ "$source" != "AC Power" ]]; then
        _doctor_report warn power "on ${source:-unknown power}" "Plug the Mac in"
    elif [[ "$caffeinated" -eq 0 ]]; then
        _doctor_report warn power "AC power, no caffeinate assertion" "Run caffeinate -dimsu in its own terminal"
    else
        _doctor_report ok power "AC power, caffeinate running"
    fi
}

_doctor_disk_gb() {
    df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'
}

_doctor_disk() {
    local free
    free=$(_doctor_disk_gb)
    if [[ -z "$free" ]]; then
        _doctor_report warn disk "could not read free space"
    elif [[ "$free" -ge $DOCTOR_DISK_OK_GB ]]; then
        _doctor_report ok disk "${free} GB free"
    elif [[ "$free" -ge $DOCTOR_DISK_LOW_GB ]]; then
        _doctor_report warn disk "${free} GB free" "Free space: ./gradlew clean in finished worktrees, remove merged worktrees"
    else
        _doctor_report fail disk "${free} GB free" "Free at least ${DOCTOR_DISK_OK_GB} GB"
    fi
}

_doctor_memory_free() {
    memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'
}

_doctor_swap_mb() {
    sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9]*\)\.[0-9]*M.*/\1/p'
}

_doctor_memory() {
    local free swap
    free=$(_doctor_memory_free)
    swap=$(_doctor_swap_mb)
    local detail="${free:-?} % free, ${swap:-?} MB swap used"
    if [[ -z "$free" ]]; then
        _doctor_report warn memory "could not read memory pressure"
    elif [[ "$free" -lt $DOCTOR_MEMORY_LOW_PERCENT ]]; then
        _doctor_report fail memory "$detail" "Quit heavy apps; run no builds until memory recovers"
    elif [[ "$free" -lt $DOCTOR_MEMORY_OK_PERCENT || "${swap:-0}" -gt $DOCTOR_SWAP_LOW_MB ]]; then
        _doctor_report warn memory "$detail" "Quit Blender, Xcode, Android Studio and browsers you don't need"
    else
        _doctor_report ok memory "$detail"
    fi
}

_doctor_heavy_apps() {
    local running=() app
    for app in Blender Xcode "Android Studio" studio; do
        pgrep -xq "$app" 2>/dev/null && running+=("$app")
    done
    if [[ ${#running[@]} -gt 0 ]]; then
        _doctor_report warn "heavy apps" "running: ${running[*]}" "Quit them before a night of builds"
    else
        _doctor_report ok "heavy apps" "none running"
    fi
}

_doctor_jdk() {
    local home
    if home=$(_resolve_java_home 2>/dev/null); then
        _doctor_report ok jdk "JDK $(_java_major "$home") at $home"
    else
        _doctor_report fail jdk "no JDK 17 or 21" "brew install openjdk@21, or set ANDROID_JAVA_HOME"
    fi
    if [[ -n "${JAVA_HOME:-}" && ! -x "${JAVA_HOME}/bin/java" ]]; then
        _doctor_report warn "JAVA_HOME" "the shell's JAVA_HOME ($JAVA_HOME) does not exist; the toolkit sets its own" "Point JAVA_HOME at /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    fi
}

_doctor_tools() {
    local tool
    for tool in "$ADB" "$EMULATOR_BIN" "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" "$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"; do
        if [[ -x "$tool" ]]; then
            _doctor_report ok "$(basename "$tool")" "$tool"
        else
            _doctor_report fail "$(basename "$tool")" "missing at $tool" "Install it with Android Studio's SDK manager or sdkmanager"
        fi
    done
    if [[ -x "$PROJECT_ROOT/gradlew" ]]; then
        _doctor_report ok "gradle wrapper" "$PROJECT_ROOT/gradlew"
    else
        _doctor_report fail "gradle wrapper" "no gradlew in $PROJECT_ROOT" "Commit the Gradle wrapper"
    fi
    local python_ok
    python_ok=$(python3 -c 'import sys; print(sys.version_info >= (3, 11))' 2>/dev/null || echo False)
    if [[ "$python_ok" == "True" ]]; then
        _doctor_report ok python3 "$(python3 --version 2>&1)"
    else
        _doctor_report fail python3 "python3 3.11 or newer missing" "brew install python"
    fi
    for tool in ffmpeg jq fswatch; do
        if command -v "$tool" >/dev/null 2>&1; then
            _doctor_report ok "$tool" "$(command -v "$tool")"
        else
            _doctor_report warn "$tool" "missing (optional: record --frames, watch)" "brew install $tool"
        fi
    done
}

_doctor_sdk() {
    if [[ ! -d "$ANDROID_SDK" ]]; then
        _doctor_report fail "sdk" "no SDK at $ANDROID_SDK" "Install the Android SDK, or set ANDROID_HOME"
        return 0
    fi
    _doctor_report ok "sdk" "$ANDROID_SDK"
    local compile build_tools image
    compile=$(sed -n 's/.*compileSdk *= *\([0-9]*\).*/\1/p' "$PROJECT_ROOT/$ANDROID_MODULE/build.gradle.kts" 2>/dev/null | head -1)
    build_tools="${ANDROID_BUILD_TOOLS:-}"
    image="${ANDROID_EMULATOR_IMAGE:-}"
    local paths=("platform-tools" "emulator")
    [[ -n "$compile" ]] && paths+=("platforms/android-$compile")
    [[ -n "$build_tools" ]] && paths+=("build-tools/$build_tools")
    [[ -n "$image" ]] && paths+=("${image//;//}")
    local p found
    for p in "${paths[@]}"; do
        found=$(ls -d "$ANDROID_SDK/$p" "$ANDROID_SDK/$p".* 2>/dev/null | head -1 || true)
        if [[ -n "$found" && -f "$found/source.properties" ]]; then
            _doctor_report ok "sdk package" "${found#"$ANDROID_SDK"/}"
        else
            _doctor_report fail "sdk package" "$p missing" "sdkmanager \"${p//\//;}\""
        fi
    done
    if [[ -f "$ANDROID_SDK/licenses/android-sdk-license" ]]; then
        _doctor_report ok licences "accepted"
    else
        _doctor_report fail licences "not accepted" "sdkmanager --licenses (by hand)"
    fi
}

_doctor_avd() {
    [[ -n "$ANDROID_EMULATOR_AVD" ]] || { _doctor_report warn avd "no ANDROID_EMULATOR_AVD in build.properties"; return 0; }
    local config="$HOME/.android/avd/$ANDROID_EMULATOR_AVD.avd/config.ini"
    if [[ ! -f "$config" ]]; then
        _doctor_report fail avd "$ANDROID_EMULATOR_AVD missing" "./build.sh android setup"
        return 0
    fi
    local problems=()
    grep -q '^hw.audioInput *= *no' "$config" || problems+=("microphone on")
    grep -qE '^hw.camera.(back|front) *= *webcam' "$config" && problems+=("a camera uses the Mac's webcam")
    if [[ ${#problems[@]} -gt 0 ]]; then
        _doctor_report warn avd "$ANDROID_EMULATOR_AVD: ${problems[*]}" "Set hw.audioInput=no and no webcam cameras in $config"
    else
        _doctor_report ok avd "$ANDROID_EMULATOR_AVD"
    fi
}

_doctor_emulator_serial() {
    [[ -x "$ADB" ]] || return 0
    _connected_serials | grep '^emulator-' | head -1 || true
}

_doctor_emulator() {
    local serial
    serial=$(_doctor_emulator_serial)
    if [[ -z "$serial" ]]; then
        _doctor_report warn emulator "not running" "./build.sh android emulator start"
        return 1
    fi
    if [[ "$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
        _doctor_report ok emulator "$serial booted"
    else
        _doctor_report warn emulator "$serial still booting" "Wait, or ./build.sh android emulator stop and start again"
        return 1
    fi
}

_doctor_devices() {
    [[ -x "$ADB" ]] || return 0
    local phones
    phones=$(_connected_serials | grep -v '^emulator-' || true)
    if [[ -n "$phones" ]]; then
        _doctor_report warn devices "phone connected: $(tr '\n' ' ' <<<"$phones")" "Unplug phones before the night; the toolkit uses the emulator"
    else
        _doctor_report ok devices "emulators only"
    fi
    local serial
    serial=$(_doctor_emulator_serial)
    if [[ -n "$serial" && "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        if "$ADB" -s "$serial" reverse --list 2>/dev/null | grep -q "tcp:$SERVER_PORT"; then
            _doctor_report ok "adb reverse" "tcp:$SERVER_PORT on $serial"
        else
            _doctor_report warn "adb reverse" "tcp:$SERVER_PORT not set on $serial (install, launch and debug set it)" "$ADB -s $serial reverse tcp:$SERVER_PORT tcp:$SERVER_PORT"
        fi
    fi
}

_doctor_gradle() {
    if [[ -d "$HOME/.gradle/caches/modules-2" ]]; then
        _doctor_report ok "gradle cache" "$(du -sh "$HOME/.gradle/caches/modules-2" 2>/dev/null | cut -f1) in ~/.gradle/caches/modules-2"
    else
        _doctor_report warn "gradle cache" "cold" "Run one full build while online"
    fi
    local props="$PROJECT_ROOT/gradle/wrapper/gradle-wrapper.properties" dist
    dist=$(sed -n 's/.*distributions\/\(gradle-[^/]*\)\.zip.*/\1/p' "$props" 2>/dev/null)
    if [[ -n "$dist" ]]; then
        if [[ -d "$HOME/.gradle/wrapper/dists/$dist" ]]; then
            _doctor_report ok "gradle wrapper dist" "$dist cached"
        else
            _doctor_report warn "gradle wrapper dist" "$dist not cached; the first build downloads it" "Run one build while online"
        fi
    fi
    if grep -qs '^org.gradle.jvmargs=.*-Xmx' "$PROJECT_ROOT/gradle.properties"; then
        _doctor_report ok "gradle memory" "$(grep '^org.gradle.jvmargs=' "$PROJECT_ROOT/gradle.properties" | cut -d= -f2-)"
    else
        _doctor_report warn "gradle memory" "no -Xmx in gradle.properties" "Set org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g"
    fi
}

_doctor_network() {
    local url failed=()
    for url in https://dl.google.com/ https://repo.maven.apache.org/ https://api.anthropic.com/; do
        local code
        code=$(curl -s -o /dev/null -I -m 5 -w '%{http_code}' "$url" 2>/dev/null || true)
        [[ -n "$code" && "$code" != "000" ]] || failed+=("${url#https://}")
    done
    if [[ ${#failed[@]} -eq 0 ]]; then
        _doctor_report ok network "Google, Maven Central and Anthropic answer"
        return 0
    fi
    if [[ ${#failed[@]} -eq 3 ]]; then
        _doctor_report fail network "no answer from ${failed[*]}" "Check the connection; Gradle runs --offline while down/network is set"
    else
        _doctor_report warn network "no answer from ${failed[*]}"
    fi
    return 1
}

_doctor_server() {
    if curl -sf -m 3 "$SERVER_HEALTH_URL" >/dev/null 2>&1; then
        _doctor_report ok server "healthy at $SERVER_HEALTH_URL"
        return 0
    fi
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        _doctor_report fail server "no answer at $SERVER_HEALTH_URL" "A person starts it${SERVER_START_CMD:+: $SERVER_START_CMD}"
    else
        _doctor_report warn server "no answer at $SERVER_HEALTH_URL"
    fi
    return 1
}

_doctor_postgres() {
    command -v pg_isready >/dev/null 2>&1 || return 0
    if pg_isready -q -h localhost 2>/dev/null; then
        _doctor_report ok postgres "accepting connections"
    else
        _doctor_report warn postgres "not accepting connections on localhost"
    fi
}

_doctor_project() {
    if [[ -f "$PROJECT_ROOT/toolkit/shared/build-utils.sh" ]]; then
        _doctor_report ok toolkit "toolkit/ checked out"
    else
        _doctor_report fail toolkit "toolkit/ is empty in $PROJECT_ROOT" "git -c protocol.file.allow=always submodule update --init"
    fi
    if [[ -f "$PROJECT_ROOT/build.properties.local" ]]; then
        _doctor_report ok "local properties" "build.properties.local present"
    else
        _doctor_report warn "local properties" "no build.properties.local (test login for signin)" "Copy it from the main checkout"
    fi
    if [[ -n "${SCODE_SANDBOXED:-}" ]]; then
        _doctor_report fail sandbox "running in an scode sandbox; Android commands need the SDK and ~/.gradle" "Run Android agents outside the sandbox"
    fi
    if [[ -n "${HOMEBREW_NO_AUTO_UPDATE:-}" ]]; then
        _doctor_report ok "brew" "HOMEBREW_NO_AUTO_UPDATE set"
    else
        _doctor_report warn "brew" "HOMEBREW_NO_AUTO_UPDATE not set; a brew install upgrades other tools" "export HOMEBREW_NO_AUTO_UPDATE=1"
    fi
    local auto
    auto=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdate 2>/dev/null || echo "")
    if [[ "$auto" == "1" ]]; then
        _doctor_report warn "auto updates" "App Store updates install by themselves" "Turn them off in System Settings, General, Software Update"
    fi
}

_doctor_flags() {
    local root night flags=()
    root=$(_overnight_root)
    night=$(_night_dir)
    [[ -e "$root/ACTIVE" ]] && flags+=("ACTIVE")
    [[ -e "$root/RESTART_OK" ]] && flags+=("RESTART_OK")
    _doctor_report ok "overnight" "$night${flags[*]:+ (${flags[*]})}"
    if [[ -e "$night/STOP" ]]; then
        _doctor_report warn "overnight" "STOP is set" "Remove $night/STOP to go on"
    fi
    local down
    down=$(ls "$night/down" 2>/dev/null | tr '\n' ' ' || true)
    if [[ -n "$down" ]]; then
        _doctor_report warn "down flags" "$down" "The watchdog clears them when the resource is back"
    else
        _doctor_report ok "down flags" "none"
    fi
}

_doctor_quick() {
    _doctor_section "Machine"
    _doctor_power
    _doctor_disk
    _doctor_memory
    _doctor_section "Emulator and server"
    _doctor_emulator || true
    _doctor_server || true
    _doctor_network || true
}

_doctor_full() {
    _doctor_section "Machine"
    _doctor_power
    _doctor_disk
    _doctor_memory
    _doctor_heavy_apps
    _doctor_section "Toolchain"
    _doctor_jdk
    _doctor_tools
    _doctor_sdk
    _doctor_gradle
    _doctor_section "Emulator and server"
    _doctor_avd
    _doctor_emulator || true
    _doctor_devices
    _doctor_server || true
    _doctor_postgres
    _doctor_network || true
    _doctor_section "Project"
    _doctor_project
    _doctor_flags
}

_doctor_set_flag() {
    local dir="$1" name="$2" down="$3" reason="${4:-}"
    if $down; then
        [[ -e "$dir/$name" ]] || echo "$(date '+%H:%M:%S')  down/$name set: $reason"
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" > "$dir/$name"
    elif [[ -e "$dir/$name" ]]; then
        rm -f "$dir/$name"
        echo "$(date '+%H:%M:%S')  down/$name cleared"
    fi
}

# One watchdog round: quick checks into watch.log, then the down/ flags.
_doctor_watch_round() {
    local night log down
    night=$(_night_dir)
    down="$night/down"
    log="$night/watch.log"
    mkdir -p "$down"
    _DOCTOR_RESULTS=()
    { echo "── $(date '+%Y-%m-%d %H:%M:%S')"; _doctor_quick; } >> "$log" 2>&1

    local disk free swap
    disk=$(_doctor_disk_gb)
    free=$(_doctor_memory_free)
    swap=$(_doctor_swap_mb)
    local disk_low=false memory_low=false
    [[ -n "$disk" && "$disk" -lt $DOCTOR_DISK_LOW_GB ]] && disk_low=true
    if [[ -n "$free" ]] && [[ "$free" -lt $DOCTOR_MEMORY_LOW_PERCENT || "${swap:-0}" -gt $DOCTOR_SWAP_LOW_MB ]]; then
        memory_low=true
    fi
    _doctor_set_flag "$down" disk "$disk_low" "${disk} GB free"
    if [[ -n "$disk" && "$disk" -lt $DOCTOR_DISK_STOP_GB && ! -e "$night/STOP" ]]; then
        echo "disk ${disk} GB free, written by doctor --watch" > "$night/STOP"
        echo "$(date '+%H:%M:%S')  STOP written: ${disk} GB free"
    fi
    _doctor_set_flag "$down" memory "$memory_low" "${free} % free, ${swap} MB swap"
    local result
    for result in "${_DOCTOR_RESULTS[@]}"; do
        case "$result" in
            "warn|emulator"|"fail|emulator") _doctor_set_flag "$down" emulator true "not booted" ;;
            "ok|emulator") _doctor_set_flag "$down" emulator false ;;
            "fail|server"|"warn|server") _doctor_set_flag "$down" server true "no answer at $SERVER_HEALTH_URL" ;;
            "ok|server") _doctor_set_flag "$down" server false ;;
            "fail|network") _doctor_set_flag "$down" network true "no answer from any host" ;;
            "ok|network"|"warn|network") _doctor_set_flag "$down" network false ;;
        esac
    done
}

do_doctor() {
    local quick=false watch="" json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick) quick=true; shift ;;
            --json) json=true; shift ;;
            --watch)
                watch=5
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    watch="$2"
                    shift
                fi
                shift
                ;;
            -h|--help|help) _doctor_usage; return 0 ;;
            *) echo "✗ Unknown option: $1"; _doctor_usage; return 1 ;;
        esac
    done

    if [[ -n "$watch" ]]; then
        if [[ "$watch" -lt 1 ]]; then
            echo "✗ --watch needs at least 1 minute"
            return 1
        fi
        echo "→ Watching every $watch minute(s); log: $(_night_dir)/watch.log (Ctrl-C to stop)"
        while true; do
            _doctor_watch_round
            sleep $((watch * 60))
        done
    fi

    _DOCTOR_JSON=$json
    _DOCTOR_FAILED=0
    $json || echo "Android build environment ($PROJECT_ROOT):"
    if $quick; then
        _doctor_quick
    else
        _doctor_full
    fi
    return "$_DOCTOR_FAILED"
}
