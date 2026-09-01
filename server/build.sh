#!/bin/bash
set -euo pipefail

# toolkit/server/build.sh — generic Go server build toolkit
# Sourced by a thin project-level build.sh, or run directly.
# Configuration lives in <project>/build.properties (generated from
# toolkit/server/config/build.properties.example via `./build.sh setup`).
# No project names are hardcoded — everything is config-driven or auto-detected.

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The host project root. The project entry exports TOOLKIT_PROJECT_ROOT; when
# run directly, fall back to walking up from the toolkit to the nearest go.mod.
_detect_project() {
    if [[ -n "${TOOLKIT_PROJECT_ROOT:-}" ]]; then
        PROJECT_ROOT="$TOOLKIT_PROJECT_ROOT"
        return 0
    fi
    local dir="$TOOLKIT_DIR"
    for _ in 1 2 3 4 5; do
        if [[ -f "$dir/go.mod" ]]; then
            PROJECT_ROOT="$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "✗ Could not detect a Go project (no go.mod found above $TOOLKIT_DIR)." >&2
    echo "  Export TOOLKIT_PROJECT_ROOT to point at the project root." >&2
    exit 1
}
_detect_project

source "$TOOLKIT_DIR/../shared/build-utils.sh"
source "$TOOLKIT_DIR/../shared/sentry.sh"
source "$TOOLKIT_DIR/build-env.sh"
source "$TOOLKIT_DIR/build-fly.sh"

PID_FILE="$PROJECT_ROOT/.watch/server.pid"
LOG_FILE="$PROJECT_ROOT/.watch/server.log"

DEPLOY_FORCE=0

# ── Timing constants ────────────────────────────────────────────────

STARTUP_DELAY=1
RESTART_DELAY=0.3

# ── Config ──────────────────────────────────────────────────────────

_load_config() {
    if [[ -f "$PROJECT_ROOT/../build.properties" ]]; then
        set -a
        source "$PROJECT_ROOT/../build.properties"
        set +a
    fi
    if [[ -f "$PROJECT_ROOT/build.properties" ]]; then
        set -a
        source "$PROJECT_ROOT/build.properties"
        set +a
    fi

    SERVER_PORT="${SERVER_PORT:-8080}"
    TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
    WATCH_COOLDOWN="${WATCH_COOLDOWN:-1.0}"
    SERVER_CMD_PATH="${SERVER_CMD_PATH:-./cmd/server}"
    SERVER_BIN_PATH="${SERVER_BIN_PATH:-bin/server}"
}

# ── Guards ──────────────────────────────────────────────────────────

_check_build_tools() {
    _require_cmd go "Install with: brew install go"
    _require_cmd golangci-lint "Install with: brew install golangci-lint"
    _require_cmd jq "Install with: brew install jq"
    _require_cmd sqlc "Install with: brew install sqlc"
}

_guard_not_running() {
    if _pid_running "$PID_FILE"; then
        echo "✗ Server already running (PID $(cat "$PID_FILE"))."
        echo "  Use './build.sh server stop' first, then retry."
        exit 1
    fi
}

# ── Build ──────────────────────────────────────────────────────────

_register_firewall() {
    local err_output
    if err_output=$(/usr/libexec/ApplicationFirewall/socketfilterfw --remove "$PROJECT_ROOT/$SERVER_BIN_PATH" 2>&1); then
        : # success
    else
        local rc=$?
        echo "  ✗ Firewall remove failed (exit $rc): ${err_output}" >&2
    fi
    if err_output=$(/usr/libexec/ApplicationFirewall/socketfilterfw --add "$PROJECT_ROOT/$SERVER_BIN_PATH" 2>&1); then
        : # success
    else
        local rc=$?
        echo "  ✗ Firewall add failed (exit $rc): ${err_output}" >&2
    fi
}

_check_quality() {
    _require_cmd golangci-lint "Install with: brew install golangci-lint"
    local log
    log=$(mktemp)
    if (cd "$PROJECT_ROOT" && golangci-lint run ./...) > "$log" 2>&1; then
        rm -f "$log"
        echo "✓ Lint passed"
    else
        echo "✗ Lint failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

_sync_locale() {
    cp "$PROJECT_ROOT/${LOCALE_SRC:-../shared/locales/}en.toml" "$PROJECT_ROOT/${LOCALE_DST:-internal/locale/}en.toml"
}

do_build() {
    _check_build_tools
    _sync_locale

    do_sqlc || return 1

    _check_quality || return 1

    local build_log
    build_log=$(mktemp)
    echo "→ Building server..."
    if (cd "$PROJECT_ROOT" && go build -o "$PROJECT_ROOT/$SERVER_BIN_PATH" "$SERVER_CMD_PATH") > "$build_log" 2>&1; then
        rm -f "$build_log"
        _register_firewall
        echo "✓ Server built"
    else
        echo "✗ Build failed:"
        cat "$build_log"
        rm -f "$build_log"
        return 1
    fi
}

# ── Local dev commands ─────────────────────────────────────────────

do_start() {
    _guard_not_running
    _load_env
    _check_database
    do_build

    mkdir -p "$(dirname "$PID_FILE")"
    nohup "$PROJECT_ROOT/$SERVER_BIN_PATH" > "$LOG_FILE" 2>&1 &
    echo "$!" > "$PID_FILE"

    sleep "$STARTUP_DELAY"
    if _pid_running "$PID_FILE"; then
        echo "✓ Server started on :${PORT} (PID $(cat "$PID_FILE"))"
    else
        echo "✗ Server failed to start. Check $LOG_FILE"
        rm -f "$PID_FILE"
        exit 1
    fi
}

do_stop() {
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -rf "$PROJECT_ROOT/.watch"
        echo "✓ Server stopped"
    else
        echo "○ Server not running"
    fi
}

do_watch() {
    _require_cmd fswatch "Install with: brew install fswatch"
    _guard_not_running
    _load_env
    _check_database
    do_build

    mkdir -p "$(dirname "$PID_FILE")"
    nohup "$PROJECT_ROOT/$SERVER_BIN_PATH" > "$LOG_FILE" 2>&1 &
    local server_pid=$!
    echo "$server_pid" > "$PID_FILE"

    echo "✓ Server started on :${PORT} (PID $server_pid)"
    echo "Watching for Go changes in $PROJECT_ROOT/ ..."

    trap 'kill $server_pid 2>/dev/null; rm -rf "$PROJECT_ROOT/.watch"' EXIT

    while read -r changed; do
        [[ "$changed" =~ \.go$ ]] || continue
        echo "[$(date '+%H:%M:%S')] → $(basename "$changed")"
        local watch_log
        watch_log=$(mktemp)
        if _sync_locale > "$watch_log" 2>&1 && (cd "$PROJECT_ROOT" && sqlc generate) > "$watch_log" 2>&1 && _check_quality > "$watch_log" 2>&1 && (cd "$PROJECT_ROOT" && go build -o "$PROJECT_ROOT/$SERVER_BIN_PATH" "$SERVER_CMD_PATH") >> "$watch_log" 2>&1; then
            rm -f "$watch_log"
            _register_firewall
            kill "$server_pid" 2>/dev/null || true
            sleep "$RESTART_DELAY"
            nohup "$PROJECT_ROOT/$SERVER_BIN_PATH" > "$LOG_FILE" 2>&1 &
            server_pid=$!
            echo "$server_pid" > "$PID_FILE"
            echo "[$(date '+%H:%M:%S')] ✓ Restarted (PID $server_pid)"
        else
            echo "[$(date '+%H:%M:%S')] ✗ Build failed:"
            cat "$watch_log"
            rm -f "$watch_log"
        fi
        while read -r -t 0 _; do :; done
        sleep "$WATCH_COOLDOWN"
    done < <(fswatch --latency 0.5 "$PROJECT_ROOT/" 2>/dev/null)
}

_require_server() {
    local url="${1:-${SERVER_HEALTH_URL:-http://localhost:8080/api/health}}"
    if ! curl -sf "$url" >/dev/null 2>&1; then
        echo >&2 "ERROR: server is not running at $url"
        echo >&2 "Start it with: ./build.sh server start"
        exit 1
    fi
}

do_test() {
    _require_cmd go "Install with: brew install go"
    _sync_locale
    do_sqlc || return 1
    _check_quality || return 1

    # Parse optional timeout from args (any bare number is treated as a timeout override)
    local timeout="${TEST_TIMEOUT}s"
    local -a filtered=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            timeout="${arg}s"
        else
            filtered+=("$arg")
        fi
    done
    if [ ${#filtered[@]} -gt 0 ]; then
        set -- "${filtered[@]}"
    else
        set --
    fi

    echo "→ Running tests..."
    local test_log
    test_log=$(mktemp)

    local test_exit=0
    if [ "${1:-}" = "service" ]; then
        _load_env
        _require_server
        (cd "$PROJECT_ROOT" && go test -timeout "$timeout" -tags=service ./internal/service/ -v -count=1) 2>&1 | tee "$test_log" || test_exit=$?
    elif [ "${1:-}" = "emails" ]; then
        _load_env
        _require_server
        (cd "$PROJECT_ROOT" && go test -timeout "$timeout" -tags=service ./internal/service/ -v -count=1 -run 'TestInvite') 2>&1 | tee "$test_log" || test_exit=$?
    elif [ "${1:-}" = "local" ]; then
        export APP_BASE_URL="http://localhost:${SERVER_PORT}"
        _require_server
        (cd "$PROJECT_ROOT" && go test -timeout "$timeout" -tags=live ./internal/livetest -v -count=1) 2>&1 | tee "$test_log" || test_exit=$?
    elif [ "${1:-}" = "live" ]; then
        _load_env
        local live_url="${LIVE_BASE_URL:-}"
        if [[ -z "$live_url" && -n "${FLY_APP:-}" ]]; then
            live_url="https://${FLY_APP}.fly.dev"
        fi
        if [[ -z "$live_url" ]]; then
            echo "✗ LIVE_BASE_URL not set (and FLY_APP unknown)."
            rm -f "$test_log"
            return 1
        fi
        export APP_BASE_URL="$live_url"
        _require_server "$live_url/api/health"
        (cd "$PROJECT_ROOT" && go test -timeout "$timeout" -tags=live ./internal/livetest -v -count=1) 2>&1 | tee "$test_log" || test_exit=$?
    else
        (cd "$PROJECT_ROOT" && go test -timeout "$timeout" ./... -v -count=1) 2>&1 | tee "$test_log" || test_exit=$?
    fi

    if [[ $test_exit -eq 0 ]]; then
        local pkg_count
        pkg_count=$(grep -c '^ok ' "$test_log" 2>/dev/null || echo 0)
        rm -f "$test_log"
        echo "✓ All tests passed"
    else
        local fail_count
        fail_count=$(grep -c '^FAIL' "$test_log" 2>/dev/null || echo 0)
        rm -f "$test_log"
        echo "✗ Tests failed ($fail_count failures)"
        return 1
    fi
}

do_lint() {
    _require_cmd golangci-lint "Install with: brew install golangci-lint"
    _sync_locale
    local log
    log=$(mktemp)
    if (cd "$PROJECT_ROOT" && golangci-lint run ./...) > "$log" 2>&1; then
        rm -f "$log"
        echo "✓ Lint passed"
    else
        echo "✗ Lint failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_format() {
    _require_cmd golangci-lint "Install with: brew install golangci-lint"
    local log
    log=$(mktemp)
    echo "→ Formatting..."
    if (cd "$PROJECT_ROOT" && golangci-lint run --fix ./...) > "$log" 2>&1; then
        rm -f "$log"
        echo "✓ Formatting complete"
    else
        echo "✗ Format failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_sqlc() {
    _require_cmd sqlc "Install with: brew install sqlc"
    local log
    log=$(mktemp)
    echo "→ Generating sqlc code..."
    if (cd "$PROJECT_ROOT" && sqlc generate) > "$log" 2>&1; then
        rm -f "$log"
        echo "✓ sqlc code generated"
    else
        echo "✗ sqlc generation failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_docs() {
    _require_cmd swag
    local log
    log=$(mktemp)
    echo "→ Generating API docs..."
    if (cd "$PROJECT_ROOT" && swag init -g "${SERVER_CMD_PATH}/main.go" --output docs) > "$log" 2>&1; then
        rm -f "$log"
        echo "✓ Swagger spec generated in docs/"
    else
        echo "✗ Docs generation failed:"
        cat "$log"
        rm -f "$log"
        return 1
    fi
}

do_migrate() {
    local cmd="${1:-}"
    if [[ "$cmd" != "up" && "$cmd" != "down" ]]; then
        echo "Usage: ./build.sh server migrate <up|down [N|all]>"
        echo ""
        echo "  up              Run all pending up migrations"
        echo "  down            Run 1 down migration (default)"
        echo "  down N          Run N down migrations"
        echo "  down all        Run all down migrations"
        return 1
    fi
    _load_env
    _check_database
    local log
    log=$(mktemp)
    if [[ "$cmd" == "up" ]]; then
        echo "→ Migrating up..."
        if (cd "$PROJECT_ROOT" && go run ./cmd/migrate up) > "$log" 2>&1; then
            rm -f "$log"
            echo "✓ Migration complete"
        else
            echo "✗ Migration failed:"
            cat "$log"
            rm -f "$log"
            return 1
        fi
    else
        local steps="${2:-1}"
        local args=(down)
        if [[ "$steps" == "all" ]]; then
            args+=(--all)
        elif [[ "$steps" =~ ^[0-9]+$ ]]; then
            args+=(--steps "$steps")
        else
            args+=(--steps 1)
        fi
        echo "→ Migrating down ($steps)..."
        if (cd "$PROJECT_ROOT" && go run ./cmd/migrate "${args[@]}") > "$log" 2>&1; then
            rm -f "$log"
            echo "✓ Migration complete"
        else
            echo "✗ Migration failed:"
            cat "$log"
            rm -f "$log"
            return 1
        fi
    fi
}

do_clean() {
    rm -rf "$PROJECT_ROOT/bin" "$PROJECT_ROOT/.watch"
    echo "✓ Removed bin/ and .watch/"
}

do_doctor() {
    local failed=0

    echo "Server build environment:"
    for cmd in go golangci-lint fswatch pg_isready varlock jq; do
        if command -v "$cmd" &>/dev/null; then
            echo "  ✓ $cmd: $(command -v "$cmd")"
        else
            echo "  ✗ $cmd: missing"
            failed=1
        fi
    done

    echo ""
    if [[ -f "$PROJECT_ROOT/.env.schema" ]]; then
        local varlock_result
        varlock_result="$(varlock load --path "$PROJECT_ROOT/" --format shell 2>&1)" || {
            echo "  ✗ Varlock config invalid:"
            echo "$varlock_result" | sed 's/^/    /'
            failed=1
        }
        if [[ $failed -eq 0 ]]; then
            echo "  ✓ Varlock config valid"
            local db_url
            db_url="$(varlock printenv DATABASE_URL --path "$PROJECT_ROOT/" 2>/dev/null)"
            if [[ -n "$db_url" ]]; then
                echo "  ✓ DATABASE_URL set"
                if command -v pg_isready &>/dev/null && pg_isready -d "$db_url" >/dev/null 2>&1; then
                    echo "  ✓ Database reachable"
                else
                    echo "  ✗ Database not reachable or pg_isready missing"
                    failed=1
                fi
            else
                echo "  ✗ DATABASE_URL missing"
                failed=1
            fi
            local jwt_val
            jwt_val="$(varlock printenv JWT_SECRET --path "$PROJECT_ROOT/" 2>/dev/null)"
            if [[ -n "$jwt_val" && ${#jwt_val} -ge 64 ]]; then
                echo "  ✓ JWT_SECRET valid"
            else
                echo "  ✗ JWT_SECRET must be at least 64 characters"
                failed=1
            fi
            local apns_content apns_path
            apns_content="$(varlock printenv APNS_KEY_CONTENT --path "$PROJECT_ROOT/" 2>/dev/null)" || true
            apns_path="$(varlock printenv APNS_KEY_PATH --path "$PROJECT_ROOT/" 2>/dev/null)" || true
            if [[ -n "$apns_content" ]]; then
                if [[ "$apns_content" == *"-----BEGIN"* ]]; then
                    local key_ok=1
                    if command -v openssl &>/dev/null; then
                        if ! echo "$apns_content" | openssl ec -noout 2>/dev/null; then
                            key_ok=0
                        fi
                    fi
                    if [[ $key_ok -eq 1 ]]; then
                        echo "  ✓ APNS_KEY_CONTENT valid (push enabled)"
                    else
                        echo "  ✗ APNS_KEY_CONTENT set but not a valid PKCS8 private key"
                        echo "    Push will crash the server on startup."
                        failed=1
                    fi
                else
                    echo "  ✗ APNS_KEY_CONTENT set but missing PEM header"
                    echo "    Expected -----BEGIN PRIVATE KEY-----"
                    echo "    The value may be a varlock reference instead of the decrypted key."
                    failed=1
                fi
            elif [[ -n "$apns_path" && -f "$apns_path" ]]; then
                echo "  ✓ APNS_KEY_PATH found (push notifications enabled)"
            else
                echo "  ⚠ APNs key not configured"
                echo "    Push notifications disabled."
                echo "    To enable: ./build.sh server apns-setup"
            fi
            local resend_val
            resend_val="$(varlock printenv RESEND_API_KEY --path "$PROJECT_ROOT/" 2>/dev/null)" || true
            if [[ -n "$resend_val" ]]; then
                echo "  ✓ RESEND_API_KEY set (email invites enabled)"
            else
                echo "  ⚠ RESEND_API_KEY not configured"
                echo "    Email invites disabled."
                echo "    To enable: ./build.sh server email-setup"
            fi

            local port_val
            port_val="$(varlock printenv PORT --path "$PROJECT_ROOT/" 2>/dev/null)"
            echo "  ✓ PORT ${port_val:-$SERVER_PORT}"

            local secrets_init_out
            if secrets_init_out="$(_get_sensitive_vars 2>&1)"; then
                echo "  ✓ Secrets init works"
            else
                echo "  ✗ Secrets init broken — deploy will fail"
                echo "    ${secrets_init_out}"
                failed=1
            fi
        fi
    else
        echo "  ✗ .env.schema missing"
        failed=1
    fi

    if [[ -f "$PROJECT_ROOT/sqlc.yaml" ]]; then
        echo "  ✓ sqlc.yaml present"
    else
        echo "  ✗ sqlc.yaml missing"
        failed=1
    fi

    return "$failed"
}

do_debug() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "✗ Local server not running. Start with: ./build.sh server start"
        return 1
    fi

    echo "→ Streaming server logs (Ctrl-C to stop)..."
    echo ""
    tail -n 0 -F "$LOG_FILE" | _fmt_server_log
}

do_local_status() {
    local port="${PORT:-$SERVER_PORT}"
    echo "── Local Server ───────────────────────────────────────────────────────────"
    echo ""
    local health
    health=$(curl -s --max-time 5 "http://localhost:${port}/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
    echo "  Health:     $(echo "$health" | jq -r '.status // "unreachable"' 2>/dev/null)"
    echo "  URL:        http://localhost:${port}"
    echo ""

    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Process:    running (PID $pid)"
        else
            echo "  Process:    stale PID file"
        fi
    else
        echo "  Process:    not running"
    fi

    echo ""
    echo "── Metrics ───────────────────────────────────────────────────────────────"
    local metrics
    metrics=$(curl -s --max-time 5 "http://localhost:${port}/metrics" 2>/dev/null)
    if [[ -n "$metrics" ]]; then
        echo "$metrics" | head -20
    else
        echo "  (metrics unreachable — server may not be running)"
    fi
}

do_sql() {
    _load_env
    _require_cmd psql "Install with: brew install postgresql@16"
    if [[ -z "${1:-}" ]]; then
        echo "Usage: ./build.sh server sql <query>"
        echo "  Executes the given SQL query on the local development database."
        echo "  Example: ./build.sh server sql 'SELECT * FROM users LIMIT 5'"
        return 1
    fi
    psql "$DATABASE_URL" -c "$*"
}

do_local_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "No server log file at $LOG_FILE"
        echo "Start the server first: ./build.sh server start"
        return 1
    fi

    if [[ "${1:-}" == "tail" ]]; then
        echo "→ Streaming server logs (Ctrl-C to stop)..."
        echo ""
        tail -n 0 -F "$LOG_FILE" | _fmt_server_log
    else
        local lines="${1:-10}"
        echo "→ Last $lines server log lines:"
        echo ""
        tail -n "$lines" "$LOG_FILE" | _fmt_server_log
    fi
}

usage() {
    cat <<EOF
Usage: ./build.sh server <command>
  Local dev:
    build        Compile Go binary
    clean        Remove build artifacts (bin/, .watch/)
    start        Build + start in background
    stop         Stop server
    status       Show local server health + metrics
    logs [N]     Show last N formatted log lines (default 10)
    logs tail    Stream formatted server logs
    debug        Stream raw server log lines (for combined debug)
    watch        Start + auto-rebuild on Go changes
    test [N] [subcommand]    Run all Go tests + lint (timeout in seconds, default $TEST_TIMEOUT)
    test service             Test email delivery pipeline (needs local server + Resend API key)
    test emails              Test email invites only
    test local               Check local server self-test health
    test live                Check production server self-test health
    lint         Run golangci-lint
    format       Auto-format all Go sources (golangci-lint --fix)
    doctor       Check local server build prerequisites
    docs         Generate OpenAPI/Swagger spec from handler annotations
    sqlc         Regenerate sqlc code from db/queries/*.sql
    migrate up              Run all pending up migrations
    migrate down            Run 1 down migration (default)
    migrate down N          Run N down migrations
    migrate down all        Run all down migrations
    sql <query>             Execute a SQL query on the local database
    apns-setup   Set up push notification key
    email-setup  Set up Resend API key for email invites
    setup        Set up local development environment (db, secrets, push, email)

  Live (remote):
    live status       Show app health, URL, machines, and metrics
    live logs [N]     Show last N lines from Fly log buffer (default 10)
    live logs tail    Stream live Fly logs
    live deploy [--dry-run] [--strategy rolling|immediate] [--force] <text>   Pre-check, snapshot DB, deploy, verify self-test
    live rollback [--dry-run] [--force]  Restore DB from backup + redeploy app
    live snapshots    List database backups
    live clusters [org]   List MPG clusters (active + deleted); org optional
    live deployments  List deploy and rollback tags
    live releases     Show deployment history
    live machines     List individual VM status
    live setup        Configure CI (Fly token + GitHub Actions secrets)
    live ci-setup     CI/CD pipeline configuration
    live sentry       Sentry queries for server project
EOF
}

_dispatch_sentry() {
    if [[ "${TOOLKIT_SERVER_SENTRY_ENABLED:-false}" != "true" || -z "${SERVER_SENTRY_PROJECT:-}" ]]; then
        echo "✗ Sentry not configured. Set TOOLKIT_SERVER_SENTRY_ENABLED=true and SERVER_SENTRY_PROJECT in build.properties."
        return 1
    fi
    _sentry_dispatch "$SERVER_SENTRY_PROJECT" "$@"
}

_dispatch() {
    for arg in "${@:-}"; do
        [[ "$arg" == "--force" ]] && DEPLOY_FORCE=1
    done

    _load_config

    case "${1:-}" in
        build)        do_build ;;
        clean)        do_clean ;;
        debug)        do_debug ;;
        start)        do_start ;;
        stop)         do_stop ;;
        status)       do_local_status ;;
        logs)         shift; do_local_logs "$@" ;;
        watch)        do_watch ;;
        test)         shift; do_test "$@" ;;
        lint)         do_lint ;;
        format)       do_format ;;
        doctor)       do_doctor ;;
        docs)         do_docs ;;
        sqlc)         do_sqlc ;;
        migrate)      shift; do_migrate "$@" ;;
        sql)          shift; do_sql "$@" ;;
        apns-setup)   do_apns_setup ;;
        email-setup)  do_email_setup ;;
        setup)        do_setup ;;
        live)
            shift
            case "${1:-}" in
                status)      _fly_status ;;
                logs)        shift; _fly_logs "$@" ;;
                deploy)      shift; _fly_deploy "$@" ;;
                rollback)    shift; _fly_rollback "$@" ;;
                snapshots)   _fly_snapshots ;;
                clusters)    shift; _fly_mpg_clusters "$@" ;;
                deployments) _fly_deployments ;;
                releases)    _fly_releases ;;
                machines)    _fly_machines ;;
                setup)       do_setup ;;
                ci-setup)    _fly_ci_setup ;;
                sentry)      shift; _dispatch_sentry "$@" ;;
                *)           usage ;;
            esac
            ;;
        *)            usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _dispatch "$@"
fi
