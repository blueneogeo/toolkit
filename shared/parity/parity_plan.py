"""sync plan: the pending units in packages, one brief each, and plan.json for the sync workflow."""

import datetime
import json
import os
import re
from collections import defaultdict
from dataclasses import dataclass, field

from parity_sync import (INTERACTION_APIS, IOS_ONLY_WORDING, android_paths_for, order_key, pending_against, short,
                         symbol_changes, symbol_notes, symbol_specs)

MAX_PACKAGES = 4
MAX_UNITS = 25
DIFF_LINES = 400
HUB_UNITS = ("model/AppState",)
TEST_CLASS = re.compile(r"^(?:internal |open )?class (\w+Tests\w*)", re.MULTILINE)
WORDING_LITERAL = re.compile(r'"[^"\n]*(?:' + IOS_ONLY_WORDING.pattern + r')[^"\n]*"')


@dataclass
class Item:
    key: str
    kind: str                 # changed, renamed, deleted, new
    status: str
    since: str                # the iOS commit the unit was ported from; the marker for a new unit
    ios: dict                 # ios path -> blob at the target
    diff_paths: list
    android: list
    tier: str
    scripts: list = field(default_factory=list)
    frames: list = field(default_factory=list)
    source: str = ""
    references: set = field(default_factory=set)
    declares: set = field(default_factory=set)
    provides: list = field(default_factory=list)    # Symbols added on iOS
    notes: list = field(default_factory=list)
    diff: str = ""
    interaction: list = field(default_factory=list)
    wording: list = field(default_factory=list)


@dataclass
class Package:
    items: list
    after: set = field(default_factory=set)       # indexes of packages this one needs first
    wave: int = 1
    id: str = ""

    @property
    def keys(self):
        return sorted(item.key for item in self.items)

    @property
    def views(self):
        return any(item.tier == "component" for item in self.items)


def folder_group(key):
    parts = key.split("/")
    if parts[0] == "view" and len(parts) > 2:
        return "/".join(parts[:2])
    return parts[0] if len(parts) > 1 else "app"


def item_tier(config, key, paths):
    if key.startswith("tests/"):
        return "test"
    if key.startswith("debug/"):
        return "script"
    tiers = {config.tier(p) for p in paths}
    for tier in ("component", "strict"):
        if tier in tiers:
            return tier
    return "other"


def collect_items(ctx, ledger, pending):
    config = ctx.config
    items = []
    for kind, entries in (("changed", pending.changed), ("renamed", pending.renamed), ("deleted", pending.deleted)):
        for unit, changes in entries:
            ios = {p: pending.target_files[p] for p in unit.ios if p in pending.target_files}
            ios.update({new: blob for _, _, new, _, blob in changes if new and blob})
            diff_paths = sorted({p for change in changes for p in change[1:3] if p} | set(ios))
            android = sorted(unit.android) or android_paths_for(config, ios)
            items.append(Item(key=unit.key, kind=kind, status=unit.status, since=unit.ios_commit, ios=ios,
                              diff_paths=diff_paths, android=android, tier=item_tier(config, unit.key, diff_paths),
                              scripts=list(unit.scripts), frames=list(unit.frames)))
    for key, paths in pending.added_units.items():
        ios = {p: pending.target_files[p] for p in paths}
        items.append(Item(key=key, kind="new", status="new", since=pending.marker, ios=ios, diff_paths=sorted(paths),
                          android=android_paths_for(config, paths), tier=item_tier(config, key, paths)))
    return sorted(items, key=lambda item: order_key(ctx, item.key))


def read_items(ctx, items, pending):
    swift = {p: b for item in items for p, b in item.ios.items() if p.endswith(".swift")}
    contents = ctx.repo.cat_blobs(set(swift.values()))
    extracted = ctx.tools.extract_ios(ctx.repo, swift)
    changes = symbol_changes(ctx, symbol_specs(pending.changed + pending.renamed, pending.deleted, pending.added_units,
                                               pending.target_files))
    for item in items:
        texts = []
        for path in sorted(item.ios):
            if path.endswith(".swift"):
                texts.append(contents[swift[path]].decode("utf-8", errors="replace"))
                entry = extracted.get(path, {})
                item.references.update(entry.get("references", []))
                item.declares.update(type_names(entry.get("types", [])))
        item.source = "\n".join(texts)
        change = changes.get(item.key)
        if change:
            item.provides = list(change["added"])
            item.notes = symbol_notes(change)
        item.diff = ctx.repo.git("diff", "-M", item.since, pending.target, "--", *item.diff_paths) if item.since else ""
        changed_lines = [line for line in item.diff.splitlines()
                         if line[:1] in "+-" and not line.startswith(("+++", "---"))]
        item.interaction = sorted({m.group(1) for line in changed_lines for m in INTERACTION_APIS.finditer(line)})
        item.wording = sorted({m.group(0) for line in changed_lines if line.startswith("+")
                               and not line[1:].lstrip().startswith("//") for m in WORDING_LITERAL.finditer(line)})


def type_names(types):
    names = set()
    for info in types:
        names.add(info["name"])
        names |= type_names(info.get("types", []))
    return names


# Grouping


def uses(dependent, symbol):
    if symbol.name[:1].isupper():
        return symbol.name in dependent.references
    if len(symbol.name) < 5:
        return False
    owner = symbol.owner
    if owner and owner not in dependent.references and owner not in dependent.declares:
        return False
    return re.search(r"\b" + re.escape(symbol.name) + r"\b", dependent.source) is not None


def group(items, max_packages):
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a, b):
        parent[find(a)] = find(b)

    # By folder, in runs of at most MAX_UNITS. Tests go with their unit first.
    folders = defaultdict(list)
    for index, item in enumerate(items):
        if item.tier != "test":
            folders[folder_group(item.key)].append(index)
    for indexes in folders.values():
        for start in range(0, len(indexes), MAX_UNITS):
            run = indexes[start:start + MAX_UNITS]
            for index in run[1:]:
                union(index, run[0])

    by_name = defaultdict(list)
    for index, item in enumerate(items):
        if item.tier != "test":
            by_name[item.key.rsplit("/", 1)[-1]].append(index)
    declared_in_model = {}
    for index, item in enumerate(items):
        if item.key.startswith("model/") and item.key not in HUB_UNITS:
            for name in item.declares:
                declared_in_model.setdefault(name, index)
    alone = []
    for index, item in enumerate(items):
        if item.tier == "test":
            subject = re.sub(r"Tests.*$", "", item.key.rsplit("/", 1)[-1])
            for other in by_name.get(subject, []):
                union(index, other)
            if not by_name.get(subject):
                alone.append(index)
        elif item.key.startswith("view/"):
            for name in sorted(item.references - item.declares):
                if name in declared_in_model:
                    union(index, declared_in_model[name])

    for start in range(0, len(alone), MAX_UNITS):
        run = alone[start:start + MAX_UNITS]
        for index in run[1:]:
            union(index, run[0])

    groups = defaultdict(list)
    for index in range(len(items)):
        groups[find(index)].append(index)
    of_item = {}
    packages = []
    for indexes in groups.values():
        for index in indexes:
            of_item[index] = len(packages)
        packages.append(Package(items=[items[i] for i in indexes]))

    # A unit that uses a symbol another package adds waits for that package.
    edges = defaultdict(set)
    for p_index, provider in enumerate(items):
        for symbol in provider.provides:
            for d_index, dependent in enumerate(items):
                if of_item[d_index] != of_item[p_index] and uses(dependent, symbol):
                    edges[of_item[d_index]].add(of_item[p_index])
    packages = merge_cycles(packages, edges)
    set_waves(packages)
    packages = fewer(packages, max_packages)
    packages.sort(key=lambda p: (p.wave, -len(p.items), p.keys[0]))
    name_packages(packages)
    return packages


def merge_cycles(packages, edges):
    """Packages that wait on each other become one (Tarjan's strongly connected components)."""
    index_of, low, stack, on_stack, components = {}, {}, [], set(), []
    counter = [0]

    def visit(node):
        index_of[node] = low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        on_stack.add(node)
        for nxt in sorted(edges.get(node, ())):
            if nxt not in index_of:
                visit(nxt)
                low[node] = min(low[node], low[nxt])
            elif nxt in on_stack:
                low[node] = min(low[node], index_of[nxt])
        if low[node] == index_of[node]:
            component = []
            while True:
                top = stack.pop()
                on_stack.discard(top)
                component.append(top)
                if top == node:
                    break
            components.append(component)

    for node in range(len(packages)):
        if node not in index_of:
            visit(node)
    component_of = {node: c for c, members in enumerate(components) for node in members}
    merged = [Package(items=[item for node in members for item in packages[node].items]) for members in components]
    for node, targets in edges.items():
        for target in targets:
            if component_of[node] != component_of[target]:
                merged[component_of[node]].after.add(component_of[target])
    return merged


def set_waves(packages):
    waves = {}

    def wave(index):
        if index not in waves:
            waves[index] = 1 + max((wave(dep) for dep in packages[index].after), default=0)
        return waves[index]

    for index, package in enumerate(packages):
        package.wave = wave(index)


def fewer(packages, max_packages):
    """Merges the two smallest packages of the fullest wave until at most max_packages are left."""
    packages = list(packages)
    while len(packages) > max(1, max_packages):
        by_wave = defaultdict(list)
        for index, package in enumerate(packages):
            by_wave[package.wave].append(index)
        fullest = max(by_wave.values(), key=len)
        if len(fullest) < 2:
            break
        a, b = sorted(fullest, key=lambda i: (len(packages[i].items), packages[i].keys[0]))[:2]
        keep, drop = min(a, b), max(a, b)
        packages[keep].items += packages[drop].items
        packages[keep].after |= packages[drop].after
        del packages[drop]
        for index, package in enumerate(packages):
            package.after = {(keep if dep == drop else dep - 1 if dep > drop else dep) for dep in package.after}
            package.after.discard(index)
    return packages


def name_packages(packages):
    for number, package in enumerate(packages, 1):
        counts = defaultdict(int)
        for item in package.items:
            counts[folder_group(item.key)] += 1
        folders = sorted(counts, key=lambda f: (-counts[f], f))[:2]
        slug = re.sub(r"[^a-z0-9-]+", "", "-".join(folders).lower().replace("/", "-"))[:40].strip("-") or "app"
        package.id = f"{number}-{slug}"


# Writing


def do_plan(ctx, to=None, out=None, max_packages=MAX_PACKAGES):
    ledger = ctx.ledger()
    target = ctx.target(to)
    pending = pending_against(ctx, ledger, target)
    note = "" if to else ctx.main_note()
    date = datetime.date.today().isoformat()
    out_dir = os.path.abspath(out or os.path.join(ctx.project_root, "build", "sync", date))
    os.makedirs(out_dir, exist_ok=True)
    for name in os.listdir(out_dir):
        if name.endswith(".md") or name == "plan.json":
            os.remove(os.path.join(out_dir, name))

    items = collect_items(ctx, ledger, pending)
    if items:
        read_items(ctx, items, pending)
    packages = group(items, max_packages) if items else []
    flags = shared_flags(pending.shared)
    coverage = read_coverage(ctx)
    repo_rel = os.path.relpath(ctx.project_root, ctx.repo.root)
    branch = ctx.repo.git("rev-parse", "--abbrev-ref", "HEAD").strip()
    by_index = {index: package for index, package in enumerate(packages)}
    assigned = set()

    plan = {
        "schema": 1,
        "date": date,
        "target": target,
        "target_short": short(target),
        "marker": pending.marker,
        "range": f"{short(pending.marker)}..{short(target)}",
        "branch": branch,
        "project": repo_rel,
        "out_dir": out_dir,
        "main_note": note,
        "pending_units": len(items),
        "packages": [],
        "shared": {"files": [line for line in pending.shared if not line.startswith(" ")], "flags": []},
        "moves_with_marker": sorted(unit.key for unit, _ in pending.skipped + pending.deferred),
    }
    for index, package in by_index.items():
        wording = [f for f in flags if any(f'"{f["key"]}"' in item.source for item in package.items)]
        assigned.update(f["key"] for f in wording)
        tests, instrumented = package_tests(ctx, ledger, package)
        scripts, frames = package_coverage(package, coverage)
        brief = os.path.join(out_dir, f"{package.id}.md")
        after = sorted(by_index[dep].id for dep in package.after)
        with open(brief, "w") as handle:
            handle.write(render_brief(ctx, package, pending, target, after, wording, tests, instrumented, scripts,
                                      frames, repo_rel))
        plan["packages"].append({
            "id": package.id,
            "branch": f"pkg/{package.id}",
            "wave": package.wave,
            "after": after,
            "units": package.keys,
            "views": package.views,
            "brief": brief,
            "android": sorted({os.path.join(repo_rel, p) for item in package.items for p in item.android}),
            "tests": tests,
            "instrumented": instrumented,
            "scripts": scripts,
            "frames": frames,
            "wording": [f["text"] for f in wording] + [w for item in package.items for w in item.wording],
        })
    plan["shared"]["flags"] = [f["text"] for f in flags if f["key"] not in assigned]
    with open(os.path.join(out_dir, "plan.json"), "w") as handle:
        json.dump(plan, handle, indent=1)

    print(f"iOS {short(target)} against the ledger (marker {short(pending.marker)})")
    if note:
        print(f"  {note}")
    if not items:
        if plan["shared"]["files"]:
            print(f"✓ No units pending; {len(plan['shared']['files'])} shared file(s) move with the marker "
                  f"(./build.sh android sync mark --commit --to {short(target)})")
        else:
            print(f"✓ Nothing pending: Android is in sync with iOS {short(target)}")
        print(f"  {os.path.join(out_dir, 'plan.json')}")
        return 0
    print(f"{len(items)} unit(s) in {len(packages)} package(s), {len(plan['shared']['files'])} shared file(s)")
    for entry in plan["packages"]:
        after = f", after {', '.join(entry['after'])}" if entry["after"] else ""
        views = ", views" if entry["views"] else ""
        print(f"  {entry['id']}: wave {entry['wave']}{after}, {len(entry['units'])} unit(s){views}")
    if plan["shared"]["flags"]:
        print(f"  {len(plan['shared']['flags'])} wording flag(s) in shared files, for the lead")
    print(f"  {os.path.join(out_dir, 'plan.json')}")
    return 0


def shared_flags(lines):
    flags = []
    current = None
    for line in lines:
        if not line.startswith(" "):
            current = line.split(" ", 1)[-1]
            continue
        text = line.strip()
        flags.append({"file": current, "key": text.split(" ", 1)[0], "text": f"{current}: {text}"})
    return flags


def read_coverage(ctx):
    path = os.path.join(ctx.project_root, ctx.config.ledger_dir, "coverage.json")
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def package_coverage(package, coverage):
    scripts, frames = set(), set()
    for item in package.items:
        scripts.update(item.scripts)
        frames.update(item.frames)
        if item.tier == "script":
            scripts.add(item.key.rsplit("/", 1)[-1])
        entry = (coverage or {}).get(item.key, {})
        scripts.update(entry.get("scripts", []))
        frames.update(entry.get("frames", []))
    return sorted(scripts), sorted(frames)


def package_tests(ctx, ledger, package):
    """Android test classes for the package: its own test units and the tests named after its units."""
    paths = set()
    names = {item.key.rsplit("/", 1)[-1] for item in package.items if item.tier != "test"}
    for item in package.items:
        if item.tier == "test":
            paths.update(item.android)
    for key, unit in ledger.units.items():
        if key.startswith("tests/") and re.sub(r"Tests.*$", "", key.rsplit("/", 1)[-1]) in names:
            paths.update(unit.android)
    tests, instrumented = set(), set()
    root = ctx.config.android_instrumented_tests
    for path in sorted(paths):
        try:
            with open(os.path.join(ctx.project_root, path)) as handle:
                text = handle.read()
        except OSError:
            continue
        names = TEST_CLASS.findall(text) or [os.path.basename(path)[:-3]]
        (instrumented if root and path.startswith(root) else tests).update(names)
    return sorted(tests), sorted(instrumented)


def render_brief(ctx, package, pending, target, after, wording, tests, instrumented, scripts, frames, repo_rel):
    t = short(target)
    since = sorted({short(item.since) for item in package.items})
    ranges = ", ".join(f"{s}..{t}" for s in since)
    lines = [f"# Sync package {package.id}", ""]
    lines.append(f"iOS {ranges}. Branch `pkg/{package.id}`. Wave {package.wave}"
                 + (f", after {', '.join(after)} is merged." if after else "."))
    lines.append(f"{len(package.items)} unit(s)." + (" It changes views, so a reviewer looks at it after you." if package.views else ""))
    lines += ["", "## Units", "", "| Unit | Change | Ledger | iOS | Android |", "|---|---|---|---|---|"]
    for item in package.items:
        android = "<br>".join(item.android) or "none yet"
        lines.append(f"| `{item.key}` | {item.kind} | {item.status} | {'<br>'.join(item.diff_paths)} | {android} |")

    keys = " ".join(package.keys)
    ledger_paths = " ".join(os.path.join(repo_rel, ctx.config.ledger_dir, key + ".toml") for key in package.keys)
    test_cmd = f"`./build.sh android test {','.join(tests)}`" if tests else "`./build.sh android test` (no test class is named after these units)"
    lines += ["", "## Steps", "",
              "1. Work where the sync workflow put you: the package worktree on "
              f"`pkg/{package.id}` (`./build.sh android worktree new {package.id}` prints its path), or the main "
              "checkout when one agent does the whole sync. Run every command from that checkout's root.",
              "2. Read the commits, then the diffs below. `./build.sh android sync diff <unit> --to " + t + "` prints a whole diff.",
              f"3. Port the current iOS state of each unit at `{t}` (`git show {t}:<path>`), not the commits in between. "
              "Follow `doc/android/platform-mapping.md`. A unit deleted on iOS: delete its Kotlin files, or give "
              "them an `[[android_only]]` reason in `android/parity.toml`.",
              f"4. `./build.sh android build`, then {test_cmd}"
              + (f", `./build.sh android test instrumented {','.join(instrumented)}`" if instrumented else "")
              + ", then `./build.sh android lint`. The parity gate in lint must pass."]
    step = 5
    if package.views:
        lines.append(f"{step}. Views: run the scripts under Coverage on both platforms, "
                     "`./build.sh android compare <scripts> --fixture`, and look at the frames side by side.")
        step += 1
    lines += [f"{step}. Mark: `./build.sh android sync mark {keys} --to {t}`. A unit whose Android code needs no "
              "change: `--no-change \"<reason>\"`. `mark` refuses a unit that fails the parity check.",
              f"{step + 1}. Commit only this package's paths: the Android files above and `{ledger_paths}`, with "
              "`git commit -m \"...\" -- <paths>`. The subject says what changed for the person using the app; the "
              f"body names the iOS range ({ranges}). Never `git add -A`.",
              f"{step + 2}. Don't write app text or `_android` variants, and don't move the marker. List wording "
              "that needs an Android variant and any platform choice the iOS code doesn't answer in your report."]

    lines += ["", "## Commits", ""]
    seen = set()
    for item in package.items:
        if not item.since:
            continue
        out = ctx.repo.git("log", "--format=%h%x1f%s%x1f%b%x1e", f"{item.since}..{target}", "--", *item.diff_paths)
        for record in out.split("\x1e"):
            parts = record.strip("\n").split("\x1f")
            if len(parts) < 2 or parts[0] in seen:
                continue
            seen.add(parts[0])
            lines.append(f"- {parts[0]} {parts[1]}")
            body = [b for b in (parts[2] if len(parts) > 2 else "").strip().splitlines() if b.strip()]
            lines += [f"  {b}" for b in body if not b.startswith(("Co-Authored-By:", "Claude-Session:"))]
    if not seen:
        lines.append("None found.")

    lines += ["", "## Symbols", ""]
    noted = [(item.key, note) for item in package.items for note in item.notes]
    lines += [f"- `{key}` {note}" for key, note in noted] or ["No symbol changes (bodies only, or files the extractor doesn't read)."]

    interaction = [(item.key, item.interaction) for item in package.items if item.interaction]
    if interaction:
        lines += ["", "## Interaction", "", "Each needs a scripted `ui` step or a note.", ""]
        lines += [f"- `{key}`: {', '.join(apis)}" for key, apis in interaction]

    in_diff = [(item.key, w) for item in package.items for w in item.wording]
    if wording or in_diff:
        lines += ["", "## Wording", "", "For the lead and the owner; don't change strings yourself.", ""]
        lines += [f"- {f['text']}" for f in wording]
        lines += [f"- `{key}` adds {w}" for key, w in in_diff]

    lines += ["", "## Coverage", ""]
    if scripts or frames:
        if scripts:
            lines.append(f"Scripts: {', '.join(f'`{s}`' for s in scripts)}.")
        if frames:
            lines.append(f"Frames: {', '.join(f'`{f}`' for f in frames)}.")
    else:
        lines.append("No script is known to show these units (`sync/coverage.json` has none). A view unit with no "
                     "script needs a frame from a new script step, or a note in your report.")

    lines += ["", "## Diffs", ""]
    for item in package.items:
        diff = item.diff.splitlines()
        lines += [f"### {item.key}", ""]
        if not diff:
            lines += ["No diff.", ""]
            continue
        lines += ["```diff", *diff[:DIFF_LINES], "```"]
        if len(diff) > DIFF_LINES:
            lines.append(f"{len(diff) - DIFF_LINES} more lines: `./build.sh android sync diff {item.key} --to {t}`.")
        lines.append("")
    return "\n".join(lines) + "\n"
