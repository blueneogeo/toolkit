# toolkit/shared/sentry.sh — generic Sentry queries (gated by TOOLKIT_SENTRY_ENABLED)
# Provides: _sentry_auth_token, _sentry_events, _sentry_issues, _sentry_event_detail, _sentry_dispatch
# Depends on: PROJECT_ROOT, SENTRY_ORG (loaded by platform _load_config)

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
    local project="$1" status="${2:-unresolved}" limit="${3:-100}"
    echo "=== Sentry ($project): $status issues (events, people, first seen, last seen, release) ==="
    local token
    token=$(_sentry_auth_token)
    curl -s -G -H "Authorization: Bearer $token" \
        --data-urlencode "query=is:$status" --data-urlencode "limit=$limit" --data-urlencode "statsPeriod=" \
        "https://sentry.io/api/0/projects/${SENTRY_ORG}/${project}/issues/" \
        | jq -r '.[] | [.shortId, .count, .userCount, .firstSeen[0:16], .lastSeen[0:16], (.lastRelease.version // "-"), .level, (.title[0:140])] | @tsv'
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

# _sentry_issue shows an issue's latest event in short: its tags, the app's own
# stack frames, the message and the last breadcrumbs.
_sentry_issue() {
    local short_id="$1"
    if [[ -z "$short_id" ]]; then
        echo "Usage: ./build.sh sentry issue <short-id>"
        return 1
    fi
    local token issue_id
    token=$(_sentry_auth_token)
    issue_id=$(curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/organizations/${SENTRY_ORG}/shortids/${short_id}/" | jq -r '.groupId // empty')
    if [[ -z "$issue_id" ]]; then
        echo "No issue $short_id"
        return 1
    fi
    echo "=== Sentry issue $short_id ($issue_id): latest event ==="
    curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issue_id}/tags/?key=release&key=environment&key=os&key=device" \
        | jq -r '.[] | "\(.key): " + ([.topValues[:4][] | "\(.value) (\(.count))"] | join(", "))'
    echo "events per day and release (last 100):"
    curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issue_id}/events/?limit=100" \
        | jq -r '.[] | "\(.dateCreated[0:10]) " + ((.tags // [] | map(select(.key == "release")) | .[0].value) // "-")' \
        | sort | uniq -c | sort -k2 -r | head -12 | sed 's/^/  /'
    curl -s -H "Authorization: Bearer $token" \
        "https://sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issue_id}/events/latest/" \
        | jq -r '
            "date: \(.dateCreated)",
            "message: \((.message // .title)[0:600])",
            (.entries[] | select(.type == "exception") | .data.values[]? |
                "exception: \(.type): \((.value // "")[0:400])",
                (.stacktrace.frames // [] | map(select(.inApp)) | reverse | .[:12][] |
                    "  at \(.function // "?") \(.filename // .module // ""):\(.lineNo // "")")),
            (.entries[] | select(.type == "threads") | .data.values[]? | select(.crashed == true) |
                (.stacktrace.frames // [] | map(select(.inApp)) | reverse | .[:12][] |
                    "  crashed at \(.function // "?") \(.filename // ""):\(.lineNo // "")")),
            (.entries[] | select(.type == "breadcrumbs") | .data.values[-15:][] |
                "  crumb \(.timestamp[11:19]) [\(.category // "")] \((.message // (.data | tostring))[0:200])")'
}

# _sentry_resolve marks issues resolved, by short id.
_sentry_resolve() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ./build.sh sentry resolve <short-id>..."
        return 1
    fi
    local token short_id issue_id
    token=$(_sentry_auth_token)
    for short_id in "$@"; do
        issue_id=$(curl -s -H "Authorization: Bearer $token" \
            "https://sentry.io/api/0/organizations/${SENTRY_ORG}/shortids/${short_id}/" | jq -r '.groupId // empty')
        if [[ -z "$issue_id" ]]; then
            echo "✗ $short_id not found"
            continue
        fi
        curl -s -X PUT -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
            -d '{"status":"resolved"}' \
            "https://sentry.io/api/0/organizations/${SENTRY_ORG}/issues/${issue_id}/" \
            | jq -r --arg id "$short_id" '"✓ \($id) \(.status // "not changed")"'
    done
}

_sentry_usage() {
    cat <<EOF
Usage: ./build.sh sentry <command>

Commands:
  events [N]        List last N events (default 10)
  issues [status] [N]  List up to N issues with counts (unresolved|resolved|muted, default unresolved, 100)
  event <id>        Show full event JSON with breadcrumbs
  issue <short-id>  An issue's tags and its latest event in short (frames, breadcrumbs)
  resolve <short-id>...  Mark issues resolved
EOF
}

_sentry_dispatch() {
    local project="$1"
    shift
    case "${1:-}" in
        events) _sentry_events "$project" "${2:-10}" ;;
        issues) _sentry_issues "$project" "${2:-unresolved}" "${3:-100}" ;;
        event)  _sentry_event_detail "$project" "$2" ;;
        issue)  _sentry_issue "$2" ;;
        resolve) shift; _sentry_resolve "$@" ;;
        *)      _sentry_usage ;;
    esac
}
