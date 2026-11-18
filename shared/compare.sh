# toolkit/shared/compare.sh: the compare page, the leading platform's frames
# beside this platform's, per frame name
# Provides: do_compare
# Depends on: _compare_prepare <no_build> <target>, _compare_run_script
#             <script> <log> <frames dir> <fixture slot> <timeout> (the platform
#             toolkit), _sanitize_script_names (shared/scripts.sh),
#             compare.py beside this file

COMPARE_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compare.py"

_compare_usage() {
    cat <<'EOF'
Usage: ./build.sh compare <scripts> [target] [--fixture [slot|standard]] [--no-build]
                          [--ios <dir>] [--android <dir>] [--out <dir>] [--timeout N]

  Runs each debug script on this platform, collects its frames and writes
  build/compare/<run>/index.html: the iOS and the Android frame of each frame
  name side by side, a frame missing on either side marked, and both sides'
  [scriptor] and [perf] lines aligned with failed checks highlighted. The page
  is one file; frames are embedded at half size and link to the full PNGs.
  build/compare/latest points at the newest run.

  <scripts>          Comma-separated script names, e.g. long_press_check,lens_check
  --fixture [slot]   Seed each launch with a fresh session of the fixture slot
                     (AGENT_SLOT by default; "standard" means that default)
  --no-build         Use the built app
  --ios <dir>        The iOS side: a folder with frames/<script>/*.png and
                     logs/<script>.log (the reference set's layout), or with
                     <script>/ and <script>.log. Default: COMPARE_IOS_REFERENCE
  --android <dir>    Frames already collected, same layout; nothing runs
  --out <dir>        Write the run there instead of build/compare/<run>
  --timeout N        Seconds per script (default TOOLKIT_DEBUG_TIMEOUT or 600)

  The iOS side is read from frames already made (a reference run on slot 8);
  compare does not run the iOS simulator.
EOF
}

do_compare() {
    local scripts="" target="" fixture="" no_build=false ios_root="${COMPARE_IOS_REFERENCE:-}" android_root="" out="" timeout=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            help|--help|-h) _compare_usage; return 0 ;;
            --fixture)
                fixture="${AGENT_SLOT:-1}"
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    fixture="$2"
                    shift
                elif [[ "${2:-}" == "standard" ]]; then
                    shift
                fi
                shift
                ;;
            --no-build) no_build=true; shift ;;
            --ios | --android | --out | --timeout)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "✗ $1 needs a value."
                    return 1
                fi
                case "$1" in
                    --ios) ios_root="$2" ;;
                    --android) android_root="$2" ;;
                    --out) out="$2" ;;
                    --timeout) timeout="$2" ;;
                esac
                shift 2
                ;;
            -*) echo "✗ Unknown flag: $1"; return 1 ;;
            *)
                if [[ -z "$scripts" ]]; then
                    scripts="$1"
                elif [[ -z "$target" ]]; then
                    target="$1"
                else
                    echo "✗ One list of scripts and one target: $scripts, $target, $1"
                    return 1
                fi
                shift
                ;;
        esac
    done
    if [[ -z "$scripts" ]]; then
        _compare_usage
        return 1
    fi
    scripts=$(_sanitize_script_names "$scripts") || { echo "$scripts"; return 1; }
    if [[ -n "$timeout" && ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "✗ --timeout needs a whole number of seconds"
        return 1
    fi
    if [[ -n "$ios_root" && ! -d "$ios_root" ]]; then
        echo "✗ No iOS frames at $ios_root"
        return 1
    fi
    [[ -z "$ios_root" ]] && echo "⚠ No iOS side: pass --ios <dir> or set COMPARE_IOS_REFERENCE. Every iOS frame shows as missing."
    if [[ -n "$android_root" && ! -d "$android_root" ]]; then
        echo "✗ No Android frames at $android_root"
        return 1
    fi

    local run_dir
    if [[ -n "$out" ]]; then
        run_dir="$out"
    else
        run_dir="$PROJECT_ROOT/build/compare/$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$run_dir"
    run_dir="$(cd "$run_dir" && pwd)"

    local list=() name
    local IFS_SAVE="$IFS"
    IFS=','
    for name in $scripts; do
        name="${name// /}"
        [[ -n "$name" ]] && list+=("$name")
    done
    IFS="$IFS_SAVE"

    local failed_runs=0
    if [[ -z "$android_root" ]]; then
        android_root="$run_dir/android"
        mkdir -p "$android_root/frames" "$android_root/logs"
        _compare_prepare "$no_build" "$target" || return 1
        for name in "${list[@]}"; do
            echo ""
            echo "━━ $name"
            _compare_run_script "$name" "$android_root/logs/$name.log" "$android_root/frames/$name" "$fixture" "$timeout" \
                || failed_runs=$((failed_runs + 1))
        done
    fi

    echo ""
    echo "→ Writing the compare page"
    python3 -B -I "$COMPARE_PY" --out "$run_dir/index.html" \
        ${ios_root:+--ios "$ios_root"} --android "$android_root" "${list[@]}" || return 1
    if [[ -z "$out" ]]; then
        ln -sfn "$(basename "$run_dir")" "$PROJECT_ROOT/build/compare/latest"
    fi
    echo "✓ $run_dir/index.html"
    if [[ $failed_runs -gt 0 ]]; then
        echo "✗ $failed_runs script run(s) failed; the page shows what they saved."
        return 1
    fi
    return 0
}
