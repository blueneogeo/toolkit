# ios-toolkit/shared/sentry.sh — generic Sentry queries (gated by TOOLKIT_SENTRY_ENABLED)
# Provides: _sentry_auth_token, _sentry_events, _sentry_issues, _sentry_event_detail, _sentry_dispatch
# Depends on: PROJECT_ROOT, SENTRY_ORG, IOS_SENTRY_PROJECT (config)

# ── Auth ──────────────────────────────────────────────────────────────

_sentry_auth_token() {
    if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
        echo "$SENTRY_AUTH_TOKEN"
        return
    fi
    for f in "$PROJECT_ROOT/.sentryclirc" "$HOME/.sentryclirc"; do
        if [[ -f "$f" ]]; then
            grep 'token=' "$f" 2>/dev/null | cut -d'=' -f2-
            return
        fi
    done
}

# ── Sentry commands ───────────────────────────────────────────────────

_sentry_events() {
    local project="$1" limit="${2:-10}"
    echo "=== Sentry ($project): last $limit events ==="
    sentry-cli events list --org "$SENTRY_ORG" --project "$project" --max-rows "$limit"
}

_sentry_issues() {
    local project="$1" status="${2:-unresolved}"
    echo "=== Sentry ($project): $status issues ==="
    sentry-cli issues list --org "$SENTRY_ORG" --project "$project" --status "$status" --max-rows 20
}

_sentry_event_detail() {
    local project="$1" event_id="$2"
    if [[ -z "$event_id" ]]; then
        echo "Usage: ./build.sh sentry event <event-id>"
        return 1
    fi
    local token
    token=$(_sentry_auth_token)
    echo "=== Sentry ($project): event $event_id ==="
    curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/projects/${SENTRY_ORG}/${project}/events/${event_id}/json/" | jq '.' 2>/dev/null || \
        curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/projects/${SENTRY_ORG}/${project}/events/${event_id}/json/"
}

_sentry_usage() {
    cat <<EOF
Usage: ./build.sh sentry <command>

Commands:
  events [N]        List last N events (default 10)
  issues [status]   List issues (unresolved|resolved|muted, default unresolved)
  event <id>        Show full event JSON with breadcrumbs
EOF
}

_sentry_dispatch() {
    local project="$1"
    shift
    case "${1:-}" in
        events) _sentry_events "$project" "${2:-10}" ;;
        issues) _sentry_issues "$project" "${2:-unresolved}" ;;
        event)  _sentry_event_detail "$project" "$2" ;;
        *)      _sentry_usage ;;
    esac
}
