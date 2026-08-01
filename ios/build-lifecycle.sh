# ios-toolkit/build-lifecycle.sh — generic app process/install/launch/redeploy
# Provides: _app_running, _wait_for_app, _terminate_app, _install_app, _launch_app, _redeploy
# Depends on: BUNDLE_ID, APP_EXECUTABLE, SIM_ID, SIM_NAME (build.sh)
# Depends on: _TARGET_SDK, _TARGET_NAME, _TARGET_DEST, DEVICE_UDID (build.sh)
# Depends on: _find_app, _do_build (build.sh)
# Depends on: LAUNCH_POLL_INTERVAL, LAUNCH_TIMEOUT_TICKS, REDEPLOY_GAP (build.sh)

# ── Unified process checks ──────────────────────────────────────────

_app_running() {
    case "$_TARGET_SDK" in
        iphonesimulator)
            xcrun simctl listapps booted 2>/dev/null | grep -q "$BUNDLE_ID"
            ;;
        iphoneos)
            [[ -z "${DEVICE_UDID:-}" ]] && return 1
            xcrun devicectl device info processes --device "$DEVICE_UDID" 2>/dev/null \
                | grep -q "${APP_EXECUTABLE}.app/$APP_EXECUTABLE"
            ;;
    esac
}

_wait_for_app() {
    if [[ -z "${DEVICE_UDID:-}" && "$_TARGET_SDK" == "iphoneos" ]]; then
        echo "  Device UDID unknown, skipping launch check."
        return 0
    fi
    local waited=0
    while [[ $waited -lt $LAUNCH_TIMEOUT_TICKS ]]; do
        if _app_running; then
            echo "  App running on $_TARGET_NAME."
            return 0
        fi
        sleep "$LAUNCH_POLL_INTERVAL"
        waited=$((waited + 1))
    done
    echo "  App may still be launching on $_TARGET_NAME (timed out)."
    return 0
}

_terminate_app() {
    case "$_TARGET_SDK" in
        iphonesimulator)
            xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
            ;;
        iphoneos)
            [[ -z "${DEVICE_UDID:-}" ]] && return
            local pid
            pid=$(xcrun devicectl device info processes --device "$DEVICE_UDID" 2>/dev/null \
                | grep "${APP_EXECUTABLE}.app/$APP_EXECUTABLE" | head -1 | awk '{print $1}' || true)
            [[ -n "$pid" ]] && xcrun devicectl device process terminate --device "$DEVICE_UDID" --pid "$pid" 2>/dev/null || true
            ;;
    esac
}

# ── Unified install ─────────────────────────────────────────────────

_install_app() {
    local app_path
    app_path=$(_find_app)
    if [[ -z "$app_path" ]]; then
        echo "✗ Could not find ${APP_EXECUTABLE}.app. Build first."
        return 1
    fi

    case "$_TARGET_SDK" in
        iphonesimulator)
            xcrun simctl install "$SIM_ID" "$app_path" 2>/dev/null || true
            ;;
        iphoneos)
            [[ -z "${DEVICE_UDID:-}" ]] && { echo "✗ Device UDID unknown."; return 1; }
            echo "→ Installing on $_TARGET_NAME"
            local out
            out=$(xcrun devicectl device install app --device "$DEVICE_UDID" "$app_path" 2>&1)
            if echo "$out" | grep -q "App installed"; then
                echo "✓ Installed"
            else
                echo "✗ Install failed:"
                echo "$out" | tail -5
                return 1
            fi
            ;;
    esac
}

# ── Unified launch ──────────────────────────────────────────────────

_launch_app() {
    echo "→ Launching on $_TARGET_NAME"
    local out
    case "$_TARGET_SDK" in
        iphonesimulator)
            if ! xcrun simctl list devices booted | grep -q "$SIM_ID"; then
                xcrun simctl boot "$SIM_ID"
            fi
            _install_app
            if [[ $# -gt 0 ]]; then
                xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" "$@" > /dev/null
            else
                xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" > /dev/null
            fi
            open -a Simulator
            ;;
        iphoneos)
            [[ -z "${DEVICE_UDID:-}" ]] && { echo "✗ Device UDID unknown."; return 1; }
            _install_app || return 1
            local launch_status
            set +e
            if [[ $# -gt 0 ]]; then
                out=$(xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" -- "$@" 2>&1)
            else
                out=$(xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1)
            fi
            launch_status=$?
            set -e
            if [[ $launch_status -eq 0 ]] && echo "$out" | grep -q "Launched application"; then
                echo "✓ Launched"
            else
                echo "✗ Launch failed:"
                echo "$out" | tail -5
                return 1
            fi
            ;;
    esac
    _wait_for_app
}

# ── Unified redeploy ────────────────────────────────────────────────

_redeploy() {
    _terminate_app
    sleep "$REDEPLOY_GAP"
    if _do_build build; then
        _install_app || return 1
        _launch_app
    else
        return 1
    fi
}
