#!/bin/bash
# android-toolkit/build-sync.sh: the parity map, its gate and the sync ledger
# Sourced by build.sh. Wraps toolkit/shared/parity/parity.py, which reads iOS
# from a commit of the leading repository (TURN_ROOT, read-only) and the
# project's parity.toml and sync/ ledger.
#
# Provides: do_sync, _parity_gate
# Depends on: _resolve_java_home, _lock_take, _lock_release, _lock_is_held_here

PARITY_PY="$SCRIPT_DIR/../shared/parity/parity.py"

_sync_usage() {
    cat <<'EOF'
Usage: ./build.sh android sync <command> [args]

  status [--to <commit>] [-v]  Units whose iOS files changed since they were ported, with
                               the commits, symbol changes and interaction APIs in the diff.
                               iOS is read from a commit of TURN_ROOT (default: its main).
                               Exits 1 while anything is pending
  diff <unit> [--to <commit>]  The iOS diff of one unit since it was ported
  mark <unit>... [--to <commit>] [--status <s>] [--no-change "<reason>"]
                               Record units as ported from the iOS commit. Refuses a unit
                               whose iOS side changed while its Android files did not, and
                               one that fails the parity check
  mark --commit [--to <commit>]
                               Move the marker once nothing is pending
  map [--gate] [--at <commit>] [--unit <unit>]
                               Compare iOS and Android symbol by symbol; writes
                               build/parity/map.md. --gate fails on errors (lint runs it)
  init --at <commit> [--force] Write the ledger: one file per unit under sync/
  coverage [<log>|-]           Turn '[coverage] script=.. frame=.. views=..' log lines into
                               sync/coverage.json and flag view units no script shows
  guide [--seed] [--at <c>]    Check the Coverage block of doc/platform-mapping.md, or print
                               a seeded block with every iOS import and framework type

  A unit is an iOS file under ios/Turn, ios/debug or ios/TurnTests, named by its path
  without the extension and '+' (model/AppStateFeed), or by its iOS or Android path.
EOF
}

_sync_env() {
    if [[ -z "${TURN_ROOT:-}" ]]; then
        echo "✗ TURN_ROOT is not set. Add the leading repository's path to build.properties."
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "✗ python3 is not installed; the parity tools need Python 3.11 or newer."
        return 1
    fi
    _SYNC_JAVA_HOME=$(_resolve_java_home) || return 1
}

_sync_python() {
    JAVA_HOME="$_SYNC_JAVA_HOME" PROJECT_ROOT="$PROJECT_ROOT" TURN_ROOT="$TURN_ROOT" python3 -B "$PARITY_PY" "$@"
}

# Builds the extractors under the gradle lock when their sources changed.
_sync_tools() {
    local code=0
    _sync_python tools >/dev/null 2>&1 || code=$?
    [[ $code -eq 0 ]] && return 0
    if [[ $code -ne 3 ]]; then
        _sync_python tools
        return 1
    fi
    local held=false
    _lock_is_held_here gradle && held=true
    _lock_take gradle || return 1
    code=0
    _sync_python tools --build || code=$?
    $held || _lock_release gradle
    return "$code"
}

do_sync() {
    case "${1:-}" in
        ""|help|--help|-h)
            _sync_usage
            return 0
            ;;
    esac
    _sync_env || return 1
    _sync_tools || return 1
    _sync_python "$@"
}

# Part of lint: fails when an iOS symbol has no Kotlin twin, or a twin is misnamed or moved.
_parity_gate() {
    if [[ ! -f "$PROJECT_ROOT/parity.toml" ]]; then
        return 0
    fi
    if [[ ! -f "$PROJECT_ROOT/sync/_sync.toml" ]]; then
        echo "⚠ No ledger under sync/; parity gate skipped (./build.sh android sync init --at <commit>)"
        return 0
    fi
    echo "→ Parity gate"
    _sync_env || return 1
    _sync_tools || return 1
    PARITY_QUIET=1 _sync_python map --gate
}
