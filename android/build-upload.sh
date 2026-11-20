# android-toolkit/build-upload.sh: preflight, upload and promote to Google Play
# Sourced by build.sh. Mirrors toolkit/ios/build-upload.sh: doctor, clean tree,
# branch, tag <prefix>N, the release bundle and its checks, upload, annotate.
# Publishing goes through Gradle Play Publisher (com.github.triplet.play), which
# the app module applies and keeps off unless ANDROID_PUBLISHER_CREDENTIALS is
# set; only the publish and promote steps here set it.
#
# Provides: do_preflight, do_upload, do_promote
# Depends on: PROJECT_ROOT, ANDROID_MODULE, ANDROID_APP_NAME (build.sh)
# Depends on: _gradle_require, _gradle_run, _gradle_log, _gradle_failure (build-gradle.sh)
# Depends on: do_doctor (build-doctor.sh)
# Config: TOOLKIT_UPLOAD_ENABLED, DEPLOY_TAG_PREFIX (default android/v),
#         ANDROID_PLAY_TRACKS (default internal: the tracks an upload ends on),
#         ANDROID_PLAY_RELEASE_STATUS (default completed), ANDROID_KEY_ALIAS (default upload),
#         ANDROID_KEYSTORE_PATH (a keystore file in place of the keychain's),
#         ANDROID_DEBUG_TOOLS_PACKAGE (default <package>.debug)
# Secrets, from the environment or else from keychain() refs in the project's
# gitignored .env.local, read with varlock as the server reads its own:
#         ANDROID_KEYSTORE (the upload keystore, base64), ANDROID_KEYSTORE_PASSWORD,
#         ANDROID_PLAY_JSON_KEY (the Play service account's JSON key)

_UPLOAD_KEY_FILE=""
_UPLOAD_KEY_ALIAS=""
_UPLOAD_KEY_KIND=""
_UPLOAD_KEY_TEMP=false
_UPLOAD_VERSION_CODE=""
_UPLOAD_AAB=""

_require_upload() {
    if [[ "${TOOLKIT_UPLOAD_ENABLED:-false}" != "true" ]]; then
        echo "✗ Upload not configured for this project."
        echo "  Set TOOLKIT_UPLOAD_ENABLED=true in build.properties."
        return 1
    fi
}

_upload_env_file() {
    echo "$PROJECT_ROOT/.env.local"
}

# True when the secret is in the environment or .env.local names it. Reads no value.
_upload_has_secret() {
    local name="$1"
    [[ -n "${!name:-}" ]] && return 0
    grep -q "^$name=" "$(_upload_env_file)" 2>/dev/null
}

# Prints the secret: the environment's value, else varlock's from .env.local.
_upload_secret() {
    local name="$1"
    if [[ -n "${!name:-}" ]]; then
        printf '%s' "${!name}"
        return 0
    fi
    if ! grep -q "^$name=" "$(_upload_env_file)" 2>/dev/null; then
        echo "✗ $name is neither in the environment nor in $(_upload_env_file)" >&2
        return 1
    fi
    if ! command -v varlock >/dev/null 2>&1; then
        echo "✗ varlock is missing; it reads $name from the keychain (brew install dmno-dev/tap/varlock)" >&2
        return 1
    fi
    local value
    if ! value=$(cd "$PROJECT_ROOT" && varlock printenv "$name" --path "$PROJECT_ROOT/" 2>/dev/null) || [[ -z "$value" ]]; then
        echo "✗ varlock could not read $name (the keychain() ref in $(_upload_env_file))" >&2
        return 1
    fi
    printf '%s' "$value"
}

# The key the bundle is signed with. The upload key when one is configured: the
# file ANDROID_KEYSTORE_PATH names, else ANDROID_KEYSTORE from the keychain,
# written to build/upload/ for the build and removed after it. A dry run without
# one makes a throwaway key there, named so it can't pass for the upload key.
_upload_prepare_key() {
    local dry="$1"
    _UPLOAD_KEY_ALIAS="${ANDROID_KEY_ALIAS:-upload}"
    local dir="$PROJECT_ROOT/build/upload"
    mkdir -p "$dir"
    if [[ -n "${ANDROID_KEYSTORE_PATH:-}" ]] || _upload_has_secret ANDROID_KEYSTORE; then
        _UPLOAD_KEY_KIND=upload
        if ! UPLOAD_STORE_PASSWORD=$(_upload_secret ANDROID_KEYSTORE_PASSWORD); then
            return 1
        fi
        export UPLOAD_STORE_PASSWORD
        if [[ -n "${ANDROID_KEYSTORE_PATH:-}" ]]; then
            if [[ ! -f "$ANDROID_KEYSTORE_PATH" ]]; then
                echo "✗ No keystore at ANDROID_KEYSTORE_PATH ($ANDROID_KEYSTORE_PATH)"
                return 1
            fi
            _UPLOAD_KEY_FILE="$ANDROID_KEYSTORE_PATH"
        else
            _UPLOAD_KEY_FILE="$dir/upload-key.jks"
            _UPLOAD_KEY_TEMP=true
            local encoded
            encoded=$(_upload_secret ANDROID_KEYSTORE) || return 1
            if ! (umask 077 && printf '%s' "$encoded" | base64 --decode > "$_UPLOAD_KEY_FILE") || [[ ! -s "$_UPLOAD_KEY_FILE" ]]; then
                echo "✗ ANDROID_KEYSTORE is not a base64 keystore"
                return 1
            fi
        fi
        if ! "$JAVA_HOME/bin/keytool" -list -keystore "$_UPLOAD_KEY_FILE" -storepass:env UPLOAD_STORE_PASSWORD \
            -alias "$_UPLOAD_KEY_ALIAS" >/dev/null 2>&1; then
            echo "✗ The keystore has no key '$_UPLOAD_KEY_ALIAS', or ANDROID_KEYSTORE_PASSWORD doesn't open it"
            return 1
        fi
        return 0
    fi
    if [[ "$dry" != true ]]; then
        echo "✗ No upload key. Store it as './build.sh android upload --help' says, or try a --dry-run."
        return 1
    fi
    _UPLOAD_KEY_KIND=throwaway
    _UPLOAD_KEY_ALIAS=throwaway
    _UPLOAD_KEY_FILE="$dir/THROWAWAY-dry-run-key-NOT-the-Play-upload-key.p12"
    UPLOAD_STORE_PASSWORD=throwaway-dry-run
    export UPLOAD_STORE_PASSWORD
    if [[ ! -f "$_UPLOAD_KEY_FILE" ]]; then
        if ! "$JAVA_HOME/bin/keytool" -genkeypair -noprompt -keystore "$_UPLOAD_KEY_FILE" -storetype PKCS12 \
            -storepass:env UPLOAD_STORE_PASSWORD -keypass:env UPLOAD_STORE_PASSWORD -alias throwaway \
            -keyalg RSA -keysize 2048 -validity 365 \
            -dname "CN=Throwaway dry-run key, OU=Not the Play upload key, O=$ANDROID_APP_NAME" >/dev/null 2>&1; then
            echo "✗ keytool could not make the throwaway key"
            return 1
        fi
    fi
}

_upload_cleanup() {
    if $_UPLOAD_KEY_TEMP; then
        rm -f "$_UPLOAD_KEY_FILE"
        _UPLOAD_KEY_TEMP=false
    fi
    unset UPLOAD_STORE_PASSWORD
}

# Builds the release bundle under the gradle lock, signed with the prepared key
# when there is one, with _UPLOAD_VERSION_CODE as its versionCode. Sets
# _UPLOAD_AAB. Signed builds run without the daemon, so no daemon keeps the
# passwords after the build.
_upload_bundle() {
    local signed="$1" code=0
    local flags=()
    [[ "$signed" == true ]] && flags+=(--no-daemon)
    (
        unset ANDROID_KEYSTORE_PASSWORD ANDROID_PUBLISHER_CREDENTIALS
        if [[ "$signed" == true ]]; then
            export ANDROID_KEYSTORE_PATH="$_UPLOAD_KEY_FILE" ANDROID_KEY_ALIAS="$_UPLOAD_KEY_ALIAS"
            export ANDROID_KEYSTORE_PASSWORD="$UPLOAD_STORE_PASSWORD"
        else
            unset ANDROID_KEYSTORE_PATH
        fi
        [[ -n "$_UPLOAD_VERSION_CODE" ]] && export ANDROID_VERSION_CODE="$_UPLOAD_VERSION_CODE"
        _gradle_run upload ${flags[@]+"${flags[@]}"} ":$ANDROID_MODULE:bundleRelease"
    ) || code=$?
    if [[ $code -ne 0 ]]; then
        echo "  ✗ Release bundle failed:"
        _gradle_failure "$(_gradle_log upload)"
        return 1
    fi
    _UPLOAD_AAB=$(find "$PROJECT_ROOT/$ANDROID_MODULE/build/outputs/bundle/release" -name '*.aab' -print -quit 2>/dev/null)
    if [[ -z "$_UPLOAD_AAB" ]]; then
        echo "  ✗ No .aab under $ANDROID_MODULE/build/outputs/bundle/release"
        return 1
    fi
    echo "  ✓ Release bundle: $(_upload_size "$_UPLOAD_AAB") $_UPLOAD_AAB"
}

_upload_size() {
    local bytes
    bytes=$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1")
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
}

# The release build's merged manifest is not debuggable, and R8's mapping
# holds no class of the debug tools' package.
_upload_check_release() {
    local ok=0 manifest mapping package debug_package hits
    # merged_manifests holds the manifest after the libraries' are merged in;
    # merged_manifest only the app's own.
    manifest=$(find "$PROJECT_ROOT/$ANDROID_MODULE/build/intermediates/merged_manifests/release" \
        -name AndroidManifest.xml -print -quit 2>/dev/null)
    if [[ -z "$manifest" ]]; then
        echo "  ✗ The release build's merged manifest wasn't found"
        ok=1
    elif grep -q 'android:debuggable="true"' "$manifest"; then
        echo "  ✗ The release manifest says android:debuggable=\"true\""
        ok=1
    else
        echo "  ✓ The release manifest isn't debuggable"
    fi
    package=$(sed -n 's/.*[[:space:]]package="\([^"]*\)".*/\1/p' "$manifest" 2>/dev/null | head -1)
    debug_package="${ANDROID_DEBUG_TOOLS_PACKAGE:-${package:+$package.debug}}"
    mapping="$PROJECT_ROOT/$ANDROID_MODULE/build/outputs/mapping/release/mapping.txt"
    if [[ -z "$debug_package" ]]; then
        echo "  ⚠ No package in the manifest; set ANDROID_DEBUG_TOOLS_PACKAGE to check for the debug tools"
    elif [[ ! -f "$mapping" ]]; then
        echo "  ✗ No R8 mapping at $mapping, so the debug tools can't be checked"
        ok=1
    else
        hits=$(grep -c "^${debug_package//./\\.}\." "$mapping" || true)
        if [[ "${hits:-0}" -gt 0 ]]; then
            echo "  ✗ The release bundle carries $hits class(es) of $debug_package:"
            grep "^${debug_package//./\\.}\." "$mapping" | head -5 | sed 's/ ->.*//; s/^/    /'
            ok=1
        else
            echo "  ✓ No debug tools ($debug_package) in the release bundle"
        fi
    fi
    return $ok
}

# The bundle's signature verifies and its signer is the prepared key.
_upload_check_signature() {
    local aab="$1" out signer expected owner
    out=$("$JAVA_HOME/bin/jarsigner" -verify "$aab" 2>&1 || true)
    if [[ "$out" != *"jar verified."* ]]; then
        echo "  ✗ jarsigner doesn't verify the bundle:"
        head -5 <<<"$out" | sed 's/^/    /'
        return 1
    fi
    signer=$("$JAVA_HOME/bin/keytool" -printcert -jarfile "$aab" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256: //p' | head -1)
    owner=$("$JAVA_HOME/bin/keytool" -printcert -jarfile "$aab" 2>/dev/null | sed -n 's/^Owner: //p' | head -1)
    expected=$("$JAVA_HOME/bin/keytool" -list -v -keystore "$_UPLOAD_KEY_FILE" -storepass:env UPLOAD_STORE_PASSWORD \
        -alias "$_UPLOAD_KEY_ALIAS" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256: //p' | head -1)
    if [[ -z "$signer" || "$signer" != "$expected" ]]; then
        echo "  ✗ The bundle is signed by ${signer:-nobody}, not by the key '$_UPLOAD_KEY_ALIAS' ($expected)"
        return 1
    fi
    echo "  ✓ Signature verifies (jarsigner), signed by $owner"
    echo "    SHA-256 $signer"
    if [[ "$_UPLOAD_KEY_KIND" == throwaway ]]; then
        echo "  ⚠ Signed with the throwaway dry-run key: Play would refuse this bundle"
    fi
}

# The tracks an upload ends on, one per line: internal first, then each track of
# ANDROID_PLAY_TRACKS (comma-separated) once.
_upload_tracks() {
    local list="${ANDROID_PLAY_TRACKS-internal}" track seen=" internal "
    local -a tracks=()
    echo internal
    IFS=',' read -r -a tracks <<<"$list"
    for track in ${tracks[@]+"${tracks[@]}"}; do
        track=$(xargs <<<"$track")
        [[ -z "$track" || "$seen" == *" $track "* ]] && continue
        seen+="$track "
        echo "$track"
    done
}

# Writes the release notes where Gradle Play Publisher reads them: the release
# source set's play/release-notes/en-US/default.txt (gitignored).
_upload_write_notes() {
    local dir="$PROJECT_ROOT/$ANDROID_MODULE/src/release/play/release-notes/en-US"
    mkdir -p "$dir"
    printf '%s\n' "$1" > "$dir/default.txt"
}

_upload_remove_notes() {
    rm -rf "$PROJECT_ROOT/$ANDROID_MODULE/src/release/play/release-notes"
    rmdir "$PROJECT_ROOT/$ANDROID_MODULE/src/release/play" "$PROJECT_ROOT/$ANDROID_MODULE/src/release" 2>/dev/null || true
}

# Runs a Gradle Play Publisher task with the service account's key.
_upload_play_task() {
    local name="$1" json code=0
    shift
    json=$(_upload_secret ANDROID_PLAY_JSON_KEY) || return 1
    (
        export ANDROID_PUBLISHER_CREDENTIALS="$json"
        if [[ -n "$_UPLOAD_KEY_FILE" ]]; then
            export ANDROID_KEYSTORE_PATH="$_UPLOAD_KEY_FILE" ANDROID_KEY_ALIAS="$_UPLOAD_KEY_ALIAS"
            export ANDROID_KEYSTORE_PASSWORD="${UPLOAD_STORE_PASSWORD:-}"
        fi
        [[ -n "$_UPLOAD_VERSION_CODE" ]] && export ANDROID_VERSION_CODE="$_UPLOAD_VERSION_CODE"
        _gradle_run "$name" --no-daemon "$@"
    ) || code=$?
    if [[ $code -ne 0 ]]; then
        echo "  ✗ Gradle Play Publisher failed:"
        _gradle_failure "$(_gradle_log "$name")"
        return 1
    fi
}

# ./build.sh android preflight: the upload's release bundle and its checks,
# unsigned, without uploading.
do_preflight() {
    _gradle_require || return 1
    echo "→ Preflight: the release bundle of $ANDROID_APP_NAME and its checks"
    _upload_bundle false || return 1
    _upload_check_release
}

do_upload() {
    local code=0
    _do_upload "$@" || code=$?
    _upload_remove_notes
    _upload_cleanup
    return $code
}

_do_upload() {
    _require_upload || return 1
    local deploy_text="" force_mode=false dry=false arg
    for arg in "$@"; do
        case "$arg" in
            --force) force_mode=true ;;
            --dry-run) dry=true ;;
            -*)
                echo "✗ Unknown option $arg"
                echo "  Usage: ./build.sh android upload [--dry-run] [--force] \"release notes\""
                return 1
                ;;
            *) [[ -z "$deploy_text" ]] && deploy_text="$arg" ;;
        esac
    done
    if [[ -z "$deploy_text" ]]; then
        echo "✗ Release notes are required."
        echo "  Usage: ./build.sh android upload [--dry-run] [--force] \"release notes\""
        return 1
    fi
    if [[ ${#deploy_text} -gt 500 ]]; then
        echo "✗ Play takes release notes of 500 characters at most; these have ${#deploy_text}."
        return 1
    fi
    _gradle_require || return 1
    if ! $dry && ! _upload_has_secret ANDROID_PLAY_JSON_KEY; then
        echo "✗ No Play service account key (ANDROID_PLAY_JSON_KEY). './build.sh android upload --help' says how to store it."
        return 1
    fi

    local tag_prefix="${DEPLOY_TAG_PREFIX:-android/v}"
    local deploy_log="${DEPLOY_LOG:-$PROJECT_ROOT/.watch/deploy.log}"
    local total_start=$SECONDS
    local tracks
    tracks=$(_upload_tracks | paste -sd ',' - | sed 's/,/, /g')

    if $dry; then
        echo "=== Upload (dry run: nothing is tagged or sent) ==="
    else
        echo "=== Upload ==="
    fi
    echo ""
    echo "[0/4] Pre-upload check"
    if ! do_doctor >/dev/null 2>&1; then
        echo "  ✗ doctor failed. Run './build.sh android doctor' for details"
        return 1
    fi
    echo "  ✓ doctor passed"

    git -C "$PROJECT_ROOT" update-index -q --refresh >/dev/null 2>&1 || true
    if ! git -C "$PROJECT_ROOT" diff-index --quiet HEAD --; then
        if $dry; then
            echo "  ⚠ uncommitted changes; a real upload stops here"
        else
            echo "  ✗ uncommitted changes. Commit or stash before uploading"
            git -C "$PROJECT_ROOT" diff-index --name-status HEAD -- | head -5 | sed 's/^/    /'
            return 1
        fi
    else
        echo "  ✓ working tree clean"
    fi

    local branch
    branch=$(git -C "$PROJECT_ROOT" branch --show-current)
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        echo "  ⚠ branch is '$branch' (not main/master)"
    fi
    local has_remote=false
    if git -C "$PROJECT_ROOT" remote get-url origin >/dev/null 2>&1; then
        has_remote=true
        local remote_sha local_sha
        remote_sha=$(git -C "$PROJECT_ROOT" rev-parse "origin/$branch" 2>/dev/null || true)
        local_sha=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
        if [[ -z "$remote_sha" ]]; then
            echo "  ⚠ no remote tracking branch for '$branch'"
        elif [[ "$remote_sha" != "$local_sha" ]]; then
            echo "  ⚠ unpushed commits on '$branch'"
        else
            echo "  ✓ up to date with origin/$branch"
        fi
        if ! $dry; then
            git -C "$PROJECT_ROOT" fetch origin --tags 2>/dev/null && echo "  ✓ tags fetched"
        fi
    else
        echo "  ⚠ no remote 'origin': the tag stays on this Mac"
    fi

    local commit deployer
    commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
    deployer=$(git config user.name 2>/dev/null || echo "unknown")

    local current_tag existing_tag tag_annotation=""
    current_tag=$(git -C "$PROJECT_ROOT" tag -l "${tag_prefix}*" --sort=-creatordate --format='%(refname:short)' 2>/dev/null | head -1)
    existing_tag=$(git -C "$PROJECT_ROOT" tag --points-at HEAD --list "${tag_prefix}*" 2>/dev/null | head -1)
    if [[ -n "$existing_tag" ]]; then
        tag_annotation=$(git -C "$PROJECT_ROOT" tag -l "$existing_tag" --format='%(contents:subject)' 2>/dev/null)
        if [[ "$tag_annotation" == *"build:"* ]] && ! $dry; then
            echo "  ✓ $existing_tag already points here ($tag_annotation)"
            echo ""
            echo "=== Already uploaded ==="
            return 0
        fi
    fi

    local new_tag current_label
    if [[ -n "$existing_tag" ]]; then
        new_tag="$existing_tag"
        current_label="$existing_tag (incomplete, resuming)"
    else
        local count
        count=$(git -C "$PROJECT_ROOT" tag -l "${tag_prefix}*" | wc -l | xargs)
        # ANDROID_FIRST_VERSION_CODE numbers the first upload, for a project
        # whose lower numbers mean something else (debug builds, say).
        new_tag="${tag_prefix}$((count + ${ANDROID_FIRST_VERSION_CODE:-1}))"
        current_label="${current_tag:-(none)}"
    fi
    _UPLOAD_VERSION_CODE="${new_tag#"$tag_prefix"}"
    if [[ ! "$_UPLOAD_VERSION_CODE" =~ ^[0-9]+$ ]]; then
        echo "  ✗ The tag $new_tag doesn't end in a version code"
        return 1
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Upload to Google Play"
    echo ""
    echo "  Current:   $current_label"
    echo "  New:       $new_tag  (versionCode $_UPLOAD_VERSION_CODE, commit $commit)"
    echo "  Tracks:    $tracks"
    echo ""
    echo "  $deploy_text"
    echo ""
    if $dry; then
        echo "  Dry run: builds and signs the bundle, then stops before the tag and Play."
    else
        echo "  This tags the commit, builds and signs the bundle and uploads it to Play."
        echo "  Play checks the bundle before testers get it (minutes to hours)."
    fi
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    if ! $dry; then
        if $force_mode; then
            echo "  --force: skipping confirmation"
            echo ""
        else
            local confirm
            read -rp "  Continue? [y/N]: " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo "  Aborted."
                return 1
            fi
            echo ""
        fi
    fi

    echo "[1/4] Git"
    if $dry; then
        echo "  - dry run: $new_tag not made"
    else
        git -C "$PROJECT_ROOT" tag -f -a "$new_tag" -m "commit: $commit" >/dev/null
        if $has_remote; then
            git -C "$PROJECT_ROOT" push origin "$new_tag" -f >/dev/null 2>&1 && echo "  ✓ $new_tag pushed" \
                || echo "  ⚠ $new_tag made, but the push failed"
        else
            echo "  ✓ $new_tag made"
        fi
    fi

    local step_start=$SECONDS
    echo ""
    echo "[2/4] Release bundle, signed"
    _upload_prepare_key "$dry" || return 1
    if [[ "$_UPLOAD_KEY_KIND" == throwaway ]]; then
        echo "  ⚠ No upload key configured: signing with a throwaway key"
        echo "    ($_UPLOAD_KEY_FILE)"
    else
        echo "  ✓ upload key '$_UPLOAD_KEY_ALIAS' opened"
    fi
    echo "  → building (R8, a few minutes; full log: build/logs/gradle-upload.log)"
    _upload_bundle true || return 1
    local checks=0
    _upload_check_release || checks=1
    _upload_check_signature "$_UPLOAD_AAB" || checks=1
    [[ $checks -eq 0 ]] || return 1
    echo "  ⏱  $((SECONDS - step_start))s"

    if $dry; then
        echo ""
        echo "[3/4] Upload"
        echo "  - dry run: not sent. A real run uploads $(basename "$_UPLOAD_AAB") to internal"
        local promoted
        promoted=$(_upload_tracks | tail -n +2 | paste -sd ',' - | sed 's/,/, /g')
        [[ -n "$promoted" ]] && echo "    and promotes it to $promoted"
        echo ""
        echo "[4/4] Tag annotation"
        echo "  - dry run: skipped"
        echo ""
        echo "=== Dry run done: $_UPLOAD_AAB ($(_upload_size "$_UPLOAD_AAB"), versionCode $_UPLOAD_VERSION_CODE, $((SECONDS - total_start))s) ==="
        return 0
    fi

    step_start=$SECONDS
    echo ""
    echo "[3/4] Upload"
    local status="${ANDROID_PLAY_RELEASE_STATUS:-completed}" track
    _upload_write_notes "$deploy_text"
    echo "  → uploading to internal (full log: build/logs/gradle-publish.log)"
    _upload_play_task publish ":$ANDROID_MODULE:publishReleaseBundle" --track internal --release-status "$status" || return 1
    echo "  ✓ uploaded to internal as versionCode $_UPLOAD_VERSION_CODE"
    while IFS= read -r track; do
        echo "  → promoting to $track"
        _upload_play_task promote ":$ANDROID_MODULE:promoteReleaseArtifact" \
            --from-track internal --promote-track "$track" --release-status "$status" || return 1
        echo "  ✓ handed to $track"
    done < <(_upload_tracks | tail -n +2)
    echo "  ⏱  $((SECONDS - step_start))s"

    echo ""
    echo "[4/4] Tag annotation"
    local annotation="build: $_UPLOAD_VERSION_CODE | commit: $commit | at: $(date -u +%Y-%m-%dT%H:%M:%SZ) | by: $deployer | tracks: $tracks | text: ${deploy_text//$'\n'/ }"
    git -C "$PROJECT_ROOT" tag -f -a "$new_tag" -m "$annotation" >/dev/null
    if $has_remote; then
        git -C "$PROJECT_ROOT" push origin "$new_tag" -f >/dev/null 2>&1 || true
    fi
    echo "  ✓ $new_tag updated"

    echo ""
    local total_duration=$((SECONDS - total_start))
    echo "=== Done: $new_tag, versionCode $_UPLOAD_VERSION_CODE (${total_duration}s) ==="
    mkdir -p "$(dirname "$deploy_log")"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) upload $new_tag done versionCode=$_UPLOAD_VERSION_CODE commit=$commit by=$deployer tracks=\"$tracks\" duration=${total_duration}s text=\"${deploy_text//$'\n'/ }\"" >> "$deploy_log"
}

# ./build.sh android promote <track> [--from <track>] ["release notes"]: hands
# the newest release on the internal track (or --from) to another track, with
# notes from the argument or else from the newest upload tag.
do_promote() {
    local code=0
    _do_promote "$@" || code=$?
    _upload_remove_notes
    return $code
}

_do_promote() {
    _require_upload || return 1
    local track="" from=internal notes=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                from="${2:-}"
                shift 2 || shift
                ;;
            -*)
                echo "✗ Unknown option $1"
                return 1
                ;;
            *)
                if [[ -z "$track" ]]; then track="$1"; elif [[ -z "$notes" ]]; then notes="$1"; fi
                shift
                ;;
        esac
    done
    if [[ -z "$track" || -z "$from" ]]; then
        echo "Usage: ./build.sh android promote <track> [--from <track>] [\"release notes\"]"
        return 1
    fi
    _gradle_require || return 1
    if [[ -z "$notes" ]]; then
        local tag
        tag=$(git -C "$PROJECT_ROOT" tag -l "${DEPLOY_TAG_PREFIX:-android/v}*" --sort=-creatordate --format='%(refname:short)' | head -1)
        [[ -n "$tag" ]] && notes=$(git -C "$PROJECT_ROOT" tag -l "$tag" --format='%(contents:subject)' | sed -n 's/.*| text: //p')
    fi
    [[ -n "$notes" ]] && _upload_write_notes "$notes"
    echo "→ the newest release on $from to $track"
    _upload_play_task promote ":$ANDROID_MODULE:promoteReleaseArtifact" \
        --from-track "$from" --promote-track "$track" --release-status "${ANDROID_PLAY_RELEASE_STATUS:-completed}" || return 1
    echo "✓ handed to $track"
}
