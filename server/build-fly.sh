# toolkit/server/build-fly.sh — sourced by build.sh
# Provides: all Fly.io production operations (deploy, rollback, status, etc.)
# Depends on: PROJECT_ROOT, FLY_APP, FLY_DB_CLUSTER, GITHUB_REPO (config)
# Depends on: DEPLOY_FORCE, _sync_locale, _check_quality, _register_firewall, do_doctor (build.sh)
# Depends on: _tty_* (shared/build-utils.sh)
# Depends on: _print_health, _get_sensitive_vars (build-env.sh)

# ═════════════════════════════════════════════════════════════════════
# Fly production commands
# ═════════════════════════════════════════════════════════════════════

# FLY_APP, FLY_DB_CLUSTER, GITHUB_REPO from shared/build.properties

_fly_status() {
    local GREEN RED YELLOW RESET BOLD
    if [[ -t 1 ]]; then
        GREEN="$(printf '\033[32m')"
        RED="$(printf '\033[31m')"
        YELLOW="$(printf '\033[33m')"
        RESET="$(printf '\033[0m')"
        BOLD="$(printf '\033[1m')"
    else
        GREEN='' RED='' YELLOW='' RESET='' BOLD=''
    fi

    echo ""
    echo "=== Fly Status ==="

    # ── Health Check ──────────────────────────────────────────────
    echo ""
    echo "── Health Check ──────────────────────────────────────────────────────────"
    local health_json
    health_json=$(curl -s --max-time 10 "https://${FLY_APP}.fly.dev/api/health" 2>/dev/null || echo '{"status":"unreachable","app":"'"${FLY_APP}"'"}')
    _print_health "$health_json"

    # ── App ─────────────────────────────────────────────────────
    echo ""
    echo "── App: $FLY_APP ─────────────────────────────────────────────────────────"
    local app_json
    app_json=$(fly status --app "$FLY_APP" --json 2>/dev/null || true)
    local hostname
    hostname=$(echo "$app_json" | jq -r '.Hostname // "?"' 2>/dev/null)
    echo "  URL:        https://$hostname"

    local latest_release
    latest_release=$(fly releases --app "$FLY_APP" --json 2>/dev/null | jq -r 'first // empty | "v\(.Version) (\(.CreatedAt[:19] | sub("T";" ")))"' 2>/dev/null || true)
    echo "  Release:    $latest_release"

    echo "$app_json" | jq -r '.Machines[]? | "\(.state // "?")|\(.region // "?")|\(.id[:12])"' | while IFS='|' read -r state region mid; do
        case "$state" in
            started) mark="$(_tty_green)✓$(_tty_reset)"; label="running" ;;
            stopped) mark="$(_tty_yellow)○$(_tty_reset)"; label="idle (auto-stop)" ;;
            *)       mark="$(_tty_red)✗$(_tty_reset)"; label="$state" ;;
        esac
        printf '  %b machine %s  region=%s  %s\n' "$mark" "$mid" "$region" "$label"
    done

    # ── Database ─────────────────────────────────────────────────
    echo ""
    echo "── Database: turn-pg ─────────────────────────────────────────────────────"
    local db_json
    db_json=$(fly mpg status "$FLY_DB_CLUSTER" --json 2>/dev/null || true)
    echo "$db_json" | jq -r '
        .data |
        "\(.id // "?")|\(.status // "?")|\(.plan // "?")|\(.disk // "?")|\(.region // "?")|\(.replicas // "?")|\(.ip_assignments.direct // "?")"
    ' | while IFS='|' read -r cid ds plan disk region replicas ip; do
        case "$ds" in
            ready)  mark="$(_tty_green)✓$(_tty_reset)" ;;
            failed) mark="$(_tty_red)✗$(_tty_reset)" ;;
            *)      mark="$(_tty_yellow)→$(_tty_reset)" ;;
        esac
        echo "  Cluster:    $cid"
        echo "  Status:     $mark $ds"
        echo "  Plan:       $plan ($disk GB, $replicas replica(s))"
        echo "  Region:     $region"
        echo "  IP:         $ip"
    done
    local cred_status
    cred_status=$(echo "$db_json" | jq -r '.credentials.status // "?"')
    if [[ "$cred_status" == "ok" ]]; then
        echo "  Credentials: $(_tty_green)✓$(_tty_reset) available"
    else
        echo "  Credentials: $(_tty_red)✗$(_tty_reset) $cred_status"
    fi

    # ── Storage ──────────────────────────────────────────────────
    echo ""
    echo "── Storage ───────────────────────────────────────────────────────────────"
    local storage_list
    storage_list=$(fly ext storage list 2>/dev/null || true)
    if echo "$storage_list" | grep -q 'NAME'; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local bname
            bname=$(echo "$line" | awk -F'│' '{gsub(/ /, "", $1); print $1}')
            [[ -z "$bname" ]] && continue
            local bstatus
            bstatus=$(fly ext storage status "$bname" 2>/dev/null | grep '│' | awk -F'│' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); key=$1; val=$2; printf "%s=%s ", key, val}' || true)
            echo "  ${GREEN}✓${RESET} $bname  $bstatus"
        done < <(echo "$storage_list" | tail -n +2)
    else
        echo "  (none)"
    fi

    # ── Deploy Tags ──────────────────────────────────────────────
    echo ""
    echo "── Deploy Tags ───────────────────────────────────────────────────────────"
    local tags
    tags=$(git -C "$PROJECT_ROOT" tag -l 'deploy/v*' --sort=-creatordate --format='%(refname:short)|%(contents:subject)' 2>/dev/null)
    if [[ -z "$tags" ]]; then
        echo "  (none)"
    else
        while IFS='|' read -r tname tinfo; do
            [[ -z "$tname" ]] && continue
            local marker=" "
            if [[ -n "$(git -C "$PROJECT_ROOT" tag --points-at HEAD --list "$tname" 2>/dev/null)" ]]; then
                marker="${BOLD}→${RESET}"
            fi
            echo "  $marker $tname  $tinfo"
        done <<< "$tags"
    fi

    # ── Conclusion ───────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    local hstatus
    hstatus=$(echo "$health_json" | jq -r '.status // "unreachable"' 2>/dev/null)
    local db_status
    db_status=$(echo "$db_json" | jq -r '.data.status // "?"' 2>/dev/null)

    local all_ok=true
    if [[ "$hstatus" != "healthy" ]]; then
        all_ok=false
    fi
    if [[ "$db_status" != "ready" ]]; then
        all_ok=false
    fi

    if $all_ok; then
        echo -e "  ${GREEN}${BOLD}✓ All systems healthy${RESET}"
    else
        echo -e "  ${RED}${BOLD}✗ Issues detected — review details above${RESET}"
        [[ "$hstatus" != "healthy" ]] && echo -e "  ${RED}→ Health check: $hstatus${RESET}"
        [[ "$db_status" != "ready" ]] && echo -e "  ${RED}→ Database: $db_status${RESET}"
    fi

    echo ""
    echo "── Metrics ───────────────────────────────────────────────────────────────"
    local metrics_token
    metrics_token=$(fly secrets list --app "$FLY_APP" --json 2>/dev/null | jq -r '.[] | select(.Name == "METRICS_TOKEN") | .Value // empty' 2>/dev/null || true)
    if [[ -n "$metrics_token" ]]; then
        curl -s --max-time 5 "https://${FLY_APP}.fly.dev/metrics?token=${metrics_token}" 2>/dev/null | head -10
    else
        echo "  (METRICS_TOKEN not set — endpoint is protected)"
    fi
    echo "═══════════════════════════════════════════════════════════════════════════"
}

_confirm_live() {
    local message="$1"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "$message" | while IFS= read -r line; do
        echo "  $line"
    done
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    if [[ $DEPLOY_FORCE -eq 1 ]]; then
        echo "  --force: skipping confirmation"
        echo ""
        return 0
    fi
    read -rp "  Continue? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Aborted."
        return 1
    fi
    echo ""
    return 0
}

_pre_deploy_check() {
    local failed=0

    echo ""
    echo "[1/8] Pre-deploy check"

    echo "  → running doctor..."
    local doctor_output
    doctor_output="$(do_doctor 2>&1)" || {
        echo "  ✗ doctor failed:"
        echo "$doctor_output" | grep '✗' | sed 's/^/    /'
        failed=1
    }
    if [[ $failed -eq 0 ]]; then
        echo "  ✓ doctor passed"
    fi

    if [[ $failed -ne 0 ]]; then
        return 1
    fi

    echo "  → checking Fly.io authentication..."
    if _fly_auth_check; then
        echo "  ✓ Fly.io authenticated"
    else
        failed=1
    fi

    if ! git -C "$PROJECT_ROOT" diff-index --quiet HEAD --; then
        echo "  ✗ uncommitted changes — commit or stash before deploying"
        echo "    $(git -C "$PROJECT_ROOT" diff-index --name-status HEAD -- | head -5)"
        failed=1
    else
        echo "  ✓ working tree clean"
    fi

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

    if [[ $failed -ne 0 ]]; then
        return 1
    fi
}

# Verifies the fly CLI is installed and authenticated. Live commands call
# this up front so fly failures surface as clear messages instead of dying
# silently inside suppressed subcommands.
_fly_auth_check() {
    if ! command -v fly &>/dev/null; then
        echo "  ✗ fly CLI not found — install it with: brew install flyctl"
        return 1
    fi
    if ! fly auth whoami &>/dev/null; then
        echo "  ✗ Fly.io is not authenticated — run: fly auth login"
        return 1
    fi
    return 0
}

_cluster_healthy() {
    local checks
    checks=$(fly machines list --app "$FLY_APP" --json 2>/dev/null | jq -r '.[].checks[0].status // "unknown"' 2>/dev/null)
    local critical=0 warning=0 passing=0 total=0
    while read -r status; do
        [[ -z "$status" ]] && continue
        total=$((total + 1))
        case "$status" in
            passing) passing=$((passing + 1)) ;;
            warning) warning=$((warning + 1)) ;;
            critical) critical=$((critical + 1)) ;;
        esac
    done <<< "$checks"
    echo "  $passing passing, $warning warning, $critical critical ($total machines)"
    if [[ $passing -eq $total ]]; then
        return 0
    elif [[ $warning -gt 0 || $critical -gt 0 ]]; then
        return 1
    fi
    return 2
}

_fly_deploy() {
    local deploy_text=""
    local DRY_RUN=0
    local DEPLOY_STRATEGY="rolling"
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --strategy) shift; DEPLOY_STRATEGY="${1:-rolling}"; shift ;;
            --strategy=*) DEPLOY_STRATEGY="${arg#*=}" ;;
            --force) : ;;
            *) deploy_text="$arg"; break ;;
        esac
    done

    if [[ -z "$deploy_text" ]]; then
        echo "✗ Deploy text is required."
        echo "  Usage: ./build.sh server deploy [--dry-run] [--strategy rolling|immediate] [--force] \"deploy text\""
        return 1
    fi

    local total_start=$SECONDS
    local commit
    commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
    local deployer
    deployer=$(git config user.name 2>/dev/null || echo "unknown")
    local deploy_log="$PROJECT_ROOT/.watch/deploy.log"
    local st_failed=0

    echo ""
    echo "=== Deploy ==="

    _pre_deploy_check || { echo ""; echo "✗ deploy aborted — fix issues above and retry"; return 1; }

    git -C "$PROJECT_ROOT" fetch origin --tags 2>/dev/null
    echo "  ✓ tags fetched"

    local current_tag
    current_tag=$(git -C "$PROJECT_ROOT" tag -l 'deploy/v*' --sort=-creatordate --format='%(refname:short)' 2>/dev/null | head -1)

    local existing_tag
    existing_tag=$(git -C "$PROJECT_ROOT" tag --points-at HEAD --list 'deploy/v*' 2>/dev/null | head -1)

    local tag_annotation
    if [[ -n "$existing_tag" ]]; then
        tag_annotation=$(git -C "$PROJECT_ROOT" tag -l "$existing_tag" --format='%(contents:subject)' 2>/dev/null)
        if [[ "$tag_annotation" == *"release: v"* ]]; then
            echo ""
            echo "  ✓ $existing_tag already points here ($tag_annotation)"
            echo "  ✓ nothing to do"
            echo ""
            echo "=== Already deployed ($((SECONDS - total_start))s) ==="
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
        count=$(git -C "$PROJECT_ROOT" tag -l 'deploy/v*' | wc -l | xargs)
        new_tag="deploy/v$((count + 1))"
        if [[ -n "$current_tag" ]]; then
            current_label="$current_tag"
        else
            current_label="(none)"
        fi
    fi

    _confirm_live "Deploy
    $([[ $DRY_RUN -eq 1 ]] && echo "(DRY RUN) ")
    Strategy: $DEPLOY_STRATEGY
    Source:    $existing_tag  (https://${FLY_APP}.fly.dev)
    New:       $new_tag  (commit: $commit)

    $deploy_text

    This will update the live production server at
    https://${FLY_APP}.fly.dev. Active users will receive the
    new code. The database will be snapshotted first
    (read-only, no downtime)." || return 1

    existing_tag="$new_tag"

    # ── Step 2: Git tag ──────────────────────────────────────────
    local step_start=$SECONDS
    echo ""
    echo "[2/8] Git"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  → would push tag $existing_tag"
    else
        if [[ -n "$tag_annotation" ]]; then
            git -C "$PROJECT_ROOT" tag -f -a "$existing_tag" -m "commit: $commit" >/dev/null
            git -C "$PROJECT_ROOT" push origin "$existing_tag" -f >/dev/null 2>&1
        else
            git -C "$PROJECT_ROOT" tag -a "$existing_tag" -m "commit: $commit" >/dev/null
            git -C "$PROJECT_ROOT" push origin "$existing_tag" >/dev/null 2>&1
        fi
        echo "  ✓ $existing_tag pushed"
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 3: Database snapshot ─────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[3/8] Database snapshot"
    local backup=""
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  → would snapshot DB ($FLY_DB_CLUSTER)"
        backup="dry-run-skip"
    else
        backup=$(fly mpg backup list "$FLY_DB_CLUSTER" --json 2>/dev/null | jq -r 'max_by(.start) | "\(.id)|\(.start)"' 2>/dev/null || true)
        if [[ -n "$backup" ]]; then
            local backup_id backup_start backup_age
            backup_id="${backup%%|*}"
            backup_start="${backup##*|}"
            local start_epoch now_epoch age_seconds
            start_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "${backup_start}" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age_seconds=$((now_epoch - start_epoch))
            if [[ $age_seconds -le 600 ]] && [[ $age_seconds -ge 0 ]]; then
                backup_age=$(awk "BEGIN {printf \"%.1f\", $age_seconds / 60}")
                echo "  ✓ recent backup found (${backup_id}, ${backup_age}m ago) — skipping"
                backup="$backup_id"
            else
                backup=""
            fi
        fi
        if [[ -z "$backup" ]]; then
            local _backup_out="$PROJECT_ROOT/.watch/backup.log"
            mkdir -p "$(dirname "$_backup_out")"
            if ! fly mpg backup create "$FLY_DB_CLUSTER" --type incr > "$_backup_out" 2>&1; then
                echo "  ✗ database backup failed — full log: $_backup_out"
                tail -n 10 "$_backup_out" | sed 's/^/    /'
                return 1
            fi
            sleep 3
            backup=$(fly mpg backup list "$FLY_DB_CLUSTER" --json 2>/dev/null | jq -r 'max_by(.start).id // ""' 2>/dev/null || true)
            if [[ -z "$backup" ]]; then
                echo "  ✗ could not capture backup ID — full log: $_backup_out"
                tail -n 10 "$_backup_out" | sed 's/^/    /'
                return 1
            fi
            echo "  ✓ backup created: $backup"
        fi
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 4: Secrets sync ─────────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[4/8] Secrets sync"
    if command -v varlock &>/dev/null && [[ -f "$PROJECT_ROOT/.env.schema" ]]; then
        local _secrets_cache="$PROJECT_ROOT/.watch/secrets-cache.json"
        mkdir -p "$(dirname "$_secrets_cache")"

        local current_json
        current_json=$(fly secrets list --app "$FLY_APP" --json 2>/dev/null || echo "[]")

        local do_sync=1
        if [[ -f "$_secrets_cache" ]]; then
            do_sync=0
            while IFS='|' read -r var_name var_desc; do
                local fly_digest
                fly_digest=$(echo "$current_json" | jq -r --arg name "$var_name" '.[] | select(.name==$name) | .digest // ""' 2>/dev/null)
                local cached_digest
                cached_digest=$(jq -r --arg name "$var_name" '.[] | select(.name==$name) | .digest // ""' "$_secrets_cache" 2>/dev/null)
                if [[ -z "$fly_digest" || "$fly_digest" != "$cached_digest" ]]; then
                    do_sync=1
                    break
                fi
            done < <(_get_sensitive_vars)
        fi

        if [[ $do_sync -eq 0 ]]; then
            echo "  ✓ secrets unchanged — skipping sync"
        else
            local secrets_args=()
            local synced=0
            while IFS='|' read -r var_name var_desc; do
                local value
                value="$(varlock printenv "$var_name" --path "$PROJECT_ROOT/" 2>/dev/null)"
                if [[ -n "$value" ]]; then
                    secrets_args+=("${var_name}=${value}")
                    synced=1
                fi
            done < <(_get_sensitive_vars)

            if [[ $synced -eq 0 ]]; then
                echo "  ✗ varlock produced no output — secrets sync failed"
                return 1
            fi

            local _secrets_out="$PROJECT_ROOT/.watch/secrets.log"
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "  → would sync ${#secrets_args[@]} secrets to Fly"
            elif fly secrets set --app "$FLY_APP" "${secrets_args[@]}" > "$_secrets_out" 2>&1; then
                echo "  ✓ secrets synced to Fly"
                fly secrets list --app "$FLY_APP" --json 2>/dev/null > "$_secrets_cache" || true
            else
                echo "  ⚠ secrets sync failed — deploy will proceed with existing secrets"
                echo "    Full log: $_secrets_out"
            fi
        fi
    else
        echo "  ⚠ varlock or .env.schema missing — skipping secrets sync"
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 5: Cluster health ────────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[5/8] Cluster health"
    local cluster_ok=0
    _cluster_healthy && cluster_ok=1 || true
    echo "  ⏱  $((SECONDS - step_start))s"
    if [[ $cluster_ok -ne 1 && "$DEPLOY_STRATEGY" == "rolling" ]]; then
        echo "  ⚠ cluster not fully healthy — switching to immediate strategy"
        DEPLOY_STRATEGY="immediate"
    fi

    # ── Step 6: Deploy to Fly ────────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[6/8] Deploy to Fly ($DEPLOY_STRATEGY)"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  → would deploy with strategy=$DEPLOY_STRATEGY"
        local release
        release=$(fly releases --app "$FLY_APP" --json 2>/dev/null | jq -r 'first.Version // "?"' 2>/dev/null || true)
    else
        echo "  → building (60-90s)..."
        _sync_locale
        local _deploy_out="$PROJECT_ROOT/.watch/deploy-build.log"
        local _deploy_filter='(^==>|^✓ Configuration|^--> Building image done|^image size:|^Visit your|^✗|[Ee]rror|[Ff]ail)'
        mkdir -p "$(dirname "$_deploy_out")"
        if fly deploy --app "$FLY_APP" --strategy "$DEPLOY_STRATEGY" 2>&1 | tee "$_deploy_out" | grep --line-buffered -E "$_deploy_filter" | sed -e 's/^==>/  →/' -e 's/^image size:/  image size:/' -e 's/^Visit your/  Visit your/'; then
            _deploy_rc=0
        else
            _deploy_rc=${PIPESTATUS[0]}
        fi
        if [[ $_deploy_rc -ne 0 ]]; then
            echo "  ✗ Deploy failed (exit $_deploy_rc). Full log: $_deploy_out"
            return 1
        fi
        local release
        release=$(fly releases --app "$FLY_APP" --json 2>/dev/null | jq -r 'first.Version // "?"' 2>/dev/null || true)
        echo "  ✓ deployed as release v$release"
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 7: Tag annotation ─────────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[7/8] Tag annotation"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  → would annotate $existing_tag"
    else
        local annotation="backup: $backup | release: v$release | commit: $commit | at: $(date -u +%Y-%m-%dT%H:%M:%SZ) | by: $deployer | text: ${deploy_text//$'\n'/ }"
        git -C "$PROJECT_ROOT" tag -f -a "$existing_tag" -m "$annotation" >/dev/null
        git -C "$PROJECT_ROOT" push origin "$existing_tag" -f >/dev/null 2>&1
        echo "  ✓ $existing_tag updated"
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 8: Health check + self-test ──────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[8/8] Health check + self-test"
    local health_json
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  → checking current server health..."
        health_json=$(curl -s --max-time 10 "https://${FLY_APP}.fly.dev/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
        _print_health "$health_json"
        echo "  ⏱  $((SECONDS - step_start))s"
        return 0
    fi

    # Wait for DNS propagation + machine startup (grace period)
    sleep 10
    for i in $(seq 1 15); do
        sleep 4
        health_json=$(curl -s --max-time 10 "https://${FLY_APP}.fly.dev/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
        local reachable
        reachable=$(echo "$health_json" | jq -r '.status // "unreachable"' 2>/dev/null)
        if [[ "$reachable" != "unreachable" ]]; then
            break
        fi
    done

    local hstatus
    hstatus=$(echo "$health_json" | jq -r '.status // "unreachable"' 2>/dev/null)
    if [[ "$hstatus" != "healthy" ]]; then
        echo "  ✗ health check failed ($hstatus)"
        _print_health "$health_json"
        echo "  ⏱  $((SECONDS - step_start))s"
        return 1
    fi

    st_failed=0
    for i in $(seq 1 15); do
        sleep 4
        local st_json
        st_json=$(curl -s --max-time 10 "https://${FLY_APP}.fly.dev/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
        local st_fast
        st_fast=$(echo "$st_json" | jq -r '.self_test.fast.status // "unreachable"' 2>/dev/null)
        if [[ "$st_fast" == "healthy" ]]; then
            break
        elif [[ $i -eq 15 ]]; then
            echo "  ✗ self-test is $st_fast after 60s — deploy may be degraded"
            local st_error
            st_error=$(echo "$st_json" | jq -r '.self_test.fast.error // "no error reported"' 2>/dev/null)
            echo "    Error: $st_error"
            st_failed=1
            break
        fi
    done

    if [[ $st_failed -eq 0 ]]; then
        echo "  ✓ healthy, self-test passing"
    else
        echo "  ✗ deploy degraded — rollback with: ./build.sh server rollback"
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Summary ──────────────────────────────────────────────────
    echo ""
    local total_duration=$((SECONDS - total_start))
    echo "=== Done: $existing_tag, backup $backup, release v$release (${total_duration}s) ==="
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) deploy $existing_tag done commit=$commit release=v$release by=$deployer duration=${total_duration}s text=\"${deploy_text//$'\n'/ }\"" >> "$deploy_log"

    if [[ $st_failed -ne 0 ]]; then
        return 1
    fi
}

_fly_snapshots() {
    echo "=== DB Backups ==="
    local backup_output
    backup_output=$(fly mpg backup list "$FLY_DB_CLUSTER" --json 2>/dev/null | jq -r 'sort_by(.start) | reverse | .[] | "  \(.id // "?")  \(.start // "unknown")  type=\(.type // "?")  status=\(.status // "?")"' 2>/dev/null || true)
    if [[ -z "$backup_output" ]]; then
        echo "  No backups found."
    else
        echo "$backup_output"
    fi
}

_fly_rollback() {
    local dry_run=""
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=true
        shift
    fi

    local total_start=$SECONDS
    echo ""
    if [[ -n "$dry_run" ]]; then
        echo "=== Rollback (dry-run) ==="
    else
        echo "=== Rollback ==="
    fi

    if ! _fly_auth_check; then
        echo ""
        echo "✗ rollback aborted — fix issues above and retry"
        return 1
    fi

    # ── Step 1: Pick deploy point ─────────────────────────────────
    local step_start=$SECONDS
    echo ""
    echo "[1/5] Pick deploy to restore"
    git -C "$PROJECT_ROOT" fetch origin --tags 2>/dev/null
    local tags
    tags=$(git -C "$PROJECT_ROOT" tag -l 'deploy/v*' --sort=-creatordate --format='%(refname:short)|%(contents:subject)')
    if [[ -z "$tags" ]]; then
        echo "  ✗ no deploy tags found"
        return 1
    fi

    local i=1
    while IFS='|' read -r tag annotation; do
        printf "  %2d) %s  %s\n" "$i" "$tag" "$annotation"
        ((i++))
    done < <(printf '%s\n' "$tags")
    echo ""
    read -rp "  Pick a tag [1-$((i-1))]: " choice
    local chosen
    chosen=$(echo "$tags" | sed -n "${choice}p" | cut -d'|' -f1)
    if [[ -z "$chosen" ]]; then
        echo "  ✗ invalid choice"
        return 1
    fi
    echo "  ✓ selected $chosen"

    # ── Check for duplicate rollback ──────────────────────────────
    local last_rollback
    last_rollback=$(git -C "$PROJECT_ROOT" tag -l 'rollback/v*' --sort=-creatordate --format='%(contents:subject)' 2>/dev/null | head -1)
    if [[ "$last_rollback" == *"from: $chosen"* ]]; then
        echo ""
        echo "  ✓ already rolled back to $chosen — nothing to do"
        echo ""
        echo "=== Already on $chosen ($((SECONDS - total_start))s) ==="
        return 0
    fi

    local chosen_annotation
    chosen_annotation=$(git -C "$PROJECT_ROOT" tag -l "$chosen" --format='%(contents:subject)' 2>/dev/null)

    local chosen_release
    chosen_release=$(echo "$chosen_annotation" | grep -o 'release: v[0-9]*' | grep -o '[0-9]*')

    local backup_id
    backup_id=$(echo "$chosen_annotation" | grep -o 'backup: [^ |]*' | cut -d' ' -f2)
    if [[ -z "$backup_id" ]]; then
        echo "  ✗ could not read backup ID from $chosen"
        return 1
    fi

    local current_tag
    current_tag=$(echo "$tags" | head -1 | cut -d'|' -f1)

    local chosen_label
    chosen_label="$chosen"
    if [[ -n "$chosen_release" ]]; then
        chosen_label="$chosen (release v$chosen_release, backup $backup_id)"
    fi

    if [[ -z "$dry_run" ]]; then
        _confirm_live "Rollback

    Current:   $current_tag  (https://${FLY_APP}.fly.dev)
    Rolling back to:
               $chosen_label

    This will restore the database to $chosen's point
    in time (data created after that backup will be
    lost) and deploy release v$chosen_release. The live
    production server at https://${FLY_APP}.fly.dev will
    be updated — active users will be affected." || return 1
    fi
    echo "  ⏱  $((SECONDS - step_start))s"

    # ── Step 2: Restore database ──────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[2/5] Restore database"
    echo "  Backup:   $backup_id"
    if [[ -n "$dry_run" ]]; then
        echo "  (dry-run) would restore from backup: $backup_id"
        echo "  ✓ validation passed"
        echo "  ⏱  $((SECONDS - step_start))s"
    else
    echo "  WARNING: this creates a new database cluster"
    if [[ $DEPLOY_FORCE -eq 1 ]]; then
        echo "  --force: skipping confirmation"
    else
        read -rp "  Continue? [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "  ✗ aborted"
            return 1
        fi
    fi
    echo "  → restoring..."
    local restore_out
    restore_out=$(fly mpg restore "$FLY_DB_CLUSTER" --backup-id "$backup_id" 2>&1 || true)
    local new_cluster
    new_cluster=$(echo "$restore_out" | grep -o 'Cluster ID: [^ ]*' | awk '{print $NF}')
    if [[ -z "$new_cluster" ]]; then
        echo "  ✗ could not determine new cluster ID"
        echo "  output: $restore_out"
        return 1
    fi
    echo "  ✓ new cluster: $new_cluster"
    echo "  → waiting for cluster to be ready..."
    local waited=0
    while [[ $waited -lt 1800 ]]; do
        local cs
        cs=$(fly mpg status "$new_cluster" --json 2>/dev/null | jq -r '.data.status // "?"' 2>/dev/null || true)
        if [[ "$cs" == "ready" ]]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
        echo "    ... still $cs (${waited}s)"
    done
    if [[ "$cs" != "ready" ]]; then
        echo "  ✗ cluster did not become ready within 30 minutes"
        return 1
    fi

    local creds
    creds=$(fly mpg status "$new_cluster" --json 2>/dev/null || true)
    local db_url
    db_url=$(echo "$creds" | jq -r '.credentials.pgbouncer_uri + "?sslmode=disable"' 2>/dev/null)
    if [[ -z "$db_url" ]]; then
        echo "  ✗ could not get connection string"
        return 1
    fi
    echo "  ⏱  $((SECONDS - step_start))s"
    fi

    # ── Step 3: Update DATABASE_URL ───────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[3/5] Update DATABASE_URL"
    if [[ -n "$dry_run" ]]; then
        echo "  (dry-run) would update DATABASE_URL with restored cluster"
        echo "  ✓ connection string would be replaced"
        echo "  ⏱  $((SECONDS - step_start))s"
    else
    echo "  → updating secret..."
    if ! fly secrets set --app "$FLY_APP" DATABASE_URL="$db_url"; then
        echo "  ✗ could not update DATABASE_URL secret on Fly"
        return 1
    fi
    echo "  ✓ DATABASE_URL updated"
    echo "  ⏱  $((SECONDS - step_start))s"
    fi

    # ── Step 4: Deploy old app version ────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[4/5] Deploy app"
    local release_ver="$chosen_release"
    if [[ -z "$release_ver" ]]; then
        echo "  ✗ could not read release version from $chosen"
        return 1
    fi
    local image
    image=$(fly releases --app "$FLY_APP" --image --json 2>/dev/null | jq -r --arg ver "$release_ver" 'map(select(.Version == ($ver | tonumber))) | first.ImageRef // ""' 2>/dev/null || true)
    if [[ -z "$image" ]]; then
        echo "  ✗ could not find image for release v$release_ver"
        return 1
    fi
    if [[ -n "$dry_run" ]]; then
        echo "  (dry-run) would deploy release v$release_ver"
        echo "  ✓ image found: $image"
        echo "  ⏱  $((SECONDS - step_start))s"
    else
    echo "  → deploying release v$release_ver ($image)..."
    local _rb_deploy_out="$PROJECT_ROOT/.watch/deploy-rollback.log"
    local _rb_deploy_filter='(^#[0-9]+ DONE|^#[0-9]+ \[.*RUN|^==>|Validating|--> Build|image size:|Updating existing|✓|✔|Visit your|✗|[Ee]rror|[Ff]ail)'
    mkdir -p "$(dirname "$_rb_deploy_out")"
    if fly deploy --app "$FLY_APP" --image "$image" 2>&1 | tee "$_rb_deploy_out" | grep --line-buffered -E "$_rb_deploy_filter"; then
        _rb_deploy_rc=0
    else
        _rb_deploy_rc=${PIPESTATUS[0]}
    fi
    if [[ $_rb_deploy_rc -ne 0 ]]; then
        echo "✗ Rollback deploy failed (exit $_rb_deploy_rc). Full log: $_rb_deploy_out"
        return 1
    fi
    echo "  ✓ deployed release v$release_ver"
    echo "  ⏱  $((SECONDS - step_start))s"
    fi

    # ── Step 5: Health check ─────────────────────────────────────
    step_start=$SECONDS
    echo ""
    echo "[5/5] Health check"
    if [[ -n "$dry_run" ]]; then
        echo "  (dry-run) would call /api/health after deploy settles"
        echo "  ⏱  $((SECONDS - step_start))s"
    else
    echo "  → waiting for deploy to settle..."
    sleep 3
    local health_json
    health_json=$(curl -s --max-time 10 "https://${FLY_APP}.fly.dev/api/health" 2>/dev/null || echo '{"status":"unreachable"}')
    _print_health "$health_json"
    echo "  ⏱  $((SECONDS - step_start))s"
    fi

    # ── Record rollback ───────────────────────────────────────────
    if [[ -n "$dry_run" ]]; then
        echo ""
        echo "=== Dry-run complete: would roll back to $chosen ($((SECONDS - total_start))s) ==="
        echo "  (no changes made)"
        echo "  To align your codebase:  git checkout $chosen"
    else
    local rb_count
    rb_count=$(git -C "$PROJECT_ROOT" tag -l 'rollback/v*' | wc -l | xargs)
    local rb_tag="rollback/v$((rb_count + 1))"
    local commit
    commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
    git -C "$PROJECT_ROOT" tag -a "$rb_tag" -m "from: $chosen | cluster: $new_cluster | backup: $backup_id | commit: $commit"
    git -C "$PROJECT_ROOT" push origin "$rb_tag"

    echo ""
    echo "=== Rollback complete: $chosen → $rb_tag ($((SECONDS - total_start))s) ==="
    echo "  New DB cluster:  $new_cluster"
    echo "  App release:     v$release_ver"
    echo "  Rollback tag:    $rb_tag"
    echo ""
    echo "  To align your codebase with the running app:"
    echo "    git checkout $chosen"
    fi
}

_fly_ci_setup() {
    echo "=== Fly.io ==="
    if ! fly auth whoami &>/dev/null; then
        echo "Not logged into Fly.io. Run: fly auth login"
        return 1
    fi
    echo "  Authenticated"

    echo ""
    echo "=== GitHub CLI ==="
    if ! gh auth status &>/dev/null; then
        echo "Not logged into GitHub. Run: gh auth login"
        return 1
    fi
    echo "  Authenticated"

    _confirm_live "CI Setup

    Affects:   Fly deploy pipeline + GitHub Actions
               ($GITHUB_REPO)

    This will revoke all existing deploy tokens for
    ${FLY_APP} (existing CI jobs will fail), create a new
    deploy token, and overwrite GitHub secrets/variables
    FLY_API_TOKEN, FLY_APP, and FLY_DB_CLUSTER." || return 1

    echo ""
    echo "=== Revoke old deploy tokens ==="
    local old_tokens
    old_tokens=$(fly tokens list -a "$FLY_APP" 2>/dev/null | awk -F'│' -v name="github-actions-deploy" '$0 ~ name {gsub(/ /, "", $1); print $1}' || true)
    if [[ -n "$old_tokens" ]]; then
        while read -r tid; do
            [[ -z "$tid" ]] && continue
            echo "  Revoking $tid..."
            fly tokens revoke "$tid" 2>&1 || true
        done <<< "$old_tokens"
    else
        echo "  None found"
    fi

    echo ""
    echo "=== Create Fly deploy token ==="
    local token_json
    token_json=$(fly tokens create deploy --app "$FLY_APP" --name "github-actions-deploy" --json 2>&1 || true)
    local token
    token=$(echo "$token_json" | jq -r '.token' 2>/dev/null)
    if [[ -z "$token" ]]; then
        echo "  Failed to create deploy token."
        echo "  Raw output: $token_json"
        return 1
    fi
    echo "  Created"

    echo ""
    echo "=== Set GitHub secrets ==="
    gh secret set FLY_API_TOKEN --body "$token" --repo $GITHUB_REPO
    echo "  FLY_API_TOKEN set"

    echo ""
    echo "=== Set GitHub variables ==="
    gh variable set FLY_APP --body "$FLY_APP" --repo $GITHUB_REPO
    gh variable set FLY_DB_CLUSTER --body "$FLY_DB_CLUSTER" --repo $GITHUB_REPO
    echo "  FLY_APP=$FLY_APP"
    echo "  FLY_DB_CLUSTER=$FLY_DB_CLUSTER"

    echo ""
    echo "=== Setup complete ==="
    echo "GitHub Actions will trigger on: git push origin 'deploy/v*'"
}

_fly_logs() {
    if [[ "${1:-}" == "tail" ]]; then
        local lines="${2:-10}"
        fly logs --app "$FLY_APP" --no-tail 2>&1 | tail -n "$lines" || { echo "✗ fly logs failed"; return 1; }
        echo "--- live ---"
        fly logs --app "$FLY_APP" 2>&1 | tail -n 0 -f || { echo "✗ fly logs stream ended with an error"; return 1; }
    else
        local lines="${1:-10}"
        fly logs --app "$FLY_APP" --no-tail 2>&1 | tail -n "$lines" || { echo "✗ fly logs failed"; return 1; }
    fi
}

_fly_deployments() {
    echo ""
    echo "=== Deploy Tags ==="
    git -C "$PROJECT_ROOT" fetch origin --tags 2>/dev/null
    local tags
    tags=$(git -C "$PROJECT_ROOT" tag -l 'deploy/v*' --sort=-creatordate --format='%(refname:short)|%(contents:subject)' 2>/dev/null)
    if [[ -z "$tags" ]]; then
        echo "  (none)"
        return 0
    fi
    while IFS='|' read -r tname tinfo; do
        [[ -z "$tname" ]] && continue
        local marker=" "
        if [[ -n "$(git -C "$PROJECT_ROOT" tag --points-at HEAD --list "$tname" 2>/dev/null)" ]]; then
            marker="→"
        fi
        printf "  %s %-14s %s\n" "$marker" "$tname" "$tinfo"
    done <<< "$tags"

    local rb_tags
    rb_tags=$(git -C "$PROJECT_ROOT" tag -l 'rollback/v*' --sort=-creatordate --format='%(refname:short)|%(contents:subject)' 2>/dev/null)
    if [[ -n "$rb_tags" ]]; then
        echo ""
        echo "=== Rollbacks ==="
        while IFS='|' read -r tname tinfo; do
            [[ -z "$tname" ]] && continue
            printf "  %-14s %s\n" "$tname" "$tinfo"
        done <<< "$rb_tags"
    fi
}

_fly_releases() {
    fly releases --app "$FLY_APP" || { echo "✗ fly releases failed — check Fly.io authentication with: fly auth login"; return 1; }
}

_fly_machines() {
    fly machine list --app "$FLY_APP" || { echo "✗ fly machine list failed — check Fly.io authentication with: fly auth login"; return 1; }
}
