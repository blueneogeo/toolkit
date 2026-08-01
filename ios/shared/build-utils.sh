# ios-toolkit/shared/build-utils.sh — generic helpers
# Provides: _tty_green, _tty_red, _tty_yellow, _tty_reset, _pid_running, _require_cmd, _fmt_server_log

# ── Color helpers ──────────────────────────────────────────────────

_tty_green()  { [[ -t 1 ]] && printf '\033[32m'; return 0; }
_tty_red()    { [[ -t 1 ]] && printf '\033[31m'; return 0; }
_tty_yellow() { [[ -t 1 ]] && printf '\033[33m'; return 0; }
_tty_reset()  { [[ -t 1 ]] && printf '\033[0m'; return 0; }

# ── Process helpers ─────────────────────────────────────────────────

_pid_running() {
    [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

# ── Tool requirement ────────────────────────────────────────────────

_require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "✗ '$1' not found. Install it first."
        [[ -n "${2:-}" ]] && echo "  ${2}"
        exit 1
    fi
}

# ── Server log formatting ────────────────────────────────────────────

_fmt_server_log() {
    local prefix="${1:-}"
    local level_filter="${2:-}"
    while IFS= read -r line; do
        [[ "$line" != {* ]] && echo "$line" && continue

        IFS=$'\t' read -r time level msg rest <<< "$(printf '%s\n' "$line" | sed -E 's/\{"time":"[^"]*T([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+)[^"]*","level":"([^"]*)","msg":"([^"]*)"(.*)\}$/\1\t\2\t\3\t\4/')"
        time="${time}000000"
        time="${time:0:15}"

        if [[ "$msg" == "request" ]]; then
            IFS=$'\t' read -r method path st dur <<< "$(printf '%s\n' "$rest" | sed -E 's/.*"method":"([^"]*)","path":"([^"]*)","status":([0-9]+),"duration":"([^"]*)".*/\1\t\2\t\3\t\4/')"
            formatted="${prefix}$time  $level  [request]  $method $path  $st  $dur"
        else
            pairs=$(echo "${rest%\}}" | sed -E '
                s/,"([^"]*)":"([^"]*)"/ \1=\2/g
                s/,"([^"]*)":([0-9]+(\.[0-9]+)?)/ \1=\2/g
                s/,"([^"]*)":(true|false)/ \1=\2/g
                s/,"([^"]*)":null/ \1=null/g
                s/,"([^"]*)":\[/ \1=[/g
                s/,"([^"]*)":\{/ \1={/g
            ')
            formatted="${prefix}$time  $level  [$msg]$pairs"
        fi

        if [[ -n "$level_filter" ]]; then
            case "$level_filter" in
                info)    [[ "$level" != "DEBUG" ]] && echo "$formatted" ;;
                warning) [[ "$level" != "DEBUG" && "$level" != "INFO" ]] && echo "$formatted" ;;
                error)   [[ "$level" == "WARN" || "$level" == "ERROR" ]] && echo "$formatted" ;;
            esac
        else
            echo "$formatted"
        fi
    done
}
