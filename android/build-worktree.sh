#!/bin/bash
# android-toolkit/build-worktree.sh: package worktrees of the repository the project sits in
# Sourced by build.sh. A worktree gets branch <prefix><package> from the main
# checkout's current branch, its submodules cloned from the main checkout's
# own submodule folders without network, and the project's gitignored local
# files copied over. The project may be a folder of a larger repository
# (android/ in Turn); the worktree is of the whole repository.
#
# Provides: _worktree_root, do_worktree
# Depends on: _main_checkout (build-overnight.sh)

_worktree_usage() {
    cat <<'EOF'
Usage: ./build.sh android worktree new <package> [--from <ref>]
       ./build.sh android worktree remove <package> [--force]
       ./build.sh android worktree list

  new       Make <worktrees>/<package>, a worktree of the whole repository, on a
            new branch pkg/<package> from the main checkout's current branch (or
            --from <ref>). Each submodule (toolkit/) is cloned from the main
            checkout's own folder, at the commit the branch pins, without
            network. The project's local.properties and build.properties.local
            are copied over. Prints the worktree's root last; run ./build.sh there.
  remove    Remove the worktree and delete its branch. Refuses when the worktree
            has uncommitted changes or its branch isn't merged into the main
            checkout's branch; --force removes it anyway and keeps the branch.
  list      The package worktrees and their branches.

  Worktrees live in TOOLKIT_WORKTREE_DIR (default: <checkout>-<project folder>-work,
  for example /Users/christian/projects/turn-android-work). Branches are
  TOOLKIT_WORKTREE_BRANCH_PREFIX (default pkg/) plus the package name.
  TOOLKIT_WORKTREE_COPY lists the local files to copy.
EOF
}

# The project's folder inside its repository ("android/"), empty at the top.
_worktree_project_dir() {
    git -C "$PROJECT_ROOT" rev-parse --show-prefix 2>/dev/null || true
}

_worktree_root() {
    if [[ -n "${TOOLKIT_WORKTREE_DIR:-}" ]]; then
        echo "$TOOLKIT_WORKTREE_DIR"
        return 0
    fi
    local main parent folder
    main=$(_main_checkout)
    folder=$(_worktree_project_dir)
    folder=${folder%/}
    if [[ -n "$folder" ]]; then
        echo "$main-${folder//\//-}-work"
        return 0
    fi
    parent=$(dirname "$main")
    echo "$(dirname "$parent")/$(basename "$parent")-$(basename "$main")-work"
}

_worktree_branch() {
    echo "${TOOLKIT_WORKTREE_BRANCH_PREFIX:-pkg/}$1"
}

_worktree_check_name() {
    if ! [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
        echo "✗ Package names are lower case letters, digits, '.', '_' and '-': '$1'"
        return 1
    fi
}

_worktree_is_registered() {
    git -C "$(_main_checkout)" worktree list --porcelain | grep -qxF "worktree $1"
}

_worktree_new() {
    local package="" from=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="${2:-}"; shift 2 ;;
            -*) echo "✗ Unknown option: $1"; return 1 ;;
            *) package="$1"; shift ;;
        esac
    done
    [[ -n "$package" ]] || { _worktree_usage; return 1; }
    _worktree_check_name "$package" || return 1

    local main root path branch
    main=$(_main_checkout)
    root=$(_worktree_root)
    path="$root/$package"
    branch=$(_worktree_branch "$package")
    [[ -n "$from" ]] || from=$(git -C "$main" symbolic-ref --short HEAD)

    if [[ -e "$path" ]]; then
        echo "✗ $path exists already."
        return 1
    fi
    if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "✗ Branch $branch exists already. Remove it first, or use another name (a second attempt: $package-2)."
        return 1
    fi
    if [[ -n "$(_night_flag disk)" ]]; then
        echo "✗ The disk is low (down/disk is set); no new worktrees."
        return 1
    fi

    mkdir -p "$root"
    echo "→ Creating $path on $branch from $from"
    if ! git -C "$main" worktree add -q -b "$branch" "$path" "$from" 2>&1 | sed 's/^/  /'; then
        echo "✗ git worktree add failed."
        return 1
    fi
    [[ -d "$path" ]] || { echo "✗ git worktree add failed."; return 1; }

    if [[ -f "$path/.gitmodules" ]]; then
        local out key sub name
        local -a urls=()
        # Clone each submodule from the main checkout's folder, never from its remote.
        while read -r key sub; do
            [[ -n "$sub" ]] || continue
            name=${key#submodule.}
            name=${name%.path}
            if [[ -e "$main/$sub/.git" ]]; then
                urls+=(-c "submodule.$name.url=$main/$sub")
            fi
        done < <(git -C "$path" config -f .gitmodules --get-regexp '\.path$' || true)
        if ! out=$(git -C "$path" -c protocol.file.allow=always ${urls[@]+"${urls[@]}"} submodule update --init --quiet 2>&1); then
            echo "✗ Submodules could not be filled from the main checkout:"
            sed 's/^/  /' <<<"$out"
            return 1
        fi
        while read -r _ sub; do
            [[ -n "$sub" ]] || continue
            local pinned mine
            pinned=$(git -C "$path/$sub" rev-parse --short HEAD 2>/dev/null || echo "?")
            mine=$(git -C "$main/$sub" rev-parse --short HEAD 2>/dev/null || echo "?")
            echo "  $sub/ at $pinned"
            if [[ "$pinned" != "$mine" ]]; then
                echo "⚠ $main/$sub is at $mine, but $from pins $pinned. Commit the new $sub/ pointer in the main checkout to pass it on."
            fi
        done < <(git -C "$path" config -f .gitmodules --get-regexp '\.path$' || true)
    fi

    local file folder
    folder=$(_worktree_project_dir)
    for file in ${TOOLKIT_WORKTREE_COPY:-local.properties build.properties.local}; do
        if [[ -f "$main/$folder$file" ]]; then
            cp "$main/$folder$file" "$path/$folder$file"
            echo "  copied $folder$file"
        fi
    done

    echo "✓ Worktree ready on $branch ($(git -C "$path" rev-parse --short HEAD))"
    echo "$path"
}

_worktree_remove() {
    local package="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            -*) echo "✗ Unknown option: $1"; return 1 ;;
            *) package="$1"; shift ;;
        esac
    done
    [[ -n "$package" ]] || { _worktree_usage; return 1; }
    _worktree_check_name "$package" || return 1

    local main path branch base
    main=$(_main_checkout)
    path="$(_worktree_root)/$package"
    branch=$(_worktree_branch "$package")
    base=$(git -C "$main" symbolic-ref --short HEAD)
    if [[ "$path" == "$main" ]] || ! _worktree_is_registered "$path"; then
        echo "✗ $path is not a package worktree."
        return 1
    fi

    if ! $force; then
        local dirty
        dirty=$(git -C "$path" status --porcelain --ignore-submodules=none 2>/dev/null || true)
        if [[ -n "$dirty" ]]; then
            echo "✗ $path has uncommitted changes:"
            head -20 <<<"$dirty" | sed 's/^/  /'
            echo "  Commit them, or remove with --force (keeps the branch)."
            return 1
        fi
        if ! git -C "$main" merge-base --is-ancestor "$branch" "$base"; then
            echo "✗ $branch is not merged into $base ($(git -C "$main" rev-list --count "$base..$branch") commit(s) ahead)."
            echo "  Merge it first, or remove with --force (keeps the branch)."
            return 1
        fi
    fi

    git -C "$path" submodule deinit --all --force --quiet >/dev/null 2>&1 || true
    if ! git -C "$main" worktree remove --force "$path"; then
        echo "✗ git worktree remove failed."
        return 1
    fi
    git -C "$main" worktree prune
    if $force; then
        echo "✓ Worktree removed; branch $branch kept"
    elif git -C "$main" branch -q -d "$branch"; then
        echo "✓ Worktree removed and $branch deleted (merged into $base)"
    else
        echo "⚠ Worktree removed; git kept $branch"
    fi
}

_worktree_list() {
    local root
    root=$(_worktree_root)
    git -C "$(_main_checkout)" worktree list | while read -r path sha branch; do
        [[ "$path" == "$root"/* ]] || continue
        echo "  $(basename "$path")  $branch  $sha"
    done
}

do_worktree() {
    case "${1:-}" in
        new) shift; _worktree_new "$@" ;;
        remove) shift; _worktree_remove "$@" ;;
        list) _worktree_list ;;
        ""|help|-h|--help) _worktree_usage ;;
        *) echo "✗ Unknown worktree command: $1"; _worktree_usage; return 1 ;;
    esac
}
