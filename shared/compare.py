#!/usr/bin/env python3
"""Writes the compare page: one self-contained HTML file with iOS and Android
frames side by side per frame name, and both platforms' script log lines
aligned.

    compare.py --out <page.html> --ios <root> --android <root> <script>...

A root holds frames/<script>/<frame>.png and logs/<script>.log (the iOS
reference set's layout); a root that holds <script>/ and <script>.log directly
works too. Frames are embedded as JPEG at half width (sips) and link to the
full-size PNG. Exits 0 when the page was written; the summary goes to stdout.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

EMBED_WIDTH = 603
SAVED = re.compile(r"DebugScreenshot: saved (.+)\.png")
LINE = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3})\s+([A-Z]+)\s+\[([^\]]+)\]\s?(.*)$")
RESULT = re.compile(r"SCRIPT_RESULT (\S+): (\d+) passed, (\d+) failed")
KEPT_CATS = {"scriptor", "perf"}
KEPT_WORDS = ("CHECK_FAILED", "CHECK_PASSED", "SCRIPT_RESULT", "DEBUG_SESSION_ENDED")


@dataclass
class Side:
    name: str
    frames_dir: Path | None
    log: Path | None
    frames: dict[str, Path] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)
    lines: list[tuple[str, str, str]] = field(default_factory=list)
    result: str = ""
    failed: int = 0


def find_dir(root: Path | None, script: str) -> Path | None:
    if root is None:
        return None
    for candidate in (root / "frames" / script, root / script):
        if candidate.is_dir():
            return candidate
    return None


def find_log(root: Path | None, script: str) -> Path | None:
    if root is None:
        return None
    for candidate in (root / "logs" / f"{script}.log", root / f"{script}.log"):
        if candidate.is_file():
            return candidate
    return None


def load_side(name: str, root: Path | None, script: str) -> Side:
    side = Side(name, find_dir(root, script), find_log(root, script))
    if side.frames_dir:
        side.frames = {p.stem: p for p in sorted(side.frames_dir.glob("*.png"))}
    saved_order: list[str] = []
    if side.log:
        text = side.log.read_text(errors="replace")
        for raw in text.splitlines():
            match = LINE.match(raw.strip())
            if not match:
                continue
            _, level, cat, msg = match.groups()
            saved = SAVED.search(msg)
            if saved and saved.group(1) not in saved_order:
                saved_order.append(saved.group(1))
            if cat in KEPT_CATS or any(word in msg for word in KEPT_WORDS):
                side.lines.append((level, cat, msg))
            result = RESULT.search(msg)
            if result and result.group(1) == script:
                side.result = f"{result.group(2)} passed, {result.group(3)} failed"
            if "CHECK_FAILED" in msg:
                side.failed += 1
    # Frames in the order the script saved them; any the log didn't name
    # (no log, or a frame saved twice) follow by name.
    side.order = [n for n in saved_order if n in side.frames]
    side.order += [n for n in sorted(side.frames) if n not in side.order]
    return side


def merged_order(ios: list[str], android: list[str]) -> list[str]:
    """iOS order, with each Android-only frame placed after the frame that
    comes before it on Android."""
    merged = list(ios)
    previous: str | None = None
    for name in android:
        if name not in merged:
            at = merged.index(previous) + 1 if previous in merged else len(merged)
            merged.insert(at, name)
        previous = name
    return merged


def embed(png: Path, work: Path) -> str:
    if shutil.which("sips"):
        out = work / (hashlib.sha1(str(png).encode()).hexdigest() + ".jpg")
        done = subprocess.run(
            ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "78",
             "--resampleWidth", str(EMBED_WIDTH), str(png), "--out", str(out)],
            capture_output=True,
        )
        if done.returncode == 0 and out.is_file():
            return "data:image/jpeg;base64," + base64.b64encode(out.read_bytes()).decode()
    return "data:image/png;base64," + base64.b64encode(png.read_bytes()).decode()


def norm(msg: str) -> str:
    msg = re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "<id>", msg)
    msg = re.sub(r"/\S+", "<path>", msg)
    return re.sub(r"\d+(\.\d+)?", "#", msg)


def aligned(ios: list[tuple[str, str, str]], android: list[tuple[str, str, str]]):
    """Rows of (ios line or None, android line or None), equal messages on one row."""
    a = [norm(m) for _, _, m in ios]
    b = [norm(m) for _, _, m in android]
    rows = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            rows += [(ios[i1 + k], android[j1 + k]) for k in range(i2 - i1)]
        else:
            left, right = ios[i1:i2], android[j1:j2]
            for k in range(max(len(left), len(right))):
                rows.append((left[k] if k < len(left) else None, right[k] if k < len(right) else None))
    return rows


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def cell(line) -> str:
    if line is None:
        return '<td class="gap"></td>'
    level, cat, msg = line
    cls = "fail" if "CHECK_FAILED" in msg or level == "ERROR" else ("warn" if level == "WARNING" else "")
    return f'<td class="{cls}"><span class="cat">[{esc(cat)}]</span> {esc(msg)}</td>'


def figure(side: Side, name: str, work: Path) -> str:
    png = side.frames.get(name)
    if png is None:
        where = "no frame folder" if side.frames_dir is None else "not saved"
        return f'<figure class="missing"><div class="hole">No {side.name} frame<br><small>{where}</small></div></figure>'
    href = "file://" + str(png.resolve())
    return (f'<figure><a href="{esc(href)}" title="Full size: {esc(str(png))}">'
            f'<img loading="lazy" alt="{esc(side.name)} {esc(name)}" src="{embed(png, work)}"></a></figure>')


def result_text(side: Side) -> str:
    if side.log is None:
        return "no log"
    return side.result or "no SCRIPT_RESULT"


def section(script: str, ios: Side, android: Side, work: Path) -> tuple[str, dict]:
    names = merged_order(ios.order, android.order)
    both = [n for n in names if n in ios.frames and n in android.frames]
    only_ios = [n for n in names if n in ios.frames and n not in android.frames]
    only_android = [n for n in names if n in android.frames and n not in ios.frames]
    rows = []
    for name in names:
        state = "both" if name in both else ("only-ios" if name in only_ios else "only-android")
        badge = {"both": "", "only-ios": '<span class="badge">only iOS</span>',
                 "only-android": '<span class="badge">only Android</span>'}[state]
        rows.append(
            f'<div class="frame {state}" id="{esc(script)}--{esc(name)}">'
            f'<h3><a href="#{esc(script)}--{esc(name)}">{esc(name)}</a>{badge}</h3>'
            f'<div class="pair">{figure(ios, name, work)}{figure(android, name, work)}</div></div>'
        )
    if not names:
        rows.append('<p class="none">Neither side has a frame for this script.</p>')
    log_rows = "".join(f"<tr>{cell(i)}{cell(a)}</tr>" for i, a in aligned(ios.lines, android.lines))
    failed = ios.failed + android.failed
    logs = (
        f'<details{" open" if failed else ""}><summary>Script lines ({len(ios.lines)} iOS, {len(android.lines)} Android'
        f'{f", {failed} failed checks" if failed else ""})</summary>'
        f'<table class="log"><thead><tr><th>iOS</th><th>Android</th></tr></thead><tbody>{log_rows}</tbody></table></details>'
        if ios.lines or android.lines else ""
    )
    counts = {"script": script, "both": len(both), "only_ios": len(only_ios), "only_android": len(only_android),
              "ios": result_text(ios), "android": result_text(android), "failed": failed}
    head = (
        f'<section id="{esc(script)}"><h2>{esc(script)}</h2>'
        f'<p class="meta">{len(both)} paired, {len(only_ios)} only on iOS, {len(only_android)} only on Android. '
        f'iOS: {esc(result_text(ios))}. Android: {esc(result_text(android))}.</p>'
        f'<div class="cols"><span>iOS</span><span>Android</span></div>'
    )
    return head + "".join(rows) + logs + "</section>", counts


STYLE = """
:root{--bg:#f6f4ef;--card:#fff;--ink:#1d1b18;--soft:#6b665e;--line:#ddd8ce;--miss:#f0ece3;--bad:#b3261e;--badbg:#fbe9e7;--warnbg:#fdf3d8;--accent:#3b5bdb}
@media (prefers-color-scheme:dark){:root{--bg:#161513;--card:#201f1c;--ink:#ece8e0;--soft:#a29d94;--line:#37342f;--miss:#2a2824;--bad:#ff8a80;--badbg:#3a1f1c;--warnbg:#3a321c;--accent:#91a7ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1180px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:19px;margin:40px 0 4px}h3{font-size:14px;margin:0 0 8px;font-weight:600}
h3 a{color:inherit;text-decoration:none}.meta,.sub{color:var(--soft);margin:0 0 12px}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
.summary td.num{text-align:right;font-variant-numeric:tabular-nums}.summary a{color:var(--accent)}
tr.bad td{background:var(--badbg)}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:16px;position:sticky;top:0;background:var(--bg);padding:6px 0;font-weight:600;color:var(--soft);z-index:1}
.frame{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;margin:0 0 14px}
.frame.only-ios,.frame.only-android{border-color:var(--bad)}
.badge{margin-left:8px;font-size:12px;color:var(--bad);font-weight:600}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}
figure{margin:0}img{display:block;width:100%;height:auto;border-radius:6px;border:1px solid var(--line)}
.hole{aspect-ratio:1206/2622;display:flex;align-items:center;justify-content:center;text-align:center;background:var(--miss);border:2px dashed var(--bad);border-radius:6px;color:var(--bad);font-weight:600}
.hole small{color:var(--soft);font-weight:400}
details{margin:8px 0 0}summary{cursor:pointer;color:var(--soft)}
table.log{font:12px/1.4 ui-monospace,Menlo,monospace;table-layout:fixed;margin-top:8px}
table.log td{word-break:break-word;width:50%}td.gap{background:var(--miss)}td.fail{background:var(--badbg);color:var(--bad);font-weight:600}td.warn{background:var(--warnbg)}
.cat{color:var(--soft)}.none{color:var(--soft)}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--ios")
    parser.add_argument("--android")
    parser.add_argument("--title", default="")
    parser.add_argument("scripts", nargs="+")
    args = parser.parse_args()
    ios_root = Path(args.ios) if args.ios else None
    android_root = Path(args.android) if args.android else None
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    sections, counts = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for script in args.scripts:
            body, c = section(script, load_side("iOS", ios_root, script), load_side("Android", android_root, script), Path(tmp))
            sections.append(body)
            counts.append(c)

    rows = "".join(
        f'<tr class="{"bad" if c["only_ios"] or c["only_android"] or c["failed"] else ""}">'
        f'<td><a href="#{esc(c["script"])}">{esc(c["script"])}</a></td>'
        f'<td class="num">{c["both"]}</td><td class="num">{c["only_ios"]}</td><td class="num">{c["only_android"]}</td>'
        f'<td>{esc(c["ios"])}</td><td>{esc(c["android"])}</td></tr>'
        for c in counts
    )
    title = args.title or "Compare " + ", ".join(args.scripts)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    page = (
        f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
        f'<meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title>'
        f'<style>{STYLE}</style></head><body><main><h1>{esc(title)}</h1>'
        f'<p class="sub">{stamp}. iOS: {esc(str(ios_root) if ios_root else "none")}. '
        f'Android: {esc(str(android_root) if android_root else "none")}. Frames are shown at half size; '
        f'click one for the full PNG.</p>'
        f'<table class="summary"><thead><tr><th>Script</th><th>Paired</th><th>Only iOS</th><th>Only Android</th>'
        f'<th>iOS checks</th><th>Android checks</th></tr></thead><tbody>{rows}</tbody></table>'
        + "".join(sections) + "</main></body></html>"
    )
    tmp_out = out.with_suffix(".html.partial")
    tmp_out.write_text(page)
    os.replace(tmp_out, out)

    for c in counts:
        print(f"  {c['script']}: {c['both']} paired, {c['only_ios']} only on iOS, {c['only_android']} only on Android"
              f" (iOS {c['ios']}; Android {c['android']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
