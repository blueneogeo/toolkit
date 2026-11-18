#!/bin/bash
# The compare page for two fake frame folders: frames paired by name, a frame
# missing on either side marked, the log lines aligned and a failed check
# highlighted. No emulator, simulator, Gradle or server.
#
#   bash toolkit/shared/compare_test.sh
#
# Prints one line per failed case and the count; exits 1 when one failed.

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/project" "$WORK/ios/frames/alpha" "$WORK/ios/logs" "$WORK/android/alpha"
printf 'ANDROID_APPLICATION_ID=com.example.app\nANDROID_LOG_TAG=Turn\n' > "$WORK/project/build.properties"

# A 2x2 PNG per frame, without image tools.
png() {
    python3 -B -I - "$1" <<'EOF'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
raw = b"".join(b"\x00" + b"\xff\x80\x00" * 2 for _ in range(2))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
EOF
}
for f in first second ios_only; do png "$WORK/ios/frames/alpha/$f.png"; done
for f in first second android_only; do png "$WORK/android/alpha/$f.png"; done

# The reference set's layout on iOS (frames/, logs/), the flat one on Android.
cat > "$WORK/ios/logs/alpha.log" <<'EOF'
01:14:19.686  INFO [scriptor] running alpha
01:14:19.700  INFO [network] GET /api/v1/feed → 200
01:14:20.100  INFO [scriptor] DebugScreenshot: saved second.png
01:14:20.200  INFO [scriptor] DebugScreenshot: saved first.png
01:14:20.300  INFO [scriptor] DebugScreenshot: saved ios_only.png
01:14:21.000  INFO [scriptor] SCRIPT_RESULT alpha: 1 passed, 0 failed
EOF
cat > "$WORK/android/alpha.log" <<'EOF'
02:00:00.000  INFO [scriptor] running alpha
02:00:01.000  INFO [scriptor] DebugScreenshot: saved second.png
02:00:01.100  INFO [scriptor] DebugScreenshot: saved android_only.png
02:00:01.200  INFO [scriptor] DebugScreenshot: saved first.png
02:00:01.300  ERROR [scriptor] CHECK_FAILED alpha: cards 11, expected 12
02:00:02.000  INFO [scriptor] SCRIPT_RESULT alpha: 0 passed, 1 failed
EOF

failures=0
fail() {
    echo "✗ $1"
    failures=$((failures + 1))
}

out=$(TOOLKIT_PROJECT_ROOT="$WORK/project" bash "$SHARED_DIR/../android/build.sh" compare alpha,beta \
    --ios "$WORK/ios" --android "$WORK/android" --out "$WORK/run" 2>&1)
code=$?
page="$WORK/run/index.html"

[[ $code -eq 0 ]] || fail "compare exited $code: $out"
[[ -s "$page" ]] || fail "no page at $page"
grep -q "alpha: 2 paired, 1 only on iOS, 1 only on Android (iOS 1 passed, 0 failed; Android 0 passed, 1 failed)" <<<"$out" \
    || fail "summary line for alpha: $out"
grep -q "beta: 0 paired, 0 only on iOS, 0 only on Android" <<<"$out" || fail "summary line for beta: $out"
[[ $(grep -o 'src="data:image/' "$page" | wc -l | tr -d ' ') -eq 6 ]] || fail "six embedded frames"
grep -q "No Android frame" "$page" || fail "iOS-only frame not marked"
grep -q "No iOS frame" "$page" || fail "Android-only frame not marked"
grep -q 'class="frame only-ios" id="alpha--ios_only"' "$page" || fail "ios_only row"
grep -q 'class="frame only-android" id="alpha--android_only"' "$page" || fail "android_only row"
grep -q 'class="frame both" id="alpha--first"' "$page" || fail "first paired"
# Frames follow the order the scripts saved them: second, android_only, first, ios_only.
order=$(grep -o 'class="frame [a-z-]*" id="alpha--[a-z_]*"' "$page" | sed -E 's/.*alpha--//; s/"//' | tr '\n' ' ')
[[ "$order" == "second android_only first ios_only " ]] || fail "frame order: $order"
grep -q '<td class="fail"><span class="cat">\[scriptor\]</span> CHECK_FAILED alpha' "$page" || fail "failed check highlighted"
grep -q '\[network\]' "$page" && fail "network lines kept"
grep -q "running alpha</td><td class=\"\"><span class=\"cat\">\[scriptor\]</span> running alpha" "$page" \
    || fail "equal lines not on one row"
grep -q "Neither side has a frame" "$page" || fail "script without frames not said"
grep -q '<details open>' "$page" || fail "log lines of a failed run not open"

# Bad input stops before writing anything.
out=$(TOOLKIT_PROJECT_ROOT="$WORK/project" bash "$SHARED_DIR/../android/build.sh" compare alpha --ios "$WORK/nowhere" --out "$WORK/run2" 2>&1)
[[ $? -ne 0 && "$out" == *"No iOS frames at"* && ! -e "$WORK/run2" ]] || fail "missing iOS folder: $out"
out=$(TOOLKIT_PROJECT_ROOT="$WORK/project" bash "$SHARED_DIR/../android/build.sh" compare 'a;b' --out "$WORK/run3" 2>&1)
[[ $? -ne 0 && "$out" == *"Invalid --script names"* ]] || fail "bad script names: $out"

if [[ $failures -gt 0 ]]; then
    echo "✗ $failures case(s) failed"
    exit 1
fi
echo "✓ compare_test: every case passed"
