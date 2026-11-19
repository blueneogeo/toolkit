"""Guide freshness: every iOS import and framework type is named in the porting guide's Coverage block."""

import os
import re
import tomllib

GUIDE = "the porting guide"
BLOCK = re.compile(r"^## Coverage\s*$.*?^```toml\s*$(.*?)^```", re.MULTILINE | re.DOTALL)


def guide_path(ctx):
    """The porting guide: parity.toml's source.guide, relative to the project."""
    return os.path.normpath(os.path.join(ctx.project_root, ctx.config.guide))


def read_block(path):
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError:
        return None
    match = BLOCK.search(text)
    if not match:
        return None
    return tomllib.loads(match.group(1))


def names_in(entries):
    """iOS imports, and type names used in the code but declared nowhere in it."""
    entries = list(entries)
    declared = set()

    def collect(types):
        for info in types:
            declared.add(info["name"])
            collect(info.get("types", []))

    for entry in entries:
        collect(entry.get("types", []))
    imports = {name for entry in entries for name in entry.get("imports", [])}
    framework = set()
    for entry in entries:
        for name in entry.get("references", []):
            if len(name) > 1 and name not in declared and name[0].isupper() and not name.isupper():
                framework.add(name)
    return imports, framework


def missing_in_guide(path, entries):
    block = read_block(path)
    if block is None:
        return []
    imports, framework = names_in(entries)
    known_imports = set(block.get("imports", {}))
    known_types = set(block.get("framework_types", {}))
    missing = [f"import {name} is not in the Coverage block of {GUIDE}" for name in sorted(imports - known_imports)]
    missing += [f"framework type {name} is not in the Coverage block of {GUIDE}" for name in sorted(framework - known_types)]
    return missing


def ledger_entries(ctx):
    ledger = ctx.ledger()
    files = {p: b for unit in ledger.units.values() if unit.status != "ios-only"
             for p, b in unit.ios.items() if p.endswith(".swift")}
    return ctx.tools.extract_ios(ctx.repo, files).values()


def check(ctx, _results=None):
    path = guide_path(ctx)
    if not os.path.exists(path):
        print(f"  guide: {os.path.relpath(path, ctx.project_root)} doesn't exist yet; check skipped")
        return []
    if read_block(path) is None:
        print(f"  guide: no Coverage block in {GUIDE} yet (./build.sh android sync guide --seed prints one)")
        return []
    return missing_in_guide(path, ledger_entries(ctx))


def do_guide(ctx, seed=False, at=None):
    if at:
        commit = ctx.repo.resolve(at)
        files = {p: b for p, b in ctx.repo.ls_tree(commit, ctx.config.ios_roots).items() if p.endswith(".swift")}
        entries = ctx.tools.extract_ios(ctx.repo, files).values()
    else:
        entries = ledger_entries(ctx)
    if seed:
        imports, framework = names_in(entries)
        block = read_block(guide_path(ctx)) or {}
        lines = ["## Coverage", "", "```toml", "[imports]"]
        lines += [f'{name} = "{block.get("imports", {}).get(name, "")}"' for name in sorted(imports)]
        lines += ["", "[framework_types]"]
        lines += [f'{name} = "{block.get("framework_types", {}).get(name, "")}"' for name in sorted(framework)]
        if block.get("watch"):
            lines += ["", "[watch]"] + [f'{k} = "{v}"' for k, v in sorted(block["watch"].items())]
        lines.append("```")
        print("\n".join(lines))
        return 0
    errors = missing_in_guide(guide_path(ctx), entries)
    if read_block(guide_path(ctx)) is None:
        print(f"⚠ No Coverage block in {GUIDE}. Paste the output of ./build.sh android sync guide --seed and fill the anchors.")
        return 0
    for error in errors:
        print(f"✗ {error}")
    if errors:
        return 1
    print("✓ The guide names every iOS import and framework type")
    return 0
