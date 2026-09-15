#!/bin/bash
# Forwards breaching build commands to a user-launched build server.
# Used when running sandboxed (SCODE_SANDBOXED) or with --server.

TURN_BUILD_SERVER_URL="${TURN_BUILD_SERVER_URL:-http://127.0.0.1:8471}"
_SERVER_FORCED=false

_srv_op_for() {
    case "$1/$2" in
        ios/build|ios/install|ios/uninstall|ios/watch|ios/test|ios/tsan-test|ios/e2e|ios/e2e-run|ios/screenshot|ios/screenshots|ios/see|ios/ui|ios/logs|ios/debug|ios/sentry)
            echo "ios-${2}" ;;
        server/build|server/test|server/lint|server/format|server/docs|server/sqlc|server/watch)
            echo "server-${2}" ;;
        server/live)
            case "${3:-}" in
                status|logs|deploy|rollback|snapshots|clusters|deployments|releases|machines|sentry)
                    echo "server-live-${3}" ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

_srv_forward() {
    local op="$1"
    shift
    local payload
    payload=$(python3 -c 'import json,sys; print(json.dumps({"op": sys.argv[1], "args": sys.argv[2:]}))' "$op" "$@")
    trap 'curl -sS -m 5 -X POST "$TURN_BUILD_SERVER_URL/kill" >/dev/null 2>&1; echo "→ Build server op cancelled"; exit 130' INT
    set +e
    local libdir
    libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    curl -sS -N -X POST "$TURN_BUILD_SERVER_URL/run" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null \
        | python3 "$libdir/build-server-filter.py"
    local parts=("${PIPESTATUS[@]}")
    set -e
    trap - INT
    if [[ "${parts[0]:-1}" -ne 0 ]]; then
        echo "✗ Build server not reachable at $TURN_BUILD_SERVER_URL — start it with ./build.sh builder start" >&2
        return 1
    fi
    return "${parts[1]:-1}"
}
