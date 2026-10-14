# toolkit/shared/record-frames.sh: frames and contact sheets from a screen recording
# Provides: _record_frames
# Depends on: ffmpeg

RECORD_SHEET_COLUMNS=8
RECORD_SHEET_ROWS=6
RECORD_SHEET_TILE_WIDTH=240

# Screen recorders write a frame only when the screen changes, so the last frame is
# held to the recording's real length before sampling.
_record_frames() {
    local video="$1" out="$2" fps="$3" seconds="$4"
    local timeline="tpad=stop_mode=clone:stop_duration=${seconds},fps=${fps}"
    rm -rf "$out"
    mkdir -p "$out"
    if ! ffmpeg -loglevel error -i "$video" -vf "$timeline" -t "$seconds" "$out/frame_%03d.png"; then
        echo "✗ Could not cut frames from $video"
        return 1
    fi
    if ! ffmpeg -loglevel error -i "$video" \
        -vf "${timeline},scale=${RECORD_SHEET_TILE_WIDTH}:-2,tile=${RECORD_SHEET_COLUMNS}x${RECORD_SHEET_ROWS}:padding=4:color=white" \
        -t "$seconds" "$out/sheet_%02d.png"; then
        echo "✗ Could not make contact sheets"
        return 1
    fi
    local frames sheets
    frames=$(find "$out" -name 'frame_*.png' | wc -l | tr -d ' ')
    sheets=$(find "$out" -name 'sheet_*.png' | wc -l | tr -d ' ')
    echo "✓ $frames frame(s) at ${fps} fps and $sheets contact sheet(s) in $(cd "$out" && pwd)"
}
