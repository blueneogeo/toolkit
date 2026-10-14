# toolkit/shared/logfmt.sh: app log lines shared by the platform toolkits
# Lines look like "HH:MM:SS.mmm  LEVEL [cat] msg" on every platform.
# Provides: _level_grep

_level_grep() {
    case "${1:-}" in
        info)    grep -v "  DEBUG " || true ;;
        warning) grep -v -E "  (DEBUG|INFO) " || true ;;
        error)   grep -E "  (WARNING|ERROR) " || true ;;
        *)       cat ;;
    esac
}
