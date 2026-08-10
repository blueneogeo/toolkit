# toolkit/shared/debug.sh — combined multi-platform log interleaver
# Provides: _do_combined_debug
# Depends on: _fmt_server_log (shared/build-utils.sh)
# Config: SERVER_LOG_FILE (default server.log), SERVER_LOG_DIR (default .watch)

_do_combined_debug() {
    local cat_args=()
    local level_args=()
    local script_args=()
    local log_dir="${SERVER_LOG_DIR:-.watch}"
    local log_file="${log_dir}/${SERVER_LOG_FILE:-server.log}"

    set -f
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --cat) cat_args=(--cat "$2"); shift 2 ;;
            --level) level_args=(--level "$2"); shift 2 ;;
            --script) script_args=(--script "$2"); shift 2 ;;
            *) echo "⚠ Unknown flag: $1" >&2; shift ;;
        esac
    done
    set +f

    local server_log_path="$SCRIPT_DIR/server/$log_file"
    if [[ ! -f "$server_log_path" ]]; then
        echo "✗ Local server not running (no log at $server_log_path). Start with: ./build.sh server start"
        return 1
    fi

    local level_val=""
    [[ ${#level_args[@]} -ge 2 ]] && level_val="${level_args[1]}"

    local srv_pid=0

    cleanup() {
        local pgid
        pgid=$(ps -o pgid= -p $srv_pid 2>/dev/null | tr -d ' ')
        [[ -n "$pgid" ]] && kill -- -"$pgid" 2>/dev/null
        wait 2>/dev/null
    }
    trap cleanup EXIT INT TERM

    tail -n 0 -F "$server_log_path" | _fmt_server_log "[srv] " "$level_val" &
    srv_pid=$!

    echo ""
    echo "→ Combined debug session started. Go to home screen to stop."
    echo ""

    local ios_debug_args=()
    [[ ${#cat_args[@]} -gt 0 ]] && ios_debug_args+=("${cat_args[@]}")
    [[ ${#level_args[@]} -gt 0 ]] && ios_debug_args+=("${level_args[@]}")
    [[ ${#script_args[@]} -gt 0 ]] && ios_debug_args+=("${script_args[@]}")

    if [[ ${#ios_debug_args[@]} -gt 0 ]]; then
        (cd "$SCRIPT_DIR/ios" && ./build.sh debug "${ios_debug_args[@]}") | while IFS= read -r line; do
            echo "[ios] $line"
        done
    else
        (cd "$SCRIPT_DIR/ios" && ./build.sh debug) | while IFS= read -r line; do
            echo "[ios] $line"
        done
    fi
    local ios_exit=${PIPESTATUS[0]}

    cleanup
    return $ios_exit
}
