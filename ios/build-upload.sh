# ios-toolkit/build-upload.sh — generic TestFlight deploy (gated by TOOLKIT_UPLOAD_ENABLED)
# Provides: do_upload, do_preflight
# Depends on: PROJECT_ROOT (config), SCRIPT_DIR (build.sh)
# Depends on: _TARGET_SDK, _TARGET_DEST, _TARGET_NAME, _BUILD_CONFIG, _BUILD_EXTRA (build.sh)
# Depends on: _check_build_tools, _ensure_project, _do_build, _find_app, do_doctor, _ruby_bundle_cmd (build.sh)
# Depends on: IOS_KEY_ID, IOS_ISSUER_ID, IOS_TEAM_ID (build.properties)
# Config: DEPLOY_TAG_PREFIX (default ios/v), FASTLANE_LANE (default ios upload),
#         FASTLANE_DISTRIBUTE_LANE (default ios distribute),
#         TESTFLIGHT_GROUPS (external groups an upload goes to; empty: internal testers only),
#         IOS_KEY_PATH (default $PROJECT_ROOT/AuthKey.p8)

_require_upload() {
    if [[ "${TOOLKIT_UPLOAD_ENABLED:-false}" != "true" ]]; then
        echo "✗ Upload not configured for this project."
        echo "  Set TOOLKIT_UPLOAD_ENABLED=true in build.properties and run ./build.sh setup."
        return 1
    fi
}

# The Release build an upload makes first, for a generic iOS device and
# unsigned, then the encryption check on what it built.
_preflight_release() {
    echo "  → building Release for generic iOS device (60-90s)..."
    local _saved_sdk="$_TARGET_SDK"
    local _saved_dest="$_TARGET_DEST"
    local _saved_name="$_TARGET_NAME"
    local _saved_cfg="${_BUILD_CONFIG:-}"
    _TARGET_SDK="iphoneos"
    _TARGET_DEST="generic/platform=iOS"
    _TARGET_NAME="generic iOS device"
    _BUILD_CONFIG="Release"
    _BUILD_EXTRA="CODE_SIGNING_ALLOWED=NO"
    local _preflight_out="$PROJECT_ROOT/.watch/preflight.log"
    mkdir -p "$(dirname "$_preflight_out")"
    local ok=1
    if ( _do_build build ) > "$_preflight_out" 2>&1; then
        echo "  ✓ Release build succeeded"
        _check_encryption_answer "$(_find_app)" || ok=0
    else
        echo "  ✗ Release build failed. Full log: $_preflight_out"
        tail -20 "$_preflight_out"
        ok=0
    fi
    _TARGET_SDK="$_saved_sdk"
    _TARGET_DEST="$_saved_dest"
    _TARGET_NAME="$_saved_name"
    _BUILD_CONFIG="$_saved_cfg"
    _BUILD_EXTRA=""
    [[ $ok -eq 1 ]]
}

# An app whose Info.plist says it uses no encryption beyond Apple's
# (ITSAppUsesNonExemptEncryption NO) must not carry a crypto library of its
# own, such as BoringSSL or OpenSSL: App Store Connect would want export
# documents for it.
_check_encryption_answer() {
    local app="$1"
    if [[ -z "$app" || ! -d "$app" ]]; then
        echo "  ✗ The Release build's app wasn't found, so its encryption can't be checked"
        return 1
    fi
    local answer
    answer=$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$app/Info.plist" 2>/dev/null || true)
    if [[ "$answer" != "false" ]]; then
        echo "  ✓ The app tells Apple it uses encryption beyond Apple's (ITSAppUsesNonExemptEncryption ${answer:-unset})"
        return 0
    fi
    # grep -c reads to the end: grep -q would stop early and, with pipefail,
    # turn a hit into a miss.
    local file kind hits found=""
    while IFS= read -r file; do
        kind=$(file -b "$file")
        [[ "$kind" == *Mach-O* ]] || continue
        hits=$(strings "$file" | grep -c -E "BoringSSL|OPENSSL_" || true)
        if [[ "${hits:-0}" -gt 0 ]]; then
            found+="    ${file#"$app"/} ($hits)"$'\n'
        fi
    done < <(find "$app" -type f -perm +111)
    if [[ -n "$found" ]]; then
        echo "  ✗ The app tells Apple it uses only Apple's encryption, but these carry BoringSSL or OpenSSL:"
        printf "%s" "$found"
        return 1
    fi
    echo "  ✓ Only Apple's encryption in the app, as its Info.plist tells Apple"
}

# ./build.sh ios preflight: the upload's Release build and checks, without
# uploading.
do_preflight() {
    _check_build_tools
    _ensure_project
    _preflight_release
}

do_upload() {
    _require_upload || return 1
    local deploy_text=""
    local force_mode=false
    for arg in "$@"; do
        if [[ "$arg" == "--force" ]]; then
            force_mode=true
        elif [[ -z "$deploy_text" ]]; then
            deploy_text="$arg"
        fi
    done

    if [[ -z "$deploy_text" ]]; then
        echo "✗ Deploy text is required."
        echo "  Usage: ./build.sh upload [--force] \"deploy text\""
        return 1
    fi

    local key_path="${IOS_KEY_PATH:-$PROJECT_ROOT/AuthKey.p8}"
    if [[ ! -f "$key_path" ]]; then
        echo "✗ AuthKey.p8 not found at $key_path"
        return 1
    fi

    if [[ -z "${IOS_KEY_ID:-}" || -z "${IOS_ISSUER_ID:-}" ]]; then
        echo "✗ IOS_KEY_ID and IOS_ISSUER_ID must be set in build.properties"
        return 1
    fi

    _check_build_tools
    _ensure_project

    local tag_prefix="${DEPLOY_TAG_PREFIX:-ios/v}"
    local fastlane_lane="${FASTLANE_LANE:-ios upload}"
    local deploy_log="${DEPLOY_LOG:-$PROJECT_ROOT/.watch/deploy.log}"
    local total_start=$SECONDS

    echo "=== Deploy ==="

    # ── Pre-deploy check ────────────────────────────────────────
    echo ""
    echo "[0/4] Pre-deploy check"

    if ! do_doctor >/dev/null 2>&1; then
        echo "  ✗ doctor failed — run './build.sh doctor' for details"
        return 1
    fi
    echo "  ✓ doctor passed"

    git -C "$PROJECT_ROOT" update-index -q --refresh >/dev/null 2>&1
    if ! git -C "$PROJECT_ROOT" diff-index --quiet HEAD --; then
        echo "  ✗ uncommitted changes — commit or stash before deploying"
        git -C "$PROJECT_ROOT" diff-index --name-status HEAD -- | head -5 | sed 's/^/    /'
        return 1
    fi
    echo "  ✓ working tree clean"

    local branch
    branch=$(git -C "$PROJECT_ROOT" branch --show-current)
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        echo "  ⚠ branch is '$branch' (not main/master)"
    fi

    local remote_sha
    remote_sha=$(git -C "$PROJECT_ROOT" rev-parse "origin/$branch" 2>/dev/null)
    local local_sha
    local_sha=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
    if [[ -z "$remote_sha" ]]; then
        echo "  ⚠ no remote tracking branch for '$branch'"
    elif [[ "$remote_sha" != "$local_sha" ]]; then
        echo "  ⚠ unpushed commits on '$branch'"
    else
        echo "  ✓ up to date with origin/$branch"
    fi

    local commit
    commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
    local deployer
    deployer=$(git config user.name 2>/dev/null || echo "unknown")

    # ── Git tag ─────────────────────────────────────────────────

    git -C "$PROJECT_ROOT" fetch origin --tags 2>/dev/null
    echo "  ✓ tags fetched"

    local current_tag
    current_tag=$(git -C "$PROJECT_ROOT" tag -l "${tag_prefix}*" --sort=-creatordate --format='%(refname:short)' 2>/dev/null | head -1)

    local existing_tag
    existing_tag=$(git -C "$PROJECT_ROOT" tag --points-at HEAD --list "${tag_prefix}*" 2>/dev/null | head -1)

    local tag_annotation
    if [[ -n "$existing_tag" ]]; then
        tag_annotation=$(git -C "$PROJECT_ROOT" tag -l "$existing_tag" --format='%(contents:subject)' 2>/dev/null)
        if [[ "$tag_annotation" == *"build:"* ]]; then
            echo "  ✓ $existing_tag already points here ($tag_annotation)"
            echo "  ✓ nothing to do"
            echo ""
            echo "=== Already deployed ==="
            return 0
        fi
    fi

    local new_tag
    local current_label
    if [[ -n "$existing_tag" ]]; then
        new_tag="$existing_tag"
        current_label="$existing_tag (incomplete — resuming)"
    else
        local count
        count=$(git -C "$PROJECT_ROOT" tag -l "${tag_prefix}*" | wc -l | xargs)
        new_tag="${tag_prefix}$((count + 1))"
        current_label="${current_tag:-(none)}"
    fi

    # ── Confirmation ──────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Deploy"
    echo ""
    echo "  Current:   $current_label  (TestFlight)"
    echo "  New:       $new_tag  (commit: $commit)"
    echo ""
    echo "  $deploy_text"
    echo ""
    echo "  This will build and upload to TestFlight."
    echo "  TestFlight will process the binary (10-30 min)."
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    if $force_mode; then
        echo "  --force: skipping confirmation"
        echo ""
    else
        read -rp "  Continue? [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "  Aborted."
            return 1
        fi
        echo ""
    fi

    existing_tag="$new_tag"

    echo "[1/4] Git"
    if [[ -n "$tag_annotation" ]]; then
        git -C "$PROJECT_ROOT" tag -f -a "$existing_tag" -m "commit: $commit" >/dev/null
        git -C "$PROJECT_ROOT" push origin "$existing_tag" -f >/dev/null 2>&1
    else
        git -C "$PROJECT_ROOT" tag -a "$existing_tag" -m "commit: $commit" >/dev/null
        git -C "$PROJECT_ROOT" push origin "$existing_tag" >/dev/null 2>&1
    fi
    echo "  ✓ $existing_tag pushed"
    echo "  ⏱  $((SECONDS - total_start))s"

    # ── Step 2: Pre-flight build ────────────────────────────────
    local step_start=$SECONDS
    echo ""
    echo "[2/4] Pre-flight build"
    _preflight_release || return 1
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 3: Archive + sign + upload ─────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[3/4] Archive + sign + upload"
    echo "  → building archive, signing, uploading (3-4 min)..."
    echo "  (full log: .watch/upload.log)"

    if [[ -z "${MATCH_PASSWORD:-}" ]]; then
        if [[ -t 0 ]]; then
            read -rsp "  Match encryption password: " MATCH_PASSWORD
            echo ""
        else
            echo "✗ MATCH_PASSWORD not set (required for non-interactive deploys)"
            return 1
        fi
    fi

    local _upload_out="$PROJECT_ROOT/.watch/upload.log"
    mkdir -p "$PROJECT_ROOT/.watch"

    local bundle_cmd
    bundle_cmd=$(_ruby_bundle_cmd)

    local build_number
    build_number="${existing_tag#${tag_prefix}}"
    build_number="${build_number:-1}"

    local _upload_filter='(\*\* ARCHIVE SUCCEEDED|Successfully exported and signed the ipa file:|Successfully uploaded the new binary|Successfully finished processing|upload succeeded|Waiting for Apple|handed to|✗|\*\* BUILD FAILED|fatal error|^error)'
    if IOS_KEY_ID="$IOS_KEY_ID" \
        IOS_ISSUER_ID="$IOS_ISSUER_ID" \
        IOS_TEAM_ID="$IOS_TEAM_ID" \
        BUILD_NUMBER="$build_number" \
        IOS_BUNDLE_ID="$IOS_BUNDLE_ID" \
        TESTFLIGHT_GROUPS="${TESTFLIGHT_GROUPS:-}" \
        IOS_KEY_PATH="$key_path" \
        CHANGELOG="$deploy_text" \
        MATCH_PASSWORD="$MATCH_PASSWORD" \
        SENTRY_ORG="$SENTRY_ORG" \
        IOS_SENTRY_PROJECT="$IOS_SENTRY_PROJECT" \
        $bundle_cmd exec fastlane $fastlane_lane 2>&1 \
        | tee "$_upload_out" \
        | grep --line-buffered -E "$_upload_filter" \
        | sed -E -l -e 's/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]: //' -e 's/^▸ //' -e 's/'$'\x1b''\[[0-9;]*m//g' -e 's/^/  /'; then
        _upload_rc=0
    else
        _upload_rc=${PIPESTATUS[0]}
    fi

    if [[ $_upload_rc -ne 0 ]]; then
        echo ""
        echo "  ✗ Upload failed (exit $_upload_rc). Full log: $_upload_out"
        return 1
    fi

    echo "  ✓ uploaded as build $build_number"
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 4: Tag annotation ──────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[4/4] Tag annotation"
    local annotation="build: $build_number | commit: $commit | at: $(date -u +%Y-%m-%dT%H:%M:%SZ) | by: $deployer | text: ${deploy_text//$'\n'/ }"
    git -C "$PROJECT_ROOT" tag -f -a "$existing_tag" -m "$annotation" >/dev/null
    git -C "$PROJECT_ROOT" push origin "$existing_tag" -f >/dev/null 2>&1
    echo "  ✓ $existing_tag updated"
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Summary ─────────────────────────────────────────────────
    echo ""
    local total_duration=$((SECONDS - total_start))
    echo "=== Done: $existing_tag, build $build_number (${total_duration}s) ==="
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) deploy $existing_tag done build=$build_number commit=$commit by=$deployer duration=${total_duration}s text=\"${deploy_text//$'\n'/ }\"" >> "$deploy_log"
}

# do_testflight gives an uploaded build to the external groups in
# TESTFLIGHT_GROUPS, with notes from the argument or else from its tag.
do_testflight() {
    _require_upload || return 1
    local build_number="${1:-}" notes="${2:-}"
    if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
        echo "Usage: ./build.sh ios testflight <build> [notes]"
        return 1
    fi
    if [[ -z "${TESTFLIGHT_GROUPS:-}" ]]; then
        echo "✗ TESTFLIGHT_GROUPS is empty in build.properties"
        return 1
    fi
    local tag="${DEPLOY_TAG_PREFIX:-ios/v}$build_number"
    if [[ -z "$notes" ]]; then
        notes=$(git -C "$PROJECT_ROOT" tag -l "$tag" --format='%(contents:subject)' | sed -n 's/.*| text: //p')
    fi
    local key_path="${IOS_KEY_PATH:-$PROJECT_ROOT/AuthKey.p8}"
    echo "→ build $build_number to $TESTFLIGHT_GROUPS"
    (cd "$PROJECT_ROOT" && IOS_KEY_ID="$IOS_KEY_ID" IOS_ISSUER_ID="$IOS_ISSUER_ID" IOS_KEY_PATH="$key_path" \
        IOS_BUNDLE_ID="$IOS_BUNDLE_ID" BUILD_NUMBER="$build_number" TESTFLIGHT_GROUPS="$TESTFLIGHT_GROUPS" CHANGELOG="$notes" \
        $(_ruby_bundle_cmd) exec fastlane ${FASTLANE_DISTRIBUTE_LANE:-ios distribute} 2>&1 \
        | grep --line-buffered -E '(Waiting for Apple|handed to|Successfully|error|Error|✗)' \
        | sed -E -l -e 's/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]: //' -e 's/'$'\x1b''\[[0-9;]*m//g' -e 's/^/  /')
    return "${PIPESTATUS[0]}"
}
