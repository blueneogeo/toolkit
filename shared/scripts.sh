# toolkit/shared/scripts.sh: debug script names shared by the platform toolkits
# Provides: _sanitize_script_names

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
