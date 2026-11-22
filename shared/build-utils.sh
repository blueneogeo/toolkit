# toolkit/shared/build-utils.sh — generic helpers (sourced by all platform toolkits)
# Provides: _tty_green, _tty_red, _tty_yellow, _tty_reset, _pid_running, _require_cmd, _fmt_server_log,
#           _help_asked, _help_show

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

# ── Help ────────────────────────────────────────────────────────────
#
# Every dispatcher starts with
#     if _help_asked "$@"; then _help_show "./build.sh <target>" <files...> -- "$@"; exit $?; fi
# before it builds, signs in or calls anything, so asking for help never runs a
# command. The text is in build-help.txt beside each dispatcher:
#
#   Lines before the first marker   The target's introduction, at the top of its list.
#   -- <heading>                    A heading in the list.
#   == <command words> <arguments>  A command. A trailing LIVE marks one that changes
#                                   something live. The lines after it are its help;
#                                   the first one is its line in the list.
#
# "<target> <words> --help" shows the commands whose words start with the
# words given: "server live deploy --help" one command, "server live --help"
# all of live.

# _help_asked <args...>: an argument before "--" is help, --help or -h.
_help_asked() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --) return 1 ;;
            help|--help|-h) return 0 ;;
        esac
    done
    return 1
}

# _help_show <title> <help files...> -- <args...>: the help of the commands the
# arguments name, or the list of all commands when they name none. Missing
# files are skipped. Returns 1 when the arguments name an unknown command.
# A dispatcher can define _help_more <command words> to add text after a
# command's help.
_help_show() {
    local title="$1"
    shift
    local files=() words=() arg skip=false out code=0 matched
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        [[ -f "$1" ]] && files+=("$1")
        shift
    done
    [[ $# -gt 0 ]] && shift
    for arg in "$@"; do
        [[ "$arg" == "--" ]] && break
        if $skip; then
            skip=false
            continue
        fi
        case "$arg" in
            help|--help|-h) ;;
            --device|-d|--config|-c) skip=true ;;
            *) [[ "$arg" =~ ^[a-z0-9][a-z0-9-]*$ ]] && words+=("$arg") ;;
        esac
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "No help text found for $title."
        return 1
    fi
    out=$(awk -v title="$title" -v words="${words[*]+${words[*]}}" "$_HELP_AWK" "${files[@]}") || code=$?
    matched="${out%%$'\n'*}"
    printf '%s\n' "${out#*$'\n'}"
    if [[ $code -eq 0 && -n "$matched" ]] && declare -F _help_more >/dev/null; then
        # shellcheck disable=SC2086
        _help_more $matched
    fi
    [[ $code -eq 0 ]]
}

# Prints the matched command words on the first line, then the text.
_HELP_AWK='
function trim_body(s,   n) {
    n = nbody[s]
    while (n > 0 && B[s, n] ~ /^[ \t]*$/) n--
    nbody[s] = n
}
function summary(s,   k) {
    for (k = 1; k <= nbody[s]; k++) if (B[s, k] !~ /^[ \t]*$/) { t = B[s, k]; sub(/^[ \t]+/, "", t); return t }
    return ""
}
function list_line(s,   u, d) {
    u = usage[s]
    d = summary(s)
    if (live[s]) d = "LIVE: " d
    if (length(u) <= 28) printf "  %-28s  %s\n", u, d
    else printf "  %s\n  %-28s  %s\n", u, "", d
}
function show(s,   hdr, k) {
    hdr = title " " usage[s]
    if (live[s]) {
        if (length(hdr) < 74) hdr = sprintf("%-74s LIVE", hdr)
        else hdr = hdr "  LIVE"
    }
    print hdr
    if (nbody[s] > 0) print ""
    for (k = 1; k <= nbody[s]; k++) {
        if (B[s, k] ~ /^[ \t]*$/) print ""
        else print "    " B[s, k]
    }
}
function overview(   k, it, n) {
    for (k = 1; k <= nintro; k++) {
        n = split(intro[k], L, "\n")
        while (n > 0 && L[n] ~ /^[ \t]*$/) n--
        while (n > 0 && L[1] ~ /^[ \t]*$/) { for (j = 1; j < n; j++) L[j] = L[j + 1]; n-- }
        if (n == 0) continue
        if (printed) print ""
        for (j = 1; j <= n; j++) print L[j]
        printed = 1
    }
    for (k = 1; k <= nitem; k++) {
        it = item[k]
        if (substr(it, 1, 1) == "h") { print ""; print substr(it, 2) ":" }
        else list_line(substr(it, 2) + 0)
    }
    print ""
    print "One command in full: " title " <command> --help"
    print "Asking for help (--help, -h or help) never runs anything."
}
FNR == 1 { nintro++; intro[nintro] = ""; inintro = 1; cur = 0 }
/^== / {
    inintro = 0
    nsec++
    u = substr($0, 4)
    live[nsec] = 0
    if (u ~ / LIVE$/) { live[nsec] = 1; sub(/ +LIVE$/, "", u) }
    usage[nsec] = u
    n = split(u, T, " ")
    nc = 0
    for (k = 1; k <= n; k++) {
        if (T[k] ~ /^[a-z0-9][a-z0-9-]*$/) { nc++; CW[nsec, nc] = T[k] } else break
    }
    ncw[nsec] = nc
    FIRST[CW[nsec, 1]] = 1
    nitem++
    item[nitem] = "s" nsec
    cur = nsec
    next
}
/^-- / {
    inintro = 0
    nitem++
    item[nitem] = "h" substr($0, 4)
    cur = 0
    next
}
{
    if (inintro) intro[nintro] = intro[nintro] $0 "\n"
    else if (cur) { nbody[cur]++; B[cur, nbody[cur]] = $0 }
}
function starts(s, from, len,   k) {
    if (ncw[s] < len) return 0
    for (k = 0; k < len; k++) if (CW[s, k + 1] != W[from + k]) return 0
    return 1
}
END {
    for (s = 1; s <= nsec; s++) trim_body(s)
    nw = split(words, W, " ")
    if (nw == 0) { print ""; overview(); exit 0 }
    from = 0
    for (k = 1; k <= nw; k++) if (W[k] in FIRST) { from = k; break }
    if (!from) {
        print ""
        print "No command \"" W[1] "\" in " title "."
        print ""
        overview()
        exit 2
    }
    len = 1
    while (from + len <= nw) {
        found = 0
        for (s = 1; s <= nsec; s++) if (starts(s, from, len + 1)) { found = 1; break }
        if (!found) break
        len++
    }
    m = W[from]
    for (k = 1; k < len; k++) m = m " " W[from + k]
    print m
    shown = 0
    for (pass = 1; pass <= 2; pass++) {
        for (s = 1; s <= nsec; s++) {
            if (!starts(s, from, len)) continue
            if ((pass == 1) != (ncw[s] == len)) continue
            if (shown) print ""
            show(s)
            shown++
        }
    }
}
'
