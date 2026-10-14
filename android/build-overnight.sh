#!/bin/bash
# android-toolkit/build-overnight.sh: the overnight folder, the queue and the blocker log
# Sourced by build.sh.
#
# Provides: _main_checkout, _overnight_root, _night_dir, do_blocker
# Depends on: PROJECT_ROOT (build.sh)

BLOCKER_KINDS="touch-id keychain tcc licence download emulator adb jdk gradle disk memory network git worktree server server-restart-needed permission-denied permission-prompt classifier-block usage-limit missing-tool needs-dependency needs-shared-change decision-needed spec-gap test-flaky lock-timeout toolkit other"
BLOCKER_SEVERITIES="blocks-step blocks-package blocks-all degraded"

# The repository's main working tree, also from inside a linked worktree.
_main_checkout() {
    local common
    common=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "$PROJECT_ROOT"; return 0; }
    dirname "$common"
}

# <main checkout>/../output/overnight unless TOOLKIT_OVERNIGHT_DIR says otherwise.
_overnight_root() {
    if [[ -n "${TOOLKIT_OVERNIGHT_DIR:-}" ]]; then
        echo "$TOOLKIT_OVERNIGHT_DIR"
    else
        echo "$(dirname "$(_main_checkout)")/output/overnight"
    fi
}

# TOOLKIT_NIGHT_DATE, else the newest night that `night init` made, else the
# day the night started: before 09:00 counts as the previous day.
_night_dir() {
    local root
    root=$(_overnight_root)
    if [[ -n "${TOOLKIT_NIGHT_DATE:-}" ]]; then
        echo "$root/$TOOLKIT_NIGHT_DATE"
        return 0
    fi
    local newest
    newest=$(ls -d "$root"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/queue.json 2>/dev/null | sort | tail -1 || true)
    if [[ -n "$newest" ]]; then
        dirname "$newest"
    else
        echo "$root/$(date -v-9H +%Y-%m-%d)"
    fi
}

_blocker_usage() {
    cat <<EOF
Usage: ./build.sh android blocker add --kind <kind> --summary "<text>" [options]

  Append one JSON line to <overnight>/<night>/blockers.jsonl and print its path.

    --kind <kind>          What blocked (required). One of:
                           $(fold -s -w 64 <<<"$BLOCKER_KINDS" | sed '2,$s/^/                           /')
    --summary "<text>"     What happened, in one sentence (required)
    --severity <s>         blocks-step (default) | blocks-package | blocks-all | degraded
    --needs "<text>"       The one thing a person must do in the morning
    --evidence <path>      A file with the command and its last 50 lines of output
    --tried "<text>"       What was tried; repeat for each attempt
    --switched-to "<text>" What you work on instead
    --package <id>         The work package (default: the worktree's name)
    --agent <name>         Who logs it (default: the worktree's name, or "lead")
    --status open|resolved When the blocker clears, add the same agent, kind and
                           package again with --status resolved (default: open)

  Never put secrets, tokens, .env values or the test login in any field.

Example:
    ./build.sh android blocker add --kind emulator --severity blocks-package \\
        --summary "Emulator did not finish booting in 240 s twice" \\
        --tried "android emulator start (2x)" --switched-to "unit tests" \\
        --needs "Cold boot Turn_Parity by hand"
EOF
}

do_blocker() {
    case "${1:-}" in
        add) shift ;;
        ""|help|-h|--help) _blocker_usage; return 0 ;;
        *) echo "✗ Unknown blocker command: $1"; _blocker_usage; return 1 ;;
    esac

    local kind="" summary="" severity="blocks-step" needs="" evidence="" switched="" package="" agent="" status="open"
    local tried=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kind) kind="${2:-}"; shift 2 ;;
            --summary) summary="${2:-}"; shift 2 ;;
            --severity) severity="${2:-}"; shift 2 ;;
            --needs) needs="${2:-}"; shift 2 ;;
            --evidence) evidence="${2:-}"; shift 2 ;;
            --tried) tried+=("${2:-}"); shift 2 ;;
            --switched-to) switched="${2:-}"; shift 2 ;;
            --package) package="${2:-}"; shift 2 ;;
            --agent) agent="${2:-}"; shift 2 ;;
            --status) status="${2:-}"; shift 2 ;;
            -h|--help) _blocker_usage; return 0 ;;
            *) echo "✗ Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$kind" || -z "$summary" ]]; then
        echo "✗ --kind and --summary are required."
        return 1
    fi
    if [[ " $BLOCKER_KINDS " != *" $kind "* ]]; then
        echo "✗ Unknown kind '$kind'. One of: $BLOCKER_KINDS"
        return 1
    fi
    if [[ " $BLOCKER_SEVERITIES " != *" $severity "* ]]; then
        echo "✗ Unknown severity '$severity'. One of: $BLOCKER_SEVERITIES"
        return 1
    fi
    if [[ "$status" != "open" && "$status" != "resolved" ]]; then
        echo "✗ --status is open or resolved."
        return 1
    fi

    local worktree branch name
    worktree=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")
    branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$worktree" == "$(_main_checkout)" ]]; then
        name="lead"
    else
        name=$(basename "$worktree")
    fi
    [[ -n "$evidence" && "$evidence" != /* && -e "$PWD/$evidence" ]] && evidence="$PWD/$evidence"

    local file
    file="$(_night_dir)/blockers.jsonl"
    mkdir -p "$(dirname "$file")"
    B_AGENT="${agent:-$name}" B_WORKTREE="$worktree" B_BRANCH="$branch" B_PACKAGE="${package:-$name}" \
    B_KIND="$kind" B_SEVERITY="$severity" B_SUMMARY="$summary" B_EVIDENCE="$evidence" \
    B_SWITCHED="$switched" B_NEEDS="$needs" B_STATUS="$status" B_FILE="$file" \
    python3 -I -c '
import datetime, json, os, sys
e = os.environ
entry = {
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "agent": e["B_AGENT"], "worktree": e["B_WORKTREE"], "branch": e["B_BRANCH"],
    "package": e["B_PACKAGE"], "kind": e["B_KIND"], "severity": e["B_SEVERITY"],
    "summary": e["B_SUMMARY"], "evidence": e["B_EVIDENCE"], "tried": sys.argv[1:],
    "switched_to": e["B_SWITCHED"], "needs": e["B_NEEDS"], "status": e["B_STATUS"],
}
with open(e["B_FILE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
' ${tried[@]+"${tried[@]}"}
    echo "✓ Blocker logged ($kind, $severity, $status)"
    echo "$file"
}

_night_usage() {
    cat <<'EOF2'
Usage: ./build.sh android night init <date> [--ios-commit <sha>] [--exclude "<IDs>"] [--force]

  Create <overnight>/<date>/ for a night: empty blockers.jsonl, progress.jsonl
  and notifications.jsonl, the down/ folder, and queue.json with every
  package of waves 1 to 4 in doc/packages.md (TOOLKIT_PACKAGES_FILE), all
  waiting. Rows whose name says ", phase 2" or ", only if" are left out, and
  so are the IDs given with --exclude. Dependencies on packages outside the
  queue (wave 0) are dropped. An existing queue.json is kept unless --force.

    --ios-commit <sha>  The iOS commit the night ports (default: the one named in
                        night/launch-prompt.md, else TOOLKIT_IOS_COMMIT)
EOF2
}

_night_ios_commit() {
    [[ -n "${TOOLKIT_IOS_COMMIT:-}" ]] && { echo "$TOOLKIT_IOS_COMMIT"; return 0; }
    sed -n 's/^The iOS commit tonight: `\([0-9a-zA-Z._/-]*\)`.*/\1/p' "$(_main_checkout)/night/launch-prompt.md" 2>/dev/null | head -1
}

do_night() {
    case "${1:-}" in
        init) shift ;;
        ""|help|-h|--help) _night_usage; return 0 ;;
        *) echo "✗ Unknown night command: $1"; _night_usage; return 1 ;;
    esac
    local date="" commit="" exclude="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ios-commit) commit="${2:-}"; shift 2 ;;
            --exclude) exclude="${2:-}"; shift 2 ;;
            --force) force=true; shift ;;
            -h|--help) _night_usage; return 0 ;;
            -*) echo "✗ Unknown option: $1"; return 1 ;;
            *) date="$1"; shift ;;
        esac
    done
    if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "✗ Give the night's start date: ./build.sh android night init 2026-10-15"
        return 1
    fi
    [[ -z "$commit" ]] && commit=$(_night_ios_commit)
    [[ -z "$commit" ]] && echo "⚠ No iOS commit known; queue.json gets an empty ios_commit. Pass --ios-commit."

    local packages="${TOOLKIT_PACKAGES_FILE:-$(_main_checkout)/doc/packages.md}"
    if [[ ! -f "$packages" ]]; then
        echo "✗ No package list at $packages."
        return 1
    fi
    local dir
    dir="$(_overnight_root)/$date"
    mkdir -p "$dir/down"
    touch "$dir/blockers.jsonl" "$dir/progress.jsonl" "$dir/notifications.jsonl"
    if [[ -f "$dir/queue.json" ]] && ! $force; then
        echo "✓ Night folder ready; queue.json exists and is kept (--force rewrites it)"
        echo "$dir"
        return 0
    fi

    local worktrees prefix
    worktrees=$(_worktree_root)
    prefix="${TOOLKIT_WORKTREE_BRANCH_PREFIX:-pkg/}"
    N_FILE="$packages" N_DATE="$date" N_COMMIT="$commit" N_EXCLUDE="$exclude" \
    N_WORKTREES="$worktrees" N_PREFIX="$prefix" N_OUT="$dir/queue.json" python3 -I -c '
import json, os, re
e = os.environ
excluded = set(e["N_EXCLUDE"].replace(",", " ").split())
rows, wave = [], None
for line in open(e["N_FILE"], encoding="utf-8"):
    heading = re.match(r"^### Wave (\d+)", line)
    if heading:
        wave = int(heading.group(1))
        continue
    if line.startswith("## "):
        wave = None
    if wave not in (1, 2, 3, 4) or not line.startswith("| "):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 4 or not re.fullmatch(r"[A-Z]{1,2}\d+", cells[0]):
        continue
    ident, name, depends = cells[0], cells[1], cells[3]
    if ident in excluded or ", phase 2" in name or ", only if" in name:
        continue
    rows.append((ident, wave, re.findall(r"\b[A-Z]{1,2}\d+\b", depends)))
queued = {r[0] for r in rows}
packages = {}
for ident, wave, depends in rows:
    low = ident.lower()
    packages[ident] = {
        "wave": wave,
        "depends_on": [d for d in depends if d in queued and d != ident],
        "status": "waiting",
        "branch": e["N_PREFIX"] + low,
        "worktree": os.path.join(e["N_WORKTREES"], low),
        "slot": None,
        "attempts": 0,
        "started": None,
        "unverified": [],
        "needs_shared_change": [],
        "last_report": "",
    }
queue = {"night": e["N_DATE"], "ios_commit": e["N_COMMIT"], "packages": packages}
tmp = e["N_OUT"] + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(queue, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, e["N_OUT"])
waves = {}
for _, wave, _ in rows:
    waves[wave] = waves.get(wave, 0) + 1
print("✓ queue.json: %d packages (%s)" % (len(rows), ", ".join("wave %d: %d" % (w, n) for w, n in sorted(waves.items()))))
'
    echo "✓ Night folder ready"
    echo "$dir"
}

# Prints the path of a down/<resource> flag of tonight when it is set.
_night_flag() {
    local flag
    flag="$(_night_dir)/down/$1"
    [[ -e "$flag" ]] && echo "$flag"
    return 0
}
