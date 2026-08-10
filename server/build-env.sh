# toolkit/server/build-env.sh — sourced by build.sh
# Provides: health display, varlock/env loading, setup commands
# Depends on: PROJECT_ROOT, _tty_* (shared/build-utils.sh), _require_cmd (shared/build-utils.sh)
# Used by: build-fly.sh (_print_health), build.sh (do_doctor calls _get_sensitive_vars)

# ── Config ─────────────────────────────────────────────────────────

_load_server_config() {
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

    SERVER_PORT="${SERVER_PORT:-8080}"
    SERVER_CMD_PATH="${SERVER_CMD_PATH:-./cmd/server}"
    SERVER_BIN_PATH="${SERVER_BIN_PATH:-bin/server}"
    TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
    WATCH_COOLDOWN="${WATCH_COOLDOWN:-1.0}"
    TOOLKIT_SERVER_SENTRY_ENABLED="${TOOLKIT_SERVER_SENTRY_ENABLED:-false}"
}

# ── Health display ─────────────────────────────────────────────────

_print_health() {
    local json="$1"
    local hstatus db_hl db_msg db_lat st_hl st_msg st_lat

    hstatus=$(echo "$json" | jq -r '.status // "unreachable"')
    if [[ "$hstatus" == "unreachable" ]]; then
        echo "  $(_tty_red)✗ App unreachable$(_tty_reset)"
        return
    fi

    db_hl=$(echo "$json" | jq -r '.db.healthy // false')
    db_msg=$(echo "$json" | jq -r '.db.message // "?"')
    db_lat=$(echo "$json" | jq -r '.db.latency // "?"')
    _print_row "DB" "$db_hl" "$db_msg" "$db_lat"

    st_hl=$(echo "$json" | jq -r '.storage.healthy // false')
    st_msg=$(echo "$json" | jq -r '.storage.message // "?"')
    st_lat=$(echo "$json" | jq -r '.storage.latency // "?"')
    _print_row "Storage" "$st_hl" "$st_msg" "$st_lat"

    local overall_hl
    [[ "$hstatus" == "healthy" ]] && overall_hl=true || overall_hl=false
    _print_row "Status" "$overall_hl" "$hstatus" ""
}

_print_row() {
    local name="$1" healthy="$2" msg="$3" lat="$4"
    local mark
    if [[ "$healthy" == "true" ]]; then
        mark="$(_tty_green)✓$(_tty_reset)"
    else
        mark="$(_tty_red)✗$(_tty_reset)"
    fi
    printf '  %-10s %b %s (%s)\n' "$name" "$mark" "$msg" "$lat"
}

# ── Env ────────────────────────────────────────────────────────────

_bootstrap_env_local() {
    local schema="$PROJECT_ROOT/.env.schema"
    local env_local="$PROJECT_ROOT/.env.local"

    if [[ -f "$env_local" ]]; then
        return 0
    fi

    if [[ ! -f "$schema" ]]; then
        echo "✗ .env.schema not found"
        exit 1
    fi

    echo "→ bootstrapping .env.local from .env.schema..."

    while IFS='|' read -r var desc; do
        if [[ -n "$var" ]]; then
            echo "${var}=varlock(prompt)" >> "$env_local"
        fi
    done < <(_get_sensitive_vars)

    echo "✓ .env.local created — varlock will prompt for secrets on first run"
}

_get_sensitive_vars() {
    local schema="$PROJECT_ROOT/.env.schema"
    local comments=() line var is_sensitive desc stripped c

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^#[[:space:]]*@ ]]; then
            comments+=("$line")
        elif [[ "$line" =~ ^#[[:space:]] ]]; then
            comments+=("$line")
        elif [[ "$line" =~ ^[A-Z][A-Z_]*= ]]; then
            var="${line%%=*}"
            is_sensitive=0
            desc=""

            for c in ${comments[@]+"${comments[@]}"}; do
                stripped="${c#\#}"
                stripped="${stripped# }"
                if [[ "$stripped" == *"@sensitive"* ]]; then
                    is_sensitive=1
                elif [[ "$stripped" != @* ]]; then
                    if [[ -n "$desc" ]]; then desc+=" "; fi
                    desc+="$stripped"
                fi
            done

            if [[ $is_sensitive -eq 1 ]]; then
                echo "${var}|${desc}"
            fi
            comments=()
        elif [[ -z "$line" ]]; then
            comments=()
        fi
    done < "$schema"
}

_load_env() {
    if ! command -v varlock &>/dev/null; then
        echo "✗ varlock not found. Install with: brew install dmno-dev/tap/varlock"
        exit 1
    fi

    _bootstrap_env_local

    local varlock_output
    varlock_output="$(varlock load --path "$PROJECT_ROOT/" --format shell 2>&1)" || {
        echo "✗ Varlock validation failed:"
        echo "$varlock_output"
        exit 1
    }

    set -a
    eval "$varlock_output"
    set +a

    export PORT="${PORT:-8080}"

    if [[ -n "${DATABASE_URL:-}" ]]; then
        export DATABASE_URL="$DATABASE_URL"
    fi

    if [[ -n "${JWT_SECRET:-}" ]]; then
        export JWT_SECRET="$JWT_SECRET"
        if [[ ${#JWT_SECRET} -lt 64 ]]; then
            echo "✗ JWT_SECRET must be at least 64 characters."
            exit 1
        fi
    fi
}

_check_database() {
    if ! command -v pg_isready &>/dev/null; then
        echo "  pg_isready not found; skipping database reachability check."
        return 0
    fi
    if ! pg_isready -d "$DATABASE_URL" >/dev/null 2>&1; then
        echo "✗ Database is not reachable: $DATABASE_URL"
        exit 1
    fi
}

# ── Setup ──────────────────────────────────────────────────────────

do_setup() {
    _require_cmd varlock "Install with: brew install dmno-dev/tap/varlock"

    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│ Turn Server — Local Development Setup       │"
    echo "└─────────────────────────────────────────────┘"
    echo ""

    echo "── Checking prerequisites ──"
    if ! do_doctor >/dev/null 2>&1; then
        echo ""
        echo "✗ Prerequisites missing. Run './build.sh server doctor' for details."
        return 1
    fi
    echo "  ✓ All prerequisites present"

    echo ""

    local db_url
    db_url="$(varlock printenv DATABASE_URL --path "$PROJECT_ROOT/" 2>/dev/null)" || true
    if [[ -n "$db_url" ]]; then
        if command -v pg_isready &>/dev/null && pg_isready -d "$db_url" >/dev/null 2>&1; then
            echo "── Database ──"
            echo "  ✓ Already configured and reachable"
        else
            echo "── Database ──"
            echo "  ⚠ DATABASE_URL is set but unreachable."
            echo "    Check: $db_url"
        fi
    else
        echo "── Database ──"
        local default_db="postgres://localhost:5432/turn?sslmode=disable"
        echo "  No DATABASE_URL configured."
        if pg_isready -d "$default_db" >/dev/null 2>&1; then
            echo "  Local database found. Using $default_db"
            _set_env_value "DATABASE_URL" "$default_db"
        else
            echo "  Local database not found. Create it? [Y/n]"
            local answer
            read -p "  > " answer
            if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                createdb turn 2>/dev/null && echo "  ✓ Created database 'turn'" || {
                    echo "  ✗ Could not create database. Check PostgreSQL."
                    return 1
                }
                _set_env_value "DATABASE_URL" "$default_db"
            else
                echo "  Skipped. Set DATABASE_URL in .env.local manually."
            fi
        fi
        echo "  Migrations will run automatically on first server start"
    fi

    echo ""

    local jwt_val
    jwt_val="$(varlock printenv JWT_SECRET --path "$PROJECT_ROOT/" 2>/dev/null)" || true
    if [[ -n "$jwt_val" && ${#jwt_val} -ge 64 ]]; then
        echo "── JWT Secret ──"
        echo "  ✓ Already set (${#jwt_val} characters)"
    else
        echo "── JWT Secret ──"
        echo "  Generating new 128-character random secret..."
        local new_secret
        new_secret="$(openssl rand -hex 64)"
        _set_env_value "JWT_SECRET" "$new_secret"
        echo "  ✓ JWT_SECRET generated"
    fi

    echo ""

    local apns_val
    apns_val="$(varlock printenv APNS_KEY_CONTENT --path "$PROJECT_ROOT/" 2>/dev/null)" || true
    local apns_path_val
    apns_path_val="$(varlock printenv APNS_KEY_PATH --path "$PROJECT_ROOT/" 2>/dev/null)" || true
    if [[ -n "$apns_val" ]] || [[ -n "$apns_path_val" && -f "$apns_path_val" ]]; then
        echo "── Push Notifications ──"
        echo "  ✓ APNs key already configured"
    else
        echo "── Push Notifications ──"
        echo "  APNs key not configured. Set up now? [Y/n]"
        local answer
        read -p "  > " answer
        if [[ "$answer" != "n" && "$answer" != "N" ]]; then
            do_apns_setup
        else
            echo "  Skipped. Run './build.sh server apns-setup' later."
        fi
    fi

    echo ""

    local resend_val
    resend_val="$(varlock printenv RESEND_API_KEY --path "$PROJECT_ROOT/" 2>/dev/null)" || true
    if [[ -n "$resend_val" ]]; then
        echo "── Email Invites ──"
        echo "  ✓ RESEND_API_KEY already configured"
    else
        echo "── Email Invites ──"
        echo "  Email invites use Resend.com to deliver invite emails."
        echo "  A free API key is available at: https://resend.com/signup"
        echo ""
        echo "  Set up now? [Y/n]"
        local answer
        read -p "  > " answer
        if [[ "$answer" != "n" && "$answer" != "N" ]]; then
            do_email_setup
        else
            echo "  Skipped. Run './build.sh server email-setup' later."
        fi
    fi

    echo ""
    echo "── Building ──"
    _sync_locale
    _check_quality
    go build -o bin/server ./cmd/server 2>&1
    _register_firewall
    echo "  ✓ Server built"

    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│ Setup complete.                             │"
    echo "│                                             │"
    echo "│ Start the server:                           │"
    echo "│   ./build.sh server start                   │"
    echo "└─────────────────────────────────────────────┘"
}

_set_env_value() {
    local key="$1"
    local value="$2"
    local envfile="$PROJECT_ROOT/.env.local"
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$envfile"
    else
        echo "${key}=${value}" >> "$envfile"
    fi
}

do_apns_setup() {
    _require_cmd varlock "Install with: brew install dmno-dev/tap/varlock"

    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│ Push notification key setup                 │"
    echo "│ An APNs Auth Key from Apple is required.    │"
    echo "└─────────────────────────────────────────────┘"
    echo ""

    local key_url="https://developer.apple.com/account/resources/authkeys/list"
    echo "Step 1 — Download the key from Apple:"
    echo "  $key_url"
    echo ""
    echo "  Create a new key, or use an existing one."
    echo "  The downloaded file is named AuthKey_XXXXXXXXX.p8"
    echo ""

    local answer
    read -p "  Downloaded the key? [y/n]: " answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo ""
        echo "  No problem — re-run './build.sh server apns-setup' when ready."
        return 0
    fi

    echo ""
    echo "Step 2 — Select the key file:"

    local keyfile
    keyfile=$(osascript -e '
        set theFile to choose file of type "p8" with prompt "Select your APNs Auth Key (.p8 file)"
        POSIX path of theFile
    ' 2>/dev/null)

    if [[ -z "$keyfile" || ! -f "$keyfile" ]]; then
        echo "  No file selected. Aborted."
        return 1
    fi

    echo "  Selected: $keyfile"
    echo ""

    echo "Step 3 — Encrypting and storing..."

    local encrypted
    encrypted=$(cat "$keyfile" | varlock encrypt 2>&1 | tail -1 | sed 's/^SOME_SENSITIVE_KEY=//')
    if [[ -z "$encrypted" ]]; then
        echo "  ✗ Encryption failed. Is varlock installed and configured?"
        return 1
    fi

    local envfile="$PROJECT_ROOT/.env.local"
    if grep -q "^APNS_KEY_CONTENT=" "$envfile" 2>/dev/null; then
        sed -i '' "s|^APNS_KEY_CONTENT=.*|APNS_KEY_CONTENT=$encrypted|" "$envfile"
    else
        echo "APNS_KEY_CONTENT=$encrypted" >> "$envfile"
    fi

    echo "  ✓ Saved to .env.local"
    echo ""
    echo "  Push notifications enabled."
    echo "  Run './build.sh server start' to restart with the new key."
}

do_email_setup() {
    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│ Email invite key setup                      │"
    echo "│ A Resend API key is required.               │"
    echo "└─────────────────────────────────────────────┘"
    echo ""
    echo "  Get your API key: https://resend.com/api-keys"
    echo ""
    echo "  Paste your Resend API key (starts with 're_'):"
    local key
    read -p "  > " key
    if [[ -z "$key" ]]; then
        echo "  ✗ No key entered. Aborted."
        return 1
    fi
    if [[ ! "$key" =~ ^re_ ]]; then
        echo "  ⚠ That doesn't look like a Resend API key (should start with 're_')."
        echo "  Continue anyway? [y/N]"
        local answer
        read -p "  > " answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            echo "  Aborted."
            return 1
        fi
    fi
    _set_env_value "RESEND_API_KEY" "$key"
    echo "  ✓ RESEND_API_KEY saved to .env.local"
    echo ""
    echo "  Email invites enabled."
    echo "  Run './build.sh server start' to restart with the new key."
}
