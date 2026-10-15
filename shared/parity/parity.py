#!/usr/bin/env python3
"""Parity map, ledger and sync commands. Stdlib only.

Usage: parity.py <command> [args]   (run through ./build.sh sync, which sets PROJECT_ROOT and TURN_ROOT)

  map [--gate] [--at <commit>]        Compare iOS and Android symbol by symbol; --gate fails on errors
  status [--to <commit>] [--verbose]  What changed on iOS since each unit was ported
  diff <unit> [--to <commit>]         The iOS diff of one unit since it was ported
  mark <unit>... [--to <commit>] [--status <s>] [--no-change "<reason>"]
                                      Record a unit as ported from the iOS commit
  mark --commit [--to <commit>]       Move the marker once nothing is pending
  init --at <commit> [--force]        Write the ledger: every unit at that commit
  coverage [<log file>|-]             Which scripts and frames show each view unit
  guide [--seed]                      Check (or print) the Coverage block of the porting guide
  tools [--build]                     Exit 3 when the extractors need building; --build builds them
  extract --ios-tree <dir> [--out f] [--guide <md>] [--project <dir>]
                                      Extract the iOS working tree (the iOS build hook); warns
                                      about names the guide misses, skipping iOS-only files
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_config  # noqa: E402
import parity_guide  # noqa: E402
import parity_sync  # noqa: E402
from parity_extract import ParityError, Repo, Tools  # noqa: E402


def context():
    project_root = os.environ.get("PROJECT_ROOT") or os.getcwd()
    turn_root = os.environ.get("TURN_ROOT", "")
    if not turn_root:
        raise ParityError("TURN_ROOT is not set; add it to build.properties.")
    if not os.path.isdir(os.path.join(turn_root, ".git")) and not os.path.isfile(os.path.join(turn_root, ".git")):
        raise ParityError(f"TURN_ROOT ({turn_root}) is not a git repository.")
    config = parity_config.load(project_root, turn_root)
    return parity_sync.Context(config, Repo(turn_root), Tools(project_root, quiet=os.environ.get("PARITY_QUIET") == "1"))


def main(argv):
    parser = argparse.ArgumentParser(prog="sync", add_help=True)
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("map")
    p.add_argument("--gate", action="store_true")
    p.add_argument("--at")
    p.add_argument("--unit")

    p = sub.add_parser("status")
    p.add_argument("--to")
    p.add_argument("--verbose", "-v", action="store_true")

    p = sub.add_parser("diff")
    p.add_argument("unit")
    p.add_argument("--to")

    p = sub.add_parser("mark")
    p.add_argument("units", nargs="*")
    p.add_argument("--to")
    p.add_argument("--status", choices=["ported", "partial", "stub", "todo", "deferred", "ios-only"])
    p.add_argument("--no-change", dest="no_change")
    p.add_argument("--commit", action="store_true")

    p = sub.add_parser("init")
    p.add_argument("--at", required=True)
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("coverage")
    p.add_argument("log", nargs="?")

    p = sub.add_parser("guide")
    p.add_argument("--seed", action="store_true")
    p.add_argument("--at")

    p = sub.add_parser("tools")
    p.add_argument("--build", action="store_true")

    p = sub.add_parser("extract")
    p.add_argument("--ios-tree", required=True)
    p.add_argument("--out")
    p.add_argument("--guide")
    p.add_argument("--project")

    args = parser.parse_args(argv)
    if args.command is None:
        print(__doc__.strip())
        return 0
    try:
        if args.command == "extract":
            return parity_sync.extract_ios_tree(args.ios_tree, args.out, args.guide, args.project)
        if args.command == "tools":
            tools = Tools(os.environ.get("PROJECT_ROOT") or os.getcwd())
            if args.build:
                tools.swift_binary()
                tools.kotlin_command()
                return 0
            return 0 if tools.up_to_date() else 3
        ctx = context()
        if args.command == "map":
            return parity_sync.do_map(ctx, gate=args.gate, at=args.at, only_unit=args.unit)
        if args.command == "status":
            return parity_sync.do_status(ctx, to=args.to, verbose=args.verbose)
        if args.command == "diff":
            return parity_sync.do_diff(ctx, args.unit, to=args.to)
        if args.command == "mark":
            if args.commit:
                return parity_sync.do_mark_commit(ctx, to=args.to)
            if not args.units:
                print("✗ Name at least one unit: sync mark <unit>... (or sync mark --commit)")
                return 2
            return parity_sync.do_mark(ctx, args.units, to=args.to, status=args.status, no_change=args.no_change)
        if args.command == "init":
            return parity_sync.do_init(ctx, args.at, force=args.force)
        if args.command == "coverage":
            return parity_sync.do_coverage(ctx, args.log)
        if args.command == "guide":
            return parity_guide.do_guide(ctx, seed=args.seed, at=args.at)
    except ParityError as error:
        print(f"✗ {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

