#!/bin/bash
# ── Profile ─────────────────────────────────────────────────────────
#
#   ./build.sh ios profile [target] [--script <names>] [--seconds N]
#                          [--render] [--template <name>] [--name <label>]
#
# Records an Instruments trace of the installed app (xctrace) on the
# connected phone or the booted simulator, then prints a summary: the frame
# lines a debug script's FrameMonitor marked (Points of Interest), the
# heaviest functions by their own time, and the app's own heaviest code.
# With --script the app is launched with those debug scripts running at
# once, so a scripted interaction is measured end to end. The trace is kept
# in build/traces/ to open in Instruments.

do_profile() {
    _detect_project_config
    _check_core_tools
    local target="" template="Time Profiler" seconds=40 scripts="" name="profile" render=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template) template="$2"; shift 2 ;;
            --seconds) seconds="$2"; shift 2 ;;
            --script) scripts="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            --render) render=true; shift ;;
            *) target="$1"; shift ;;
        esac
    done

    _select_capture_target "$target" || return 1
    BUNDLE_ID="$(_bundle_id_for_config)"

    local dir="${PROJECT_ROOT}/build/traces"
    mkdir -p "$dir"
    local trace="$dir/${name}_$(date +%Y%m%d-%H%M%S).trace"
    local args=(record --template "$template" --device "$_CAPTURE_UDID" --time-limit "${seconds}s" --output "$trace")
    # Time Profiler carries the frame lines a FrameMonitor marks (Points of
    # Interest); --render adds the render server and GPU frame times.
    [[ "$render" == true ]] && args+=(--instrument "Hitches" --instrument "GPU")
    if [[ -n "$scripts" ]]; then
        args+=(--env "TURN_DEBUG_SCRIPT_NAMES=$scripts" --env "TURN_DEBUG_SCRIPT_NO_MARKER=1")
    fi
    args+=(--launch -- "$BUNDLE_ID")

    echo "→ Profiling ${BUNDLE_ID} on $(_capture_target_label) for ${seconds}s (${template})"
    [[ -n "$scripts" ]] && echo "  running debug script(s): $scripts"
    if ! xcrun xctrace "${args[@]}" >/dev/null 2>"$dir/.xctrace.err"; then
        # xctrace exits non-zero when the time limit ends the launched app;
        # a written trace is still a good one.
        if [[ ! -d "$trace" ]]; then
            echo "✗ Recording failed:"
            cat "$dir/.xctrace.err"
            return 1
        fi
    fi
    echo "✓ Trace saved: $trace"
    _profile_summary "$trace"
}

# Prints the frame lines, the heaviest functions and the app's hot code.
_profile_summary() {
    local trace="$1"
    local tmp
    tmp=$(mktemp -d)
    xcrun xctrace export --input "$trace" --toc > "$tmp/toc.xml" 2>/dev/null || true
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$tmp/profile.xml" 2>/dev/null || true
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > "$tmp/signposts.xml" 2>/dev/null || true
    for table in hitches-renders hitches-gpu displayed-surfaces-per-second; do
        xcrun xctrace export --input "$trace" \
            --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$table\"]" > "$tmp/$table.xml" 2>/dev/null || true
    done
    python3 - "$tmp" "$PROJECT_NAME" <<'PY'
import sys, xml.etree.ElementTree as ET
from collections import Counter

tmp, app = sys.argv[1], sys.argv[2]

def load(name):
    try:
        return ET.parse(f"{tmp}/{name}").getroot()
    except Exception:
        return None

def resolver(root):
    by_id = {}
    for el in root.iter():
        if "id" in el.attrib:
            by_id[el.attrib["id"]] = el
    return lambda el: by_id.get(el.attrib["ref"], el) if el is not None and "ref" in el.attrib else el

signposts = load("signposts.xml")
if signposts is not None:
    real = resolver(signposts)
    lines, seen = [], set()
    for row in signposts.iter("row"):
        name = real(row.find("signpost-name"))
        message = real(row.find("os-log-metadata"))
        if message is None:
            message = real(row.find("message"))
        stamp = real(row.find("event-time"))
        text = (message.attrib.get("fmt") if message is not None else None) or ""
        key = (stamp.text if stamp is not None else None, text)
        if name is not None and name.attrib.get("fmt", "") in ("fps", "perf summary", "perf start") and key not in seen:
            seen.add(key)
            lines.append(f"  {name.attrib['fmt']:<13} {text}")
    if lines:
        print("\nFrames (FrameMonitor):")
        print("\n".join(lines))

def rows(name):
    root = load(name)
    if root is None:
        return []
    real = resolver(root)
    return [[real(c) for c in row] for row in root.iter("row")]

def value(cell):
    try:
        return int(cell.text)
    except (TypeError, ValueError):
        return 0

shown = [value(r[3]) for r in rows("displayed-surfaces-per-second.xml") if len(r) > 3]
renders = rows("hitches-renders.xml")
gpu = rows("hitches-gpu.xml")
if shown or renders:
    print("\nRendering (render server and GPU):")
    busy = [n for n in shown if n > 0]
    if busy:
        print(f"  frames shown per second: median {sorted(busy)[len(busy) // 2]}, lowest {min(busy)}")
    for label, table in (("render", renders), ("gpu", gpu)):
        times = sorted(value(r[1]) / 1e6 for r in table if len(r) > 1)
        if times:
            n = len(times)
            late = sum(1 for t in times if t > 16.7)
            print(f"  {label} time per frame: median {times[n // 2]:.1f} ms, p90 {times[int(n * 0.9)]:.1f} ms, "
                  f"max {times[-1]:.1f} ms; {late} of {n} over 16.7 ms")
    passes = sorted(value(r[3]) for r in renders if len(r) > 3)
    if passes:
        print(f"  offscreen passes per frame: median {passes[len(passes) // 2]}, max {passes[-1]}")
    windows = {}
    for r in renders:
        if len(r) > 3:
            windows.setdefault(value(r[0]) // 5_000_000_000 * 5, []).append((value(r[1]) / 1e6, value(r[3])))
    gpu_windows = {}
    for r in gpu:
        if len(r) > 1:
            gpu_windows.setdefault(value(r[0]) // 5_000_000_000 * 5, []).append(value(r[1]) / 1e6)
    if windows:
        print("  per 5 s:  frames  render ms  gpu ms  offscreen")
        for start in sorted(windows):
            frames = windows[start]
            gpu_ms = gpu_windows.get(start, [0])
            print(f"  {start:3d}-{start + 5:<3d}s {len(frames):6d}  {sum(f[0] for f in frames) / len(frames):9.1f}"
                  f"  {sum(gpu_ms) / len(gpu_ms):6.1f}  {sum(f[1] for f in frames) / len(frames):9.0f}")

profile = load("profile.xml")
if profile is None:
    print("\n(no time profile in this trace)")
    sys.exit(0)
real = resolver(profile)
self_time, app_inclusive, threads, total = Counter(), Counter(), Counter(), 0
for row in profile.iter("row"):
    weight = real(row.find("weight"))
    backtrace = real(row.find("tagged-backtrace"))
    if backtrace is None:
        backtrace = real(row.find("backtrace"))
    if weight is None or backtrace is None:
        continue
    try:
        w = int(weight.text or weight.attrib.get("fmt", "0").split()[0])
    except ValueError:
        w = 1
    frames = [real(f) for f in backtrace.findall("frame")]
    names = [(f.attrib.get("name", "?"), real(f.find("binary"))) for f in frames]
    if not names:
        continue
    total += w
    self_time[names[0][0]] += w
    thread = real(row.find("thread"))
    label = thread.attrib.get("fmt", "?").split(" (")[0] if thread is not None else "?"
    threads[label] += w
    seen = set()
    for fname, binary in names:
        if binary is not None and binary.attrib.get("name", "").startswith(app) and fname not in seen:
            app_inclusive[fname] += w
            seen.add(fname)

def show(title, counter, n):
    print(f"\n{title}")
    for fname, w in counter.most_common(n):
        print(f"  {100 * w / max(total, 1):5.1f}%  {fname[:150]}")

print(f"\nSampled {total / 1e6:.0f} ms of CPU in the app")
show("Time per thread:", threads, 8)
show("Heaviest functions (own time):", self_time, 25)
show(f"{app}'s own code (including what it calls):", app_inclusive, 25)
PY
    rm -rf "$tmp"
}
