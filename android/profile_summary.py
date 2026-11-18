"""Summary of a Perfetto trace for ./build.sh android profile.

Runs trace_processor_shell on the device, where the trace is, and prints what
toolkit/ios/build-profile.sh prints for an Instruments trace: the FrameMonitor
lines, the frame timeline (--render), CPU time per thread, the heaviest
functions by their own time and the app's own code. --main keeps only the main
thread and adds its busy time per quarter second; --until keeps only the first
seconds; --callers lists what was on the stack under a function.
"""

import argparse
import csv
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

parser = argparse.ArgumentParser()
parser.add_argument("--adb", required=True)
parser.add_argument("--serial", required=True)
parser.add_argument("--tp", required=True, help="trace_processor_shell on the device")
parser.add_argument("--trace", required=True, help="the trace on the device")
parser.add_argument("--work", required=True, help="a folder on the device for the query file")
parser.add_argument("--app", required=True, help="the application id")
parser.add_argument("--tag", required=True, help="the app's log tag")
parser.add_argument("--code", default="", help="the package prefix of the app's own code")
parser.add_argument("--mapping", default="", help="R8's mapping.txt for a minified build")
parser.add_argument("--callers", default="")
parser.add_argument("--until", type=float, default=0)
parser.add_argument("--main", action="store_true")
parser.add_argument("--render", action="store_true")
args = parser.parse_args()

QUERY_FILE = f"{args.work}/turn-profile-query.sql"


def query(sql):
    """Rows of one SELECT, as lists of strings (None for NULL)."""
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql)
        local = f.name
    try:
        subprocess.run([args.adb, "-s", args.serial, "push", local, QUERY_FILE], check=True, capture_output=True)
    finally:
        os.unlink(local)
    done = subprocess.run(
        [args.adb, "-s", args.serial, "shell", args.tp, "-q", QUERY_FILE, args.trace],
        capture_output=True,
        text=True,
        errors="replace",
    )
    out = done.stdout.replace("\r", "")
    if done.returncode != 0 and not out.strip():
        sys.stderr.write(done.stderr[-2000:])
        raise SystemExit("✗ trace_processor_shell failed on the query:\n" + sql)
    reader = csv.reader(io.StringIO(out))
    rows = [row for row in reader if row]
    if not rows:
        return []
    return [[None if cell == "[NULL]" else cell for cell in row] for row in rows[1:]]


def number(cell, default=0):
    try:
        return int(cell)
    except (TypeError, ValueError):
        try:
            return float(cell)
        except (TypeError, ValueError):
            return default


app = args.app.replace("'", "''")
bounds = query("SELECT start_ts, end_ts FROM trace_bounds;")
if not bounds:
    raise SystemExit("✗ The trace has no events.")
start, end = number(bounds[0][0]), number(bounds[0][1])
limit = start + int(args.until * 1e9) if args.until else end + 1


def at(ts):
    return (number(ts) - start) / 1e9


# A process forked from the zygote can keep the zygote's name in the trace; its
# main thread carries the last 15 characters of the application id.
processes = query(
    f"SELECT p.upid, p.pid FROM process p WHERE p.name = '{app}' OR p.cmdline = '{app}' "
    f"OR p.upid IN (SELECT t.upid FROM thread t JOIN process q USING (upid) "
    f"WHERE t.tid = q.pid AND t.name = '{app[-15:]}');"
)
upids = ",".join(row[0] for row in processes) or "-1"
pids = {row[1] for row in processes}
threads = {}
for utid, tid, name, upid in query(f"SELECT utid, tid, name, upid FROM thread WHERE upid IN ({upids});"):
    threads[utid] = (name or f"thread {tid}", tid in pids)
main_utids = [utid for utid, (_, is_main) in threads.items() if is_main]
if not processes:
    print(f"\n(no process {args.app} in this trace)")

# ── Frames (FrameMonitor) ─────────────────────────────────────────────
#
# The app logs each FrameMonitor line in full; the trace sections are cut at
# 127 characters, so the log lines come first and the sections stand in when
# the log is missing.

lines = []
logs = query(
    f"SELECT ts, msg FROM android_logs WHERE tag = '{args.tag.replace(chr(39), '')}' "
    f"AND msg GLOB '*] perf *' AND ts < {limit} ORDER BY ts;"
)
for ts, msg in logs:
    text = re.sub(r"^.*?\] perf ", "", msg or "")
    if " second: " in text:
        lines.append((number(ts), "fps", text.replace(" second:", ":")))
    else:
        lines.append((number(ts), "perf summary", text))
sections = query(
    f"SELECT s.ts, s.name FROM slice s JOIN thread_track t ON s.track_id = t.id "
    f"WHERE t.utid IN ({','.join(threads) or '-1'}) AND (s.name GLOB 'perf start *' OR s.name GLOB 'perf summary *') "
    f"AND s.ts < {limit} ORDER BY s.ts;"
)
for ts, name in sections:
    if name.startswith("perf start "):
        lines.append((number(ts), "perf start", name[len("perf start "):]))
    elif not logs:
        lines.append((number(ts), "perf summary", name[len("perf summary "):]))
if not logs:
    for ts, name, value in query(
        f"SELECT c.ts, t.name, c.value FROM counter c JOIN process_counter_track t ON c.track_id = t.id "
        f"WHERE t.upid IN ({upids}) AND t.name GLOB 'fps *' AND c.ts < {limit} ORDER BY c.ts;"
    ):
        lines.append((number(ts), "fps", f"{name[4:]}: {number(value):.0f} fps"))
if lines:
    print("\nFrames (FrameMonitor):")
    for ts, kind, text in sorted(lines, key=lambda line: line[0]):
        print(f"  {kind:<13} {text}")

# ── Rendering (frame timeline) ────────────────────────────────────────

if args.render:
    frames = query(
        f"SELECT ts, dur, jank_type FROM actual_frame_timeline_slice "
        f"WHERE upid IN ({upids}) AND ts < {limit} ORDER BY ts;"
    )
    draws = query(
        f"SELECT s.dur FROM slice s JOIN thread_track t ON s.track_id = t.id JOIN thread th USING (utid) "
        f"WHERE th.upid IN ({upids}) AND th.name = 'RenderThread' AND s.name GLOB 'DrawFrame*' AND s.ts < {limit};"
    )
    if frames:
        print("\nRendering (frame timeline):")
        per_second = Counter(int(at(ts)) for ts, _, _ in frames)
        busy = sorted(per_second.values())
        print(f"  frames shown per second: median {busy[len(busy) // 2]}, lowest {busy[0]}")
        for label, times in (
            ("frame", sorted(number(dur) / 1e6 for _, dur, _ in frames)),
            ("RenderThread draw", sorted(number(row[0]) / 1e6 for row in draws)),
        ):
            if times:
                n = len(times)
                late = sum(1 for t in times if t > 16.7)
                print(
                    f"  {label} time: median {times[n // 2]:.1f} ms, p90 {times[int(n * 0.9)]:.1f} ms, "
                    f"max {times[-1]:.1f} ms; {late} of {n} over 16.7 ms"
                )
        janks = Counter(jank for _, _, jank in frames if jank and jank != "None")
        if janks:
            print("  missed deadlines: " + ", ".join(f"{name} {n}" for name, n in janks.most_common()))
        windows = {}
        for ts, dur, jank in frames:
            windows.setdefault(int(at(ts)) // 5 * 5, []).append((number(dur) / 1e6, bool(jank and jank != "None")))
        print("  per 5 s:  frames  frame ms  janky")
        for first in sorted(windows):
            window = windows[first]
            print(
                f"  {first:3d}-{first + 5:<3d}s {len(window):6d}  {sum(w[0] for w in window) / len(window):8.1f}"
                f"  {sum(1 for w in window if w[1]):5d}"
            )
    else:
        print("\n(no frame timeline for the app in this trace)")

# ── CPU ───────────────────────────────────────────────────────────────

scope_utids = main_utids if args.main else list(threads)
scope_list = ",".join(scope_utids) or "-1"
running = Counter()
timeline = Counter()
first_slice = None
for utid, ts, dur in query(
    f"SELECT utid, ts, dur FROM sched_slice WHERE utid IN ({scope_list}) AND ts < {limit} AND dur > 0;"
):
    ts, dur = number(ts), min(number(dur), limit - number(ts))
    running[utid] += dur
    if utid in main_utids:
        first_slice = ts if first_slice is None else min(first_slice, ts)
        # Splits the slice across the quarter seconds it spans.
        while dur > 0:
            quarter = (ts - start) // 250_000_000
            edge = start + (quarter + 1) * 250_000_000
            part = min(dur, edge - ts)
            timeline[quarter] += part
            ts, dur = ts + part, dur - part

scope = "on the main thread" if args.main else "in the app"
window = f" in the first {args.until:g} s" if args.until else ""
total_running = sum(running.values())
print(f"\nRan {total_running / 1e6:.0f} ms of CPU {scope}{window}")
if args.main and timeline:
    print(f"\nMain thread busy per quarter second (first run at {at(first_slice):.2f} s):")
    for quarter in range(min(timeline), max(timeline) + 1):
        ms = timeline[quarter] / 1e6
        print(f"  {quarter / 4:6.2f} s  {ms:5.0f} ms  {'#' * round(ms / 10)}")

by_name = Counter()
for utid, ns in running.items():
    by_name[threads[utid][0] + (" (main)" if threads[utid][1] else "")] += ns
print("\nTime per thread:")
for name, ns in by_name.most_common(8):
    print(f"  {100 * ns / max(total_running, 1):5.1f}%  {ns / 1e6:6.0f} ms  {name[:120]}")

# ── Callstack samples ────────────────────────────────────────────────


def load_mapping(path):
    """R8's renames: obfuscated class to (class, {obfuscated method: [original names]}).

    R8 gives methods of different signatures the same short name, and lists
    inlined methods under the method they were inlined into, qualified with
    their own class. A frame carries no line, so every unqualified original
    of a short name is kept, in order.
    """
    classes, current = {}, None
    if not path or not os.path.isfile(path):
        return classes
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("#"):
                continue
            if not line.startswith(" "):
                m = re.match(r"(\S+) -> (\S+):", line)
                current = None
                if m:
                    current = (m.group(1), {})
                    classes[m.group(2)] = current
                continue
            if current is None:
                continue
            m = re.match(r"\s+(?:\d+:\d+:)?\S+ (\S+)\(.*\)(?::\d+(?::\d+)?)? -> (\S+)", line)
            if not m:
                continue
            original, short = m.group(1), m.group(2)
            names = current[1].setdefault(short, [])
            if "." in original:
                names.append("?" + original)
            elif original not in names:
                names.append(original)
    for _, methods in classes.values():
        for short, names in methods.items():
            own = [name for name in names if not name.startswith("?")]
            methods[short] = own or [names[-1][1:]]
    return classes


renames = load_mapping(args.mapping)


def readable(name):
    """A frame name with R8's renames undone, when a mapping is given."""
    if not renames or not name:
        return name
    m = re.match(r"^(.*?)([\w$.]+)\.([\w$<>]+)(\(.*)?$", name)
    if not m:
        return name
    owner = renames.get(m.group(2))
    if owner is None:
        return name
    names = owner[1].get(m.group(3), [m.group(3)])
    full = names[0] if len(names) == 1 and "." in names[0] else f"{owner[0]}.{'|'.join(names[:3])}"
    return f"{m.group(1)}{full}{m.group(4) or ''}"


samples = query(
    f"SELECT ts, utid, callsite_id FROM perf_sample WHERE utid IN ({scope_list}) "
    f"AND callsite_id IS NOT NULL AND ts < {limit};"
)
if not samples:
    print("\n(no callstack samples in this trace: callstacks need a profile or debug build)")
    sys.exit(0)

frames = {}
for fid, name, mapping in query(
    "SELECT f.id, coalesce(f.deobfuscated_name, f.name), m.name FROM stack_profile_frame f "
    "LEFT JOIN stack_profile_mapping m ON f.mapping = m.id;"
):
    frames[fid] = readable(name) if name else f"[{os.path.basename(mapping or '?')}]"
# Native frames come mangled; c++filt (Xcode's command line tools) reads them all at once.
mangled = sorted({name for name in frames.values() if name.startswith("_Z")})
if mangled and shutil.which("c++filt"):
    plain = [re.sub(r"\.__uniq\.\d+", "", name) for name in mangled]
    done = subprocess.run(["c++filt"], input="\n".join(plain) + "\n", capture_output=True, text=True)
    readable_names = done.stdout.splitlines()
    if done.returncode == 0 and len(readable_names) == len(mangled):
        names = dict(zip(mangled, readable_names))
        frames = {fid: names.get(name, name) for fid, name in frames.items()}
callsites = {cid: (parent, fid) for cid, parent, fid in query("SELECT id, parent_id, frame_id FROM stack_profile_callsite;")}


def stack(cid):
    """Frame names from the leaf to the root."""
    names = []
    while cid is not None and cid in callsites:
        parent, fid = callsites[cid]
        names.append(frames.get(fid, "?"))
        cid = parent
    return names


code = args.code
self_time, app_inclusive, thread_samples = Counter(), Counter(), Counter()
on_stack, wanted_total, total = Counter(), 0, 0
stacks = {}
for ts, utid, cid in samples:
    names = stacks.get(cid)
    if names is None:
        names = stacks[cid] = stack(cid)
    if not names:
        continue
    total += 1
    self_time[names[0]] += 1
    thread_samples[threads[utid][0]] += 1
    seen = set()
    for name in names:
        if code and code in name and name not in seen:
            app_inclusive[name] += 1
            seen.add(name)
    if args.callers and args.callers in names[0]:
        wanted_total += 1
        for name in dict.fromkeys(names[1:]):
            on_stack[name] += 1


def show(title, counter, n):
    print(f"\n{title}")
    for name, w in counter.most_common(n):
        print(f"  {100 * w / max(total, 1):5.1f}%  {name[:150]}")


print(f"\nSampled {total} callstacks {scope}{window}")
show("Samples per thread:", thread_samples, 8)
show("Heaviest functions (own time):", self_time, 25)
if code:
    show(f"{code.rstrip('.')}'s own code (including what it calls):", app_inclusive, 25)
if args.callers:
    print(f"\nOn the stack under {args.callers} ({100 * wanted_total / max(total, 1):.1f}% of the time), share of its samples:")
    for name, w in on_stack.most_common(40):
        print(f"  {100 * w / max(wanted_total, 1):5.1f}%  {name[:150]}")
