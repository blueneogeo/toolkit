#!/bin/bash
# Argument parsing of debug, record, ui, see and screenshots collect, and the
# fixture's stale-app check, against a fake adb. No emulator, Gradle or server.
#
#   bash toolkit/android/tests/args_test.sh
#
# Prints one line per failed case and the count; exits 1 when one failed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/project" "$WORK/sdk/platform-tools" "$WORK/state"
cat > "$WORK/project/build.properties" <<'EOF'
ANDROID_APPLICATION_ID=com.example.app
ANDROID_LOG_TAG=Turn
TOOLKIT_DEBUG_SCRIPTS=true
EOF

# The fake adb logs every call to state/adb.log and answers the few commands
# the toolkit reads from.
cat > "$WORK/sdk/platform-tools/adb" <<'EOF'
#!/bin/bash
state="$FAKE_ADB_STATE"
echo "$*" >> "$state/adb.log"
[[ "$1" == "-s" ]] && shift 2
case "$*" in
    devices) printf 'List of devices attached\nemulator-5554\tdevice\n' ;;
    "emu avd name") printf 'Turn_Parity\r\nOK\r\n' ;;
    "shell wm density") printf 'Physical density: 480\r\n' ;;
    "shell wm size") printf 'Physical size: 1206x2622\r\n' ;;
    "exec-out uiautomator dump"*)
        failures=$(cat "$state/dump-failures" 2>/dev/null || echo 0)
        if [[ "$failures" -gt 0 ]]; then
            echo $((failures - 1)) > "$state/dump-failures"
            echo "ERROR: could not get idle state."
        else
            cat "$state/dump.xml"
            echo "UI hierchary dumped to: /dev/tty"
        fi
        ;;
    "shell pm path"*) [[ -f "$state/installed" ]] && echo "package:/data/app/base.apk" ;;
    "shell run-as com.example.app cat files/toolkit-fixture-seed"*) cat "$state/stamp" 2>/dev/null || true ;;
    "shell run-as com.example.app sh -c"*)
        if [[ "$*" == *toolkit-fixture-seed* ]]; then
            value="$*"
            value="${value#*echo }"
            value="${value%% > files*}"
            tr -d "'\\\\" <<<"$value" > "$state/stamp"
        fi
        ;;
    "shell dumpsys package com.example.app")
        cat <<'DUMP'
    install permissions:
      android.permission.INTERNET: granted=true
    User 0: ceDataInode=1 installed=true
      runtime permissions:
        android.permission.CAMERA: granted=true, flags=[ USER_SET ]
        android.permission.RECORD_AUDIO: granted=false, flags=[ USER_SET ]
        android.permission.READ_CONTACTS: granted=true, flags=[ USER_SET ]
      enabledComponents:
DUMP
        ;;
    "shell pm clear com.example.app") echo Success ;;
esac
exit 0
EOF
chmod +x "$WORK/sdk/platform-tools/adb"

export FAKE_ADB_STATE="$WORK/state"
export ANDROID_HOME="$WORK/sdk"
export TOOLKIT_PROJECT_ROOT="$WORK/project"
unset AGENT_SLOT ANDROID_LAUNCH_ARGS ANDROID_DEVICE
# shellcheck disable=SC1091
source "$TESTS_DIR/../build.sh"
set +e +o pipefail
_load_android_config
SERIAL=emulator-5554

# Nothing in these tests may build, lock or wait.
_lock_take() { return 0; }
do_build() { return 0; }
sleep() { :; }

FAILED=0
PASSED=0

_expect() {
    local name="$1" pattern="$2" output="$3"
    if grep -qE -- "$pattern" <<<"$output"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "✗ $name: expected /$pattern/ in:"
        sed 's/^/    /' <<<"$output"
    fi
}

_expect_not() {
    local name="$1" pattern="$2" output="$3"
    if grep -qE -- "$pattern" <<<"$output"; then
        FAILED=$((FAILED + 1))
        echo "✗ $name: did not expect /$pattern/ in:"
        sed 's/^/    /' <<<"$output"
    else
        PASSED=$((PASSED + 1))
    fi
}

_expect_code() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "✗ $name: exit $got, expected $want"
    fi
}

_reset_state() {
    rm -f "$WORK/state/"*
    touch "$WORK/state/adb.log"
}

# ── debug ───────────────────────────────────────────────────────────

_reset_state
out=$(_android_debug --timeout soon 2>&1); code=$?
_expect "debug --timeout soon" "needs a whole number of seconds" "$out"
_expect_code "debug --timeout soon" 1 "$code"

out=$(_android_debug --script 2>&1); code=$?
_expect "debug --script without names" "--script needs a value" "$out"
_expect_code "debug --script without names" 1 "$code"

out=$(_android_debug --script --no-build 2>&1)
_expect "debug --script followed by a flag" "--script needs a value" "$out"

out=$(_android_debug emulator device 2>&1); code=$?
_expect "debug with two targets" "Two targets: emulator and device" "$out"
_expect_code "debug with two targets" 1 "$code"

out=$(_android_debug --verbose 2>&1)
_expect "debug with an unknown flag" "Unknown flag: --verbose" "$out"

out=$(_android_debug --script 'lens_check;rm' 2>&1); code=$?
_expect "debug with a bad script name" "Invalid --script names" "$out"
_expect_code "debug with a bad script name" 1 "$code"

# Flags in any order reach the launch: stub everything after the parsing.
(
    _use_target() { echo "TARGET=${1:-none}"; }
    _app_id() { echo com.example.app; }
    _install_app() { :; }
    _reverse_server_port() { :; }
    _clear_scriptor_marker() { :; }
    _write_scriptor_marker() { :; }
    _app_pid() { echo 4242; }
    _fixture_extras() { echo "FIXTURE=$1"; _FIXTURE_EXTRAS=(--es TURN_CLOCK 2026-11-17T23:47:43Z); }
    _am_start() { shift; echo "EXTRAS=$*"; }
    _debug_follow() {
        _DEBUG_OUTCOME=ended
        printf '%s\n' "lens_check SCRIPT_RESULT lens_check: 2 passed, 0 failed" "DEBUG_SESSION_ENDED failed=0" > "$7"
    }
    _android_debug --script lens_check --no-build --fixture 3 emulator --level info
    echo "CODE=$?"
) > "$WORK/out" 2>&1
out=$(cat "$WORK/out")
_expect "debug flags in any order: target" "TARGET=emulator" "$out"
_expect "debug flags in any order: fixture slot" "FIXTURE=3" "$out"
_expect "debug flags in any order: script names" "EXTRAS=--es TURN_DEBUG_SCRIPT_NAMES lens_check" "$out"
_expect "debug flags in any order: fixture clock" "TURN_CLOCK 2026-11-17T23:47:43Z" "$out"
_expect "debug flags in any order: summary" "Every check passed" "$out"
_expect "debug flags in any order: exit" "CODE=0" "$out"

(
    AGENT_SLOT=6
    _use_target() { :; }
    _app_id() { echo com.example.app; }
    _install_app() { :; }
    _reverse_server_port() { :; }
    _app_pid() { echo 4242; }
    _fixture_extras() { echo "FIXTURE=$1"; return 1; }
    _android_debug --fixture --no-build
) > "$WORK/out" 2>&1
_expect "debug --fixture takes AGENT_SLOT" "FIXTURE=6" "$(cat "$WORK/out")"

# The summary: a failed check and an app that stopped both exit 1.
results="$WORK/results"
printf '%s\n' \
    "11-18 10:00:00.000 I/Turn    ( 4242): INFO [scriptor] running lens_check" \
    "11-18 10:00:01.000 E/Turn    ( 4242): ERROR [scriptor] CHECK_FAILED lens_check: all tab shows every card" \
    "11-18 10:00:02.000 I/Turn    ( 4242): INFO [scriptor] SCRIPT_RESULT lens_check: 1 passed, 1 failed" \
    "11-18 10:00:02.100 I/Turn    ( 4242): INFO [scriptor] DEBUG_SESSION_ENDED failed=1" \
    "11-18 10:00:03.000 I/Turn    ( 4242): INFO [feed] after the end" > "$WORK/lines"
: > "$results"
out=$(_debug_follow com.example.app "" "" "" lens_check 600 "$results" < "$WORK/lines"; echo "OUTCOME=$_DEBUG_OUTCOME")
_expect "debug follow stops on DEBUG_SESSION_ENDED" "OUTCOME=ended" "$out"
_expect_not "debug follow stops on DEBUG_SESSION_ENDED" "after the end" "$out"
_DEBUG_OUTCOME=ended
out=$(_debug_outcome lens_check 600 "$results"); code=$?
_expect "debug summary of a failed check" "1 check\(s\) failed" "$out"
_expect "debug summary names the check" "all tab shows every card" "$out"
_expect_code "debug summary of a failed check" 1 "$code"

printf '%s\n' "11-18 10:00:00.000 I/Turn    ( 4242): INFO [scriptor] running lens_check" > "$WORK/lines"
: > "$results"
_debug_follow com.example.app "" "" "" lens_check 600 "$results" < "$WORK/lines" > /dev/null
out=$(_debug_outcome lens_check 600 "$results"); code=$?
_expect "debug summary when the app stopped" "The app stopped before its scripts ended" "$out"
_expect_code "debug summary when the app stopped" 1 "$code"

# ── fixture: a stale app is cleared ─────────────────────────────────

_app_id() { echo com.example.app; }
_reset_state
touch "$WORK/state/installed"
echo "5 2026-11-10T08:00:00Z" > "$WORK/state/stamp"
out=$(_fixture_clear_stale_app 5 2026-11-17T23:47:43Z 2>&1)
log=$(cat "$WORK/state/adb.log")
_expect "fixture reset since the last seed clears" "slot 5 as reset at 2026-11-10T08:00:00Z: clearing" "$out"
_expect "fixture reset since the last seed clears" "shell pm clear com.example.app" "$log"
_expect "fixture clear grants the camera again" "pm grant com.example.app android.permission.CAMERA" "$log"
_expect "fixture clear grants contacts again" "pm grant com.example.app android.permission.READ_CONTACTS" "$log"
_expect_not "fixture clear skips a denied permission" "pm grant com.example.app android.permission.RECORD_AUDIO" "$log"
_expect_not "fixture clear skips install permissions" "pm grant com.example.app android.permission.INTERNET" "$log"
_expect "fixture clear writes the new stamp" "^5 2026-11-17T23:47:43Z$" "$(cat "$WORK/state/stamp")"

: > "$WORK/state/adb.log"
out=$(_fixture_clear_stale_app 5 2026-11-17T23:47:43Z 2>&1)
_expect_not "fixture seeded from the same reset keeps the data" "pm clear" "$(cat "$WORK/state/adb.log")"
_expect_not "fixture seeded from the same reset says nothing" "clearing" "$out"

: > "$WORK/state/adb.log"
out=$(_fixture_clear_stale_app 2 2026-11-17T23:47:43Z 2>&1)
_expect "fixture of another slot clears" "holds slot 5" "$out"

rm -f "$WORK/state/stamp"
out=$(_fixture_clear_stale_app 2 2026-11-17T23:47:43Z 2>&1)
_expect "fixture on an app never seeded clears" "wasn't seeded from a fixture slot" "$out"

_reset_state
out=$(_fixture_clear_stale_app 2 2026-11-17T23:47:43Z 2>&1)
_expect_not "fixture leaves an app that isn't installed" "pm clear|run-as" "$(cat "$WORK/state/adb.log")"

(
    _BUILD_CONFIG=profile
    touch "$WORK/state/installed"
    _fixture_clear_stale_app 2 2026-11-17T23:47:43Z
) > /dev/null 2>&1
_expect_not "fixture leaves a build that isn't debuggable" "pm clear" "$(cat "$WORK/state/adb.log")"
unset -f _app_id
source "$TESTS_DIR/../build-lifecycle.sh"

# ── record ──────────────────────────────────────────────────────────

_reset_state
out=$(do_record --seconds 0 2>&1); code=$?
_expect "record --seconds 0" "needs a whole number of seconds" "$out"
_expect_code "record --seconds 0" 1 "$code"

out=$(do_record --seconds 181 2>&1)
_expect "record --seconds over the limit" "at most 180" "$out"

out=$(do_record --seconds 2>&1)
_expect "record --seconds without a value" "--seconds needs a value" "$out"

out=$(do_record --frames ten 2>&1)
_expect "record --frames ten" "needs a whole number of frames per second" "$out"

out=$(do_record --script --frames 5 2>&1)
_expect "record --script followed by a flag" "--script needs a value" "$out"

out=$(do_record --fixture 2 2>&1); code=$?
_expect "record --fixture without --script" "it needs --script" "$out"
_expect_code "record --fixture without --script" 1 "$code"

out=$(do_record --loud 2>&1)
_expect "record with an unknown option" "Unknown option: --loud" "$out"

out=$(do_record one two 2>&1)
_expect "record with two names" "Unexpected argument: two" "$out"

out=$(do_record --help 2>&1); code=$?
_expect "record --help" "Usage: ./build.sh android record" "$out"
_expect "record --help names --fixture" "--fixture \[slot\]" "$out"
_expect_code "record --help" 0 "$code"

(
    _use_target() { echo "TARGET=${1:-none}"; return 1; }
    do_record emulator clip --seconds 5
    do_record clip --seconds 5
    do_record emulator-5554 --seconds 5
) > "$WORK/out" 2>&1
out=$(cat "$WORK/out")
_expect "record takes a target word" "TARGET=emulator$" "$out"
_expect "record takes a name alone" "TARGET=none" "$out"
_expect "record takes a serial" "TARGET=emulator-5554" "$out"

(
    _use_target() { :; }
    _fixture_extras() { echo "FIXTURE=$1"; return 1; }
    do_record motion --script motion_tour --fixture 4 --seconds 30
    AGENT_SLOT=7 do_record motion --fixture --script motion_tour
) > "$WORK/out" 2>&1
out=$(cat "$WORK/out")
_expect "record --fixture slot" "FIXTURE=4" "$out"
_expect "record --fixture takes AGENT_SLOT" "FIXTURE=7" "$out"
_expect_not "record --fixture fails before recording" "Recording the" "$out"

# The scripted launch carries the scripts, the fixture and ANDROID_LAUNCH_ARGS.
_reset_state
touch "$WORK/state/installed"
(
    _main_component() { echo com.example.app/.MainActivity; }
    _reverse_server_port() { :; }
    _app_id() { echo com.example.app; }
    _FIXTURE_EXTRAS=(--es TURN_DEBUG_REFRESH_TOKEN token)
    ANDROID_LAUNCH_ARGS="--es TURN_CLOCK 2026-11-17T23:47:43Z"
    _record_launch_scripts motion_tour
) > /dev/null 2>&1
log=$(grep "am start" "$WORK/state/adb.log")
_expect "record launch: scripts without the marker" "TURN_DEBUG_SCRIPT_NAMES' 'motion_tour' '--es' 'TURN_DEBUG_SCRIPT_NO_MARKER' '1'" "$log"
_expect "record launch: fixture session" "'TURN_DEBUG_REFRESH_TOKEN' 'token'" "$log"
_expect "record launch: launch args last" "'TURN_DEBUG_REFRESH_TOKEN' 'token' '--es' 'TURN_CLOCK' '2026-11-17T23:47:43Z'$" "$log"

# ── ui ──────────────────────────────────────────────────────────────

cat > "$WORK/state.xml" <<'EOF'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" bounds="[0,0][1206,2622]"><node index="0" text="Send" resource-id="send-button" class="android.view.View" content-desc="" bounds="[30,60][120,180]" /><node index="1" text="" resource-id="com.example.app:id/feed-list" class="android.view.View" content-desc="Your feed" bounds="[0,300][1206,2400]" /></node></hierarchy>
EOF

_ui_reset() {
    _reset_state
    cp "$WORK/state.xml" "$WORK/state/dump.xml"
}

_ui_reset
out=$(do_ui wave 2>&1); code=$?
_expect "ui with an unknown command" "Unknown ui command: wave" "$out"
_expect_code "ui with an unknown command" 1 "$code"

out=$(do_ui 2>&1); code=$?
_expect "ui without a command shows usage" "Usage: ./build.sh android ui" "$out"
_expect_code "ui without a command shows usage" 0 "$code"

out=$(do_ui tap 10 2>&1)
_expect "ui tap with one number" "tap expects <x> <y>" "$out"

out=$(do_ui tap 10 abc 2>&1)
_expect "ui tap with a word" "tap expects <x> <y>" "$out"

out=$(do_ui tap 500 100 --no-shot 2>&1)
_expect "ui tap outside the screen" "outside the screen \(402×874\)" "$out"

out=$(do_ui tap --id 2>&1)
_expect "ui tap --id without a value" "tap id requires a value" "$out"

out=$(do_ui swipe sideways 2>&1)
_expect "ui swipe with a bad direction" "swipe expects" "$out"

out=$(do_ui press menu 2>&1)
_expect "ui press with a bad button" "press expects a button: home \| back \| lock" "$out"

out=$(do_ui type 2>&1)
_expect "ui type without text" "type expects text" "$out"

out=$(do_ui type "Café" --no-shot 2>&1); code=$?
_expect "ui type refuses non-ASCII" "ASCII only" "$out"
_expect_code "ui type refuses non-ASCII" 1 "$code"
_expect_not "ui type refuses non-ASCII before typing" "input text" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui type "Family calls" --no-shot 2>&1)
_expect "ui type sends spaces as %s" "shell input text Family%scalls" "$(cat "$WORK/state/adb.log")"

out=$(do_ui tap 10 10 --delay 2>&1)
_expect "ui --delay without milliseconds" "--delay requires milliseconds" "$out"

_ui_reset
out=$(do_ui tap 100.5 200 --no-shot 2>&1)
_expect "ui tap converts dp to pixels" "shell input tap 302 600" "$(cat "$WORK/state/adb.log")"
_expect_not "ui --no-shot takes no screenshot" "screencap" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui tap --id send-button --no-shot 2>&1)
_expect "ui tap --id taps the centre" "shell input tap 75 120" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui tap --id feed-list --no-shot 2>&1)
_expect "ui tap --id reads a package-qualified id" "shell input tap 603 1350" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui tap --label "your feed" --no-shot 2>&1)
_expect "ui tap --label matches the content description" "shell input tap 603 1350" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui tap --id missing --no-shot 2>&1); code=$?
_expect "ui tap --id of a missing element" "No element with id 'missing'" "$out"
_expect_code "ui tap --id of a missing element" 1 "$code"

_ui_reset
out=$(do_ui swipe up --no-shot 2>&1)
_expect "ui swipe up uses the iOS fractions" "shell input swipe 603 1833 603 654 300" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui press back --no-shot 2>&1)
_expect "ui press back" "shell input keyevent KEYCODE_BACK" "$(cat "$WORK/state/adb.log")"

_ui_reset
out=$(do_ui describe feed 2>&1)
_expect "ui describe lists test tags in dp" "^  View \| 'Send' \| id=send-button \| x=10 y=20 w=30 h=40$" "$out"
_expect "ui describe strips the package from ids" "View \| 'Your feed' \| id=feed-list \| x=0 y=100 w=402 h=700" "$out"
_expect "ui describe saves the tree" "feed-ui.txt$" "$out"
_expect "ui describe saves the same lines" "id=send-button" "$(cat "$WORK/project/build/screenshots/feed-ui.txt" 2>/dev/null)"
_expect_not "ui describe holds no motion after a clean dump" "HOLD_MOTION" "$(cat "$WORK/state/adb.log")"

# A dump that fails while something moves: hold, retry, release.
_ui_reset
echo 2 > "$WORK/state/dump-failures"
out=$(do_ui describe busy 2>&1); code=$?
log=$(cat "$WORK/state/adb.log")
_expect "ui describe retries a failed dump" "id=send-button" "$out"
_expect_code "ui describe retries a failed dump" 0 "$code"
_expect "ui describe holds motion" "am broadcast -a com.example.app.HOLD_MOTION -p com.example.app --ez hold true" "$log"
_expect "ui describe releases motion" "am broadcast -a com.example.app.HOLD_MOTION -p com.example.app --ez hold false" "$log"
_expect "ui describe dumps three times" "^3$" "$(grep -c "uiautomator dump" <<<"$log")"

_ui_reset
echo 9 > "$WORK/state/dump-failures"
out=$(do_ui describe busy 2>&1); code=$?
_expect "ui describe gives up after three retries" "Could not read the view tree" "$out"
_expect_code "ui describe gives up after three retries" 1 "$code"
_expect "ui describe gives up after three retries" "^4$" "$(grep -c "uiautomator dump" "$WORK/state/adb.log")"

# ── see and screenshots ─────────────────────────────────────────────

(
    _capture_screenshot() { : > "$1"; }
    _do_vision() { echo "VISION=$1 $2 $3"; }
    do_see --focus "Is the record button coral?"
    do_see emulator
    do_see --colour
) > "$WORK/out" 2>&1
out=$(cat "$WORK/out")
_expect "see --focus asks the question" "VISION=.*see_.*\.png --focus Is the record button coral\?" "$out"
_expect "see without --focus describes the screen" "--focus Describe what is currently on screen" "$out"
_expect "see names the device" "From: emulator Turn_Parity \(emulator-5554\)" "$out"
_expect "see with an unknown argument" "Unknown argument: --colour" "$out"

_reset_state
(
    _capture_screenshot() { : > "$1"; }
    do_screenshot clip_name
    do_screenshot emulator named
) > "$WORK/out" 2>&1
out=$(cat "$WORK/out")
_expect "screenshot takes a name alone" "build/screenshots/clip_name.png$" "$out"
_expect "screenshot takes a target and a name" "build/screenshots/named.png$" "$out"

(
    _app_id() { echo com.example.app; }
    do_screenshots_collect collect emulator
) > "$WORK/out" 2>&1
_expect "screenshots collect with nothing saved" "No scripted screenshots found" "$(cat "$WORK/out")"

echo ""
if [[ $FAILED -gt 0 ]]; then
    echo "✗ $FAILED of $((PASSED + FAILED)) checks failed"
    exit 1
fi
echo "✓ $PASSED checks passed"
