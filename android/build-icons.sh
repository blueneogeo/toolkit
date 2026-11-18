#!/bin/bash
# android-toolkit/build-icons.sh: SF Symbols mapped to Material Symbols vectors
# Sourced by build.sh. Wraps icons.py, which reads icons.toml from the shared
# token folders and the iOS sources from TURN_ROOT (read-only, with git).
#
# Provides: do_icons, _icons_gate

ICONS_PY="$SCRIPT_DIR/icons.py"

_icons_usage() {
    cat <<'EOF'
Usage: ./build.sh android icons [command]

  (none), generate  Download the mapped Material Symbols, write res/drawable/ic_*.xml
                    and view/generated/TurnIcons.kt, delete drawables nothing maps.
                    Fails when an SF name in the iOS sources isn't in icons.toml
  check             The same checks offline: mapping, drawables, table and every
                    TurnIcon("...") call in the app (lint runs it)
  scan [--commit c] SF names in the iOS sources with their sites; ! marks unmapped
  sheet [--out dir] The review sheet: SF and Material side by side (HTML)
EOF
}

_icons_python() {
    python3 -B "$ICONS_PY" "$@" --project "$PROJECT_ROOT" --turn-root "$TURN_ROOT"
}

# Skipped when the project has no icons.toml.
_icons_gate() {
    [[ -f "$PROJECT_ROOT/shared-pending/tokens/icons.toml" || -f "${TURN_ROOT:-/nonexistent}/shared/tokens/icons.toml" ]] || return 0
    echo "→ Icons gate"
    _icons_python check
}

do_icons() {
    if [[ -z "${TURN_ROOT:-}" ]]; then
        echo "✗ TURN_ROOT is not set. Add the leading repository's path to build.properties."
        return 1
    fi
    local command="${1:-generate}"
    [[ $# -gt 0 ]] && shift
    case "$command" in
        generate|check|scan|sheet) _icons_python "$command" "$@" ;;
        help|--help|-h) _icons_usage ;;
        *)
            echo "✗ Unknown icons command: $command"
            _icons_usage
            return 1
            ;;
    esac
}
