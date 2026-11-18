#!/bin/bash
# android-toolkit/build-transcription-bench.sh: the transcription quality test's
# host side. Pushes a corpus of clips into the app's files, runs the app's
# benchmark debug script over them, pulls its results.json, and prints the
# word error rate, language switching, caption timing, speed, memory and heat
# per engine and language, against a baseline from the leading platform.
# Sourced by build.sh.
#
# Provides: do_transcription_bench
# Depends on: _use_target, _app_id, _app_installed, _install_app, _find_apk
#             (build-lifecycle.sh), _run_as (build-debug.sh), _android_debug
#             (build-debug.sh), _lock_take (build-lock.sh), do_build (build-gradle.sh)
#
# Configuration (build.properties):
#   TRANSCRIPTION_BENCH_SCRIPT   the debug script that runs the clips (transcription_benchmark)
#   TRANSCRIPTION_BENCH_FOLDER   its folder under the app's files (transcription-bench)
#   TRANSCRIPTION_BENCH_CORPUS   the corpus folder with manifest.json (build/transcription-corpus)

_transcription_bench_usage() {
    cat <<'EOF'
Usage: ./build.sh android transcription-bench [target] [step] [options]

  Steps (none: push, run and report in turn):
    push      Copy the corpus's clips and a list of them into the app's files
    run       Run the benchmark script over them and pull results.json into
              build/transcription-bench/<serial>-<time>.json
    report    Print the tables for result files (--results, default the newest)
    clean     Remove the clips, the results and the benchmark's own model copy from the app

  Options:
    --corpus <dir>       The corpus: manifest.json and the clips it names
                         (default build/transcription-corpus)
    --engines <list>     whisper (default), google or whisper,google: the engines to run
    --prompts <list>     app, none or app,none (default): Whisper with the app's prompt, without it,
                         or both; Google's engine takes no prompt and runs once
    --clips <ids>        Only these clips, comma separated
    --baseline <file>    The leading platform's results.json for the same clips
    --results <file>     A result file for report; repeat for several phones
    --timeout <s>        How long run waits for the script (default 14400)
    --json               report prints its numbers as JSON instead of tables

  The corpus manifest (spec/recording.md 6.6):
    { "clips": [ { "id": "nl-switch-01", "file": "clips/nl-switch-01.m4a",
                   "language": "nl", "kind": "switching",
                   "reference": [ { "start": 0.4, "end": 3.1, "language": "nl",
                                    "text": "Hoi, ik zat net te denken" } ] } ] }
  kind is speech (default), switching, mixed, negative, long or public.
  A negative clip has no reference lines.
EOF
}

do_transcription_bench() {
    local target="" step="" corpus="" engines="whisper" prompts="app,none" clips="" baseline="" timeout=14400 as_json=false
    local results=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --corpus | --engines | --prompts | --clips | --baseline | --results | --timeout)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --corpus) corpus="$2" ;;
                    --engines) engines="$2" ;;
                    --prompts) prompts="$2" ;;
                    --clips) clips="$2" ;;
                    --baseline) baseline="$2" ;;
                    --results) results+=("$2") ;;
                    --timeout) timeout="$2" ;;
                esac
                shift 2
                ;;
            --json) as_json=true; shift ;;
            help | --help | -h) _transcription_bench_usage; return 0 ;;
            push | run | report | clean)
                if [[ -n "$step" ]]; then
                    echo "✗ Two steps: $step and $1"
                    return 1
                fi
                step="$1"
                shift
                ;;
            -*) echo "✗ Unknown flag: $1"; return 1 ;;
            *)
                if [[ -n "$target" ]]; then
                    echo "✗ Two targets: $target and $1"
                    return 1
                fi
                target="$1"
                shift
                ;;
        esac
    done
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        echo "✗ --timeout needs a whole number of seconds"
        return 1
    fi
    case "$prompts" in
        app | none | app,none | none,app) ;;
        *) echo "✗ --prompts takes app, none or app,none"; return 1 ;;
    esac
    case "$engines" in
        whisper | google | whisper,google | google,whisper) ;;
        *) echo "✗ --engines takes whisper, google or whisper,google"; return 1 ;;
    esac
    corpus="${corpus:-${TRANSCRIPTION_BENCH_CORPUS:-$PROJECT_ROOT/build/transcription-corpus}}"
    [[ "$corpus" == /* ]] || corpus="$PROJECT_ROOT/$corpus"
    if [[ -n "$baseline" && ! -f "$baseline" ]]; then
        echo "✗ No baseline at $baseline"
        return 1
    fi

    case "$step" in
        push) _bench_push "$target" "$corpus" ;;
        run) _bench_run "$target" "$prompts" "$clips" "$timeout" "$engines" ;;
        report) _bench_report "$corpus" "$baseline" "$as_json" ${results[@]+"${results[@]}"} ;;
        clean) _bench_clean "$target" ;;
        "")
            _bench_push "$target" "$corpus" || return 1
            _bench_run "$target" "$prompts" "$clips" "$timeout" "$engines" || return 1
            _bench_report "$corpus" "$baseline" "$as_json" "$_BENCH_PULLED"
            ;;
    esac
}

_bench_folder() {
    echo "files/${TRANSCRIPTION_BENCH_FOLDER:-transcription-bench}"
}

# The device and the installed debug app; installs the last build when it isn't there.
_bench_device() {
    local target="$1"
    if ! _debuggable_config; then
        echo "✗ The benchmark reads and writes the app's files with run-as, which needs the debug build."
        return 1
    fi
    _lock_take emulator || return 1
    _use_target "$target" || return 1
    "$ADB" -s "$SERIAL" wait-for-device
    _BENCH_APP=$(_app_id) || return 1
    if ! _app_installed "$_BENCH_APP"; then
        [[ -n "$(_find_apk)" ]] || do_build || return 1
        _install_app || return 1
    fi
}

_bench_push() {
    local target="$1" corpus="$2"
    if [[ ! -f "$corpus/manifest.json" ]]; then
        echo "✗ No manifest.json in $corpus ('./build.sh android transcription-bench help' shows its shape)"
        return 1
    fi
    local listing
    listing=$(python3 -B "$SCRIPT_DIR/transcription_bench.py" files --corpus "$corpus") || return 1
    _bench_device "$target" || return 1
    local folder staging count=0 file
    folder=$(_bench_folder)
    staging="/data/local/tmp/transcription-bench"
    _run_as "$_BENCH_APP" "rm -rf $folder/clips $folder/results.json && mkdir -p $folder/clips" || {
        echo "✗ Could not make $folder in $_BENCH_APP"
        return 1
    }
    "$ADB" -s "$SERIAL" shell "rm -rf $staging && mkdir -p $staging" >/dev/null
    echo "→ Pushing clips to $(_target_label)"
    # adb reads stdin, so the list comes on its own descriptor.
    while IFS= read -r file <&3; do
        [[ -z "$file" ]] && continue
        local name="${file//\//_}"
        "$ADB" -s "$SERIAL" push "$corpus/$file" "$staging/$name" >/dev/null || { echo "✗ adb push $file failed"; return 1; }
        _run_as "$_BENCH_APP" "cp $staging/$name $folder/clips/$name" || { echo "✗ Could not copy $file into the app"; return 1; }
        "$ADB" -s "$SERIAL" shell "rm -f $staging/$name" >/dev/null
        count=$((count + 1))
    done 3<<<"$listing"
    # The phone gets only the ids and files; the references stay on the Mac.
    local manifest
    manifest=$(mktemp)
    python3 -B "$SCRIPT_DIR/transcription_bench.py" device-manifest --corpus "$corpus" > "$manifest" || { rm -f "$manifest"; return 1; }
    "$ADB" -s "$SERIAL" push "$manifest" "$staging/manifest.json" >/dev/null || { rm -f "$manifest"; return 1; }
    rm -f "$manifest"
    _run_as "$_BENCH_APP" "cp $staging/manifest.json $folder/manifest.json" || return 1
    "$ADB" -s "$SERIAL" shell "rm -rf $staging" >/dev/null
    echo "✓ Clips in $_BENCH_APP/$folder: $count"
}

_bench_run() {
    local target="$1" prompts="$2" clips="$3" timeout="$4" engines="${5:-whisper}"
    _bench_device "$target" || return 1
    local folder
    folder=$(_bench_folder)
    export SCRIPT_ENV_TRANSCRIPTION_BENCH_PROMPTS="$prompts"
    export SCRIPT_ENV_TRANSCRIPTION_BENCH_ENGINES="$engines"
    if [[ -n "$clips" ]]; then
        export SCRIPT_ENV_TRANSCRIPTION_BENCH_CLIPS="$clips"
    fi
    local code=0
    _android_debug "$SERIAL" --no-build --script "${TRANSCRIPTION_BENCH_SCRIPT:-transcription_benchmark}" --timeout "$timeout" || code=$?
    unset SCRIPT_ENV_TRANSCRIPTION_BENCH_PROMPTS SCRIPT_ENV_TRANSCRIPTION_BENCH_ENGINES SCRIPT_ENV_TRANSCRIPTION_BENCH_CLIPS
    local out_dir="$PROJECT_ROOT/build/transcription-bench" out
    mkdir -p "$out_dir"
    out="$out_dir/${SERIAL//[^A-Za-z0-9_-]/_}-$(date +%Y%m%d-%H%M%S).json"
    if ! "$ADB" -s "$SERIAL" exec-out run-as "$_BENCH_APP" cat "$folder/results.json" > "$out" 2>/dev/null || ! python3 -B -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
        rm -f "$out"
        echo "✗ No results.json from the script"
        return 1
    fi
    _BENCH_PULLED="$out"
    echo "✓ Results in $out"
    return "$code"
}

_bench_report() {
    local corpus="$1" baseline="$2" as_json="$3"
    shift 3
    local files=("$@")
    if [[ ${#files[@]} -eq 0 ]]; then
        local newest
        newest=$(ls -t "$PROJECT_ROOT/build/transcription-bench/"*.json 2>/dev/null | head -1 || true)
        if [[ -z "$newest" ]]; then
            echo "✗ No results in build/transcription-bench; run the benchmark first or pass --results"
            return 1
        fi
        files=("$newest")
    fi
    local args=(report --corpus "$corpus")
    [[ -n "$baseline" ]] && args+=(--baseline "$baseline")
    [[ "$as_json" == true ]] && args+=(--json)
    python3 -B "$SCRIPT_DIR/transcription_bench.py" "${args[@]}" "${files[@]}"
}

_bench_clean() {
    local target="$1"
    _bench_device "$target" || return 1
    local folder
    folder=$(_bench_folder)
    _run_as "$_BENCH_APP" "rm -rf $folder" || { echo "✗ Could not remove $folder"; return 1; }
    echo "✓ Removed $_BENCH_APP/$folder"
}
