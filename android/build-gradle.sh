#!/bin/bash
# android-toolkit/build-gradle.sh: the JDK, the Gradle wrapper, build, clean, test, lint, format
# Sourced by build.sh. Gradle runs through the project's ./gradlew with
# JAVA_HOME set here, under the gradle lock (two builds at most).
#
# Provides: _resolve_java_home, _gradle_run, do_build, do_clean, do_test,
#           do_test_instrumented, do_lint, do_format
# Depends on: _build_config, _build_variant, ANDROID_MODULE (build.sh)
# Depends on: _lock_take, _lock_release (build-lock.sh), _night_dir (build-overnight.sh)
# Depends on: _parity_gate (build-sync.sh), _icons_gate (build-icons.sh)

TOKENS_PY="$SCRIPT_DIR/../shared/tokens.py"

# The look tokens against the iOS sources they were read from, at the TOML's
# ios_commit in TURN_ROOT. Skipped when no token folder exists.
_tokens_gate() {
    local dirs=() dir
    for dir in ${TOOLKIT_TOKENS_DIRS:-${TURN_ROOT:+$TURN_ROOT/shared/tokens} $PROJECT_ROOT/shared-pending/tokens}; do
        [[ -d "$dir" ]] && dirs+=(--tokens "$dir")
    done
    if [[ ${#dirs[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ -z "${TURN_ROOT:-}" ]]; then
        echo "⚠ TURN_ROOT is not set; token gate skipped"
        return 0
    fi
    echo "→ Token gate"
    python3 -B "$TOKENS_PY" "${dirs[@]}" --ios-gate "$TURN_ROOT"
}

# Prints the JDK's major version (17, 21, ...) from its release file.
_java_major() {
    local home="$1" version
    [[ -x "$home/bin/java" && -f "$home/release" ]] || return 1
    version=$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$home/release")
    [[ -n "$version" ]] && echo "$version"
}

# ANDROID_JAVA_HOME, else Android Studio's JDK, else Homebrew's openjdk@21,
# else java_home -v 21 or 17. Only JDK 17 and 21 count.
_resolve_java_home() {
    if [[ -n "${ANDROID_JAVA_HOME:-}" ]]; then
        local major
        major=$(_java_major "$ANDROID_JAVA_HOME") || { echo "✗ ANDROID_JAVA_HOME ($ANDROID_JAVA_HOME) is not a JDK." >&2; return 1; }
        if [[ "$major" != 17 && "$major" != 21 ]]; then
            echo "✗ ANDROID_JAVA_HOME is JDK $major; Gradle and AGP need 17 or 21." >&2
            return 1
        fi
        echo "$ANDROID_JAVA_HOME"
        return 0
    fi
    local candidate
    for candidate in \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
        "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
        "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
        [[ -n "$candidate" ]] || continue
        case "$(_java_major "$candidate" || true)" in
            17|21) echo "$candidate"; return 0 ;;
        esac
    done
    echo "✗ No JDK 17 or 21 found. Install one (brew install openjdk@21) or set ANDROID_JAVA_HOME." >&2
    return 1
}

_gradle_require() {
    if [[ ! -x "$PROJECT_ROOT/gradlew" ]]; then
        echo "✗ No Gradle wrapper at $PROJECT_ROOT/gradlew."
        return 1
    fi
    JAVA_HOME=$(_resolve_java_home) || return 1
    export JAVA_HOME
}

# True when a Gradle build file applies the plugin (ktlint, detekt).
_gradle_has_plugin() {
    grep -qs "$1" "$PROJECT_ROOT"/build.gradle.kts "$PROJECT_ROOT/$ANDROID_MODULE/build.gradle.kts"
}

_gradle_log() {
    echo "$PROJECT_ROOT/build/logs/gradle-$1.log"
}

# Offline while the night's down/network flag is set, or ANDROID_GRADLE_OFFLINE=true.
_gradle_flags() {
    echo "--console=plain"
    if [[ "${ANDROID_GRADLE_OFFLINE:-false}" == "true" || -f "$(_night_dir)/down/network" ]]; then
        echo "--offline"
    fi
}

# Runs ./gradlew with the given tasks under the gradle lock; output goes to
# build/logs/gradle-<name>.log.
_gradle_run() {
    local name="$1"
    shift
    local log
    log=$(_gradle_log "$name")
    mkdir -p "$(dirname "$log")"
    local held=false
    _lock_is_held_here gradle && held=true
    _lock_take gradle || return 1
    local code=0
    (cd "$PROJECT_ROOT" && ./gradlew $(_gradle_flags) "$@") > "$log" 2>&1 || code=$?
    $held || _lock_release gradle
    return "$code"
}

# The part of a Gradle log that says what failed, and where the rest is.
_gradle_failure() {
    local log="$1"
    LOG="$log" python3 -I -c '
import os, re
lines = open(os.environ["LOG"], errors="replace").read().splitlines()
shown, block = [], False
for line in lines:
    if line.startswith("* What went wrong"):
        block = True
    elif line.startswith("* Try") or line.startswith("* Get more help"):
        block = False
    if block or line.startswith("e: ") or "FAILED" in line or re.search(r"\.kts?:\d+:\d+ |: (Error|Warning): |Lint found", line):
        if line.strip():
            shown.append(line)
for line in shown[:80]:
    print("  " + line)
if len(shown) > 80:
    print("  ... %d more lines" % (len(shown) - 80))
'
    echo "  Full log: $log"
}

# ktlint and detekt checks, then the project's own grep gates when a lint
# file declares do_android_arch_checks. Every check runs, so one failure
# doesn't hide the others.
_lint_fast() {
    local tasks=() failed=false
    _gradle_has_plugin ktlint && tasks+=(ktlintCheck)
    _gradle_has_plugin detekt && tasks+=(detekt)
    if [[ ${#tasks[@]} -gt 0 ]]; then
        if ! _gradle_run lint --continue "${tasks[@]}"; then
            echo "✗ Lint failed:"
            _gradle_failure "$(_gradle_log lint)"
            failed=true
        fi
    fi
    if [[ "${TOOLKIT_ARCH_CHECKS:-true}" == "true" ]] && declare -F do_android_arch_checks >/dev/null; then
        do_android_arch_checks || failed=true
    fi
    if [[ "${TOOLKIT_ARCH_CHECKS:-true}" == "true" ]]; then
        _tokens_gate || failed=true
        _icons_gate || failed=true
        _parity_gate || failed=true
    fi
    if $failed; then
        echo "✗ Lint failed. Fix violations before building."
        return 1
    fi
    echo "✓ Lint passed"
}

_assemble() {
    local variant
    variant=$(_build_variant)
    echo "→ Building $ANDROID_APP_NAME ($(_build_config))"
    if _gradle_run build ":$ANDROID_MODULE:assemble$variant"; then
        echo "✓ Build complete"
    else
        echo "✗ Build failed:"
        _gradle_failure "$(_gradle_log build)"
        return 1
    fi
}

do_build() {
    _gradle_require || return 1
    do_format || return 1
    _lint_fast || return 1
    _assemble
}

do_clean() {
    _gradle_require || return 1
    echo "Cleaning $ANDROID_APP_NAME."
    if ! _gradle_run clean clean; then
        echo "✗ Clean failed:"
        _gradle_failure "$(_gradle_log clean)"
        return 1
    fi
    rm -rf "$PROJECT_ROOT/build"
    echo "Removed build/ and the Gradle outputs."
}

do_format() {
    _gradle_require || return 1
    if ! _gradle_has_plugin ktlint; then
        echo "⚠ No ktlint plugin in the Gradle build; nothing to format."
        return 0
    fi
    if _gradle_run format ktlintFormat; then
        echo "✓ Format passed"
    else
        echo "✗ Format failed:"
        _gradle_failure "$(_gradle_log format)"
        return 1
    fi
}

do_lint() {
    _gradle_require || return 1
    _lint_fast || return 1
    local variant
    variant=$(_build_variant)
    if _gradle_run android-lint ":$ANDROID_MODULE:lint$variant"; then
        echo "✓ Android Lint passed"
    else
        echo "✗ Android Lint failed:"
        _gradle_failure "$(_gradle_log android-lint)"
        return 1
    fi
}

_require_server() {
    if ! curl -sf -m 3 "$SERVER_HEALTH_URL" >/dev/null 2>&1; then
        echo >&2 "ERROR: server is not running at $SERVER_HEALTH_URL"
        [[ -n "$SERVER_START_CMD" ]] && echo >&2 "Start it with: $SERVER_START_CMD"
        exit 1
    fi
}

# Runs Gradle in the background and stops it once the timeout passes.
_run_tests_with_timeout() {
    local hard_timeout="$1"
    shift
    local log
    log=$(_gradle_log test)
    mkdir -p "$(dirname "$log")"
    local held=false
    _lock_is_held_here gradle && held=true
    _lock_take gradle || return 1
    (cd "$PROJECT_ROOT" && exec ./gradlew $(_gradle_flags) "$@") > "$log" 2>&1 &
    local gradle_pid=$! started=$SECONDS timed_out=false
    while kill -0 "$gradle_pid" 2>/dev/null; do
        if (( SECONDS - started >= hard_timeout )); then
            echo "  Tests exceeded ${hard_timeout}s; stopping Gradle."
            kill "$gradle_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$gradle_pid" 2>/dev/null || true
            timed_out=true
            break
        fi
        sleep 1
    done
    local rc=0
    wait "$gradle_pid" 2>/dev/null || rc=$?
    $held || _lock_release gradle
    $timed_out && return 124
    return "$rc"
}

# Prints the verdict from the JUnit XML reports Gradle wrote.
_test_summary() {
    local dir="$1"
    DIR="$dir" python3 -I -c '
import glob, os, sys
import xml.etree.ElementTree as ET
total = failed = skipped = 0
failures = []
for path in sorted(glob.glob(os.path.join(os.environ["DIR"], "**", "TEST-*.xml"), recursive=True)):
    suite = ET.parse(path).getroot()
    for case in suite.iter("testcase"):
        total += 1
        problem = case.find("failure")
        if problem is None:
            problem = case.find("error")
        if problem is not None:
            failed += 1
            message = (problem.get("message") or problem.text or "").strip().splitlines()
            name = case.get("classname", "").split(".")[-1] + "." + case.get("name", "")
            failures.append((name, message[0] if message else ""))
        elif case.find("skipped") is not None:
            skipped += 1
if total == 0:
    print("✗ No test results found.")
    sys.exit(1)
extra = " (%d skipped)" % skipped if skipped else ""
if failed:
    print("✗ %d of %d tests failed%s:" % (failed, total, extra))
    for name, message in failures:
        print("  %s: %s" % (name, message[:300]))
    sys.exit(1)
print("✓ %d tests passed%s" % (total - skipped, extra))
'
}

# Parses [filter] [timeout] [--no-build|--build-only] into _TEST_FILTER,
# _TEST_TIMEOUT and _TEST_BUILD_ONLY.
_test_args() {
    _TEST_FILTER=""
    _TEST_TIMEOUT=$TEST_TIMEOUT
    _TEST_BUILD_ONLY=false
    local arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            _TEST_TIMEOUT="$arg"
        elif [[ "$arg" == "--no-build" ]]; then
            :
        elif [[ "$arg" == "--build-only" ]]; then
            _TEST_BUILD_ONLY=true
        elif [[ "$arg" == -* ]]; then
            echo "✗ Unknown flag: $arg"
            return 1
        else
            _TEST_FILTER="$arg"
        fi
    done
}

# Compiles the tests without running them, and without the local server.
_test_build_only() {
    local name="$1" task="$2"
    echo "  Building tests..."
    if _gradle_run "$name" "$task"; then
        echo "✓ Tests build"
    else
        echo "✗ Tests don't build:"
        _gradle_failure "$(_gradle_log "$name")"
        return 1
    fi
}

# Runs the Gradle test task, then prints the verdict from the JUnit reports in
# the results folder.
_run_test_task() {
    local results="$1" timeout="$2"
    shift 2
    rm -rf "$results"
    local rc=0
    _run_tests_with_timeout "$timeout" "$@" || rc=$?
    if [[ $rc -eq 124 ]]; then
        if [[ -n "$(_test_reports "$results")" ]]; then
            _test_summary "$results" || true
        fi
        echo "✗ Tests timed out after ${timeout}s"
        return 1
    fi
    if [[ -n "$(_test_reports "$results")" ]]; then
        _test_summary "$results" || return 1
        [[ $rc -eq 0 ]] && return 0
    fi
    if [[ $rc -ne 0 ]]; then
        echo "✗ Tests failed:"
        _gradle_failure "$(_gradle_log test)"
        return 1
    fi
}

_test_reports() {
    find "$1" -name 'TEST-*.xml' 2>/dev/null | head -1
}

do_test() {
    if [[ "${1:-}" == "instrumented" ]]; then
        shift
        do_test_instrumented "$@"
        return
    fi
    _gradle_require || return 1
    _test_args "$@" || return 1
    local variant
    variant=$(_build_variant)
    echo "Testing $ANDROID_APP_NAME (unit tests, $(_build_config))."
    if $_TEST_BUILD_ONLY; then
        _test_build_only test ":$ANDROID_MODULE:compile${variant}UnitTestKotlin"
        return
    fi
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        _require_server
    fi

    local task=":$ANDROID_MODULE:test${variant}UnitTest"
    local args=("$task" --rerun)
    if [[ -n "$_TEST_FILTER" ]]; then
        local pattern="${_TEST_FILTER//\//.}"
        [[ "$pattern" == *"*"* || "$pattern" == *.*.* ]] || pattern="*.$pattern"
        args+=(--tests "$pattern")
        echo "  Running tests filtered by '$_TEST_FILTER' (timeout: ${_TEST_TIMEOUT}s)..."
    else
        echo "  Running tests... (timeout: ${_TEST_TIMEOUT}s)"
    fi
    _run_test_task "$PROJECT_ROOT/$ANDROID_MODULE/build/test-results/test${variant}UnitTest" "$_TEST_TIMEOUT" "${args[@]}"
}

# The fully qualified name of a test class under src/androidTest, for the
# runner's class argument. A dotted name is taken as it is.
_instrumented_class() {
    local name="$1" file package
    if [[ "$name" == *.* ]]; then
        echo "$name"
        return 0
    fi
    file=$(grep -rlE "^(internal |open |abstract )*class $name\b" "$PROJECT_ROOT/$ANDROID_MODULE/src/androidTest" 2>/dev/null | head -1 || true)
    if [[ -z "$file" ]]; then
        echo "✗ No test class $name under $ANDROID_MODULE/src/androidTest." >&2
        return 1
    fi
    package=$(sed -n 's/^package \([A-Za-z0-9_.]*\).*/\1/p' "$file" | head -1)
    echo "${package:+$package.}$name"
}

# test instrumented [filter] [timeout] [--no-build|--build-only]: the tests
# under src/androidTest, on the emulator or a phone (the target of
# --device or ANDROID_DEVICE, else the running emulator, else the one phone).
do_test_instrumented() {
    _gradle_require || return 1
    _test_args "$@" || return 1
    local variant
    variant=$(_build_variant)
    echo "Testing $ANDROID_APP_NAME (instrumented tests, $(_build_config))."
    if $_TEST_BUILD_ONLY; then
        _test_build_only test ":$ANDROID_MODULE:assemble${variant}AndroidTest"
        return
    fi
    if [[ "${TOOLKIT_SERVER_ENABLED:-false}" == "true" ]]; then
        _require_server
    fi
    local args=(":$ANDROID_MODULE:connected${variant}AndroidTest")
    if [[ -n "$_TEST_FILTER" ]]; then
        local class method=""
        class="${_TEST_FILTER%%/*}"
        [[ "$_TEST_FILTER" == */* ]] && method="#${_TEST_FILTER#*/}"
        class=$(_instrumented_class "$class") || return 1
        args+=("-Pandroid.testInstrumentationRunnerArguments.class=$class$method")
        echo "  Running tests filtered by '$_TEST_FILTER' (timeout: ${_TEST_TIMEOUT}s)..."
    else
        echo "  Running tests... (timeout: ${_TEST_TIMEOUT}s)"
    fi
    _lock_take emulator || return 1
    _use_target "" || return 1
    echo "  On $(_target_label)"
    ANDROID_SERIAL="$SERIAL" _run_test_task "$PROJECT_ROOT/$ANDROID_MODULE/build/outputs/androidTest-results/connected" "$_TEST_TIMEOUT" "${args[@]}"
}
