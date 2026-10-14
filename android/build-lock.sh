#!/bin/bash
# android-toolkit/build-lock.sh: shared locks between agents and terminals
# Sourced by build.sh. A lock is a set of slot directories made with mkdir
# under <overnight>/locks/, each holding the owner's PID and start time.
# gradle has two slots, emulator one. A slot whose owner is gone is cleared.
# TOOLKIT_LOCKS_HELD (exported) lets commands run under `lock` reuse the lock.
#
# Provides: do_lock, _lock_take, _lock_release, _ui_wants_lock
# Depends on: _overnight_root (build-overnight.sh)

_LOCK_SLOTS=()

_lock_usage() {
    cat <<'EOF'
Usage: ./build.sh android lock <gradle|emulator> -- <command...>
       ./build.sh android lock status

  Run a command while holding a lock shared by every checkout and worktree on
  this Mac. gradle has two holders at most, emulator one. A command waits up to
  20 minutes (TOOLKIT_LOCK_TIMEOUT, in seconds) and then fails.

  build, test, lint and format take the gradle lock while Gradle runs; install,
  launch, uninstall, debug, record, screenshot, screenshots collect, see, ui and
  emulator start|stop take the emulator lock. Commands run inside 'lock' reuse
  the lock they already hold, so one lock can cover install, a script run and
  collecting its frames:

    ./build.sh android lock emulator -- sh -c './build.sh android debug --script lens_check && ./build.sh android screenshots collect'

  Locks whose holder has exited are cleared. Locks live in
  <overnight>/locks/ (TOOLKIT_OVERNIGHT_DIR).
EOF
}

_lock_holders() {
    case "$1" in
        gradle) echo 2 ;;
        emulator) echo 1 ;;
        *) return 1 ;;
    esac
}

_lock_dir() {
    echo "$(_overnight_root)/locks"
}

_lock_is_held_here() {
    [[ " ${TOOLKIT_LOCKS_HELD:-} " == *" $1 "* ]]
}

_process_start() {
    ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' || true
}

# True when the slot's owner is still the process that took it.
_lock_slot_alive() {
    local slot="$1" pid started
    [[ -f "$slot/owner" ]] || return 1
    pid=$(sed -n 1p "$slot/owner")
    started=$(sed -n 2p "$slot/owner")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(_process_start "$pid")" == "$started" ]]
}

# A slot without an owner file is being written; give it 10 seconds.
_lock_slot_stale() {
    local slot="$1"
    if [[ ! -f "$slot/owner" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -f %m "$slot" 2>/dev/null || date +%s) ))
        [[ $age -gt 10 ]]
        return
    fi
    ! _lock_slot_alive "$slot"
}

_lock_describe_holders() {
    local name="$1" slot
    for slot in "$(_lock_dir)/$name".*; do
        [[ -f "$slot/owner" ]] || continue
        echo "PID $(sed -n 1p "$slot/owner"): $(sed -n 3p "$slot/owner")"
    done
}

_lock_take() {
    local name="$1"
    _lock_is_held_here "$name" && return 0
    local holders dir
    holders=$(_lock_holders "$name") || { echo "✗ Unknown lock '$name'. Use gradle or emulator."; return 1; }
    dir=$(_lock_dir)
    mkdir -p "$dir"

    local timeout="${TOOLKIT_LOCK_TIMEOUT:-1200}" started=$SECONDS announced=false
    while true; do
        local i slot
        for ((i = 1; i <= holders; i++)); do
            slot="$dir/$name.$i"
            if mkdir "$slot" 2>/dev/null; then
                printf '%s\n%s\n%s\n%s\n' "$$" "$(_process_start "$$")" "${_LOCK_COMMAND:-${_INVOCATION:-}}" "$PROJECT_ROOT" > "$slot/owner"
                _LOCK_SLOTS+=("$slot")
                TOOLKIT_LOCKS_HELD="${TOOLKIT_LOCKS_HELD:-} $name"
                export TOOLKIT_LOCKS_HELD
                trap '_lock_release_all' EXIT
                $announced && echo "  got the $name lock after $((SECONDS - started))s"
                return 0
            fi
            if _lock_slot_stale "$slot"; then
                rm -rf "$slot"
                [[ -e "$slot" ]] || i=$((i - 1))
            fi
        done
        if ! $announced; then
            echo "→ Waiting for the $name lock, held by:"
            _lock_describe_holders "$name" | sed 's/^/    /'
            announced=true
        fi
        if (( SECONDS - started >= timeout )); then
            echo "✗ Waited ${timeout}s for the $name lock. Log it with:"
            echo "  ./build.sh blocker add --kind lock-timeout --summary \"Waited ${timeout}s for the $name lock\""
            return 1
        fi
        sleep 1
    done
}

_lock_release() {
    local name="$1" kept=() slot
    for slot in ${_LOCK_SLOTS[@]+"${_LOCK_SLOTS[@]}"}; do
        if [[ "$(basename "$slot")" == "$name".* ]]; then
            rm -rf "$slot"
        else
            kept+=("$slot")
        fi
    done
    _LOCK_SLOTS=(${kept[@]+"${kept[@]}"})
    TOOLKIT_LOCKS_HELD=$(tr ' ' '\n' <<<"${TOOLKIT_LOCKS_HELD:-}" | grep -vx "$name" | tr '\n' ' ' || true)
    export TOOLKIT_LOCKS_HELD
}

_lock_release_all() {
    local slot
    for slot in ${_LOCK_SLOTS[@]+"${_LOCK_SLOTS[@]}"}; do
        rm -rf "$slot"
    done
    _LOCK_SLOTS=()
}

_ui_wants_lock() {
    case "${1:-}" in
        tap|swipe|type|press|describe) return 0 ;;
    esac
    return 1
}

_lock_status() {
    local dir name slot any=false
    dir=$(_lock_dir)
    for name in gradle emulator; do
        local line=""
        for slot in "$dir/$name".*; do
            [[ -d "$slot" ]] || continue
            any=true
            if _lock_slot_alive "$slot"; then
                line="PID $(sed -n 1p "$slot/owner"): $(sed -n 3p "$slot/owner") (in $(sed -n 4p "$slot/owner"))"
            else
                line="stale (cleared on the next take)"
            fi
            echo "  $name: $line"
        done
    done
    $any || echo "  No locks held."
}

do_lock() {
    case "${1:-}" in
        ""|help|-h|--help) _lock_usage; return 0 ;;
        status) _lock_status; return 0 ;;
    esac
    local name="$1"
    shift
    if [[ "${1:-}" != "--" || $# -lt 2 ]]; then
        echo "✗ Give the command after --: ./build.sh android lock $name -- <command...>"
        return 1
    fi
    shift
    _LOCK_COMMAND="$*"
    _lock_take "$name" || return 1
    local code=0
    "$@" || code=$?
    _lock_release "$name"
    return "$code"
}
