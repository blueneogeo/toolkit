#!/bin/bash
# Per-project build-server lifecycle. Sourceable: project roots source this
# for builder_start/stop/status. Executed directly, it launches the server.
set -euo pipefail
_BUILD_SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO_ROOT:=$(cd "$_BUILD_SERVER_DIR/../.." && pwd)}"
export REPO_ROOT
source "$_BUILD_SERVER_DIR/server-port.sh"

BUILDER_PORT_FILE="$REPO_ROOT/.watch/builder.port"
BUILDER_PID="$REPO_ROOT/.watch/builder.pid"
BUILDER_LOG="$REPO_ROOT/.watch/builder.log"

_builder_port() {
    if [[ -n "${PORT:-}" ]]; then
        echo "${PORT}"
    elif [[ -s "$BUILDER_PORT_FILE" ]]; then
        cat "$BUILDER_PORT_FILE"
    elif declare -F _builder_port_for >/dev/null 2>&1; then
        _builder_port_for "$REPO_ROOT"
    else
        echo "8471"
    fi
}
BUILDER_PORT="$(_builder_port)"
BUILDER_URL="${TURN_BUILD_SERVER_URL:-http://127.0.0.1:$BUILDER_PORT}"

_builder_healthy() {
    local out
    out=$(curl -sS -m 2 "$BUILDER_URL/health" 2>/dev/null || true)
    [[ "$out" == "ok" ]]
}

_builder_info() {
    local url="$1"
    curl -sS -m 2 "$url/info" 2>/dev/null || true
}

_builder_field() {
    local json="$1" key="$2"
    python3 -c 'import json,sys
def _load():
    try:
        return json.loads(sys.argv[1])
    except Exception:
        return {}
v = _load().get(sys.argv[2], "")
print(v if type(v) in (str, int) else "")' "$json" "$key" 2>/dev/null || true
}

_port_open() {
    local port="$1"
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

_fmt_uptime() {
    local total="${1:-0}"
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    local h=$((total / 3600)) m=$(((total % 3600) / 60)) s=$((total % 60))
    if (( h > 0 )); then
        echo "${h}h ${m}m"
    elif (( m > 0 )); then
        echo "${m}m ${s}s"
    else
        echo "${s}s"
    fi
}

builder_start() {
    mkdir -p "$REPO_ROOT/.watch"
    local port
    port=$(_builder_port)
    local info proj
    info=$(_builder_info "$BUILDER_URL" || true)
    proj=$(_builder_field "$info" project || true)
    if [[ "$proj" == "$REPO_ROOT" ]]; then
        if _builder_healthy; then
            echo "Build server already running at $BUILDER_URL"
            return 0
        fi
        if [[ -f "$BUILDER_PID" ]] && kill -0 "$(cat "$BUILDER_PID")" 2>/dev/null; then
            echo "Build server already starting (pid $(cat "$BUILDER_PID"))"
            return 0
        fi
    elif [[ -n "$proj" ]] || _port_open "$port"; then
        local lo hi range attempts
        lo="${BUILDER_PORT_LO:-8471}"
        hi="${BUILDER_PORT_HI:-8570}"
        range=$((hi - lo + 1))
        attempts=0
        while [[ -n "$proj" ]] || _port_open "$port"; do
            attempts=$((attempts + 1))
            if (( attempts >= range )); then
                echo "✗ No free builder port in [$lo,$hi]"
                return 1
            fi
            port=$((port + 1))
            if (( port > hi || port < lo )); then
                port=$lo
            fi
            info=$(_builder_info "http://127.0.0.1:$port" || true)
            proj=$(_builder_field "$info" project || true)
        done
    fi
    rm -f "$BUILDER_PID"
    BUILDER_PORT="$port"
    BUILDER_URL="${TURN_BUILD_SERVER_URL:-http://127.0.0.1:$port}"
    if ! command -v setsid >/dev/null 2>&1; then
        _setsid_fallback() {
            python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
        }
        PORT="$port" BUILDER_PIDFILE="$BUILDER_PID" _setsid_fallback nohup "$_BUILD_SERVER_DIR/run.sh" > "$BUILDER_LOG" 2>&1 < /dev/null &
    else
        PORT="$port" BUILDER_PIDFILE="$BUILDER_PID" setsid nohup "$_BUILD_SERVER_DIR/run.sh" > "$BUILDER_LOG" 2>&1 < /dev/null &
    fi
    echo $! > "$BUILDER_PID"
    printf '%s\n' "$port" > "$BUILDER_PORT_FILE"
    local i pid
    for i in $(seq 1 20); do
        if _builder_healthy && [[ -f "$BUILDER_PID" ]] && pid=$(cat "$BUILDER_PID" 2>/dev/null); then
            case "$pid" in
                ''|*[!0-9]*) ;;
                *)
                    if kill -0 "$pid" 2>/dev/null; then
                        echo "Build server running at $BUILDER_URL (pid $(cat "$BUILDER_PID"), log $BUILDER_LOG, port $port)"
                        return 0
                    fi
                    ;;
            esac
        fi
        sleep 0.5
    done
    echo "✗ Build server did not come up — see $BUILDER_LOG"
    return 1
}

builder_stop() {
    if [[ -f "$BUILDER_PID" ]]; then
        local pid
        pid=$(cat "$BUILDER_PID")
        kill "$pid" 2>/dev/null || true
        local i
        for i in $(seq 1 10); do
            _builder_healthy || break
            sleep 0.5
        done
        if _builder_healthy; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$BUILDER_PID"
        rm -f "$BUILDER_PORT_FILE"
        echo "Build server stopped"
    elif _builder_healthy; then
        echo "Build server is running but has no pid file (started manually?) — stop it in its own terminal"
        return 1
    else
        echo "Build server is not running"
    fi
}

builder_status() {
    local info proj
    info=$(_builder_info "$BUILDER_URL" || true)
    proj=$(_builder_field "$info" project || true)
    local running=0
    if _builder_healthy && [[ "$proj" == "$REPO_ROOT" ]]; then
        running=1
        local pid uptime_s
        pid=$(_builder_field "$info" pid || true)
        if [[ -z "$pid" && -f "$BUILDER_PID" ]]; then
            pid=$(cat "$BUILDER_PID")
        fi
        uptime_s=$(_builder_field "$info" uptime_s || true)
        echo "● Builder (this project): RUNNING"
        echo "  Project  $REPO_ROOT"
        echo "  URL      $BUILDER_URL"
        if [[ -n "$uptime_s" ]]; then
            echo "  PID      ${pid:-?} (alive) · uptime $(_fmt_uptime "$uptime_s")"
        else
            echo "  PID      ${pid:-?} (alive)"
        fi
        echo "  Log      .watch/builder.log"
    elif [[ -n "$proj" ]]; then
        echo "● Builder (this project): CONFLICT — port $BUILDER_PORT is serving $proj"
    else
        echo "○ Builder (this project): STOPPED"
        echo "  Project  $REPO_ROOT"
        echo "  Expected $BUILDER_URL (port free — start with ./build.sh builder start)"
    fi
    local lo hi
    lo="${BUILDER_PORT_LO:-8471}"
    hi="${BUILDER_PORT_HI:-8570}"
    local peer_lines="" peer_count=0
    local p pinfo pproj ppid entry
    for p in $(seq "$lo" "$hi"); do
        if [[ "$p" == "$BUILDER_PORT" ]]; then
            continue
        fi
        pinfo=$(curl -sS -m 1 --connect-timeout 1 "http://127.0.0.1:$p/info" 2>/dev/null || true)
        [[ -n "$pinfo" ]] || continue
        pproj=$(_builder_field "$pinfo" project || true)
        [[ -n "$pproj" ]] || continue
        ppid=$(_builder_field "$pinfo" pid || true)
        entry="  ● $pproj → http://127.0.0.1:$p (pid ${ppid:-?})"
        if (( peer_count == 0 )); then
            peer_lines="$entry"
        else
            peer_lines="$peer_lines
$entry"
        fi
        peer_count=$((peer_count + 1))
    done
    echo "Other builder servers ($peer_count):"
    if (( peer_count == 0 )); then
        echo "  (none)"
    else
        printf '%s\n' "$peer_lines"
    fi
    if (( running )); then
        return 0
    fi
    return 1
}

builder() {
    case "${1:-status}" in
        start)  builder_start ;;
        stop)   builder_stop ;;
        status) builder_status ;;
        *)      echo "Usage: ./build.sh builder <start|stop|status>"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    PORT="${PORT:-$(_builder_port)}"
    echo "build-server ready on port $PORT (repo $REPO_ROOT)"
    exec python3 "$_BUILD_SERVER_DIR/server.py"
fi
