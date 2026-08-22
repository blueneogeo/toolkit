#!/bin/bash
# Vision analysis through an OpenAI-compatible chat completions endpoint.
# Lets a non-vision agent interrogate a screenshot with a focused question.

_vision_usage() {
    cat <<'EOF'
Usage: ./build.sh vision <image> --focus "<question>" [--model <id>] [--max-dim N]

Send an image to a vision model and print its answer as plain text.

  <image>              Path to a PNG/JPEG/HEIC image (e.g. ios/build/screenshots/x.png)
  --focus "<question>"   REQUIRED. A focused question about the image.
  --model <id>         Override TOOLKIT_VISION_MODEL.
  --max-dim N          Longest-edge cap in px; 0 (default) sends the original at full resolution.

Env:
  TOOLKIT_MODEL_API_KEY   Required. Provider API key (never printed or stored here).
  TOOLKIT_MODEL_BASE_URL  Default: https://opencode.ai/zen/go/v1
  TOOLKIT_VISION_MODEL    Default: deepseek-v4-flash-vision-exp

Writing good --focus prompts:
  - Point at a region: "top-left corner of the card", "the header bar",
    "the gap between the avatar and the name".
  - Ask about specifics, not a broad description: "Is there a dark halo
    hugging the top-left corner arc?" beats "Describe this image."
  - Name what you expect to be true so the model can confirm or refute:
    "Roughly how many px separate the avatar and the name label? Less than 12?"
  - Ask one thing per call; iterate with follow-ups.
EOF
}

_do_vision() {
    local image="" focus="" model="" max_dim=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --focus) focus="${2:-}"; shift 2 ;;
            --model) model="${2:-}"; shift 2 ;;
            --max-dim) max_dim="${2:-0}"; shift 2 ;;
            -h|--help) _vision_usage; return 0 ;;
            *)
                if [[ -z "$image" ]]; then image="$1"; else echo "✗ Unexpected argument: $1" >&2; _vision_usage; return 1; fi
                shift
                ;;
        esac
    done

    if [[ -z "$image" ]]; then
        echo "✗ Missing <image>." >&2
        _vision_usage
        return 1
    fi

    if [[ -z "$focus" ]]; then
        echo "✗ --focus is required." >&2
        echo "" >&2
        echo "Give the vision model a focused question — it answers best when you" >&2
        echo "point at a region and name what you expect. Examples:" >&2
        echo '  --focus "Is there a dark halo hugging the top-left corner of the card?"' >&2
        echo '  --focus "Roughly how many px separate the avatar and the name label?"' >&2
        echo '  --focus "Describe the spacing around the header text — is anything clipped?"' >&2
        echo "" >&2
        _vision_usage
        return 1
    fi

    [[ -z "${TOOLKIT_MODEL_API_KEY:-}" ]] && { echo "✗ TOOLKIT_MODEL_API_KEY is not set." >&2; return 1; }

    local base_url="${TOOLKIT_MODEL_BASE_URL:-https://opencode.ai/zen/go/v1}"
    local model="${model:-${TOOLKIT_VISION_MODEL:-deepseek-v4-flash-vision-exp}}"

    [[ -f "$image" ]] || { echo "✗ Image not found: $image" >&2; return 1; }

    # Image prep: full resolution by default; convert non-PNG/JPEG (HEIC etc.) and
    # apply --max-dim cap via sips (built-in macOS).
    local ext="${image##*.}"; ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    local mime upload_file tmp_img=""
    case "$ext" in
        png) mime="image/png" ;;
        jpg|jpeg) mime="image/jpeg" ;;
        *) mime="image/jpeg" ;;
    esac
    upload_file="$image"
    if [[ "$max_dim" != "0" || ( "$ext" != "png" && "$ext" != "jpg" && "$ext" != "jpeg" ) ]]; then
        tmp_img=$(mktemp -t vision_img).jpg
        if [[ "$max_dim" != "0" ]]; then
            sips -Z "$max_dim" -s format jpeg "$image" --out "$tmp_img" >/dev/null 2>&1 \
                || { echo "✗ sips failed to resize $image" >&2; return 1; }
        else
            sips -s format jpeg "$image" --out "$tmp_img" >/dev/null 2>&1 \
                || { echo "✗ sips failed to convert $image" >&2; return 1; }
        fi
        upload_file="$tmp_img"
        mime="image/jpeg"
    fi

    local req_file resp_file
    req_file=$(mktemp -t vision_req).json
    resp_file=$(mktemp -t vision_resp).json

    # Build the request JSON with python3 (handles base64 + escaping without
    # blowing past ARG_MAX on large images).
    python3 - "$upload_file" "$focus" "$model" "$mime" "$req_file" <<'PY'
import base64, json, sys
img_path, focus, model, mime, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(img_path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
payload = {
    "model": model,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": focus},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
        ],
    }],
    "max_tokens": 1024,
}
with open(out_path, "w") as f:
    json.dump(payload, f)
PY
    [[ -n "$tmp_img" ]] && rm -f "$tmp_img"

    local status
    status=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -X POST "${base_url%/}/chat/completions" \
        -H "Authorization: Bearer ${TOOLKIT_MODEL_API_KEY}" \
        -H "Content-Type: application/json" \
        --data-binary "@$req_file")

    if [[ "$status" != "200" ]]; then
        echo "✗ Vision API error (HTTP $status):" >&2
        head -c 2000 "$resp_file" >&2; echo "" >&2
        rm -f "$req_file" "$resp_file"
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        jq -r '.choices[0].message.content // .choices[0].text // .error.message // "✗ no content in response"' "$resp_file"
    else
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("choices",[{}])[0].get("message",{}).get("content") or d.get("error",{}).get("message") or "✗ no content in response")' "$resp_file"
    fi

    rm -f "$req_file" "$resp_file"
}
