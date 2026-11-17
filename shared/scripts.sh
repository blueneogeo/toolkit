# toolkit/shared/scripts.sh: debug script names shared by the platform toolkits
# Provides: _sanitize_script_names, _note_script_line, _script_summary

_sanitize_script_names() {
    local names="$1"
    local pattern='^[A-Za-z0-9_, -]+$'
    if [[ "$names" =~ $pattern && "$names" =~ [A-Za-z0-9_] ]]; then
        printf '%s' "$names"
        return 0
    fi
    echo "✗ Invalid --script names: use comma-separated identifiers (letters, digits, _, -, space)."
    return 1
}

# Scripts report each failed check as a CHECK_FAILED line and end with
# "DEBUG_SESSION_ENDED failed=<n>". Keeps those lines for the summary, put
# through the platform's line formatter when one is given.
_note_script_line() {
    local line="$1" results="$2" format="${3:-cat}"
    case "$line" in
        *CHECK_FAILED*|*SCRIPT_RESULT*|*DEBUG_SESSION_ENDED*)
            echo "$line" | "$format" >> "$results"
            ;;
    esac
}

# The summary of a script run, and whether every check passed.
_script_summary() {
    local results="$1"
    echo ""
    if ! grep -q "DEBUG_SESSION_ENDED" "$results" 2>/dev/null; then
        echo "✗ The app stopped before its scripts ended."
        return 1
    fi
    grep "SCRIPT_RESULT" "$results" | sed -E 's/.*SCRIPT_RESULT /  /'
    local failed
    failed=$(grep "DEBUG_SESSION_ENDED" "$results" | sed -nE 's/.*failed=([0-9]+).*/\1/p' | tail -1)
    if [[ "${failed:-0}" -gt 0 ]]; then
        echo "✗ $failed check(s) failed:"
        grep "CHECK_FAILED" "$results" | sed -E 's/.*CHECK_FAILED /  /'
        return 1
    fi
    echo "✓ Every check passed."
}
