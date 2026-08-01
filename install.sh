#!/bin/bash
set -euo pipefail

# toolkit/install.sh — scaffold a project against the toolkit monorepo.
# Usage: toolkit/install.sh [project-dir]
# Idempotent: detects platforms, mounts the submodule (only if absent), generates
# build.sh entries + seeds config (only if missing), then runs each platform setup.
# External services are configured later via <platform>/build.sh configure.

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
MOUNT="toolkit"

say()  { echo "→ $*"; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*"; }

# ── Platform detection ──────────────────────────────────────────────

detect_platforms() {
    local platforms=()
    if [[ -f "$PROJECT_DIR/project.yml" || -n "$(ls -d "$PROJECT_DIR"/*.xcodeproj 2>/dev/null | head -1)" ]]; then
        platforms+=("ios-root")
    fi
    if [[ -f "$PROJECT_DIR/ios/project.yml" || -n "$(ls -d "$PROJECT_DIR"/ios/*.xcodeproj 2>/dev/null | head -1)" ]]; then
        platforms+=("ios")
    fi
    [[ -f "$PROJECT_DIR/server/go.mod" ]] && platforms+=("server")
    [[ -f "$PROJECT_DIR/android/build.gradle" || -f "$PROJECT_DIR/android/build.gradle.kts" ]] && platforms+=("android")
    [[ -f "$PROJECT_DIR/web/package.json" ]] && platforms+=("web")
    echo "${platforms[@]}"
}

platform_dir() {
    case "$1" in
        ios-root) echo "." ;;
        *) echo "$1" ;;
    esac
}

# ── Mounting ────────────────────────────────────────────────────────

mount_toolkit() {
    if [[ -e "$PROJECT_DIR/$MOUNT/.git" && -f "$PROJECT_DIR/$MOUNT/ios/build.sh" ]]; then
        ok "toolkit already mounted at $MOUNT/"
        return 0
    fi
    if [[ -d "$PROJECT_DIR/$MOUNT" && -n "$(ls -A "$PROJECT_DIR/$MOUNT" 2>/dev/null)" ]]; then
        warn "$MOUNT/ exists and is not empty — refusing to overwrite."
        warn "Move it aside or remove it, then re-run."
        exit 1
    fi
    if [[ ! -d "$PROJECT_DIR/.git" ]]; then
        warn "Not a git repository — copying instead of submoduling."
        cp -R "$TOOLKIT_DIR" "$PROJECT_DIR/$MOUNT"
        rm -rf "$PROJECT_DIR/$MOUNT/.git"
        ok "toolkit copied to $MOUNT/"
        return 0
    fi
    git -C "$PROJECT_DIR" submodule add "$TOOLKIT_DIR" "$MOUNT" >/dev/null 2>&1
    ok "toolkit mounted as submodule at $MOUNT/"
}

# ── Entry generation ────────────────────────────────────────────────

gen_platform_entry() {
    local platform="$1"
    local dir="$PROJECT_DIR/$(platform_dir "$platform")"
    local rel_toolkit
    if [[ "$platform" == "ios-root" ]]; then
        rel_toolkit="$MOUNT/ios/build.sh"
    else
        rel_toolkit="../$MOUNT/$platform/build.sh"
    fi
    local entry="$dir/build.sh"
    if [[ -f "$entry" ]]; then
        ok "build.sh already present in $(platform_dir "$platform")/ (kept)"
        return 0
    fi
    if [[ "$platform" == "ios" || "$platform" == "ios-root" || -f "$TOOLKIT_DIR/$platform/build.sh" ]]; then
        cat > "$entry" <<EOF
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export TOOLKIT_PROJECT_ROOT="\$SCRIPT_DIR"
source "\$SCRIPT_DIR/$rel_toolkit"
_dispatch "\$@"
EOF
        chmod +x "$entry"
        ok "generated $(platform_dir "$platform")/build.sh → $rel_toolkit"
    else
        cat > "$entry" <<EOF
#!/bin/bash
set -euo pipefail
echo "✗ toolkit/$platform is not available yet (planned)."
exit 1
EOF
        chmod +x "$entry"
        warn "generated placeholder $(platform_dir "$platform")/build.sh ($platform toolkit not available yet)"
    fi
}

gen_aggregator() {
    local platforms=("$@")
    local entry="$PROJECT_DIR/build.sh"
    if [[ -f "$entry" ]]; then
        ok "root build.sh already present (kept)"
        return 0
    fi
    cat > "$entry" <<EOF
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
usage() {
    cat <<USAGE
Usage: ./build.sh <target> <command>
Targets: $(printf '%s ' "${platforms[@]}")
USAGE
}
case "\${1:-}" in
$(for p in "${platforms[@]}"; do
    d=$(platform_dir "$p")
    if [[ "$p" == "ios-root" ]]; then
        echo "    *) usage ;;"
    else
        echo "    $p)"
        echo "        shift"
        echo "        cd \"\$SCRIPT_DIR/$d\" && exec ./build.sh \"\$@\""
        echo "        ;;"
    fi
done)
    *) usage ;;
esac
EOF
    chmod +x "$entry"
    ok "generated multi-platform root build.sh (targets: $(printf '%s ' "${platforms[@]}"))"
}

gen_single_entry() {
    local entry="$PROJECT_DIR/build.sh"
    if [[ -f "$entry" ]]; then
        ok "root build.sh already present (kept)"
        return 0
    fi
    cat > "$entry" <<EOF
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export TOOLKIT_PROJECT_ROOT="\$SCRIPT_DIR"
source "\$SCRIPT_DIR/$MOUNT/ios/build.sh"
_dispatch "\$@"
EOF
    chmod +x "$entry"
    ok "generated root build.sh → $MOUNT/ios/build.sh"
}

# ── Config seeding ──────────────────────────────────────────────────

seed_config() {
    local platform="$1"
    local dir="$PROJECT_DIR/$(platform_dir "$platform")"
    local cfg="$TOOLKIT_DIR/$platform/config"
    [[ -d "$cfg" ]] || return 0
    if [[ ! -f "$dir/build.properties" ]]; then
        if [[ -f "$cfg/build.properties.example" ]]; then
            cp "$cfg/build.properties.example" "$dir/build.properties"
            ok "created build.properties in $(platform_dir "$platform")/"
        fi
    fi
    for f in .swiftlint.yml .swiftformat .periphery.yml; do
        if [[ -f "$cfg/$f" && ! -f "$dir/$f" ]]; then
            cp "$cfg/$f" "$dir/$f"
            ok "seeded $f in $(platform_dir "$platform")/"
        fi
    done
}

# ── Main ────────────────────────────────────────────────────────────

main() {
    say "Installing toolkit into $PROJECT_DIR"
    echo ""
    local platforms=($(detect_platforms))
    if [[ ${#platforms[@]} -eq 0 ]]; then
        echo "✗ No platforms detected."
        echo "  Detected: ios (project.yml/*.xcodeproj), server (go.mod), android (build.gradle), web (package.json)."
        exit 1
    fi

    echo "Detected platforms: ${platforms[*]}"
    if [[ -t 0 ]]; then
        read -rp "Proceed with these platforms? [Y/n]: " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
    echo ""

    mount_toolkit
    echo ""

    if [[ ${#platforms[@]} -eq 1 && "${platforms[0]}" == "ios-root" ]]; then
        gen_single_entry
    else
        gen_aggregator "${platforms[@]}"
        for p in "${platforms[@]}"; do
            [[ "$p" == "ios-root" ]] && continue
            gen_platform_entry "$p"
        done
    fi
    echo ""

    for p in "${platforms[@]}"; do
        seed_config "$p"
    done
    echo ""

    for p in "${platforms[@]}"; do
        local d
        d="$PROJECT_DIR/$(platform_dir "$p")"
        say "Running setup for $p ..."
        (cd "$d" && ./build.sh setup) || warn "setup for $p reported problems (see above)"
    done
    echo ""
    ok "Install complete. Configure external services per platform with: ./build.sh configure"
}

main "$@"
