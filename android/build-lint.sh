#!/bin/bash
# android-toolkit/build-lint.sh: the grep gates, ported from toolkit/ios/build.sh
# Sourced by build.sh. _lint_fast (build-gradle.sh) runs do_android_arch_checks
# after ktlint and detekt; the gates that need the syntax tree are detekt rules
# in detekt-rules/.
#
# Provides: do_android_arch_checks, ANDROID_GATES and every do_android_*_check
# Depends on: PROJECT_ROOT; ANDROID_MODULE (default app); optional
#             ANDROID_SOURCE_DIR, ANDROID_STATE_FILE, ANDROID_TRANSPORT_FILE,
#             ANDROID_RIPPLE_FILE, ANDROID_CAMERA_OWNER, TOOLKIT_LINT_HOOK
#
# Overrides: // lint:allow <rule-id> <reason>, with the ids in
# ANDROID_OVERRIDE_RULES. The hard gates (the hard concurrency tier, the look)
# take no override.

ANDROID_OVERRIDE_RULES='message-bus view-state-mutation ui-from-state'
ANDROID_ANNOTATION_FORMS='non-actionable concurrent-safe android-only old-server'
ANDROID_HANDLER_SUFFIXES_DEFAULT="Tapped Pressed DoubleTapped LongPressed Swiped Submitted Toggled Selected Appeared Disappeared Dismissed Changed Updated Ended Started Loaded Refreshed Received BecomeActive EnterBackground ResignActive EnterForeground Completed Failed Focused Unfocused Scrolled Prefetched Shown Hidden Triggered"

# Every gate, in the order do_android_arch_checks runs them. The fixture tests
# (detekt-rules/src/test) read this list: each gate has a fail and a pass fixture.
ANDROID_GATES=(
    do_android_override_syntax_check
    do_android_annotation_reason_check
    do_android_suppress_check
    do_android_message_bus_check
    do_android_state_check
    do_android_concurrency_check
    do_android_mark_spacing_check
    do_android_section_marker_check
    do_android_handler_suffix_check
    do_android_handler_visibility_check
    do_android_root_immutability_check
    do_android_mark_allowlist_check
    do_android_transport_purity_check
    do_android_transport_construction_check
    do_android_material_check
    do_android_ripple_check
    do_android_shadow_check
    do_android_projection_check
    do_android_easing_check
    do_android_colour_literal_check
    do_android_file_length_check
)

_LINT_RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# ── Where to look ───────────────────────────────────────────────────

# The app's Kotlin root (the folder holding model/, view/, service/):
# ANDROID_SOURCE_DIR, else the parent of the first model/ under src/main/kotlin.
_lint_source_dir() {
    if [[ -n "${ANDROID_SOURCE_DIR:-}" ]]; then
        echo "$PROJECT_ROOT/$ANDROID_SOURCE_DIR"
        return
    fi
    local kotlin="$PROJECT_ROOT/${ANDROID_MODULE:-app}/src/main/kotlin" model
    model=$(find "$kotlin" -maxdepth 6 -type d -name model 2>/dev/null | sort | head -1)
    if [[ -n "$model" ]]; then
        dirname "$model"
    else
        echo "$kotlin"
    fi
}

_lint_state_dir() {
    echo "$(_lint_source_dir)/model"
}

# The app, its debug tools, the tests and the debug scripts (iOS CODE_DIRS).
_lint_code_dirs() {
    local module="$PROJECT_ROOT/${ANDROID_MODULE:-app}" dir
    for dir in "$module/src/main" "$module/src/debugTools" "$module/src/test" "$module/src/androidTest" "$PROJECT_ROOT/debug"; do
        [[ -d "$dir" ]] && echo "$dir"
    done
}

# grep -rnE over the Kotlin files of the given folders.
_lint_grep() {
    local pattern="$1"
    shift
    local dirs=() dir
    for dir in "$@"; do
        [[ -d "$dir" ]] && dirs+=("$dir")
    done
    [[ ${#dirs[@]} -gt 0 ]] || return 0
    grep -rnE "$pattern" "${dirs[@]}" --include="*.kt" 2>/dev/null || true
}

_lint_code_grep() {
    local pattern="$1" dirs=() dir
    while IFS= read -r dir; do dirs+=("$dir"); done < <(_lint_code_dirs)
    _lint_grep "$pattern" "${dirs[@]}"
}

# Drops matches on comment, import and package lines.
_lint_code_only() {
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*|import[[:space:]]|package[[:space:]])' || true
}

# Drops matches whose line, or the line above, carries "// <form>: <reason>".
# Kotlin lines run long, so the reason may sit on its own line above the code.
_lint_annotated_filter() {
    local form="$1" line file lineno above
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" =~ //\ ${form}:[[:space:]]*[^[:space:]] ]] && continue
        file="${line%%:*}"
        lineno="${line#*:}"
        lineno="${lineno%%:*}"
        if [[ "$lineno" =~ ^[0-9]+$ && $lineno -gt 1 ]]; then
            above=$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null)
            [[ "$above" =~ //\ ${form}:[[:space:]]*[^[:space:]] ]] && continue
        fi
        echo "$line"
    done
}

_allow_filter_android() {
    grep -vE "// lint:allow ${1} [^[:space:]].*" || true
}

_lint_print() {
    local msg="$1" matches="$2" line
    echo ""
    echo "  ✗ $msg"
    while IFS= read -r line; do
        [[ -n "$line" ]] && echo "    ${line#$PROJECT_ROOT/}"
    done <<< "$matches"
}

_lint_footer() {
    echo "$_LINT_RULE"
    local line
    for line in "$@"; do
        echo "  $line"
    done
    echo "$_LINT_RULE"
}

# ── Overrides and annotations ───────────────────────────────────────

do_android_override_syntax_check() {
    local found=0 line rest rule reason
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        rest="${line#*// lint:allow }"
        rule="${rest%% *}"
        if [[ " $ANDROID_OVERRIDE_RULES " != *" $rule "* ]]; then
            echo "  ✗ unknown override rule '${rule}': ${line#$PROJECT_ROOT/}"
            found=1
            continue
        fi
        reason="${rest#"$rule"}"
        reason="${reason# }"
        if [[ -z "${reason// /}" ]]; then
            echo "  ✗ override missing reason: ${line#$PROJECT_ROOT/}"
            found=1
        fi
    done < <(_lint_code_grep '// lint:allow')
    if [[ $found -eq 1 ]]; then
        echo ""
        _lint_footer "// lint:allow <rule-id> <reason>: the rule-id is one of" "$ANDROID_OVERRIDE_RULES" \
            "A reason is required; an unknown rule-id suppresses nothing."
        return 1
    fi
    echo "✓ lint:allow override syntax passed"
}

do_android_annotation_reason_check() {
    local forms matches
    forms=$(echo "$ANDROID_ANNOTATION_FORMS" | tr ' ' '|')
    matches=$(_lint_code_grep "// (${forms}):[[:space:]]*\$")
    if [[ -n "$matches" ]]; then
        _lint_print "Annotation without a reason" "$matches"
        _lint_footer "Write the reason after the colon, e.g. // android-only: CameraX needs this." \
            "Forms: $ANDROID_ANNOTATION_FORMS"
        return 1
    fi
    echo "✓ Annotation reasons passed"
}

# iOS no_disable_commands: no rule is switched off in the code.
do_android_suppress_check() {
    local matches
    matches=$(_lint_code_grep '@(file:)?Suppress(Lint|Warnings)?\(|ktlint-disable|noinspection|detekt:disable')
    if [[ -n "$matches" ]]; then
        _lint_print "A lint rule switched off in the code" "$matches"
        _lint_footer "@Suppress, @SuppressLint, ktlint-disable and noinspection are forbidden." \
            "Fix the code, or change the rule in the toolkit for everyone."
        return 1
    fi
    echo "✓ Suppress check passed"
}

# ── State ───────────────────────────────────────────────────────────

do_android_message_bus_check() {
    local matches
    matches=$(_lint_grep '\b(var|val)[[:space:]]+[a-zA-Z0-9_]*(Trigger|Counter|Version|Flag)[a-zA-Z0-9_]*' "$(_lint_state_dir)" | _allow_filter_android message-bus)
    if [[ -n "$matches" ]]; then
        _lint_print "A signal counter on state is a message bus: model the change as a value" "$matches"
        _lint_footer "State is data and its own logic, not a view-to-view signalling bus." \
            "Override with: // lint:allow message-bus <reason>"
        return 1
    fi
    echo "✓ message-bus check passed"
}

do_android_state_check() {
    local found=0 matches src state_file
    src=$(_lint_source_dir)

    matches=$(_lint_grep '\b(ViewModel|LiveData|StateFlow|collectAsState)' "$src/model" "$src/view")
    if [[ -n "$matches" ]]; then
        _lint_print "ViewModel, LiveData, StateFlow or collectAsState: state lives in the state classes as snapshot state" "$matches"
        found=1
    fi

    matches=$(_lint_grep 'InputMethodManager|hideSoftInputFromWindow|SoftwareKeyboardController|FocusManager|clearFocus\(' "$src/model" | _allow_filter_android ui-from-state)
    if [[ -n "$matches" ]]; then
        _lint_print "Keyboard or focus handling in state: move it into the view layer" "$matches"
        found=1
    fi

    state_file="$(_lint_state_dir)/${ANDROID_STATE_FILE:-AppState.kt}"
    if [[ -f "$state_file" ]]; then
        matches=$(grep -nE '(^|[^[:alnum:]_])fun[[:space:]]' "$state_file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
        if [[ -n "$matches" ]]; then
            _lint_print "fun in ${state_file#$PROJECT_ROOT/}: move it to an AppState<Area>.kt file" "$matches"
            found=1
        fi
    fi

    if [[ $found -eq 1 ]]; then
        echo ""
        _lint_footer "All state lives in the state classes, read through LocalAppState." \
            "Views read state and call its handlers. AppState.kt holds no functions." \
            "Override keyboard handling in state with: // lint:allow ui-from-state <reason>"
        return 1
    fi
    echo "✓ State check passed"
}

# ── Concurrency ─────────────────────────────────────────────────────

do_android_concurrency_check() {
    local src found=0 matches camera_owner
    src=$(_lint_source_dir)

    _conc_soft() {
        local pattern="$1" msg="$2" m
        m=$(_lint_grep "$pattern" "$src" | _lint_code_only | _lint_annotated_filter concurrent-safe)
        if [[ -n "$m" ]]; then
            _lint_print "$msg" "$m"
            found=1
        fi
    }

    # A system callback: the call, with its next five lines, names the thread it runs on.
    _conc_callback() {
        local pattern="$1" required="$2" msg="$3" m="" file lineno window
        while IFS=: read -r file lineno _; do
            [[ -n "$file" ]] || continue
            window=$(sed -n "${lineno},$((lineno + 5))p" "$file")
            window+=$'\n'"$(sed -n "$((lineno > 1 ? lineno - 1 : 1))p" "$file")"
            if ! grep -qE "$required|// concurrent-safe:[[:space:]]*[^[:space:]]" <<< "$window"; then
                m+="$file:$lineno:$(sed -n "${lineno}p" "$file")"$'\n'
            fi
        done < <(_lint_grep "$pattern" "$src" | _lint_code_only)
        if [[ -n "$m" ]]; then
            _lint_print "$msg" "$m"
            found=1
        fi
    }

    _conc_hard() {
        local pattern="$1" msg="$2" m
        m=$(_lint_grep "$pattern" "$src" | _lint_code_only)
        if [[ -n "$m" ]]; then
            _lint_print "$msg" "$m"
            found=1
        fi
    }

    # Bypassable: a documented outside guarantee may justify these.
    _conc_soft '@Volatile|(^|[^A-Za-z0-9_])synchronized\(|ReentrantLock|(^|[^A-Za-z0-9_])Mutex\(|(^|[^A-Za-z0-9_])Atomic[A-Z][A-Za-z]*' \
        'Lock or atomic: add // concurrent-safe: <reason> naming the guarantee the compiler cannot see'
    _conc_soft '([Ff]ile[A-Za-z0-9_]*|File\([^)]*\))\.(readText|readBytes|readLines|writeText|writeBytes|appendText|appendBytes|forEachLine|useLines)\(|FileInputStream\(|FileOutputStream\(|RandomAccessFile\(|BitmapFactory\.decodeFile' \
        'Synchronous file I/O runs off the main thread: add // concurrent-safe: <reason> naming the dispatcher'
    _conc_soft 'Handler\(Looper\.myLooper|Handler\([A-Za-z_]*[lL]ooper\)|HandlerThread\(' \
        'A Handler off the main looper: add // concurrent-safe: <reason> naming what it guards'
    camera_owner="${ANDROID_CAMERA_OWNER:-CameraController.kt}"
    matches=$(_lint_grep '\.bindToLifecycle\(' "$src" | grep -v "/$camera_owner:" | _lint_annotated_filter concurrent-safe)
    if [[ -n "$matches" ]]; then
        _lint_print "bindToLifecycle outside $camera_owner: the camera owner binds and unbinds the camera" "$matches"
        found=1
    fi

    # Callbacks Android calls on a thread of its own: they run on the main thread.
    _conc_callback 'register(Default)?NetworkCallback\(' 'Looper\.getMainLooper\(\)|mainHandler' \
        'ConnectivityManager network callback: pass a Handler on the main looper'
    _conc_callback '\.addListener\([[:space:]]*(\{|Runnable|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*,)' 'ContextCompat\.getMainExecutor\(|mainExecutor' \
        'ListenableFuture.addListener: pass ContextCompat.getMainExecutor(context), or name the executor with // concurrent-safe:'
    _conc_callback '[cC]odec[A-Za-z0-9_]*\.setCallback\(' '[hH]andler' \
        'MediaCodec.setCallback: pass the codec Handler'
    matches=$(_lint_grep 'registerReceiver\(' "$src" | grep -E 'Handler\(' | grep -v 'getMainLooper' | _lint_annotated_filter concurrent-safe)
    if [[ -n "$matches" ]]; then
        _lint_print "registerReceiver with a Handler off the main looper: receive on the main thread" "$matches"
        found=1
    fi

    # Hard: no override exists for these.
    _conc_hard '(^|[^A-Za-z0-9_])GlobalScope\b' 'GlobalScope is forbidden. Use AppState.scope or a scope with an owner'
    _conc_hard '(^|[^A-Za-z0-9_])runBlocking\b' 'runBlocking is forbidden. It blocks the thread; suspend instead'
    _conc_hard 'Dispatchers\.Unconfined' 'Dispatchers.Unconfined is forbidden. Name the dispatcher'
    _conc_hard '(^|[^A-Za-z0-9_.])Thread\(|(^|[^A-Za-z0-9_.])thread[[:space:]]*(\{|\()' 'Thread is forbidden. Use a coroutine on a named dispatcher'
    _conc_hard '(^|[^A-Za-z0-9_])Executors\.' 'Executors are forbidden. A serial queue is Dispatchers.IO.limitedParallelism(1)'
    _conc_hard '(^|[^A-Za-z0-9_])CountDownLatch\b|(^|[^A-Za-z0-9_])Semaphore\(' 'CountDownLatch and Semaphore are forbidden. They block the thread'

    if [[ $found -eq 1 ]]; then
        echo ""
        _lint_footer "Code is concurrency-safe by construction: coroutines on named dispatchers," \
            "state written on the main thread. Locks, latches and blocking calls are forbidden." \
            "// concurrent-safe: is only for a guarantee the compiler cannot see." \
            "The hard tier (GlobalScope, runBlocking, Thread, Executors, latches) has no override."
        return 1
    fi
    echo "✓ Concurrency check passed"
}

# ── Structure ───────────────────────────────────────────────────────

do_android_mark_spacing_check() {
    local src violations="" line
    src=$(_lint_state_dir)
    if [[ ! -d "$src" ]]; then
        echo "✓ MARK spacing passed"
        return 0
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] && violations+="  opened brace stuck to MARK: ${line#$PROJECT_ROOT/}"$'\n'
    done < <(grep -rn -A1 '{[[:space:]]*$' "$src" --include="*.kt" 2>/dev/null | grep -E '^.+-[0-9]+-[[:space:]]*// MARK:' || true)
    while IFS= read -r line; do
        [[ -n "$line" ]] && violations+="  closed brace stuck to MARK: ${line#$PROJECT_ROOT/}"$'\n'
    done < <(grep -rn -B1 '// MARK:' "$src" --include="*.kt" 2>/dev/null | grep -E '^.+-[0-9]+-[[:space:]]*}[[:space:]]*$' || true)
    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ MARK comments need a blank line above and below"
        echo "$violations"
        _lint_footer "Add an empty line between the brace and // MARK:."
        return 1
    fi
    echo "✓ MARK spacing passed"
}

do_android_section_marker_check() {
    local src violations="" file line
    src=$(_lint_state_dir)
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        local last=-1 last_name="" lineno text marker order in_handlers=false
        while IFS= read -r line; do
            lineno="${line%%:*}"
            text="${line#*:}"
            if [[ "$text" =~ //\ MARK:\ *-?\ *([A-Za-z]+) ]]; then
                marker="${BASH_REMATCH[1]}"
                case "$marker" in
                    Queries) order=0 ;;
                    Handlers) order=1 ;;
                    Actions) order=2 ;;
                    Helpers) order=3 ;;
                    *)
                        in_handlers=false
                        continue
                        ;;
                esac
                if [[ $order -lt $last ]]; then
                    violations+="  out of order: ${file#$PROJECT_ROOT/}:$lineno $marker after $last_name"$'\n'
                fi
                last=$order
                last_name=$marker
                if [[ "$marker" == Handlers ]]; then in_handlers=true; else in_handlers=false; fi
                continue
            fi
            if $in_handlers && [[ "$text" =~ (private|internal)[[:space:]]+(suspend[[:space:]]+)?fun ]]; then
                violations+="  private fun in Handlers section: ${file#$PROJECT_ROOT/}:$lineno:$text"$'\n'
            fi
        done < <(grep -n '' "$file")
    done < <(find "$src" -name "${ANDROID_STATE_BASENAME:-AppState}*.kt" -type f 2>/dev/null | sort)
    while IFS= read -r line; do
        [[ -n "$line" ]] && violations+="  dash not allowed: ${line#$PROJECT_ROOT/}"$'\n'
    done < <(_lint_code_grep '// MARK: -')
    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Section marker violations"
        echo "$violations"
        _lint_footer "Section order: Queries, Handlers, Actions, Helpers." \
            "No dashes in MARK comments: // MARK: Handlers (not // MARK: - Handlers)." \
            "Private functions belong in Actions, not Handlers."
        return 1
    fi
    echo "✓ Section markers passed"
}

_android_handler_suffixes() {
    local shared file
    shared="${TOOLKIT_SHARED_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../shared" 2>/dev/null && pwd)}"
    file="$shared/handler-suffixes.txt"
    if [[ -f "$file" ]]; then
        grep -vE '^[[:space:]]*(#|$)' "$file" | tr '\n' ' '
    else
        echo "$ANDROID_HANDLER_SUFFIXES_DEFAULT"
    fi
}

do_android_handler_suffix_check() {
    local src approved violations="" name suffix matched location
    src=$(_lint_state_dir)
    approved=$(_android_handler_suffixes)
    # Android-only handlers recorded in parity.toml (android_only_symbol) keep the name the plan gave them.
    local recorded=""
    if [[ -f "$PROJECT_ROOT/parity.toml" ]]; then
        recorded=" $(grep -oE '"AppState\.on[A-Za-z0-9]+"' "$PROJECT_ROOT/parity.toml" | tr -d '"' | sed 's/^AppState\.//' | tr '\n' ' ')"
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ "$recorded " == *" $name "* ]] && continue
        matched=false
        for suffix in $approved; do
            if [[ "$name" =~ ${suffix}$ ]]; then
                matched=true
                break
            fi
        done
        if ! $matched; then
            location=$(_lint_grep "fun[[:space:]]+(AppState\\.)?${name}\\b" "$src" | head -1)
            violations+="  invalid suffix: ${location#$PROJECT_ROOT/}"$'\n'
        fi
    done < <(_lint_grep 'fun[[:space:]]+(AppState\.)?on[A-Z][a-zA-Z0-9]*' "$src" | grep -oE 'fun[[:space:]]+(AppState\.)?on[A-Z][a-zA-Z0-9]*' | sed -E 's/fun[[:space:]]+(AppState\.)?//' | sort -u)
    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Handler suffix violations: a handler ends with an approved event word"
        echo "$violations"
        _lint_footer "Approved suffixes: $approved" "Handler names are on<Subject><ApprovedSuffix>."
        return 1
    fi
    echo "✓ Handler suffixes passed"
}

do_android_handler_visibility_check() {
    local matches
    matches=$(_lint_grep '(private|internal)[[:space:]]+(suspend[[:space:]]+)?fun[[:space:]]+(AppState\.)?on[A-Z]' "$(_lint_source_dir)")
    if [[ -n "$matches" ]]; then
        _lint_print "Private handlers: handlers (on<Subject><Event>) are public; private work belongs in Actions" "$matches"
        _lint_footer "Views call handlers, so they are never private or internal." \
            "Private work drops the 'on' prefix and becomes an action."
        return 1
    fi
    echo "✓ Handler visibility passed"
}

do_android_root_immutability_check() {
    local file matches
    file="$(_lint_state_dir)/${ANDROID_STATE_FILE:-AppState.kt}"
    if [[ ! -f "$file" ]]; then
        echo "✓ Root immutability passed (no state file)"
        return 0
    fi
    matches=$(grep -nE '(^|[^[:alnum:]_])var[[:space:]]' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
    if [[ -n "$matches" ]]; then
        _lint_print "Mutable state on the composition root: AppState holds only val state objects and resources" "$(sed "s|^|${file#$PROJECT_ROOT/}:|" <<< "$matches")"
        _lint_footer "Mutable state belongs in a domain state class, not the root."
        return 1
    fi
    echo "✓ Root immutability passed"
}

do_android_mark_allowlist_check() {
    local src violations="" file line lineno marker
    src=$(_lint_state_dir)
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        while IFS= read -r line; do
            lineno="${line%%:*}"
            marker=$(sed 's/.*MARK: *//' <<< "$line")
            case "$marker" in
                Queries|Handlers|Actions|Helpers) continue ;;
                *) violations+="  ${file#$PROJECT_ROOT/}:$lineno '// MARK: $marker': only Queries, Handlers, Actions and Helpers here"$'\n' ;;
            esac
        done < <(grep -n '// MARK:' "$file" 2>/dev/null)
    done < <(find "$src" -name "${ANDROID_STATE_BASENAME:-AppState}?*.kt" -type f 2>/dev/null | sort)
    if [[ -n "$violations" ]]; then
        echo ""
        echo "  ✗ Unrecognised section markers"
        echo "$violations"
        _lint_footer "State classes group properties with blank lines, not // MARK:." \
            "AppState<Area>.kt files use only Queries, Handlers, Actions and Helpers."
        return 1
    fi
    echo "✓ MARK allowlist passed"
}

_lint_transport_file() {
    echo "$(_lint_source_dir)/${ANDROID_TRANSPORT_FILE:-service/APIClient.kt}"
}

do_android_transport_purity_check() {
    local file matches
    file=$(_lint_transport_file)
    if [[ ! -f "$file" ]]; then
        echo "✓ Transport purity passed (no transport file)"
        return 0
    fi
    matches=$(grep -nE 'SharedPreferences|PreferenceManager|DataStore|UserDefaults|BuildConfig|System\.getenv|System\.getProperty|(^|[^A-Za-z0-9_])Context([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])Resources([^A-Za-z0-9_]|$)' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
    if [[ -n "$matches" ]]; then
        _lint_print "The transport reads configuration: it reads no preferences, BuildConfig, environment or Context" "$(sed "s|^|${file#$PROJECT_ROOT/}:|" <<< "$matches")"
        _lint_footer "The transport has no configuration of its own: everything arrives through the constructor."
        return 1
    fi
    echo "✓ Transport purity passed"
}

do_android_transport_construction_check() {
    local file class matches
    file=$(_lint_transport_file)
    class=$(basename "$file" .kt)
    matches=$(_lint_grep "(^|[^[:alnum:]_])${class}\\(\\)" "$(_lint_source_dir)")
    if [[ -n "$matches" ]]; then
        _lint_print "${class}() with no arguments: pass the base URL, or use the client the composition root made" "$matches"
        _lint_footer "The transport is never made with defaults; its settings are resolved once at the root and passed in."
        return 1
    fi
    echo "✓ Transport construction passed"
}

# ── The look (platform-mapping.md, Lint gates for the look) ─────────

# The one file that may draw a ripple: the top bar's icon buttons (doc/android/decisions.md A75).
_lint_ripple_file_pattern() {
    local file="${ANDROID_RIPPLE_FILE:-view/component/TopBarIconButton.kt}"
    echo "/${file//./\\.}:"
}

do_android_material_check() {
    local found=0 matches
    matches=$(_lint_code_grep 'androidx\.compose\.material3\.' |
        grep -vE 'androidx\.compose\.material3\.pulltorefresh\.(PullToRefreshState|rememberPullToRefreshState|pullToRefresh)([^A-Za-z0-9_]|$)' || true)
    if [[ -n "$matches" ]]; then
        _lint_print "Material 3: Turn draws its own components" "$matches"
        found=1
    fi
    matches=$(_lint_code_grep 'androidx\.compose\.material\.' |
        grep -vE "$(_lint_ripple_file_pattern)[0-9]+:.*androidx\.compose\.material\.ripple\." || true)
    if [[ -n "$matches" ]]; then
        _lint_print "Material 2: Turn draws its own components" "$matches"
        found=1
    fi
    if [[ $found -eq 1 ]]; then
        echo ""
        _lint_footer "No Material components. Allowed: the pull-to-refresh state" \
            "(PullToRefreshState, rememberPullToRefreshState, Modifier.pullToRefresh)," \
            "and androidx.compose.material.ripple in ${ANDROID_RIPPLE_FILE:-view/component/TopBarIconButton.kt}."
        return 1
    fi
    echo "✓ Material check passed"
}

do_android_ripple_check() {
    local matches ripple_file
    ripple_file=$(_lint_ripple_file_pattern)
    matches=$(
        _lint_code_grep '(^|[^A-Za-z0-9_])ripple\(|rememberRipple|androidx\.compose\.material\.ripple|createRippleModifierNode|RippleAlpha|RippleConfiguration' |
            grep -vE "$ripple_file" || true
        _lint_code_grep '(^|[^A-Za-z0-9_])ripple\(|rememberRipple|RippleConfiguration' | grep -E "$ripple_file" || true
    )
    if [[ -n "$matches" ]]; then
        _lint_print "Ripple: Turn's buttons show no ripple" "$matches"
        _lint_footer "Clickables pass indication = null. The one ripple is the top bar's icon buttons," \
            "built with createRippleModifierNode in ${ANDROID_RIPPLE_FILE:-view/component/TopBarIconButton.kt}."
        return 1
    fi
    echo "✓ Ripple check passed"
}

do_android_shadow_check() {
    local matches
    matches=$(_lint_code_grep '\.(shadow|dropShadow)\(|(^|[^A-Za-z0-9_.])dropShadow\(' | _lint_code_only)
    if [[ -n "$matches" ]]; then
        _lint_print "Modifier.shadow or dropShadow: use turnShadow or compositedShadow" "$matches"
        _lint_footer "Shadows are turnShadow (layered) or compositedShadow."
        return 1
    fi
    echo "✓ Shadow check passed"
}

do_android_projection_check() {
    local matches
    matches=$(_lint_code_grep '(^|[^A-Za-z0-9_])(cameraDistance|rotationX|rotationY)[[:space:]]*=' | _lint_code_only | grep -v '/Projection\.kt:' || true)
    if [[ -n "$matches" ]]; then
        _lint_print "cameraDistance, rotationX or rotationY in a graphicsLayer: 3D goes through Projection.kt" "$matches"
        _lint_footer "Projection.kt matches iOS's perspective; graphicsLayer's camera does not."
        return 1
    fi
    echo "✓ Projection check passed"
}

do_android_easing_check() {
    local matches
    matches=$(_lint_code_grep '(^|[^A-Za-z0-9_])(FastOutSlowInEasing|LinearOutSlowInEasing|FastOutLinearInEasing)([^A-Za-z0-9_]|$)' | _lint_code_only)
    if [[ -n "$matches" ]]; then
        _lint_print "Material easing: use the curves the motion specs name" "$matches"
        _lint_footer "Turn's motion mirrors iOS; Material's easings are not part of it."
        return 1
    fi
    echo "✓ Easing check passed"
}

# Colours come from the tokens: the generated TurnTokens.kt and the Palette in
# design/DesignTokens.kt (iOS keeps its literals in DesignTokens.swift). Previews
# and tests that check a token's value may write a literal.
do_android_colour_literal_check() {
    local matches
    matches=$(_lint_code_grep '(^|[^A-Za-z0-9_])Color\([[:space:]]*(0x[0-9A-Fa-f]+|[0-9.]+f?[[:space:]]*,[[:space:]]*[0-9.]+f?[[:space:]]*,|red[[:space:]]*=)' |
        _lint_code_only | sed "s|^$PROJECT_ROOT/||" |
        grep -vE "/generated/TurnTokens\\.kt:|/design/DesignTokens\\.kt:|/PreviewSupport\\.kt:|^${ANDROID_MODULE:-app}/src/(test|androidTest)/" || true)
    if [[ -n "$matches" ]]; then
        _lint_print "Colour literal: use a token from TurnTokens" "$matches"
        _lint_footer "Colours live in shared/tokens (TurnTokens.kt) and the Palette (design/DesignTokens.kt)." \
            "Previews use PreviewSupport.kt."
        return 1
    fi
    echo "✓ Colour literal check passed"
}

# iOS file_length (600, strict). Over 400 lines is a warning (testing.md: a test file splits by concern).
do_android_file_length_check() {
    local dirs=() dir file lines over="" long="" line
    while IFS= read -r dir; do dirs+=("$dir"); done < <(_lint_code_dirs)
    if [[ ${#dirs[@]} -eq 0 ]]; then
        echo "✓ File length passed"
        return 0
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ "$file" == */generated/* ]] && continue
        lines=$(wc -l < "$file" | tr -d ' ')
        if [[ $lines -gt 600 ]]; then
            over+="${file#$PROJECT_ROOT/}: $lines lines"$'\n'
        elif [[ $lines -gt 400 ]]; then
            long+="${file#$PROJECT_ROOT/}: $lines lines"$'\n'
        fi
    done < <(find "${dirs[@]}" -name "*.kt" -type f 2>/dev/null | sort)
    if [[ -n "$long" ]]; then
        echo "⚠ Files over 400 lines; split by concern before 600:"
        while IFS= read -r line; do [[ -n "$line" ]] && echo "    $line"; done <<< "$long"
    fi
    if [[ -n "$over" ]]; then
        _lint_print "Files over 600 lines" "$over"
        _lint_footer "Split the file by concern, as iOS's file_length asks."
        return 1
    fi
    echo "✓ File length passed"
}

# ── Entry points ────────────────────────────────────────────────────

# The project's own checks: TOOLKIT_LINT_HOOK (default lint.sh) runs after the
# toolkit's gates when it exists, with PROJECT_ROOT and SOURCE_DIR set.
do_android_project_lint_hook() {
    local hook="$PROJECT_ROOT/${TOOLKIT_LINT_HOOK:-lint.sh}" source_dir
    [[ -f "$hook" ]] || return 0
    source_dir=$(_lint_source_dir)
    PROJECT_ROOT="$PROJECT_ROOT" SOURCE_DIR="${source_dir#$PROJECT_ROOT/}" bash "$hook"
}

# ── Audit (iOS: overrides, unused, analyze) ──────────────────────────

do_android_override_audit() {
    local matches line
    matches=$(_lint_code_grep '// lint:allow')
    echo "── lint:allow overrides ──"
    if [[ -z "$matches" ]]; then
        echo "  (none)"
    else
        while IFS= read -r line; do
            echo "  ${line#$PROJECT_ROOT/}"
        done <<< "$matches"
        echo ""
        echo "  Each override is a deliberate departure from the architecture: rare, and it says why."
    fi
}

# What R8 removes from the profile build (minified, the app's own classes only).
do_android_unused() {
    _gradle_require || return 1
    local usage="$PROJECT_ROOT/${ANDROID_MODULE:-app}/build/outputs/mapping/profile/usage.txt" found
    echo "→ Building the profile app with R8"
    if ! _gradle_run unused ":${ANDROID_MODULE:-app}:assembleProfile"; then
        echo "✗ Unused check failed:"
        _gradle_failure "$(_gradle_log unused)"
        return 1
    fi
    if [[ ! -f "$usage" ]]; then
        echo "✗ R8 wrote no usage.txt at ${usage#$PROJECT_ROOT/}"
        return 1
    fi
    found=$(grep -E "^${ANDROID_UNUSED_PACKAGE:-com\.sendaturn\.app}\." "$usage" | grep -vE '\.(BuildConfig|R|R\$[a-z]+)(:|$)' || true)
    if [[ -n "$found" ]]; then
        echo "✗ Unused code found ($(wc -l <<< "$found" | tr -d ' ') classes; members are listed under each):"
        echo "$found" | head -200
        echo "  Full list: ${usage#$PROJECT_ROOT/}"
        return 1
    fi
    echo "✓ Unused code: none"
}

# Android Lint with compose-lints, every warning an error (the Gradle build reads turn.lint.strict).
do_android_analyze() {
    _gradle_require || return 1
    local variant
    variant=$(_build_variant)
    if _gradle_run analyze ":${ANDROID_MODULE:-app}:lint$variant" -Pturn.lint.strict=true; then
        echo "✓ Analyze passed"
    else
        echo "✗ Analyze failed:"
        _gradle_failure "$(_gradle_log analyze)"
        return 1
    fi
}

# Everything that checks the code, as iOS's audit: lint, then unused and analyze.
do_android_audit() {
    local failed=""
    do_android_override_audit
    do_lint || failed+=" lint"
    do_android_unused || failed+=" unused"
    do_android_analyze || failed+=" analyze"
    if [[ -n "$failed" ]]; then
        echo "✗ Audit failed:$failed"
        return 1
    fi
    echo "✓ Audit passed"
}

# Called by _lint_fast after ktlint and detekt.
do_android_arch_checks() {
    local gate failed=0
    for gate in "${ANDROID_GATES[@]}"; do
        "$gate" || failed=1
    done
    do_android_project_lint_hook || failed=1
    return "$failed"
}
