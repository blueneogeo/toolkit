"""The sync commands: map and gate, status, diff, mark, init, coverage, and the iOS build hook's extraction."""

import datetime
import json
import os
import re
import tomllib
from collections import Counter, defaultdict
from dataclasses import dataclass

from parity_extract import ParityError, Tools, hash_files
from parity_ledger import Ledger, Unit
from parity_map import Comparer
from parity_symbols import ios_symbols

INTERACTION_APIS = re.compile(
    r"\b(onTapGesture|onLongPressGesture|contentShape|ButtonStyle|buttonStyle|allowsHitTesting|disabled|"
    r"contextMenu|Menu|DragGesture|LongPressGesture|MagnifyGesture|TapGesture|simultaneousGesture|"
    r"highPriorityGesture|gesture|swipeActions|onSubmit|focused|sensoryFeedback)\b"
)
IOS_ONLY_WORDING = re.compile(r"Face ID|Touch ID|iCloud|Settings →|App Store|iPhone|iOS\b|Apple ID|AirDrop")


@dataclass
class Context:
    config: object
    repo: object
    tools: Tools

    @property
    def project_root(self):
        return self.config.project_root

    def ledger(self):
        return Ledger(self.project_root, self.config.ledger_dir).load()

    def default_target(self):
        for name in ("main", "HEAD"):
            try:
                return self.repo.resolve(name)
            except ParityError:
                continue
        raise ParityError("Turn's repository has no main branch")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def short(commit):
    return commit[:8] if commit else "?"


# Units


def units_at(ctx, commit):
    """{unit key: {ios path: blob}} for every iOS file at a commit."""
    files = ctx.repo.ls_tree(commit, ctx.config.ios_roots)
    units = defaultdict(dict)
    for path, blob in files.items():
        key = ctx.config.ios_unit(path)
        if key:
            units[key][path] = blob
    return dict(units)


def android_paths_for(config, ios_paths):
    paths = []
    for ios_path in sorted(ios_paths):
        for path in config.android_paths(ios_path):
            if path not in paths:
                paths.append(path)
    return paths


def default_status(config, ios_paths, android_present):
    for path in ios_paths:
        if config.ios_only_file(path):
            return "ios-only"
        if config.deferred_file(path):
            return "deferred"
    return "stub" if android_present else "todo"


def all_android_sources(config):
    roots = [config.android_root, config.android_debug_tools, config.android_debug, config.android_tests]
    paths = []
    for root in roots:
        if not root:
            continue
        base = os.path.join(config.project_root, root)
        for directory, _, files in os.walk(base):
            for name in files:
                if name.endswith(".kt"):
                    paths.append(os.path.relpath(os.path.join(directory, name), config.project_root))
    return sorted(set(paths))


def shared_files(ctx, commit):
    if not ctx.config.shared:
        return {}
    return ctx.repo.ls_tree(commit, ctx.config.shared)


# Map and gate


def build_map(ctx, unit_specs, extra_android=None):
    """unit_specs: list of (key, status, {ios path: blob}). Returns (results, extras)."""
    config = ctx.config
    swift = {p: b for _, _, ios in unit_specs for p, b in ios.items() if p.endswith(".swift")}
    ios_files = ctx.tools.extract_ios(ctx.repo, swift)
    contents = ctx.repo.cat_blobs(set(swift.values()))
    ios_sources = {p: contents[b].decode("utf-8", errors="replace") for p, b in swift.items()}
    android_hashes = hash_files(config.project_root, all_android_sources(config) + list(extra_android or []))
    android_files = ctx.tools.extract_android(android_hashes)
    actual = {p.lower(): p for p in android_hashes}
    specs = [(key, status, sorted(ios), [actual.get(p.lower(), p) for p in android_paths_for(config, ios)])
             for key, status, ios in unit_specs]
    return Comparer(config, ios_sources).compare(specs, ios_files, android_files)


def ledger_specs(ctx, ledger, only=None):
    specs = []
    for key, unit in sorted(ledger.units.items()):
        if only and key not in only:
            continue
        specs.append((key, unit.status, dict(unit.ios)))
    return specs


def do_map(ctx, gate=False, at=None, only_unit=None):
    ledger = ctx.ledger()
    if at:
        commit = ctx.repo.resolve(at)
        specs = []
        for key, ios in sorted(units_at(ctx, commit).items()):
            existing = ledger.units.get(key)
            present = any(os.path.exists(os.path.join(ctx.project_root, p)) for p in android_paths_for(ctx.config, ios))
            status = existing.status if existing else default_status(ctx.config, ios, present)
            specs.append((key, status, ios))
        label = f"iOS {short(commit)}"
    else:
        if not ledger.units:
            raise ParityError("No ledger under sync/. Run ./build.sh sync init --at <commit> first, or pass --at.")
        specs = ledger_specs(ctx, ledger)
        label = "the ledger's iOS blobs"
    if only_unit:
        unit = ledger.unit_for(only_unit, ctx.config)
        key = unit.key if unit else only_unit
        specs = [s for s in specs if s[0] == key]
        if not specs:
            raise ParityError(f"No unit '{only_unit}'")
    results, extras = build_map(ctx, specs)
    write_map(ctx, results, extras, label)
    return report_map(ctx, results, extras, label, gate)


def write_map(ctx, results, extras, label):
    out_dir = os.path.join(ctx.project_root, "build", "parity")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for result in results:
        for row in result.rows:
            rows.append(row_json(row))
    for row in extras:
        rows.append(row_json(row))
    with open(os.path.join(out_dir, "map.json"), "w") as handle:
        json.dump({"schema": 1, "against": label, "rows": rows}, handle, indent=1)
    lines = [f"# Parity map against {label}", "", "| Unit | Tier | Ledger | Matching | Not matching |", "|---|---|---|---|---|"]
    for result in results:
        counts = Counter(r.status for r in result.rows)
        bad = sum(v for k, v in counts.items() if k not in ("matching", "ios_only", "deferred"))
        lines.append(f"| {result.key} | {result.tier} | {result.ledger_status} | {counts.get('matching', 0)} | {bad} |")
    lines += ["", "## Rows that don't match", ""]
    for result in results:
        for row in result.rows:
            if row.status not in ("matching", "ios_only", "deferred"):
                lines.append("- " + describe(row))
    for row in extras:
        lines.append("- " + describe(row))
    with open(os.path.join(out_dir, "map.md"), "w") as handle:
        handle.write("\n".join(lines) + "\n")


def row_json(row):
    def sym(s):
        if s is None:
            return None
        return {"kind": s.kind, "owner": s.owner, "name": s.name, "path": s.path, "line": s.line, "key": s.key}
    return {"unit": row.unit, "tier": row.tier, "status": row.status, "ios": sym(row.ios), "android": sym(row.android),
            "detail": row.detail, "failing": row.failing}


def describe(row):
    if row.ios is not None:
        where = f"{row.ios.path}:{row.ios.line}"
        text = f"{row.status}: {row.ios.kind} {row.ios.display} ({where})"
    elif row.android is not None:
        text = f"{row.status}: {row.android.kind} {row.android.display} ({row.android.path}:{row.android.line})"
    else:
        text = f"{row.status}: {row.unit}"
    if row.detail:
        text += f", {row.detail}"
    return text


def report_map(ctx, results, extras, label, gate):
    counts = Counter()
    for result in results:
        for row in result.rows:
            counts[(row.tier, row.status)] += 1
    failing = [row for result in results for row in result.rows if row.failing] + [row for row in extras if row.failing]
    warnings = [row for result in results for row in result.rows if row.status == "signature_drift"]
    pending_misses = [row for result in results for row in result.rows
                      if row.status == "missing_on_android" and not row.failing]
    for tier in ("strict", "component", "other"):
        parts = [f"{counts[(tier, s)]} {s.replace('_', ' ')}" for s in
                 ("matching", "signature_drift", "missing_on_android", "misnamed", "moved", "ios_only", "deferred")
                 if counts[(tier, s)]]
        if parts:
            print(f"  {tier}: " + ", ".join(parts))
    extra_count = len(extras)
    if extra_count:
        print(f"  android only: {extra_count} ({sum(1 for r in extras if r.failing)} without a reason)")
    print(f"  map: {os.path.join(ctx.project_root, 'build', 'parity', 'map.md')}")
    guide_errors = []
    if gate:
        import parity_guide
        guide_errors = parity_guide.check(ctx, results)
    if failing or guide_errors:
        for row in failing[:60]:
            print("✗ " + describe(row))
        if len(failing) > 60:
            print(f"✗ ... and {len(failing) - 60} more in build/parity/map.md")
        for error in guide_errors:
            print("✗ " + error)
        print(f"✗ Parity gate failed against {label}: {len(failing) + len(guide_errors)} error(s)")
        return 1 if gate else 0
    note = f", {len(warnings)} signature drift warning(s)" if warnings else ""
    if pending_misses:
        note += f", {len(pending_misses)} not ported yet"
    print(f"✓ Parity passed against {label}{note}")
    return 0


# init


def do_init(ctx, at, force=False):
    ledger = ctx.ledger()
    if ledger.units and not force:
        raise ParityError(f"The ledger already has {len(ledger.units)} units. Pass --force to write it again.")
    commit = ctx.repo.resolve(at)
    stamp = now()
    units = units_at(ctx, commit)
    if force:
        for key in list(ledger.units):
            ledger.remove_unit(key)
    counts = Counter()
    for key, ios in sorted(units.items()):
        android = android_paths_for(ctx.config, ios)
        hashes = hash_files(ctx.project_root, android)
        status = default_status(ctx.config, ios, bool(hashes))
        note = ""
        if status == "ios-only":
            note = next(ctx.config.ios_only_file(p) for p in ios if ctx.config.ios_only_file(p))
        unit = Unit(key=key, status=status, ios_commit=commit, marked_at=stamp, note=note, ios=dict(ios), android=hashes)
        ledger.write_unit(unit)
        counts[status] += 1
    ledger.marker.ios_commit = commit
    ledger.marker.synced_at = stamp
    ledger.marker.shared = shared_files(ctx, commit)
    ledger.write_marker()
    summary = ", ".join(f"{n} {s}" for s, n in sorted(counts.items()))
    print(f"✓ Ledger written at iOS {short(commit)}: {len(units)} units ({summary})")
    return 0


# status


def symbol_table(entry):
    if not entry:
        return {}
    return {s.ident: s for s in ios_symbols(entry)
            if s.kind not in ("script", "test") and (s.kind != "view" or s.detail == "ViewExtension")}


def do_status(ctx, to=None, verbose=False):
    ledger = ctx.ledger()
    if not ledger.units:
        raise ParityError("No ledger under sync/. Run ./build.sh sync init --at <commit> first.")
    target = ctx.repo.resolve(to) if to else ctx.default_target()
    marker = ledger.marker.ios_commit or next(iter(ledger.units.values())).ios_commit
    target_files = ctx.repo.ls_tree(target, ctx.config.ios_roots)
    print(f"iOS {short(target)} against the ledger (marker {short(marker)})")

    renames = {}
    if marker and marker != target:
        out = ctx.repo.git("diff", "-M", "--name-status", marker, target, "--", *ctx.config.ios_roots)
        for line in out.splitlines():
            parts = line.split("\t")
            if parts[0].startswith("R") and len(parts) == 3:
                renames[parts[1]] = (parts[2], int(parts[0][1:] or 100))
    by_old_blob = defaultdict(list)
    for path, blob in target_files.items():
        by_old_blob[blob].append(path)

    known = set()
    changed, renamed, deleted, skipped, deferred, edited = [], [], [], [], [], []
    android_now = hash_files(ctx.project_root, sorted({p for unit in ledger.units.values() for p in unit.android}))
    for key, unit in sorted(ledger.units.items()):
        known.update(unit.ios)
        unit_changes = []
        for path, blob in sorted(unit.ios.items()):
            if path in target_files:
                if target_files[path] != blob:
                    unit_changes.append(("changed", path, path, blob, target_files[path]))
            elif path in renames and renames[path][0] in target_files:
                new = renames[path][0]
                unit_changes.append((f"renamed R{renames[path][1]}", path, new, blob, target_files[new]))
                known.add(new)
            elif blob in by_old_blob and not any(p in unit.ios for p in by_old_blob[blob]):
                new = by_old_blob[blob][0]
                unit_changes.append(("renamed R100", path, new, blob, blob))
                known.add(new)
            else:
                unit_changes.append(("deleted", path, None, blob, None))
        android_edited = any(android_now.get(p) != b for p, b in unit.android.items() if b)
        if not unit_changes:
            if android_edited and unit.status in ("ported", "partial", "stub"):
                edited.append(unit)
            continue
        if unit.status == "ios-only":
            skipped.append((unit, unit_changes))
        elif unit.status == "deferred":
            deferred.append((unit, unit_changes))
        elif all(c[0] == "deleted" for c in unit_changes):
            deleted.append((unit, unit_changes))
        elif any(c[0].startswith("renamed") for c in unit_changes):
            renamed.append((unit, unit_changes))
        else:
            changed.append((unit, unit_changes))

    added = sorted(p for p in target_files if p not in known and ctx.config.ios_unit(p))
    added_units = defaultdict(list)
    for path in added:
        added_units[ctx.config.ios_unit(path)].append(path)

    shared_changes = shared_status(ctx, ledger, target)
    moves = symbol_moves(ctx, changed + renamed, deleted, added_units, target_files)

    pending = 0
    if shared_changes:
        print("\nShared")
        for line in shared_changes:
            print("  " + line)
        pending += len(shared_changes)
    for title, items in (("Changed", changed), ("Renamed", renamed), ("Deleted on iOS", deleted)):
        if not items:
            continue
        print(f"\n{title}")
        for unit, unit_changes in sorted(items, key=lambda item: order_key(ctx, item[0].key)):
            pending += 1
            print_unit(ctx, unit, unit_changes, target, moves, verbose)
    if added_units:
        print("\nNew on iOS")
        for key, paths in sorted(added_units.items(), key=lambda item: order_key(ctx, item[0])):
            pending += 1
            android = android_paths_for(ctx.config, paths)
            arrow = f" -> {', '.join(android)}" if android else ""
            print(f"  new {', '.join(paths)}{arrow}")
            for path in paths:
                for line in commit_messages(ctx, [path], marker, target)[:5]:
                    print(f"      {line}")
            for text in moves.get(key, []):
                print(f"      {text}")
    for unit, unit_changes in skipped:
        print(f"  skipped (iOS-only: {unit.note or 'parity.toml'}) {unit.key}")
    for unit, unit_changes in deferred:
        print(f"  deferred, changed {unit.key}")
    if edited:
        print("\nEdited on Android after the last mark (fine; mark again when done)")
        for unit in edited:
            print(f"  {unit.key}")

    if pending == 0:
        print(f"\n✓ Nothing pending: Android is in sync with iOS {short(target)}")
        return 0
    print(f"\n{pending} unit(s) pending against iOS {short(target)}")
    return 1


def order_key(ctx, key):
    if key.startswith("model/AppState") or key.endswith("State"):
        rank = 2
    elif key.startswith("model/"):
        rank = 0
    elif key.startswith("service/"):
        rank = 1
    elif key.startswith("view/"):
        rank = 3
    elif key.startswith("tests/"):
        rank = 4
    elif key.startswith("debug/"):
        rank = 5
    else:
        rank = 3
    return (rank, key)


def print_unit(ctx, unit, unit_changes, target, moves, verbose):
    android = ", ".join(unit.android) or "(no Android files yet)"
    status = "" if unit.status in ("ported",) else f" [{unit.status}]"
    print(f"  {unit_changes[0][0].split()[0]} {unit.key}{status} -> {android}")
    for kind, old, new, old_blob, new_blob in unit_changes:
        if kind.startswith("renamed"):
            mirror = ctx.config.android_paths(new)
            if mirror and mirror != sorted(unit.android):
                print(f"      the Kotlin file moves to {', '.join(mirror)}; mark {ctx.config.ios_unit(new)} when done")
    paths = []
    for kind, old, new, old_blob, new_blob in unit_changes:
        label = f"{old} -> {new}" if new and new != old else old
        stat = ""
        if old_blob and new_blob and old_blob != new_blob:
            stat = ctx.repo.git("diff", "--shortstat", old_blob, new_blob).strip()
            stat = f" ({stat})" if stat else ""
        print(f"      {kind} {label}{stat}")
        paths += [p for p in (old, new) if p]
    since = unit.ios_commit
    for line in commit_messages(ctx, sorted(set(paths)), since, target)[:12]:
        print(f"      {line}")
    for text in moves.get(unit.key, []):
        print(f"      {text}")
    for kind, old, new, old_blob, new_blob in unit_changes:
        if old_blob and new_blob and old_blob != new_blob:
            diff = ctx.repo.git("diff", "-U0", old_blob, new_blob)
            apis = sorted({m.group(1) for line in diff.splitlines() if line[:1] in "+-" and not line.startswith(("+++", "---"))
                           for m in INTERACTION_APIS.finditer(line)})
            if apis:
                print(f"      interaction in the diff: {', '.join(apis)} (each needs a scripted ui step or a note)")
            if verbose:
                for line in diff.splitlines():
                    print(f"        {line}")


def commit_messages(ctx, paths, since, target):
    if not since or since == target:
        return []
    out = ctx.repo.git("log", "--format=%h %s", f"{since}...{target}", "--", *paths)
    return out.splitlines()


def symbol_moves(ctx, changed, deleted, added_units, target_files):
    """Per unit: symbols added, removed, changed, and moved to or from another unit."""
    before, after = {}, {}
    for unit, unit_changes in changed + deleted:
        for kind, old, new, old_blob, new_blob in unit_changes:
            if old.endswith(".swift"):
                before.setdefault(unit.key, {})[old] = old_blob
            if new and new.endswith(".swift") and new_blob:
                after.setdefault(unit.key, {})[new] = new_blob
    for key, paths in added_units.items():
        for path in paths:
            if path.endswith(".swift"):
                after.setdefault(key, {})[path] = target_files[path]
    wanted = {}
    for table in (before, after):
        for files in table.values():
            for path, blob in files.items():
                wanted[f"{blob}:{path}"] = blob
    if not wanted:
        return {}
    extracted = ctx.tools.extract_ios(ctx.repo, wanted)

    def symbols(table):
        out = {}
        for key, files in table.items():
            merged = {}
            for path, blob in files.items():
                entry = extracted.get(f"{blob}:{path}")
                if entry:
                    entry = dict(entry, path=path)
                merged.update(symbol_table(entry))
            out[key] = merged
        return out

    old_symbols, new_symbols = symbols(before), symbols(after)
    removed_where = {}
    for key, table in old_symbols.items():
        for ident in table:
            if ident not in new_symbols.get(key, {}):
                removed_where.setdefault(ident, key)
    added_where = {}
    for key, table in new_symbols.items():
        for ident in table:
            if ident not in old_symbols.get(key, {}):
                added_where.setdefault(ident, key)
    notes = defaultdict(list)
    for key in sorted(set(old_symbols) | set(new_symbols)):
        old, new = old_symbols.get(key, {}), new_symbols.get(key, {})
        added = [i for i in new if i not in old]
        removed = [i for i in old if i not in new]
        modified = [i for i in new if i in old and new[i].kind != "type" and new[i].hash and new[i].hash != old[i].hash]
        moved_in = [i for i in added if removed_where.get(i) not in (None, key)]
        moved_out = [i for i in removed if added_where.get(i) not in (None, key)]
        added = [i for i in added if i not in moved_in]
        removed = [i for i in removed if i not in moved_out]
        if added:
            notes[key].append("added: " + ", ".join(new[i].display for i in added[:20]) + (" ..." if len(added) > 20 else ""))
        if removed:
            notes[key].append("removed: " + ", ".join(old[i].display for i in removed[:20]) + (" ..." if len(removed) > 20 else ""))
        if modified:
            notes[key].append("changed: " + ", ".join(new[i].display for i in modified[:20]) + (" ..." if len(modified) > 20 else ""))
        for ident in moved_in:
            notes[key].append(f"moved here from {removed_where[ident]}: {new[ident].display} (move the Kotlin body)")
        for ident in moved_out:
            notes[key].append(f"moved to {added_where[ident]}: {old[ident].display} (move the Kotlin body)")
    return notes


def shared_status(ctx, ledger, target):
    current = shared_files(ctx, target)
    lines = []
    for path, blob in sorted(current.items()):
        old = ledger.marker.shared.get(path)
        if old == blob:
            continue
        lines.append(f"{'changed' if old else 'new'} {path}")
        if path.endswith(".toml"):
            lines += [f"    {flag}" for flag in wording_flags(ctx, old, blob)]
    for path in sorted(set(ledger.marker.shared) - set(current)):
        lines.append(f"deleted {path}")
    return lines


def wording_flags(ctx, old_blob, new_blob):
    contents = ctx.repo.cat_blobs([b for b in (old_blob, new_blob) if b])
    old = flatten(tomllib.loads(contents[old_blob].decode())) if old_blob else {}
    new = flatten(tomllib.loads(contents[new_blob].decode()))
    flags = []
    for key, value in sorted(new.items()):
        if old.get(key) == value or key.endswith("_android"):
            continue
        if f"{key}_android" in new:
            flags.append(f"{key} changed and has an Android variant {key}_android: check it")
        elif isinstance(value, str) and IOS_ONLY_WORDING.search(value):
            flags.append(f"{key} has iOS-only wording ('{value}'): add {key}_android")
    return flags


def flatten(data, prefix=""):
    out = {}
    for key, value in data.items():
        name = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            out.update(flatten(value, name))
        else:
            out[name] = value
    return out


# diff


def do_diff(ctx, name, to=None):
    ledger = ctx.ledger()
    unit = ledger.unit_for(name, ctx.config)
    if unit is None:
        raise ParityError(f"No unit '{name}' in the ledger")
    target = ctx.repo.resolve(to) if to else ctx.default_target()
    print(ctx.repo.git("diff", "-M", unit.ios_commit, target, "--", *sorted(unit.ios)), end="")
    return 0


# mark


def do_mark(ctx, names, to=None, status=None, no_change=None):
    ledger = ctx.ledger()
    target = ctx.repo.resolve(to) if to else ctx.default_target()
    current = units_at(ctx, target)
    refused = 0
    for name in names:
        unit = ledger.unit_for(name, ctx.config)
        key = unit.key if unit else ctx.config.ios_unit(name) or name
        if key not in current:
            if unit is None:
                print(f"✗ {name}: no such unit at iOS {short(target)}")
                refused += 1
            elif any(os.path.exists(os.path.join(ctx.project_root, p)) for p in unit.android):
                print(f"✗ {key}: deleted on iOS, but {', '.join(unit.android)} still exist. Delete them, or give them "
                      "an [[android_only]] reason in parity.toml.")
                refused += 1
            else:
                ledger.remove_unit(key)
                print(f"✓ {key} removed: deleted on iOS {short(target)}")
            continue
        ios_now = current[key]
        old_keys = [k for k in renamed_from(ctx, ledger, ios_now, current, target) if k != key]
        previous = unit or (ledger.units[old_keys[0]] if old_keys else None)
        android = android_paths_for(ctx.config, ios_now)
        if unit:
            android = sorted(set(android) | set(unit.android))
        android_now = hash_files(ctx.project_root, android)
        if not android_now and previous and previous.status in ("stub", "partial", "ported") and status not in ("todo", "ios-only", "deferred"):
            print(f"✗ {key}: no Android file at {', '.join(android) or '(no mirror path)'}; it was {previous.status} as "
                  f"{previous.key}. Move or create the Kotlin file first.")
            refused += 1
            continue
        ios_changed = unit is None or unit.ios != ios_now
        android_changed = unit is None or {p: b for p, b in unit.android.items() if b} != android_now
        new_status = status or default_mark_status(ctx, unit, android_now)
        if ios_changed and not android_changed and not no_change and unit is not None and unit.status not in ("ios-only", "deferred"):
            print(f"✗ {key}: iOS changed since {short(unit.ios_commit)} but its Android files did not. "
                  "Port the change, or pass --no-change \"<reason>\".")
            refused += 1
            continue
        if new_status in ("ported", "partial", "stub"):
            results, _ = build_map(ctx, [(key, new_status, ios_now)])
            failing = [row for result in results for row in result.rows if row.failing]
            if failing:
                for row in failing[:20]:
                    print("✗ " + describe(row))
                print(f"✗ {key}: the parity check fails at iOS {short(target)}; not marked")
                refused += 1
                continue
        note = unit.note if unit else ""
        if no_change:
            note = f"no Android change for iOS {short(target)}: {no_change}"
        for old_key in old_keys:
            ledger.remove_unit(old_key)
            print(f"  {old_key} is now {key}")
        ledger.write_unit(Unit(key=key, status=new_status, ios_commit=target, marked_at=now(), note=note, ios=dict(ios_now),
                               android=android_now, scripts=unit.scripts if unit else [], frames=unit.frames if unit else []))
        print(f"✓ {key} marked {new_status} from iOS {short(target)}")
    return 1 if refused else 0


def renamed_from(ctx, ledger, ios_now, current, target):
    """Ledger units whose iOS files were renamed into these paths."""
    old_paths = {}
    for key, unit in ledger.units.items():
        if key in current:
            continue
        for path, blob in unit.ios.items():
            old_paths[path] = (key, blob)
    if not old_paths:
        return []
    found = set()
    commits = {ledger.units[key].ios_commit for key, _ in old_paths.values()}
    for commit in commits:
        out = ctx.repo.git("diff", "-M", "--name-status", commit, target, "--", *ctx.config.ios_roots)
        for line in out.splitlines():
            parts = line.split("\t")
            if parts[0].startswith("R") and len(parts) == 3 and parts[2] in ios_now and parts[1] in old_paths:
                found.add(old_paths[parts[1]][0])
    for path, (key, blob) in old_paths.items():
        if blob in ios_now.values():
            found.add(key)
    return sorted(found)


STUB_MARKER = b'TODO("port:'


def default_mark_status(ctx, unit, android_now):
    """ported once no stub marker is left in the unit's Android files; stub or partial before that."""
    if unit and unit.status in ("ios-only", "deferred"):
        return unit.status
    if not android_now:
        return "todo"
    for path in android_now:
        with open(os.path.join(ctx.project_root, path), "rb") as handle:
            if STUB_MARKER in handle.read():
                return "stub" if unit is None or unit.status in ("stub", "todo") else "partial"
    return "ported"


def do_mark_commit(ctx, to=None):
    ledger = ctx.ledger()
    target = ctx.repo.resolve(to) if to else ctx.default_target()
    current = units_at(ctx, target)
    pending = []
    for key, ios in current.items():
        unit = ledger.units.get(key)
        if unit is None:
            pending.append(f"new {key}")
        elif unit.ios != ios and unit.status not in ("ios-only", "deferred"):
            pending.append(f"changed {key}")
    for key, unit in ledger.units.items():
        if key not in current and unit.status not in ("ios-only", "deferred"):
            pending.append(f"deleted {key}")
    if pending:
        for line in sorted(pending)[:40]:
            print(f"✗ {line}")
        print(f"✗ {len(pending)} unit(s) still pending against iOS {short(target)}; the marker stays at "
              f"{short(ledger.marker.ios_commit)}")
        return 1
    for key, unit in ledger.units.items():
        if unit.status in ("ios-only", "deferred") and key in current and unit.ios != current[key]:
            unit.ios = dict(current[key])
            unit.ios_commit = target
            ledger.write_unit(unit)
    ledger.marker.ios_commit = target
    ledger.marker.synced_at = now()
    ledger.marker.shared = shared_files(ctx, target)
    ledger.write_marker()
    print(f"✓ Marker moved to iOS {short(target)}")
    return 0


# coverage


COVERAGE_LINE = re.compile(r"\[coverage\]\s+script=(\S+)\s+frame=(\S+)\s+views=(\S*)")


def do_coverage(ctx, log):
    """Reads '[coverage] script=<name> frame=<frame> views=<A,B>' log lines into sync/coverage.json."""
    if log in (None, "-"):
        import sys
        text = sys.stdin.read()
    else:
        with open(log) as handle:
            text = handle.read()
    shown = defaultdict(lambda: {"scripts": set(), "frames": set()})
    for match in COVERAGE_LINE.finditer(text):
        script, frame, views = match.groups()
        for view in filter(None, views.split(",")):
            shown[view]["scripts"].add(script)
            if frame != "-":
                shown[view]["frames"].add(frame)
    ledger = ctx.ledger()
    view_units = {}
    for key, unit in ledger.units.items():
        if unit.status in ("ios-only", "deferred"):
            continue
        for path in unit.ios:
            if ctx.config.tier(path) == "component":
                view_units[key] = unit
    extracted = ctx.tools.extract_ios(ctx.repo, {p: b for u in view_units.values() for p, b in u.ios.items() if p.endswith(".swift")})
    coverage = {}
    uncovered = []
    for key, unit in sorted(view_units.items()):
        names = [s.name for p in unit.ios for s in ios_symbols(extracted.get(p, {"path": p})) if s.kind == "view"]
        scripts = sorted({s for n in names for s in shown.get(n, {}).get("scripts", ())})
        frames = sorted({f for n in names for f in shown.get(n, {}).get("frames", ())})
        coverage[key] = {"views": names, "scripts": scripts, "frames": frames}
        if names and not scripts:
            uncovered.append(key)
    path = os.path.join(ctx.project_root, ctx.config.ledger_dir, "coverage.json")
    with open(path, "w") as handle:
        json.dump(coverage, handle, indent=1, sort_keys=True)
    with_views = sum(1 for entry in coverage.values() if entry["views"])
    print(f"✓ {with_views - len(uncovered)} of {with_views} view units shown by a script; written to {path}")
    for key in uncovered:
        print(f"⚠ no script shows {key}")
    return 0


# The iOS build hook


def extract_ios_tree(root, out, guide_path, project=None):
    import parity_config
    import parity_guide
    tools = Tools(os.environ.get("PROJECT_ROOT") or root, quiet=True)
    config = None
    if project and os.path.exists(os.path.join(project, "parity.toml")):
        config = parity_config.load(project, root)
    sources = []
    for base in ("ios/Turn", "ios/debug", "ios/TurnTests"):
        for directory, _, files in os.walk(os.path.join(root, base)):
            sources += [os.path.relpath(os.path.join(directory, f), root) for f in files if f.endswith(".swift")]
    files = tools.extract_ios_tree(root, sorted(sources))
    out = out or os.path.join(root, "ios", "build", "parity", "ios.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as handle:
        json.dump({"schema": 1, "platform": "ios", "files": list(files.values())}, handle)
    symbols = [s for entry in files.values() for s in ios_symbols(entry)]
    handlers = sum(1 for s in symbols if s.kind == "function" and s.owner == "AppState" and re.match(r"on[A-Z]", s.name))
    views = sum(1 for s in symbols if s.kind == "view")
    print(f"Parity: {len(files)} Swift files, {handlers} handlers, {views} views -> {os.path.relpath(out, root)}")
    if guide_path and os.path.exists(guide_path):
        ported = [entry for path, entry in files.items() if config is None or not config.ios_only_file(path)]
        for warning in parity_guide.missing_in_guide(guide_path, ported):
            print(f"⚠ {warning}")
    return 0
