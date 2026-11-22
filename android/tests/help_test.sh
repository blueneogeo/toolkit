#!/bin/bash
# Every command's --help, against config/README.md and the usage list. No
# emulator, Gradle or server.
#
#   bash toolkit/android/tests/help_test.sh
#
# Per command: --help exits 0 and prints text; a flag in the command's help or in
# its line in the list of commands is in its README rows or section, and a flag
# in its README rows is in its help. Prints one line per failed case and the count;
# exits 1 when one failed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README="$TESTS_DIR/../config/README.md"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/project" "$WORK/sdk/platform-tools"
printf 'ANDROID_APPLICATION_ID=com.example.app\n' > "$WORK/project/build.properties"
printf '#!/bin/bash\necho "adb $*" >> "%s/adb.log"\n' "$WORK" > "$WORK/sdk/platform-tools/adb"
chmod +x "$WORK/sdk/platform-tools/adb"

export ANDROID_HOME="$WORK/sdk"
export TOOLKIT_PROJECT_ROOT="$WORK/project"
unset ANDROID_DEVICE ANDROID_CONFIG
# shellcheck disable=SC1091
source "$TESTS_DIR/../build.sh"
set +e +o pipefail

FAILED=0
PASSED=0

_fail() {
    FAILED=$((FAILED + 1))
    echo "✗ $1"
}

# The flags in a text, one per line, without the ones every command takes and am
# start's extras.
_flags() {
    grep -oE -- '--[a-z][a-z-]*' | grep -vxE -- '--(help|device|config|es|ez)' | sort -u
}

# A command's rows (first cell, then both cells) and section in the README.
_readme_entry() {
    python3 -B - "$1" "$README" "$2" <<'PY'
import re, sys
cmd, readme, part = sys.argv[1:4]
starts = re.compile(r"`" + re.escape(cmd) + r"[ `]")
heading = None
for line in open(readme, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("#"):
        heading = line.lstrip("#").strip()
        continue
    if line.startswith("|"):
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line)[1:-1]]
        if len(cells) >= 2 and starts.search(cells[0]):
            print(cells[0] if part == "usage" else " ".join(cells[:2]))
    elif heading == cmd and part == "all":
        print(line)
PY
}

# The command's lines in the list of all commands (build-help.txt): their
# usage, without the summary.
_usage_signature() {
    usage | awk -v cmd="$1" '$0 ~ "^  " cmd "( |$)" { sub(/  +[A-Z].*$/, ""); print }'
}

# ANDROID_COMMANDS and the dispatch's case labels agree.
listed=$(tr -s ' \n' '\n\n' <<<"$ANDROID_COMMANDS" | grep -v '^$' | sort)
dispatched=$(declare -f _dispatch | sed -n 's/^ *\([a-z][a-z-]*\))$/\1/p; s/^ *\([a-z][a-z-]*\)) .*/\1/p' | grep -vxE 'help|start' | sort -u)
missing=$(comm -13 <(echo "$listed") <(echo "$dispatched"))
extra=$(comm -23 <(echo "$listed") <(echo "$dispatched"))
if [[ -n "$missing$extra" ]]; then
    _fail "ANDROID_COMMANDS and _dispatch differ: missing [$(echo $missing)], not dispatched [$(echo $extra)]"
else
    PASSED=$((PASSED + 1))
fi

for cmd in $ANDROID_COMMANDS; do
    out=$(_dispatch "$cmd" --help 2>&1)
    code=$?
    if [[ $code -ne 0 || -z "$out" || "$out" == ✗* ]]; then
        _fail "$cmd --help: exit $code"
        sed 's/^/    /' <<<"$out" | head -5
        continue
    fi
    PASSED=$((PASSED + 1))

    readme_all=$(_readme_entry "$cmd" all | _flags)
    readme_rows=$(_readme_entry "$cmd" usage | _flags)
    help_flags=$(_flags <<<"$out")
    signature=$(_usage_signature "$cmd" | _flags)

    not_in_readme=$(comm -23 <(echo "$help_flags") <(echo "$readme_all") | grep -v '^$')
    [[ -n "$not_in_readme" ]] && _fail "$cmd: --help names $(echo $not_in_readme) and the README doesn't" || PASSED=$((PASSED + 1))

    not_in_help=$(comm -23 <(echo "$readme_rows") <(echo "$help_flags") | grep -v '^$')
    [[ -n "$not_in_help" ]] && _fail "$cmd: the README names $(echo $not_in_help) and --help doesn't" || PASSED=$((PASSED + 1))

    usage_only=$(comm -23 <(echo "$signature") <(echo "$readme_all") | grep -v '^$')
    [[ -n "$usage_only" ]] && _fail "$cmd: the usage list names $(echo $usage_only) and the README doesn't" || PASSED=$((PASSED + 1))
done

out=$(_dispatch nothing --help 2>&1)
code=$?
[[ $code -eq 1 && "$out" == *'No command "nothing"'* ]] && PASSED=$((PASSED + 1)) || _fail "unknown command --help: exit $code"

[[ ! -s "$WORK/adb.log" ]] && PASSED=$((PASSED + 1)) || _fail "--help called adb: $(head -3 "$WORK/adb.log")"

echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
