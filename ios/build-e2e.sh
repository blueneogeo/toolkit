# ios-toolkit/build-e2e.sh — generic UI test runner (gated by TOOLKIT_E2E_ENABLED)
# Provides: do_e2e
# Depends on: PROJECT_NAME, SCHEME_NAME, BUNDLE_ID, TOOLKIT_E2E_ENABLED, E2E_SCHEME (config)
# Depends on: _check_core_tools, _set_mode_sim, _set_mode_device, _detect_device,
#             _validate_target, _ensure_project, _guard_not_running, _DEVICE_FORCED,
#             _TARGET_SDK, _TARGET_DEST, _TARGET_NAME, _BUILD_EXTRA (build.sh)
# Depends on: _require_cmd (shared/build-utils.sh)
# Optional: E2E_SCHEME (default ${PROJECT_NAME}E2E), SERVER_START_CMD, E2E_SEED_SCRIPT,
#           E2E_ENV_<NAME>="value" environment passthrough

_require_e2e() {
    if [[ "${TOOLKIT_E2E_ENABLED:-false}" != "true" ]]; then
        echo "✗ E2E not configured for this project."
        echo "  Set TOOLKIT_E2E_ENABLED=true in build.properties to enable."
        return 1
    fi
}

do_e2e() {
    _require_e2e || return 1
    local skip_build="${1:-false}"
    _check_core_tools
    if $_DEVICE_FORCED; then
        if ! _detect_device; then
            echo "✗ Could not detect a physical iOS device."
            return 1
        fi
        _set_mode_device
    else
        _set_mode_sim
    fi
    _validate_target
    _ensure_project

    local e2e_scheme="${E2E_SCHEME:-${PROJECT_NAME}E2E}"
    local base_url="${E2E_BASE_URL:-}"
    local started_server=false

    if [[ -n "$base_url" && -n "${SERVER_START_CMD:-}" ]]; then
        if ! curl -fsS "$base_url/api/ping" >/dev/null 2>&1; then
            echo "→ Starting local server..."
            eval "$SERVER_START_CMD"
            started_server=true
            sleep 1
        fi
    fi

    cleanup_e2e() {
        if [[ "$started_server" == true && -n "${SERVER_STOP_CMD:-}" ]]; then
            eval "$SERVER_STOP_CMD" >/dev/null 2>&1 || true
        fi
    }
    if [[ "$started_server" == true ]]; then
        trap cleanup_e2e EXIT
    fi

    if [[ -n "${E2E_SEED_SCRIPT:-}" && -x "$PROJECT_ROOT/$E2E_SEED_SCRIPT" ]]; then
        echo "→ Preparing e2e seed data..."
        "$PROJECT_ROOT/$E2E_SEED_SCRIPT" "$base_url"
    fi

    local e2e_env=()
    local env_name env_value
    while IFS='=' read -r env_name env_value; do
        [[ -n "$env_name" ]] || continue
        e2e_env+=("$env_name"="$env_value")
    done < <(env | grep '^E2E_ENV_' | sed 's/^E2E_ENV_//' || true)
    if [[ -n "$base_url" ]]; then
        e2e_env+=("E2E_BASE_URL"="$base_url")
    fi

    local provisioning_args=""
    if [[ "$_TARGET_SDK" == "iphoneos" ]]; then
        provisioning_args="-allowProvisioningUpdates"
    fi

    echo "Testing ${PROJECT_NAME} e2e on $_TARGET_NAME ($_TARGET_SDK)."

    if [[ "$skip_build" != "true" ]]; then
        echo "  Building e2e tests..."
        env "${e2e_env[@]}" xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$e2e_scheme" \
          -sdk "$_TARGET_SDK" -destination "$_TARGET_DEST" -configuration Debug \
          build-for-testing $_BUILD_EXTRA $provisioning_args 2>&1 || return 1
    fi

    echo "  Running e2e tests..."
    env "${e2e_env[@]}" xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$e2e_scheme" \
      -sdk "$_TARGET_SDK" -destination "$_TARGET_DEST" -configuration Debug \
      test-without-building $_BUILD_EXTRA $provisioning_args 2>&1
}
