#!/bin/bash
set -euo pipefail

# ios-toolkit/build.sh — generic iOS build toolkit (drop-in for any project)
# Sourced by a thin project-level build.sh, or run directly.
# Configuration lives in <project>/build.properties (generated from
# ios-toolkit/config/build.properties.example via `./build.sh setup`).
# No project names are hardcoded — everything is config-driven or auto-detected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The host project root. The project entry exports TOOLKIT_PROJECT_ROOT; when
# run directly, fall back to walking up from the toolkit to the nearest
# project.yml/build.properties (handles <project>/toolkit/ios and <project>/ios-toolkit layouts).
_find_project_root() {
    local dir="$SCRIPT_DIR"
    for _ in 1 2 3 4 5; do
        if [[ -f "$dir/project.yml" || -f "$dir/build.properties" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "$SCRIPT_DIR"
}

if [[ -n "${TOOLKIT_PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$TOOLKIT_PROJECT_ROOT"
else
    PROJECT_ROOT="$(_find_project_root)"
fi

source "$SCRIPT_DIR/shared/build-utils.sh"
source "$SCRIPT_DIR/shared/sentry.sh"
source "$SCRIPT_DIR/build-lifecycle.sh"
source "$SCRIPT_DIR/build-e2e.sh"
source "$SCRIPT_DIR/build-upload.sh"

PID_FILE="$PROJECT_ROOT/.watch/ios.pid"
TEST_TIMEOUT=120

# ── Timing constants ────────────────────────────────────────────────

LAUNCH_POLL_INTERVAL=0.5
LAUNCH_TIMEOUT_TICKS=16
REDEPLOY_GAP=0.5

WATCH_COOLDOWN=2.0

# ── Config ──────────────────────────────────────────────────────────

_load_config() {
    local props=""
    for p in "$PROJECT_ROOT/build.properties" "$PROJECT_ROOT/../build.properties"; do
        if [[ -f "$p" ]]; then
            props="$p"
            break
        fi
    done
    if [[ -n "$props" ]]; then
        set -a
        source "$props"
        set +a
    fi

    # Offline-first defaults: nothing that requires configuration is on.
    TOOLKIT_SERVER_ENABLED="${TOOLKIT_SERVER_ENABLED:-false}"
    TOOLKIT_E2E_ENABLED="${TOOLKIT_E2E_ENABLED:-false}"
    TOOLKIT_UPLOAD_ENABLED="${TOOLKIT_UPLOAD_ENABLED:-false}"
    TOOLKIT_SENTRY_ENABLED="${TOOLKIT_SENTRY_ENABLED:-false}"
    TOOLKIT_LOGS_ENABLED="${TOOLKIT_LOGS_ENABLED:-true}"
    TOOLKIT_DEBUG_SCRIPTS="${TOOLKIT_DEBUG_SCRIPTS:-false}"
    TOOLKIT_ARCH_CHECKS="${TOOLKIT_ARCH_CHECKS:-true}"

    DEV_BUNDLE_SUFFIX="${DEV_BUNDLE_SUFFIX:-}"
    SERVER_START_CMD="${SERVER_START_CMD:-}"
    SERVER_STOP_CMD="${SERVER_STOP_CMD:-}"
}

_find_up() {
    local name="$1" dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/$name" ]]; then
            echo "$dir/$name"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

_detect_project_config() {
    _load_config

    PROJECT_NAME="${IOS_PROJECT_NAME:-}"
    if [[ -z "$PROJECT_NAME" && -f "$PROJECT_ROOT/project.yml" ]]; then
        PROJECT_NAME=$(grep -m1 '^name:' "$PROJECT_ROOT/project.yml" | sed 's/^name:[[:space:]]*//' || true)
    fi
    if [[ -z "$PROJECT_NAME" ]]; then
        local xcodeproj
        xcodeproj=$(ls -d "$PROJECT_ROOT"/*.xcodeproj 2>/dev/null | head -1 || true)
        if [[ -n "$xcodeproj" ]]; then
            PROJECT_NAME=$(basename "$xcodeproj" .xcodeproj)
        fi
    fi
    PROJECT_NAME="${PROJECT_NAME:-MyApp}"

    SCHEME_NAME="${IOS_SCHEME_NAME:-}"
    if [[ -z "$SCHEME_NAME" && -f "$PROJECT_ROOT/project.yml" ]] && grep -q '^schemes:' "$PROJECT_ROOT/project.yml"; then
        SCHEME_NAME=$(sed -n '/^schemes:/,/^[a-z]/p' "$PROJECT_ROOT/project.yml" | grep -m1 '^  [A-Za-z]' | sed 's/^  //;s/:.*//' || true)
    fi
    SCHEME_NAME="${SCHEME_NAME:-$PROJECT_NAME}"

    APP_EXECUTABLE="${IOS_APP_NAME:-$PROJECT_NAME}"
    SOURCE_DIR="${IOS_SOURCE_DIR:-$PROJECT_NAME}"
    TEST_TARGET="${IOS_TEST_TARGET:-${PROJECT_NAME}Tests}"
    BUNDLE_ID="${IOS_BUNDLE_ID:-}"
    if [[ -z "$BUNDLE_ID" && -f "$PROJECT_ROOT/project.yml" ]]; then
        BUNDLE_ID=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER:' "$PROJECT_ROOT/project.yml" | sed 's/.*: *//' | sed 's/[()$]//g' || true)
    fi
    BUNDLE_ID="${BUNDLE_ID:-com.example.${PROJECT_NAME,,}}"

    E2E_SCHEME="${E2E_SCHEME:-${PROJECT_NAME}E2E}"

    # Architecture-check configuration (used only when TOOLKIT_ARCH_CHECKS=true)
    TOOLKIT_STATE_CLASS="${TOOLKIT_STATE_CLASS:-AppState}"
    TOOLKIT_STATE_FILE="${TOOLKIT_STATE_FILE:-model/AppState.swift}"
    STATE_EXCLUSION="${TOOLKIT_STATE_EXCLUSION:-@State private var appState = ${TOOLKIT_STATE_CLASS}()}"
    STATE_DIR="$(dirname "$SOURCE_DIR/$TOOLKIT_STATE_FILE")"
    STATE_BASENAME="$(basename "$TOOLKIT_STATE_FILE" .swift)"
    STATE_FILE_PATH="$SOURCE_DIR/$TOOLKIT_STATE_FILE"

    SWIFTLINT_CONFIG="${SWIFTLINT_CONFIG:-$(_find_up .swiftlint.yml || true)}"
    PERIPHERY_CONFIG="${PERIPHERY_CONFIG:-$(_find_up .periphery.yml || true)}"
}

# ── Simulator discovery ─────────────────────────────────────────────

_SIM_NAME=""
_SIM_ID=""
_SIM_OS=""
if command -v xcrun &>/dev/null; then
    _SIM_NAME=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone [0-9]" | head -1 | sed -E 's/^[[:space:]]*//' | sed -E 's/ \([A-F0-9\-]+\) \(.*$//' || true)
    _SIM_ID=$(xcrun simctl list devices available 2>/dev/null | grep -E "iPhone [0-9]" | head -1 | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' || true)
    _SIM_OS=$(xcrun simctl list runtimes 2>/dev/null | grep "iOS" | head -1 | sed -E 's/.*\(([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' || true)
fi
SIM_NAME="${SIM_NAME:-$_SIM_NAME}"
SIM_ID="${SIM_DEVICE_ID:-$_SIM_ID}"
SIM_OS="${SIM_OS_VERSION:-$_SIM_OS}"
SIM_DEST="platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}"

# ── Device discovery ────────────────────────────────────────────────

_detect_device() {
    local all_devices dest match_count
    all_devices=$(xcrun devicectl list devices 2>/dev/null | grep -v "Name\|^--")
    if [[ -z "$all_devices" ]]; then
        return 1
    fi

    if [[ -n "$_DEVICE_SELECTOR" ]]; then
        dest=$(echo "$all_devices" | grep -i "$_DEVICE_SELECTOR" | head -1)
        if [[ -z "$dest" ]]; then
            echo "✗ No device matching '$_DEVICE_SELECTOR' found."
            echo ""
            echo "  Available devices:"
            echo "$all_devices" | while IFS= read -r line; do
                local name udid
                udid=$(echo "$line" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
                name=$(echo "$line" | sed -E "s/ *${udid}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
                echo "    $name  ($udid)"
            done
            exit 1
        fi
        match_count=$(echo "$all_devices" | grep -ci "$_DEVICE_SELECTOR" || true)
        if [[ "$match_count" -gt 1 ]]; then
            echo "✗ Multiple devices match '$_DEVICE_SELECTOR'. Be more specific, or set IOS_DEVICE:"
            echo ""
            echo "$all_devices" | while IFS= read -r line; do
                local name udid
                udid=$(echo "$line" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
                name=$(echo "$line" | sed -E "s/ *${udid}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
                echo "    $name  ($udid)"
            done
            exit 1
        fi
    else
        match_count=$(echo "$all_devices" | wc -l | tr -d ' ')
        if [[ "$match_count" -gt 1 ]]; then
            local first_name first_udid
            first_udid=$(echo "$all_devices" | head -1 | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
            first_name=$(echo "$all_devices" | head -1 | sed -E "s/ *${first_udid}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
            echo "✗ Multiple devices found. Use --device to select one, or set IOS_DEVICE:"
            echo ""
            echo "$all_devices" | while IFS= read -r line; do
                local name udid
                udid=$(echo "$line" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
                name=$(echo "$line" | sed -E "s/ *${udid}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
                echo "    $name  ($udid)"
            done
            echo ""
            echo "  Example: ./build.sh --device \"$first_name\" install"
            echo "  Or set:  export IOS_DEVICE=\"$first_name\""
            exit 1
        fi
        dest="$all_devices"
    fi

    DEVICE_UDID=$(echo "$dest" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    DEVICE_NAME=$(echo "$dest" | sed -E "s/ *${DEVICE_UDID}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
    DEVICE_DEST="generic/platform=iOS"

    if [[ -n "$_DEVICE_SELECTOR" && -z "${IOS_DEVICE:-}" ]]; then
        local total_devices
        total_devices=$(echo "$all_devices" | wc -l | tr -d ' ')
        if [[ "$total_devices" -gt 1 ]]; then
            echo "  Tip: set export IOS_DEVICE=\"$_DEVICE_SELECTOR\" to skip --device next time."
        fi
    fi
}

# ── Mode state ──────────────────────────────────────────────────────

_TARGET_SDK=""
_TARGET_DEST=""
_TARGET_NAME=""
_BUILD_EXTRA=""
_DEVICE_FORCED=false
_DEVICE_SELECTOR=""

_set_mode_sim() {
    _TARGET_SDK="iphonesimulator"
    _TARGET_DEST="$SIM_DEST"
    _TARGET_NAME="$SIM_NAME"
    _BUILD_EXTRA=""
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        export API_BASE_URL
        API_BASE_URL="${API_BASE_URL:-http://localhost:8080}"
    fi
    BUNDLE_ID="${BUNDLE_ID}${DEV_BUNDLE_SUFFIX}"
}

_set_mode_device() {
    _TARGET_SDK="iphoneos"
    _TARGET_DEST="$DEVICE_DEST"
    _TARGET_NAME="$DEVICE_NAME"
    _BUILD_EXTRA="ONLY_ACTIVE_ARCH=YES"
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        export API_BASE_URL
        local host_ip
        host_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "")
        API_BASE_URL="http://${host_ip:-localhost}:8080"
    fi
    BUNDLE_ID="${BUNDLE_ID}${DEV_BUNDLE_SUFFIX}"
}

_set_mode_device_forced() {
    if ! _detect_device; then
        echo "✗ No physical device found."
        exit 1
    fi
    _set_mode_device
}

_select_target() {
    local requested="${1:-simulator}"
    if $_DEVICE_FORCED; then
        _set_mode_device_forced
        return
    fi
    case "$requested" in
        iphone|device)
            _set_mode_device_forced
            ;;
        *)
            _set_mode_sim
            _validate_sim_target
            ;;
    esac
}

# ── Guards ──────────────────────────────────────────────────────────

_check_core_tools() {
    _require_cmd xcrun "Install Xcode and run: xcode-select --install"
    _require_cmd xcodebuild "Install Xcode and run: xcode-select --install"
}

_check_build_tools() {
    _check_core_tools
    _require_cmd xcodegen "Install with: brew install xcodegen"
    _require_cmd xcode-build-server "Install with: brew install xcode-build-server"
}

_validate_sim_target() {
    if [[ -z "$SIM_NAME" || -z "$SIM_ID" || -z "$SIM_OS" ]]; then
        echo "✗ Could not detect an available iPhone simulator."
        echo "  Override with SIM_NAME, SIM_DEVICE_ID, and SIM_OS_VERSION."
        exit 1
    fi
}

_validate_target() {
    case "$_TARGET_SDK" in
        iphonesimulator) _validate_sim_target ;;
        iphoneos)
            if [[ -z "${DEVICE_UDID:-}" && "$_TARGET_DEST" != "generic/platform=iOS" ]]; then
                echo "✗ Could not detect a physical iOS device."
                exit 1
            fi
            ;;
        *)
            echo "✗ Build target was not selected."
            exit 1
            ;;
    esac
}

_guard_not_running() {
    if _pid_running "$PID_FILE"; then
        echo "✗ iOS watcher already running (PID $(cat "$PID_FILE"))."
        echo "  Use './build.sh uninstall' first, then retry."
        exit 1
    fi
}

# ── Project ─────────────────────────────────────────────────────────

_ensure_project() {
    local project_file="$PROJECT_ROOT/$PROJECT_NAME.xcodeproj/project.pbxproj"
    if [[ ! -f "$project_file" ]]; then
        _require_cmd xcodegen "Install with: brew install xcodegen"
        (cd "$PROJECT_ROOT" && xcodegen generate)
        return
    fi
    local newer_source_dir
    newer_source_dir=$(find "$PROJECT_ROOT/$SOURCE_DIR" "$PROJECT_ROOT/${PROJECT_NAME}Tests" "$PROJECT_ROOT/${PROJECT_NAME}UITests" -type d -newer "$project_file" -print -quit 2>/dev/null || true)
    if [[ "$PROJECT_ROOT/project.yml" -nt "$project_file" || -n "$newer_source_dir" ]]; then
        _require_cmd xcodegen "Install with: brew install xcodegen"
        (cd "$PROJECT_ROOT" && xcodegen generate)
    fi
}

# ── Unified build ───────────────────────────────────────────────────

_do_build() {
    local action="${1:-build}"
    local cfg="${_BUILD_CONFIG:-Debug}"
    _check_build_tools
    _validate_target
    _ensure_project
    if command -v swiftlint &>/dev/null; then
        do_lint || return 1
    fi
    echo "→ Building $PROJECT_NAME for $_TARGET_NAME ($_TARGET_SDK, $cfg)"
    local logfile
    logfile=$(mktemp)
    if (cd "$PROJECT_ROOT" && xcodebuild -quiet -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME" -sdk "$_TARGET_SDK" \
      -destination "$_TARGET_DEST" -configuration "$cfg" $action $_BUILD_EXTRA \
      -allowProvisioningUpdates \
      > "$logfile" 2>&1); then
        xcode-build-server parse -a < "$logfile" 2>/dev/null || true
        rm -f "$logfile"
        echo "✓ Build complete"
    else
        echo "✗ Build failed:"
        cat "$logfile"
        rm -f "$logfile"
        return 1
    fi
}

# ── Unified app path ────────────────────────────────────────────────

_find_app() {
    local derived
    derived=$(ls -dt ~/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}-*/ 2>/dev/null | head -1)
    if [[ -n "$derived" ]]; then
        find "$derived"Build/Products/Debug-"$_TARGET_SDK" \
            -name "${APP_EXECUTABLE}.app" -maxdepth 1 2>/dev/null | head -1
    fi
}

# ── Fastlane ──────────────────────────────────────────────────────────

_ruby_bundle_cmd() {
    local prefix
    prefix=$(brew --prefix ruby 2>/dev/null || true)
    if [[ -n "$prefix" ]]; then
        echo "$prefix/bin/bundle"
    else
        echo "bundle"
    fi
}

_fastlane_setup() {
    local bundle_cmd
    bundle_cmd=$(_ruby_bundle_cmd)
    if ! command -v "$bundle_cmd" &>/dev/null; then
        echo "✗ bundle not found. Install with: brew install ruby"
        return 1
    fi

    if [[ ! -f "$PROJECT_ROOT/Gemfile.lock" ]] || ! (cd "$PROJECT_ROOT" && "$bundle_cmd" check &>/dev/null); then
        echo "→ Installing fastlane..."
        (cd "$PROJECT_ROOT" && "$bundle_cmd" install) || {
            echo "✗ bundle install failed"
            return 1
        }
        echo "  ✓ fastlane installed"
    fi

    echo ""
    echo "=== Certificate Setup ==="
    echo ""
    echo "Fastlane Match will sync signing certificates and"
    echo "provisioning profiles from the shared cert store."
    echo ""

    if [[ -z "${FASTLANE_USER:-}" ]]; then
        read -rp "  Apple ID: " FASTLANE_USER
    fi

    if [[ -z "${FASTLANE_PASSWORD:-}" ]]; then
        read -rsp "  Apple ID password: " FASTLANE_PASSWORD
        echo ""
    fi

    if [[ -z "${MATCH_PASSWORD:-}" ]]; then
        read -rsp "  Match encryption password: " MATCH_PASSWORD
        echo ""
    fi

    echo ""
    echo "→ Syncing certificates..."
    MATCH_PASSWORD="$MATCH_PASSWORD" \
        FASTLANE_USER="$FASTLANE_USER" \
        FASTLANE_PASSWORD="$FASTLANE_PASSWORD" \
        $bundle_cmd exec fastlane match appstore

    echo ""
    echo "  ✓ Certificates synced"
}

# ── Commands ────────────────────────────────────────────────────────

do_setup() {
    local force=false
    for arg in "$@"; do
        [[ "$arg" == "--force" ]] && force=true
    done
    _detect_project_config
    if [[ ! -f "$PROJECT_ROOT/build.properties" ]]; then
        if [[ -f "$SCRIPT_DIR/config/build.properties.example" ]]; then
            cp "$SCRIPT_DIR/config/build.properties.example" "$PROJECT_ROOT/build.properties"
            echo "→ Created build.properties from example."
        fi
    fi
    _load_config

    if ! do_doctor; then
        echo ""
        echo "✗ Prerequisites missing. Install the above and re-run."
        return 1
    fi

    _check_build_tools
    _set_mode_sim
    _validate_sim_target
    _ensure_project
    if [[ -f "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj/project.pbxproj" ]]; then
        echo "Project up to date."
    else
        echo "Project generated."
    fi
    if $force || [[ ! -f "$PROJECT_ROOT/buildServer.json" ]]; then
        (cd "$PROJECT_ROOT" && xcode-build-server config -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME")
        echo "LSP config generated."
    else
        echo "LSP config up to date."
    fi
    if $force; then
        _do_build "clean build"
    else
        _do_build build
    fi
    echo ""
    echo "Setup done. Helix LSP should now resolve Swift symbols."
    echo "Re-running ./build.sh setup is a no-op; use --force to regenerate."

    if [[ "${TOOLKIT_UPLOAD_ENABLED:-false}" == "true" ]]; then
        _fastlane_setup
    else
        echo ""
        echo "ℹ Online features are disabled. To enable:"
        echo "  Run:  ./build.sh configure"
        echo "  Or set flags directly in build.properties."
    fi
}

do_build() {
    _detect_project_config
    do_format
    _check_build_tools
    _set_mode_sim
    _validate_sim_target
    _do_build build
}

do_clean() {
    _detect_project_config
    _check_core_tools
    _set_mode_sim
    _validate_sim_target
    _ensure_project
    echo "Cleaning $PROJECT_NAME for $_TARGET_NAME ($_TARGET_SDK)."
    (cd "$PROJECT_ROOT" && xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME" -sdk "$_TARGET_SDK" \
      -destination "$_TARGET_DEST" -configuration Debug clean 2>&1)
    rm -rf "$PROJECT_ROOT/build"
    rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}-*
    echo "Removed build/ and DerivedData."
}

do_install() {
    _detect_project_config
    do_format
    _check_build_tools
    _select_target "${1:-simulator}"
    _validate_target
    _guard_not_running
    _do_build build
    _launch_app
}

do_uninstall() {
    _detect_project_config
    _check_core_tools
    _select_target "${1:-simulator}"
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -rf "$PROJECT_ROOT/.watch"
        echo "iOS watcher stopped."
    fi
    _terminate_app
    echo "App stopped."
    if [[ "$_TARGET_SDK" == "iphoneos" ]]; then
        if [[ -n "${DEVICE_UDID:-}" ]]; then
            xcrun devicectl device uninstall app --device "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true
            echo "App uninstalled from device."
        else
            echo "✗ Device UDID unknown, cannot uninstall."
        fi
    fi
    if [[ "$_TARGET_SDK" == "iphonesimulator" ]]; then
        xcrun simctl shutdown "$SIM_ID" 2>/dev/null || true
        echo "Simulator stopped."
    fi
}

do_watch() {
    _detect_project_config
    _check_build_tools
    local target="simulator"
    if [[ "${1:-}" == "simulator" || "${1:-}" == "iphone" || "${1:-}" == "device" ]]; then
        target="$1"
        shift
    fi
    _select_target "$target"
    _validate_target
    _require_cmd fswatch "Install with: brew install fswatch"
    _guard_not_running

    local mode="${1:-swift}"

    _do_build "clean build"
    _launch_app

    mkdir -p "$(dirname "$PID_FILE")"
    echo "$$" > "$PID_FILE"
    trap 'rm -rf "$PROJECT_ROOT/.watch"' EXIT

    case "$mode" in
        swift)
            echo "Watching for Swift changes in $PROJECT_ROOT/$SOURCE_DIR/ ..."
            echo ""

            while true; do
                local changed
                changed=$(fswatch --latency 0.5 --one-event "$PROJECT_ROOT/$SOURCE_DIR/" 2>/dev/null || true)
                [[ "$changed" == *\.swift ]] || continue
                echo "[$(date '+%H:%M:%S')] Change: $(basename "$changed") → rebuilding"
                _redeploy || true
                echo "[$(date '+%H:%M:%S')] Done."
                echo ""
                sleep "$WATCH_COOLDOWN"
            done
            ;;
        build)
            local stamp="$PROJECT_ROOT/.watch/build.stamp"
            mkdir -p "$(dirname "$stamp")"
            if [[ ! -f "$stamp" ]]; then
                touch "$stamp"
            fi
            echo "Watching for builds via $stamp ..."
            echo ""

            while true; do
                fswatch --latency 0.5 --one-event "$stamp" >/dev/null 2>&1 || true
                echo "[$(date '+%H:%M:%S')] Build detected → redeploying"
                _terminate_app
                sleep "$REDEPLOY_GAP"
                _install_app || true
                _launch_app
                echo "[$(date '+%H:%M:%S')] Done."
                echo ""
                sleep "$WATCH_COOLDOWN"
            done
            ;;
        *)
            echo "✗ Unknown watch mode: $mode. Use 'swift' or 'build'."
            return 1
            ;;
    esac
}

_require_server() {
    if ! curl -sf "${SERVER_HEALTH_URL:-http://localhost:8080/api/health}" >/dev/null 2>&1; then
        echo >&2 "ERROR: server is not running at ${SERVER_HEALTH_URL:-http://localhost:8080}"
        echo >&2 "Start it with: $SERVER_START_CMD"
        exit 1
    fi
}

do_test() {
    _detect_project_config
    _check_core_tools
    _set_mode_sim
    _validate_sim_target
    _ensure_project
    echo "Testing $PROJECT_NAME on $SIM_NAME ($SIM_OS)."
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        _require_server
    fi

    local test_filter=""
    local test_timeout=$TEST_TIMEOUT
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            test_timeout="$arg"
        else
            test_filter="$arg"
        fi
    done

    echo "  Building tests..."
    (cd "$PROJECT_ROOT" && xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME" -sdk "$_TARGET_SDK" \
      -destination "$_TARGET_DEST" -configuration Debug \
      build-for-testing 2>&1) || return 1

    local test_args=(-project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME" -sdk "$_TARGET_SDK" \
      -destination "$_TARGET_DEST" -configuration Debug test-without-building)

    if [[ -n "$test_filter" ]]; then
        test_args+=(-only-testing "$TEST_TARGET/$test_filter")
        echo "  Running tests filtered by '$test_filter' (timeout: ${test_timeout}s)..."
    else
        echo "  Running tests... (timeout: ${test_timeout}s)"
    fi

    if command -v timeout &>/dev/null; then
        (cd "$PROJECT_ROOT" && timeout "$test_timeout" xcodebuild "${test_args[@]}" 2>&1)
    else
        (cd "$PROJECT_ROOT" && xcodebuild "${test_args[@]}" 2>&1)
    fi
}

# ── Architecture lint gates ──────────────────────────────────────────

do_state_check() {
    local src="$PROJECT_ROOT/$SOURCE_DIR"
    local found=0

    _state_grep() {
        local pattern="$1" msg="$2"
        local matches
        matches=$(grep -rn "$pattern" "$src" --include="*.swift" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            echo ""
            echo "  ✗ $msg"
            while IFS= read -r line; do
                echo "    ${line#$PROJECT_ROOT/}"
            done <<< "$matches"
            found=1
        fi
    }

    _state_grep '@StateObject'     '@StateObject — use the central state class instead'
    _state_grep '@ObservedObject'  '@ObservedObject — use the central state class instead'
    _state_grep '@EnvironmentObject' '@EnvironmentObject — use the central state class instead'
    _state_grep '@Published'       '@Published — use the central state class instead'
    _state_grep 'ObservableObject' 'ObservableObject — convert to @Observable, then use the central state class'

    local state_matches
    state_matches=$(grep -rn '@State' "$src" --include="*.swift" 2>/dev/null | grep -vF "$STATE_EXCLUSION" || true)
    if [[ -n "$state_matches" ]]; then
        echo ""
        echo "  ✗ @State — move to the central state class instead"
        while IFS= read -r line; do
            echo "    ${line#$PROJECT_ROOT/}"
        done <<< "$state_matches"
        found=1
    fi

    if [[ -f "$PROJECT_ROOT/$STATE_FILE_PATH" ]]; then
        local func_matches
        func_matches=$(grep -n 'func ' "$PROJECT_ROOT/$STATE_FILE_PATH" 2>/dev/null | grep -v 'init(' || true)
        if [[ -n "$func_matches" ]]; then
            echo ""
            echo "  ✗ func in $TOOLKIT_STATE_FILE — move to an extension file"
            while IFS= read -r line; do
                echo "    $TOOLKIT_STATE_FILE:$line"
            done <<< "$func_matches"
            found=1
        fi
    fi

    if [[ $found -eq 1 ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  All state must live in the central state class (@Observable)."
        echo "  Views only read state properties and call state handlers."
        echo "  Functions in the state class file must live in extension files."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    echo "✓ State check passed"
}

do_structure_check() {
    do_mark_spacing_check || return 1
    do_section_marker_check || return 1
    do_handler_suffix_check || return 1
    do_try_check || return 1
}

do_try_check() {
    local src="$PROJECT_ROOT/$SOURCE_DIR"
    local violations

    violations=$(grep -rn 'try?' "$src" --include="*.swift" 2>/dev/null | grep -v '[a-zA-Z]try?' | grep -v '// non-actionable:' || true)

    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Unjustified try? — every try? must have a // non-actionable: comment"
        echo "$violations"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  try? swallows errors with no logging."
        echo "  Add // non-actionable: <reason> on the same line, or use do/catch + Log.error."
        echo "  Example: try? FileManager.default.removeItem(at: url) // non-actionable: file cleanup"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    echo "✓ try? justification passed"
}

do_mark_spacing_check() {
    local src="$PROJECT_ROOT/$STATE_DIR"
    local violations=""

    while IFS= read -r line; do
        violations+="  opened brace stuck to MARK: ${line#$PROJECT_ROOT/}"$'\n'
    done < <(grep -rn -A1 '{' "$src" --include="*.swift" 2>/dev/null | grep '// MARK:' || true)

    while IFS= read -r line; do
        violations+="  closed brace stuck to MARK: ${line#$PROJECT_ROOT/}"$'\n'
    done < <(grep -rn -B1 '// MARK:' "$src" --include="*.swift" 2>/dev/null | grep '}$' || true)

    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ MARK comments must have a blank line above and below"
        echo "$violations"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Section markers need blank line padding."
        echo "  Fix: add empty line between brace and // MARK:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    echo "✓ MARK spacing passed"
}

do_section_marker_check() {
    local src="$PROJECT_ROOT/$STATE_DIR"
    local violations=""

    while IFS= read -r file; do
        local markers
        markers=$(grep -n '// MARK:' "$file" 2>/dev/null || true)
        local last_section=""

        while IFS= read -r marker_line; do
            local marker
            marker=$(echo "$marker_line" | sed 's/.*MARK: \?-* *//')
            case "$marker" in
                Queries)       local order=0 ;;
                Handlers)      local order=1 ;;
                Actions)       local order=2 ;;
                Helpers)       local order=3 ;;
                *)             continue ;;
            esac
            if [[ -n "$last_section" ]] && [[ $order -lt $last_section ]]; then
                violations+="  out of order: ${file#$PROJECT_ROOT/}: $marker after $(grep "MARK:.*$last_section" <<< "$markers" | head -1 | sed 's/:.*//')"$'\n'
            fi
            local last_section=$order
        done < <(echo "$markers")

        while IFS= read -r line; do
            violations+="  dash not allowed: ${file#$PROJECT_ROOT/}:$line"$'\n'
        done < <(grep -n '// MARK: -' "$file" 2>/dev/null || true)

        local in_handlers=false
        while IFS= read -r line; do
            [[ "$line" =~ "// MARK: Handlers" ]] && { in_handlers=true; continue; }
            [[ "$line" =~ "// MARK:" ]] && { in_handlers=false; continue; }
            $in_handlers && [[ "$line" =~ "private func" ]] && {
                violations+="  private func in Handlers section: ${file#$PROJECT_ROOT/}: $line"$'\n'
            }
        done < <(grep -n '' "$file" 2>/dev/null)
    done < <(find "$src" -name "${STATE_BASENAME}*.swift" -type f 2>/dev/null)

    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Section marker violations"
        echo "$violations"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Section order: Queries → Handlers → Actions → Helpers"
        echo "  No dashes in MARK comments: // MARK: Handlers (not // MARK: - Handlers)"
        echo "  Private functions belong in Actions, not Handlers"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    echo "✓ Section markers passed"
}

do_handler_suffix_check() {
    local src="$PROJECT_ROOT/$STATE_DIR"
    local approved="Tapped Pressed DoubleTapped LongPressed Swiped Submitted Toggled Selected Appeared Disappeared Dismissed Changed Updated Ended Started Loaded Refreshed Received BecomeActive EnterBackground ResignActive EnterForeground Completed Failed Focused Unfocused Scrolled Prefetched Shown Hidden Triggered"
    local violations=""

    while IFS= read -r handler_name; do
        local matched=false
        for suffix in $approved; do
            [[ "$handler_name" =~ $suffix$ ]] && { matched=true; break; }
        done
        if ! $matched; then
            local location
            location=$(grep -rn "func $handler_name" "$src" --include="*.swift" 2>/dev/null | head -1)
            violations+="  invalid suffix: ${location#$PROJECT_ROOT/}"$'\n'
        fi
    done < <(grep -roh 'func on[A-Z][a-zA-Z]*' "$src" --include="*.swift" 2>/dev/null | sed 's/func //' | sort -u)

    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Handler suffix violations — must end with an approved event word"
        echo "$violations"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Approved suffixes: $approved"
        echo "  Handler names must use: on<Subject><ApprovedSuffix>"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
    fi
    echo "✓ Handler suffixes passed"
}

do_lint() {
    _require_cmd swiftlint "Install with: brew install swiftlint"
    local output
    local lint_args=(--strict --quiet)
    if [[ -n "$SWIFTLINT_CONFIG" ]]; then
        lint_args+=(--config "$SWIFTLINT_CONFIG")
    fi
    output=$(cd "$PROJECT_ROOT" && swiftlint "${lint_args[@]}" 2>&1) || true
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] || echo "$output" | grep -qi "warning:"; then
        echo "✗ Lint failed:"
        [[ -n "$output" ]] && echo "$output"
        echo "✗ Lint failed — fix violations before building."
        return 1
    fi
    echo "✓ Lint passed"

    if [[ "${TOOLKIT_ARCH_CHECKS:-true}" == "true" ]]; then
        do_state_check || return 1
        do_structure_check || return 1
    else
        do_try_check || return 1
    fi
}

do_format_check() {
    _require_cmd swiftformat "Install with: brew install swiftformat"
    local log
    log=$(mktemp)
    if (cd "$PROJECT_ROOT" && swiftformat --lint "$SOURCE_DIR/" > "$log" 2>&1); then
        rm -f "$log"
        echo "✓ Format check passed"
    else
        echo "✗ Format check failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_format() {
    _require_cmd swiftformat "Install with: brew install swiftformat"
    local log
    log=$(mktemp)
    if (cd "$PROJECT_ROOT" && swiftformat "$SOURCE_DIR/" > "$log" 2>&1); then
        rm -f "$log"
        echo "✓ Format passed"
    else
        echo "✗ Format failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_unused() {
    _require_cmd periphery "Install with: brew install periphery"
    _ensure_project
    local log
    log=$(mktemp)
    local periphery_args=(scan)
    if [[ -n "$PERIPHERY_CONFIG" ]]; then
        periphery_args+=(--config "$PERIPHERY_CONFIG")
    fi
    periphery_args+=(--project "$PROJECT_NAME.xcodeproj" --schemes "$SCHEME_NAME")
    if (cd "$PROJECT_ROOT" && periphery "${periphery_args[@]}" > "$log" 2>&1); then
        rm -f "$log"
        echo "✓ Unused code: none"
    else
        echo "✗ Unused code scan failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_analyze() {
    _select_target "${1:-simulator}"
    _validate_target
    _ensure_project
    local log
    log=$(mktemp)
    if (cd "$PROJECT_ROOT" && xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME" -sdk "$_TARGET_SDK" \
      -destination "$_TARGET_DEST" analyze -quiet > "$log" 2>&1); then
        rm -f "$log"
        echo "✓ Analyze passed"
    else
        echo "✗ Analyze failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_audit() {
    do_lint || true
    do_format_check || true

    if command -v periphery &>/dev/null; then
        do_unused || true
    fi

    do_analyze || true

    echo "✓ Audit complete"
}

do_doctor() {
    local failed=0

    echo "iOS build environment:"
    for cmd in xcrun xcodebuild xcodegen xcode-build-server fswatch jq swiftlint swiftformat; do
        if command -v "$cmd" &>/dev/null; then
            echo "  ✓ $cmd: $(command -v "$cmd")"
        else
            case "$cmd" in
                swiftlint|swiftformat) echo "  ⚠ $cmd: missing (optional, lint/format disabled)" ;;
                fswatch) echo "  ⚠ $cmd: missing (optional, watch disabled)" ;;
                jq) echo "  ⚠ $cmd: missing (optional, some commands need it)" ;;
                *) echo "  ✗ $cmd: missing"; failed=1 ;;
            esac
        fi
    done

    if [[ "${TOOLKIT_UPLOAD_ENABLED:-false}" == "true" ]]; then
        echo ""
        echo "Fastlane environment:"
        local brew_ruby_prefix
        brew_ruby_prefix=$(brew --prefix ruby 2>/dev/null || true)
        local ruby_cmd bundle_cmd
        if [[ -n "$brew_ruby_prefix" ]]; then
            ruby_cmd="$brew_ruby_prefix/bin/ruby"
            bundle_cmd="$brew_ruby_prefix/bin/bundle"
        else
            ruby_cmd="ruby"
            bundle_cmd="bundle"
        fi

        if command -v "$ruby_cmd" &>/dev/null; then
            echo "  ✓ ruby: $($ruby_cmd --version 2>&1 | head -1)"
        else
            echo "  ✗ ruby: missing (install with: brew install ruby)"
            failed=1
        fi

        if command -v "$bundle_cmd" &>/dev/null; then
            echo "  ✓ bundler: $($bundle_cmd --version 2>&1 | head -1)"
        else
            echo "  ✗ bundler: missing (comes with brew ruby)"
            failed=1
        fi

        if [[ -f "$PROJECT_ROOT/Gemfile.lock" ]]; then
            if (cd "$PROJECT_ROOT" && "$bundle_cmd" check &>/dev/null); then
                echo "  ✓ fastlane: installed"
            else
                echo "  ✗ fastlane: gems missing (run: bundle install)"
                failed=1
            fi
        else
            echo "  ⚠ fastlane: no Gemfile.lock (upload setup will install)"
        fi
    fi

    echo ""
    if [[ -n "$SIM_NAME" && -n "$SIM_ID" && -n "$SIM_OS" ]]; then
        echo "  ✓ Simulator: $SIM_NAME ($SIM_OS, $SIM_ID)"
    else
        echo "  ✗ Simulator: no available iPhone simulator detected"
        failed=1
    fi

    local device_info device_count
    device_info=$(xcrun devicectl list devices 2>/dev/null | grep -v "Name\|^--" || true)
    device_count=$(echo "$device_info" | grep -c . || true)
    if [[ "$device_count" -eq 1 ]]; then
        local dev_udid dev_name
        dev_udid=$(echo "$device_info" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)
        dev_name=$(echo "$device_info" | sed -E "s/ *${dev_udid}.*//" | sed 's/^ *//;s/ *$//' | sed -E 's/ +[^ ]+\.coredevice\.local//')
        echo "  ✓ Device: $dev_name ($dev_udid)"
    elif [[ "$device_count" -gt 1 ]]; then
        echo "  ℹ $device_count devices detected — use --device or IOS_DEVICE to select one"
    else
        echo "  ℹ Device: none detected"
    fi

    if [[ -f "$PROJECT_ROOT/project.yml" ]]; then
        echo "  ✓ project.yml present"
    else
        echo "  ✗ project.yml missing"
        failed=1
    fi

    if [[ -f "$PROJECT_ROOT/$PROJECT_NAME.xcodeproj/project.pbxproj" ]]; then
        echo "  ✓ $PROJECT_NAME.xcodeproj present"
    else
        echo "  ℹ $PROJECT_NAME.xcodeproj missing; setup/build will generate it"
    fi

    return "$failed"
}

# ── Toolkit sync ─────────────────────────────────────────────────────

do_pull() {
    _detect_project_config
    local root="$PROJECT_ROOT" mount=""
    for _ in 1 2 3 4 5; do
        if [[ -f "$root/.gitmodules" ]]; then
            mount=$(git -C "$root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | head -1 | awk '{print $2}')
            break
        fi
        root="$(dirname "$root")"
    done
    mount="${mount:-toolkit}"
    local tool_dir="$root/$mount"
    if [[ ! -e "$tool_dir/.git" ]]; then
        echo "✗ No toolkit mount found at $tool_dir (not a git submodule?)."
        return 1
    fi
    local before after
    before=$(git -C "$tool_dir" rev-parse --short HEAD 2>/dev/null || echo "none")
    echo "→ Syncing toolkit ($mount) ..."
    GIT_ALLOW_PROTOCOL=file git -C "$root" submodule update --remote "$mount" 2>&1 | tail -2
    after=$(git -C "$tool_dir" rev-parse --short HEAD 2>/dev/null || echo "none")
    if [[ "$before" != "$after" ]]; then
        echo "✓ toolkit synced: $before → $after"
        echo "  The new submodule commit is staged in the superproject; commit it when ready."
    else
        echo "✓ toolkit already up to date ($before)"
    fi
}

# ── External services configuration ─────────────────────────────────

_config_set() {
    local key="$1" value="$2"
    local props="$PROJECT_ROOT/build.properties"
    if [[ ! -f "$props" ]]; then
        cp "$SCRIPT_DIR/config/build.properties.example" "$props"
    fi
    if grep -q "^${key}=" "$props"; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$props"
    else
        echo "${key}=${value}" >> "$props"
    fi
    export "$key=$value"
}

_configure_sentry() {
    echo ""
    echo "Sentry"
    if [[ "${TOOLKIT_SENTRY_ENABLED:-false}" == "true" && -n "${SENTRY_ORG:-}" && -n "${IOS_SENTRY_PROJECT:-}" ]]; then
        echo "  ✓ already configured (org: $SENTRY_ORG, project: $IOS_SENTRY_PROJECT)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "  ℹ not configured (non-interactive — run './build.sh configure' in a terminal)"
        return 0
    fi
    read -rp "  Enable Sentry error tracking? [y/N]: " enable
    if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
        read -rp "  Sentry org slug: " org
        read -rp "  Sentry project slug: " project
        _config_set TOOLKIT_SENTRY_ENABLED true
        _config_set SENTRY_ORG "$org"
        _config_set IOS_SENTRY_PROJECT "$project"
        echo "  ✓ Sentry enabled (auth token: export SENTRY_AUTH_TOKEN or add ~/.sentryclirc)"
    fi
}

_configure_server() {
    echo ""
    echo "Local server"
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        echo "  ✓ already enabled"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "  ℹ not enabled (non-interactive)"
        return 0
    fi
    read -rp "  Does this project need a local server (API_BASE_URL + test health gate)? [y/N]: " enable
    if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
        _config_set TOOLKIT_SERVER_ENABLED true
        echo "  ✓ server mode enabled"
    fi
}

_configure_e2e() {
    echo ""
    echo "E2E tests"
    if [[ "${TOOLKIT_E2E_ENABLED:-false}" == "true" ]]; then
        echo "  ✓ already enabled (scheme: ${E2E_SCHEME:-${PROJECT_NAME}E2E})"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "  ℹ not enabled (non-interactive)"
        return 0
    fi
    read -rp "  Enable UI tests against a server (e2e/e2e-run)? [y/N]: " enable
    if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
        read -rp "  Base URL [http://localhost:8080]: " base_url
        read -rp "  Server start command (empty to skip auto-start): " start_cmd
        read -rp "  Server stop command (empty to skip): " stop_cmd
        _config_set TOOLKIT_E2E_ENABLED true
        _config_set E2E_BASE_URL "${base_url:-http://localhost:8080}"
        [[ -n "$start_cmd" ]] && _config_set SERVER_START_CMD "$start_cmd"
        [[ -n "$stop_cmd" ]] && _config_set SERVER_STOP_CMD "$stop_cmd"
        echo "  ✓ e2e enabled"
    fi
}

_configure_upload() {
    echo ""
    echo "TestFlight upload"
    local key_path="${IOS_KEY_PATH:-$PROJECT_ROOT/AuthKey.p8}"
    if [[ "${TOOLKIT_UPLOAD_ENABLED:-false}" == "true" && -n "${IOS_KEY_ID:-}" && -n "${IOS_ISSUER_ID:-}" && -f "$key_path" ]]; then
        echo "  ✓ already configured (key: $key_path)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "  ℹ not configured (non-interactive)"
        return 0
    fi
    read -rp "  Enable TestFlight upload? [y/N]: " enable
    if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
        read -rp "  App Store Connect key ID: " key_id
        read -rp "  Issuer ID: " issuer_id
        read -rp "  Path to AuthKey.p8 [$key_path]: " path
        _config_set TOOLKIT_UPLOAD_ENABLED true
        _config_set IOS_KEY_ID "$key_id"
        _config_set IOS_ISSUER_ID "$issuer_id"
        [[ -n "$path" ]] && _config_set IOS_KEY_PATH "$path"
        echo "  ✓ upload enabled (run './build.sh setup' to install fastlane)"
    fi
}

do_configure() {
    _detect_project_config
    echo "=== External services (idempotent — already-configured items are skipped) ==="
    _configure_sentry
    _configure_server
    _configure_e2e
    _configure_upload
    echo ""
    echo "✓ Configure done. Changed values are written to build.properties."
}

# ── Log inspection ───────────────────────────────────────────────────

_level_grep() {
    case "${1:-}" in
        info)    grep -v "  DEBUG " || true ;;
        warning) grep -v -E "  (DEBUG|INFO) " || true ;;
        error)   grep -E "  (WARNING|ERROR) " || true ;;
        *)       cat ;;
    esac
}

_ios_logs() {
    _detect_project_config
    if [[ "${TOOLKIT_LOGS_ENABLED:-true}" != "true" ]]; then
        echo "✗ Logs disabled. Set TOOLKIT_LOGS_ENABLED=true in build.properties."
        return 1
    fi
    _select_target "${1:-simulator}"
    local cat_filter=""
    local level_filter=""
    local cmd=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cat) cat_filter="${2:-}"; shift 2 ;;
            --level) level_filter="${2:-}"; shift 2 ;;
            *) cmd="$1"; shift ;;
        esac
    done
    if [[ -z "$cmd" ]]; then
        cmd=10
    fi

    case "$cmd" in
        tail)
            case "$_TARGET_SDK" in
                iphoneos)
                    _require_cmd idevicesyslog "Install with: brew install libimobiledevice"
                    if [[ -n "$cat_filter" ]]; then
                        echo "→ Streaming device logs (filter: $cat_filter, Ctrl-C to stop)..."
                        idevicesyslog 2>/dev/null | grep --line-buffered "$APP_EXECUTABLE" | grep -F --line-buffered "[${cat_filter}]" | while IFS= read -r line; do echo "$line" | sed -E 's/^[A-Z][a-z]{2} [0-9]+ ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) .*<[^>]+>: /\1  /'; done | _level_grep "$level_filter"
                    else
                        echo "→ Streaming device logs (Ctrl-C to stop)..."
                        idevicesyslog 2>/dev/null | grep --line-buffered "$APP_EXECUTABLE" | while IFS= read -r line; do echo "$line" | sed -E 's/^[A-Z][a-z]{2} [0-9]+ ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) .*<[^>]+>: /\1  /'; done | _level_grep "$level_filter"
                    fi
                    ;;
                iphonesimulator)
                    if [[ -n "$cat_filter" ]]; then
                        echo "→ Streaming sim logs (filter: $cat_filter, Ctrl-C to stop)..."
                        log stream --predicate "process == \"$APP_EXECUTABLE\"" --style compact 2>/dev/null | grep -F --line-buffered "[${cat_filter}]" | while IFS= read -r line; do echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /'; done | _level_grep "$level_filter"
                    else
                        echo "→ Streaming sim logs (Ctrl-C to stop)..."
                        log stream --predicate "process == \"$APP_EXECUTABLE\"" --style compact 2>/dev/null | while IFS= read -r line; do echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /'; done | _level_grep "$level_filter"
                    fi
                    ;;
            esac
            ;;
        *)
            local lines="$cmd"
            if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
                lines=10
            fi
            case "$_TARGET_SDK" in
                iphoneos)
                    if [[ -n "${DEVICE_UDID:-}" ]]; then
                        local desc="Collecting device logs"
                        if [[ -n "$cat_filter" ]]; then
                            desc="Collecting device logs (filter: $cat_filter)"
                        fi
                        echo "→ ${desc} (last ${lines} lines)..."
                        local archive=/tmp/${PROJECT_NAME}-device-$$.logarchive
                        log collect --device-udid "$DEVICE_UDID" --last 2m --output "$archive"
                        if [[ -d "$archive" ]]; then
                            if [[ -n "$cat_filter" ]]; then
                                log show "$archive" --predicate "process == \"$APP_EXECUTABLE\"" --style compact 2>/dev/null | grep -F "[${cat_filter}]" | tail -n "$lines" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /' | _level_grep "$level_filter"
                            else
                                log show "$archive" --predicate "process == \"$APP_EXECUTABLE\"" --style compact 2>/dev/null | tail -n "$lines" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /' | _level_grep "$level_filter"
                            fi
                            rm -rf "$archive"
                        else
                            echo "  (log collect failed — see error above)"
                        fi
                    else
                        echo "✗ No device UDID found."
                        return 1
                    fi
                    ;;
                iphonesimulator)
                    local desc="Last $lines sim logs"
                    if [[ -n "$cat_filter" ]]; then
                        desc="Last $lines sim logs (filter: $cat_filter)"
                    fi
                    echo "→ ${desc}:"
                    if [[ -n "$cat_filter" ]]; then
                        log show --predicate "process == \"$APP_EXECUTABLE\"" --style compact --last 2m 2>/dev/null | grep -F "[${cat_filter}]" | tail -n "$lines" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /' | _level_grep "$level_filter"
                    else
                        log show --predicate "process == \"$APP_EXECUTABLE\"" --style compact --last 2m 2>/dev/null | tail -n "$lines" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /' | _level_grep "$level_filter"
                    fi
                    ;;
            esac
            ;;
    esac
}

# ── Debug session ────────────────────────────────────────────────────

_clear_scriptor_marker() {
    local marker="${DEBUG_MARKER_NAME:-scriptor-ready}"
    case "$_TARGET_SDK" in
        iphoneos) ;; # marker overwritten on write, host app cleans up after read
        iphonesimulator)
            local data_dir
            data_dir=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data 2>/dev/null || true)
            [[ -n "$data_dir" ]] && rm -f "$data_dir/Library/Caches/$marker"
            ;;
    esac
}

_write_scriptor_marker() {
    local marker="${DEBUG_MARKER_NAME:-scriptor-ready}"
    case "$_TARGET_SDK" in
        iphoneos)
            echo "ready" > "$PROJECT_ROOT/.watch/marker"
            xcrun devicectl device copy to \
                --device "$DEVICE_UDID" \
                --source "$PROJECT_ROOT/.watch/marker" \
                --destination "Library/Caches/$marker" \
                --domain-type appDataContainer \
                --domain-identifier "$BUNDLE_ID" 2>/dev/null || true
            rm -f "$PROJECT_ROOT/.watch/marker"
            ;;
        iphonesimulator)
            local data_dir
            data_dir=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data 2>/dev/null || true)
            [[ -n "$data_dir" ]] && touch "$data_dir/Library/Caches/$marker"
            ;;
    esac
}

_ios_debug() {
    _detect_project_config
    if [[ "${TOOLKIT_LOGS_ENABLED:-true}" != "true" ]]; then
        echo "✗ Logs disabled. Set TOOLKIT_LOGS_ENABLED=true in build.properties."
        return 1
    fi
    _select_target "${1:-simulator}"
    local cat_filter=""
    local level_filter=""
    local script_names=""
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --cat) cat_filter="${2:-}"; shift 2 ;;
            --level) level_filter="${2:-}"; shift 2 ;;
            --script) script_names="${2:-}"; shift 2 ;;
            *) echo "⚠ Unknown flag: $1" >&2; shift ;;
        esac
    done
    if [[ -n "$script_names" && "${TOOLKIT_DEBUG_SCRIPTS:-false}" != "true" ]]; then
        echo "⚠ --script ignored: set TOOLKIT_DEBUG_SCRIPTS=true in build.properties to enable debug scripts."
        script_names=""
    fi
    local debug_dir="${TOOLKIT_DEBUG_SCRIPT_DIR:-debug}"
    if [[ -n "$script_names" && -d "$PROJECT_ROOT/$debug_dir" ]]; then
        cat > "$PROJECT_ROOT/$debug_dir/config.swift" << EOF
#if DEBUG
enum DebugScriptConfig {
    static let names = "$script_names"
}
#endif
EOF
        _clear_scriptor_marker
    fi
    case "$_TARGET_SDK" in
        iphoneos)
            _require_cmd idevicesyslog "Install with: brew install libimobiledevice"
            do_install
            if [[ -n "$script_names" ]]; then
                _write_scriptor_marker
            fi
            local tmpfile fifo syslog_pid pipe_pid
            tmpfile=$(mktemp)
            fifo=$(mktemp -u)
            mkfifo "$fifo"
            idevicesyslog 2>/dev/null > "$tmpfile" &
            syslog_pid=$!
            local waited=0
            while [[ $waited -lt 5 ]]; do
                [[ -s "$tmpfile" ]] && break
                sleep 0.5
                ((waited++))
            done
            if [[ ! -s "$tmpfile" ]]; then
                echo ""
                echo "✗ No log data from device. Is it connected and unlocked?"
                kill "$syslog_pid" 2>/dev/null
                rm -f "$fifo" "$tmpfile" 2>/dev/null || true
                return 1
            fi
            echo ""
            if [[ -n "$cat_filter" ]]; then
                echo "→ Debug session started (filter: $cat_filter). Go to home screen to stop."
            else
                echo "→ Debug session started. Go to home screen to stop."
            fi
            echo ""
            tail -n 0 -f "$tmpfile" | grep --line-buffered "$APP_EXECUTABLE" > "$fifo" &
            pipe_pid=$!
            while IFS= read -r line; do
                if [[ -z "$cat_filter" ]] || [[ "$line" == *"[${cat_filter}]"* ]] || [[ "$line" == *"DEBUG_SESSION_ENDED"* ]]; then
                    formatted=$(echo "$line" | sed -E 's/^[A-Z][a-z]{2} [0-9]+ ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) .*<[^>]+>: /\1  /')
                    if [[ -n "$level_filter" ]]; then
                        level_token="${formatted#*  }"
                        level_token="${level_token%% *}"
                        case "$level_filter" in
                            info)    [[ "$level_token" != "DEBUG" ]] && echo "$formatted" ;;
                            warning) [[ "$level_token" != "DEBUG" && "$level_token" != "INFO" ]] && echo "$formatted" ;;
                            error)   [[ "$level_token" == "WARNING" || "$level_token" == "ERROR" ]] && echo "$formatted" ;;
                        esac
                    else
                        echo "$formatted"
                    fi
                fi
                if [[ "$line" == *"DEBUG_SESSION_ENDED"* ]]; then
                    break
                fi
            done < "$fifo"
            kill -9 "$pipe_pid" 2>/dev/null; { wait "$pipe_pid"; } 2>/dev/null || true
            kill -9 "$syslog_pid" 2>/dev/null; { wait "$syslog_pid"; } 2>/dev/null || true
            rm -f "$fifo" "$tmpfile" 2>/dev/null || true
            ;;
        iphonesimulator)
            do_install
            if [[ -n "$script_names" ]]; then
                _write_scriptor_marker
            fi
            echo ""
            if [[ -n "$cat_filter" ]]; then
                echo "→ Debug session started (filter: $cat_filter). Go to home screen to stop."
            else
                echo "→ Debug session started. Go to home screen to stop."
            fi
            echo ""
            local fifo pipe_pid
            fifo=$(mktemp -u)
            mkfifo "$fifo"
            log stream --predicate "process == \"$APP_EXECUTABLE\"" --style compact 2>/dev/null > "$fifo" &
            pipe_pid=$!
            while IFS= read -r line; do
                if [[ -z "$cat_filter" ]] || [[ "$line" == *"[${cat_filter}]"* ]] || [[ "$line" == *"DEBUG_SESSION_ENDED"* ]]; then
                    formatted=$(echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) [^ ]+ [^ ]+ <[^>]+>: /\1  /')
                    if [[ -n "$level_filter" ]]; then
                        level_token="${formatted#*  }"
                        level_token="${level_token%% *}"
                        case "$level_filter" in
                            info)    [[ "$level_token" != "DEBUG" ]] && echo "$formatted" ;;
                            warning) [[ "$level_token" != "DEBUG" && "$level_token" != "INFO" ]] && echo "$formatted" ;;
                            error)   [[ "$level_token" == "WARNING" || "$level_token" == "ERROR" ]] && echo "$formatted" ;;
                        esac
                    else
                        echo "$formatted"
                    fi
                fi
                if [[ "$line" == *"DEBUG_SESSION_ENDED"* ]]; then
                    break
                fi
            done < "$fifo"
            kill -9 "$pipe_pid" 2>/dev/null; { wait "$pipe_pid"; } 2>/dev/null || true
            rm -f "$fifo" 2>/dev/null || true
            ;;
    esac
    echo ""
    echo "✓ App backgrounded — session ended."
}

# ── Dispatch ────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: ./build.sh [device] [--device <name|udid>] <command> [<args>]

  Local dev:
    setup              First-time setup: config + generate + build + LSP config (sim only)
    pull               Sync the toolkit submodule to the latest version
    configure          Enable/configure external services (Sentry, upload, e2e, server) — idempotent
    build              Lint → format → incremental build
    clean              Clean build artifacts
    install [iphone]   Build + launch (default simulator; pass 'iphone' for device)
    uninstall [iphone] Stop watcher + app + uninstall (default simulator; 'iphone' for device)
    watch [iphone] [mode]  Build + launch + auto-redeploy (mode: swift|build, default: swift)
    test [filter] [timeout]   Run unit tests; filter by class name, timeout in seconds (default $TEST_TIMEOUT)
    lint               Run SwiftLint on all Swift sources
    format             Auto-format all Swift sources with SwiftFormat
    unused             Scan for unused code with Periphery
    analyze            Run Xcode static analyzer (memory, logic, dead stores)
    audit              Run all analysis tools: lint + format-check + unused + analyze
    doctor             Check local build prerequisites
    logs [--cat <cat>] [--level <level>] [N]  Show last N lines (default 10)
    logs [--cat <cat>] [--level <level>] tail  Stream live app logs
    debug [--cat <cat>] [--level <level>]  Build, launch, and trace logs (auto-stop on background)

  Online (enable via setup / build.properties):
    e2e              Run UI tests against a configured server (TOOLKIT_E2E_ENABLED)
    e2e-run          Run built e2e tests without rebuilding (TOOLKIT_E2E_ENABLED)
    upload [--force] <text>
                       Build, sign, upload to TestFlight (TOOLKIT_UPLOAD_ENABLED)
    sentry <cmd>     Sentry queries (TOOLKIT_SENTRY_ENABLED)

Options:
    --device, -d <name|udid>   Target a specific device by name substring or UDID.
                               When multiple devices are connected, this is required.
                               Example: ./build.sh --device "iPhone 15" install

    IOS_DEVICE=<name|udid>     Environment variable fallback for --device.
                               Set once to always target the same device.
                               Example: export IOS_DEVICE="iPhone 15"

Prefix with 'device' to force physical device target (uses network
or USB). Without 'device', install/uninstall/watch default to the
simulator; pass 'iphone' to target the physical device.
EOF
}

_dispatch() {
    local _NEW_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device|-d)
                shift
                if [[ -z "${1:-}" || "${1:0:1}" == "-" ]]; then
                    echo "✗ --device requires a device name or UDID"
                    exit 1
                fi
                _DEVICE_SELECTOR="$1"
                _DEVICE_FORCED=true
                shift
                ;;
            *)
                _NEW_ARGS+=("$1")
                shift
                ;;
        esac
    done
    if [[ ${#_NEW_ARGS[@]} -gt 0 ]]; then
        set -- "${_NEW_ARGS[@]}"
    else
        set --
    fi

    if [[ -z "$_DEVICE_SELECTOR" && -n "${IOS_DEVICE:-}" ]]; then
        _DEVICE_SELECTOR="$IOS_DEVICE"
        _DEVICE_FORCED=true
    fi

    _detect_project_config

    case "${1:-}" in
        device)
            shift
            _DEVICE_FORCED=true
            case "${1:-}" in
                build)     do_build ;;
                clean)     do_clean ;;
                install)   shift; do_install "$@" ;;
                uninstall) shift; do_uninstall "$@" ;;
                watch)     shift; do_watch "$@" ;;
                e2e)       do_e2e false ;;
                e2e-run)   do_e2e true ;;
                sentry)    shift; _dispatch_sentry "$@" ;;
                pull)      do_pull ;;
                configure) do_configure ;;
                doctor)    do_doctor ;;
                lint)      do_lint ;;
                format)    do_format ;;
                unused)    do_unused ;;
                analyze)   do_analyze ;;
                audit)     do_audit ;;
                logs)      shift; _ios_logs "$@" ;;
                debug)     shift; _ios_debug "$@" ; exit 0 ;;
                *)         usage ;;
            esac
            ;;
        setup)    do_setup ;;
        build)    do_build ;;
        clean)    do_clean ;;
        install)  shift; do_install "$@" ;;
        uninstall) shift; do_uninstall "$@" ;;
        watch)    shift; do_watch "$@" ;;
        test)     shift; do_test "$@" ;;
        e2e)      do_e2e false ;;
        e2e-run)  do_e2e true ;;
        sentry)   shift; _dispatch_sentry "$@" ;;
        upload)   shift; do_upload "$@" ;;
        pull)     do_pull ;;
        configure) do_configure ;;
        doctor)   do_doctor ;;
        lint)     do_lint ;;
        format)   do_format ;;
        unused)   do_unused ;;
        analyze)  do_analyze ;;
        audit)    do_audit ;;
        logs)     shift; _ios_logs "$@" ;;
        debug)    shift; _ios_debug "$@" ; exit 0 ;;
        *)        usage ;;
    esac
}

_dispatch_sentry() {
    if [[ "${TOOLKIT_SENTRY_ENABLED:-false}" != "true" || -z "${SENTRY_ORG:-}" ]]; then
        echo "✗ Sentry not configured. Set TOOLKIT_SENTRY_ENABLED=true, SENTRY_ORG, and IOS_SENTRY_PROJECT in build.properties."
        return 1
    fi
    _sentry_dispatch "$IOS_SENTRY_PROJECT" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _dispatch "$@"
fi
