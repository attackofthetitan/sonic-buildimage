#!/usr/bin/env bash

# Prepare AG9032v1 refresh/build candidates, preview an upstream replay, and
# print a guarded promotion. Rebase/cherry-pick rewrite disposable local
# candidates; the script never pushes, promotes, or deletes refs.

set -euo pipefail

readonly INTEGRATION="integration/ag9032v1"
readonly REFRESH="refresh/ag9032v1"
readonly BUILD="build/ag9032v1"
readonly PROMOTE="promote/master"
readonly MAINTENANCE="maintenance/fork"
readonly LOCAL_PROFILE="local/ag9032v1-build-profile"
readonly PLATFORM_DIR="device/delta/x86_64-delta_ag9032v1-r0"
readonly STATE_VERSION=5
# Exactly the paths the consolidated maintenance commit changes.
readonly -a MAINTENANCE_FILES=(
    .github/workflows/protect-file.yml
    .github/workflows/upstream-drift.yml
    FORK_MAINTENANCE.md
    scripts/build-ag9032v1.sh
    scripts/fork-refresh-ag9032v1.sh
)

mode=prepare
fetch=1
pause_after_rebase=0
local_profile=""
allow_default_password=0
password_warning_emitted=0
phase=""
old_local_profile_sha=""
local_profile_sha=""
maintenance_sha="absent"
prepared_refresh_sha=""
prepared_build_sha=""
replay_index=""
replay_tip=""
replay_result=""
replay_conflict_paths=()

usage() {
    cat <<'EOF'
Usage:
  scripts/fork-refresh-ag9032v1.sh [--no-fetch] [--local-profile REV] [--allow-default-password] [--pause-after-rebase]
  scripts/fork-refresh-ag9032v1.sh --resume [--no-fetch] [--local-profile REV]
  scripts/fork-refresh-ag9032v1.sh --check [--no-fetch]
  scripts/fork-refresh-ag9032v1.sh --print-promotion [--no-fetch]

The default mode archives the reviewed remote tips, rebases the entire
integration stack onto upstream/master, prints a range-diff, and creates a
local build candidate. These operations create/rewrite local candidate commits.
A completed state whose candidate was already promoted is preserved and moved
aside automatically.
--pause-after-rebase stops after a clean rebase so reusable commits can be
added or adapted on refresh/ag9032v1 before --resume.
--resume finishes after manually resolved conflicts or a pause.
--check replays the stack, maintenance commit, and local profile onto
upstream/master in a private index and prints a Markdown report. It changes no
refs, worktree files, or saved state. Exit status 2 means attention is needed.
--allow-default-password explicitly approves a local profile which embeds a
DEFAULT_PASSWORD change. The approval is saved with the sealed candidate.
--print-promotion validates candidates and prints, but never runs, an atomic
force-with-lease push command.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

parse_args() {
    while (($#)); do
        case "$1" in
            --resume|--check|--print-promotion)
                [[ "$mode" == prepare ]] || die "choose only one mode"
                mode="${1#--}"
                ;;
            --local-profile)
                shift
                (($#)) || die "--local-profile requires a revision"
                local_profile="$1"
                ;;
            --allow-default-password) allow_default_password=1 ;;
            --pause-after-rebase) pause_after_rebase=1 ;;
            --no-fetch) fetch=0 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done

    [[ -z "$local_profile" || "$mode" == prepare || "$mode" == resume ]] ||
        die "--local-profile is valid only when preparing or resuming"
    [[ "$allow_default_password" == 0 || "$mode" == prepare ]] ||
        die "--allow-default-password is valid only when preparing candidates"
    [[ "$pause_after_rebase" == 0 || "$mode" == prepare ]] ||
        die "--pause-after-rebase is valid only when preparing candidates"
}

url_is() {
    local url="$1" slug="$2"
    case "$url" in
        "https://github.com/$slug"|"https://github.com/$slug.git"|\
        "git@github.com:$slug"|"git@github.com:$slug.git"|\
        "ssh://git@github.com/$slug"|"ssh://git@github.com/$slug.git") return 0 ;;
        *) return 1 ;;
    esac
}

remote_urls_are() {
    local remote="$1" direction="$2" slug="$3" url
    local -a urls=()
    if [[ "$direction" == push ]]; then
        mapfile -t urls < <(git remote get-url --push --all "$remote" 2>/dev/null)
    else
        mapfile -t urls < <(git remote get-url --all "$remote" 2>/dev/null)
    fi
    ((${#urls[@]})) || die "missing $remote $direction URL"
    for url in "${urls[@]}"; do
        url_is "$url" "$slug" || die "unexpected $remote $direction URL: $url"
    done
}

preflight() {
    root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
        die "run inside sonic-buildimage"
    cd "$root"
    git_dir="$(git rev-parse --git-dir)"
    git_common_dir="$(git rev-parse --git-common-dir)"
    state_file="$git_common_dir/fork-refresh-ag9032v1.state"

    if [[ "$mode" == prepare || "$mode" == resume ]]; then
        local clean
        clean="$(git status --porcelain=v1 --untracked-files=all)"
        [[ -z "$clean" ]] || {
            printf '%s\n' "$clean" >&2
            die "worktree is not clean; run the helper from the dedicated maintenance worktree"
        }
    fi
    if [[ "$mode" != check ]]; then
        [[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] ||
            die "finish or abort the active rebase first"
        [[ ! -f "$git_dir/CHERRY_PICK_HEAD" ]] ||
            die "finish or abort the active cherry-pick first"
    fi

    remote_urls_are origin fetch "attackofthetitan/sonic-buildimage"
    remote_urls_are origin push "attackofthetitan/sonic-buildimage"
    remote_urls_are upstream fetch "sonic-net/sonic-buildimage"
    local -a upstream_push_urls=()
    mapfile -t upstream_push_urls < <(
        git remote get-url --push --all upstream 2>/dev/null
    )
    [[ "${#upstream_push_urls[@]}" == 1 && "${upstream_push_urls[0]}" == DISABLED ]] ||
        die "upstream push URL must be exactly DISABLED"

    if ((fetch)); then
        git fetch --prune upstream
        git fetch --prune origin
    else
        warn "--no-fetch uses possibly stale remote-tracking refs"
    fi
}

need_ref() {
    git show-ref --verify --quiet "$1" || die "missing required ref: $1"
}

commit_patch_id() {
    git show --format= --no-ext-diff "$1" |
        git patch-id --stable |
        awk 'NR == 1 { print $1; found = 1 } END { exit !found }'
}

range_patch_id() {
    git diff --no-ext-diff "$1" "$2" |
        git patch-id --stable |
        awk 'NR == 1 { print $1; found = 1 } END { exit !found }'
}

validate_profile_source() {
    local profile_sha="$1"
    [[ "$(git rev-list --parents -n1 "$profile_sha" | awk '{print NF - 1}')" == 1 ]] ||
        die "$LOCAL_PROFILE must be one non-merge commit"
    [[ "$(git diff-tree --no-commit-id --name-only -r "$profile_sha")" == rules/config ]] ||
        die "$LOCAL_PROFILE must be one commit changing only rules/config"
    if git diff --unified=0 "$profile_sha^" "$profile_sha" -- rules/config |
        grep -Eq '^[+-][[:space:]]*(export[[:space:]]+)?DEFAULT_PASSWORD[[:space:]]*(\?|\+|:)?='; then
        [[ "$allow_default_password" == 1 ]] ||
            die "$LOCAL_PROFILE changes DEFAULT_PASSWORD; review it and rerun prepare with --allow-default-password"
        if [[ "$password_warning_emitted" == 0 ]]; then
            warn "$LOCAL_PROFILE embeds DEFAULT_PASSWORD in Git and in every resulting image"
            password_warning_emitted=1
        fi
    fi
}

state_field() {
    awk -F= -v key="$1" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' \
        "$state_file"
}

read_state() {
    [[ -f "$state_file" ]] || die "no saved refresh state; run prepare mode first"
    state_version=""
    old_integration=""; old_master=""; upstream_sha=""; old_base=""
    integration_archive=""; master_archive=""; starting_branch=""; phase=""
    old_local_profile_sha=""; local_profile_sha=""; maintenance_sha=""
    allow_default_password=""
    prepared_refresh_sha=""; prepared_build_sha=""
    while IFS='=' read -r key value; do
        case "$key" in
            state_version|old_integration|old_master|upstream_sha|old_base|\
            integration_archive|master_archive|starting_branch|\
            old_local_profile_sha|local_profile_sha|maintenance_sha|\
            allow_default_password|\
            prepared_refresh_sha|prepared_build_sha|phase)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done <"$state_file"
    [[ "$state_version" == "$STATE_VERSION" ]] ||
        die "saved state is legacy or unsupported; preserve it, move it aside, and prepare a fresh hardware-tested candidate"
    for sha in "$old_integration" "$old_master" "$upstream_sha" "$old_base"; do
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "invalid saved SHA"
    done
    [[ "$old_local_profile_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved old local-profile SHA"
    [[ "$local_profile_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved local-profile SHA"
    [[ "$maintenance_sha" == absent || "$maintenance_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved maintenance SHA"
    [[ "$allow_default_password" == 0 || "$allow_default_password" == 1 ]] ||
        die "invalid saved default-password approval"
    case "$phase" in rebase|build|done) ;; *) die "invalid saved phase" ;; esac
    if [[ "$phase" == done ]]; then
        [[ "$prepared_refresh_sha" =~ ^[0-9a-f]{40}$ &&
           "$prepared_build_sha" =~ ^[0-9a-f]{40}$ ]] ||
            die "completed state is missing sealed candidate SHAs"
    else
        [[ -z "$prepared_refresh_sha" && -z "$prepared_build_sha" ]] ||
            die "incomplete state must not contain sealed candidate SHAs"
    fi
    git check-ref-format "refs/heads/$integration_archive" >/dev/null || die "invalid saved archive"
    git check-ref-format "refs/heads/$master_archive" >/dev/null || die "invalid saved archive"
    git check-ref-format --branch "$starting_branch" >/dev/null || die "invalid saved starting branch"
}

save_state() {
    local tmp="$state_file.tmp"
    (
        umask 077
        {
            printf 'state_version=%s\n' "$STATE_VERSION"
            printf 'old_integration=%s\n' "$old_integration"
            printf 'old_master=%s\n' "$old_master"
            printf 'upstream_sha=%s\n' "$upstream_sha"
            printf 'old_base=%s\n' "$old_base"
            printf 'integration_archive=%s\n' "$integration_archive"
            printf 'master_archive=%s\n' "$master_archive"
            printf 'starting_branch=%s\n' "$starting_branch"
            printf 'old_local_profile_sha=%s\n' "$old_local_profile_sha"
            printf 'local_profile_sha=%s\n' "$local_profile_sha"
            printf 'maintenance_sha=%s\n' "$maintenance_sha"
            printf 'allow_default_password=%s\n' "$allow_default_password"
            printf 'prepared_refresh_sha=%s\n' "$prepared_refresh_sha"
            printf 'prepared_build_sha=%s\n' "$prepared_build_sha"
            printf 'phase=%s\n' "$phase"
        } >"$tmp"
    )
    mv "$tmp" "$state_file"
}

# A completed state whose refresh candidate is already on the published
# integration branch has nothing left to promote. Preserve it under another
# name instead of asking for a manual move; any other state still blocks.
rotate_promoted_state() {
    [[ -e "$state_file" ]] || return 0
    local saved_refresh preserved
    saved_refresh="$(state_field prepared_refresh_sha)"
    if [[ "$(state_field phase)" == done && "$saved_refresh" =~ ^[0-9a-f]{40}$ ]] &&
        git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION" &&
        git merge-base --is-ancestor "$saved_refresh" "refs/remotes/origin/$INTEGRATION" 2>/dev/null; then
        preserved="$state_file.promoted-$(date -u +%Y%m%dT%H%M%SZ)"
        mv "$state_file" "$preserved"
        printf 'Preserved the promoted refresh state as %s\n' "$preserved"
        return 0
    fi
    die "saved refresh state is not promoted; resume it or preserve and move it aside before a fresh prepare"
}

resolve_refs() {
    need_ref "refs/remotes/origin/$INTEGRATION"
    need_ref refs/remotes/origin/master
    need_ref refs/remotes/upstream/master
    need_ref "refs/remotes/origin/$LOCAL_PROFILE"
    old_integration="$(git rev-parse "refs/remotes/origin/$INTEGRATION")"
    old_master="$(git rev-parse refs/remotes/origin/master)"
    upstream_sha="$(git rev-parse refs/remotes/upstream/master)"
    old_local_profile_sha="$(git rev-parse "refs/remotes/origin/$LOCAL_PROFILE")"
    local_profile_sha="$old_local_profile_sha"
    if git show-ref --verify --quiet "refs/remotes/origin/$MAINTENANCE"; then
        maintenance_sha="$(git rev-parse "refs/remotes/origin/$MAINTENANCE")"
    else
        maintenance_sha=absent
    fi
    old_base="$(git merge-base "$old_integration" "$upstream_sha")"
    [[ -n "$old_base" ]] || die "integration has no upstream merge base"
    ! git rev-list --min-parents=2 "$old_base..$old_integration" | grep -q . ||
        die "$INTEGRATION is not a linear stack"
    if [[ "$maintenance_sha" != absent ]]; then
        [[ "$(git rev-list --parents -n1 "$maintenance_sha" | awk '{print NF - 1}')" == 1 ]] ||
            die "$MAINTENANCE must be one non-merge commit"
    fi
}

validate_reviewed_inputs() {
    need_ref "refs/remotes/origin/$LOCAL_PROFILE"
    [[ "$(git rev-parse "refs/remotes/origin/$LOCAL_PROFILE")" == "$old_local_profile_sha" ]] ||
        die "origin/$LOCAL_PROFILE moved; start a new refresh"
    git cat-file -e "$local_profile_sha^{commit}" ||
        die "saved local-profile commit is missing"
    validate_profile_source "$local_profile_sha"
    if [[ "$maintenance_sha" == absent ]]; then
        ! git show-ref --verify --quiet "refs/remotes/origin/$MAINTENANCE" ||
            die "origin/$MAINTENANCE appeared; start a new refresh"
    else
        need_ref "refs/remotes/origin/$MAINTENANCE"
        [[ "$(git rev-parse "refs/remotes/origin/$MAINTENANCE")" == "$maintenance_sha" ]] ||
            die "origin/$MAINTENANCE moved; start a new refresh"
    fi
}

resolve_local_profile() {
    local cli_sha
    if [[ -n "$local_profile" ]]; then
        cli_sha="$(git rev-parse --verify "$local_profile^{commit}")" ||
            die "invalid local-profile revision: $local_profile"
        if [[ "$mode" == prepare ]]; then
            local_profile_sha="$cli_sha"
        elif [[ "$cli_sha" != "$local_profile_sha" ]]; then
            die "--local-profile does not match the revision saved during preparation"
        fi
    fi
    validate_profile_source "$local_profile_sha"
}

# Git refuses to reset a branch that another worktree has checked out. Stop
# before rewriting anything and say which worktree must detach first.
ensure_branches_free() {
    local line path="" branch here
    here="$(realpath "$root")"
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) path="${line#worktree }" ;;
            "branch refs/heads/"*)
                if [[ "$(realpath "$path")" != "$here" ]]; then
                    for branch in "$@"; do
                        if [[ "${line#branch refs/heads/}" == "$branch" ]]; then
                            die "$branch is checked out in $path; run: git -C '$path' switch --detach"
                        fi
                    done
                fi
                ;;
        esac
    done < <(git worktree list --porcelain)
    return 0
}

profile_is_applied() {
    git show-ref --verify --quiet "refs/heads/$BUILD" || return 1
    git merge-base --is-ancestor "refs/heads/$REFRESH" "refs/heads/$BUILD" || return 1
    local refresh_sha
    refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
    [[ "$(git rev-list --count "$refresh_sha..refs/heads/$BUILD")" == 1 ]] ||
        return 1
    [[ "$(git diff --name-only "$refresh_sha..refs/heads/$BUILD")" == rules/config ]] ||
        return 1
    local build_patch profile_patch
    build_patch="$(commit_patch_id "refs/heads/$BUILD")" || return 1
    profile_patch="$(commit_patch_id "$local_profile_sha")" || return 1
    [[ "$build_patch" == "$profile_patch" ]]
}

rebase_help() {
    cat >&2 <<EOF

No remote ref changed. Resolve with:
  git status
  git add <resolved-files>
  git rebase --continue
  # repeat, then return to the branch containing this helper and run:
  git switch $starting_branch
  bash scripts/fork-refresh-ag9032v1.sh --resume --no-fetch

Abort with:
  git rebase --abort
  git switch $starting_branch

Rollback refs: $integration_archive and $master_archive
EOF
}

pause_help() {
    cat >&2 <<EOF

Paused after a clean rebase; no remote ref changed. $REFRESH is checked out
here. Add or adapt reusable commits, keep the stack linear, then resume:
  git switch $starting_branch
  bash scripts/fork-refresh-ag9032v1.sh --resume --no-fetch
EOF
}

pick_help() {
    cat >&2 <<EOF

No remote ref changed. Resolve with git add and git cherry-pick --continue,
then return to the helper branch and resume:
  git switch $starting_branch
  bash scripts/fork-refresh-ag9032v1.sh --resume --no-fetch
Abort with git cherry-pick --abort. The candidate remains at $BUILD.
EOF
}

validate_refresh() {
    need_ref "refs/heads/$REFRESH"
    git merge-base --is-ancestor "$upstream_sha" "refs/heads/$REFRESH" ||
        die "$REFRESH is not based on the recorded upstream SHA"
    ! git rev-list --min-parents=2 "$upstream_sha..refs/heads/$REFRESH" | grep -q . ||
        die "$REFRESH contains merge commits"
}

validate_runtime_target() {
    local platform_asic
    platform_asic="$(git show "refs/heads/$REFRESH:$PLATFORM_DIR/platform_asic")" ||
        die "refresh candidate is missing AG9032v1 platform_asic"
    [[ "$platform_asic" == broadcom-legacy-th ]] ||
        die "AG9032v1 platform_asic must be broadcom-legacy-th, found: $platform_asic"
}

# Run the validator from the reviewed integration tip against TREEISH.
run_breakout_validator() {
    local treeish="$1"
    (
        tmp_dir="$(mktemp -d -t ag9032v1-validate.XXXXXXXX)"
        trap 'rm -rf "$tmp_dir"' EXIT
        git archive "$old_integration" -- \
            scripts/validate-ag9032v1-breakout.py | tar -x -C "$tmp_dir"
        git archive "$treeish" -- \
            "$PLATFORM_DIR/platform.json" \
            "$PLATFORM_DIR/Delta-ag9032v1/hwsku.json" \
            "$PLATFORM_DIR/Delta-ag9032v1/th-ag9032v1-32x100G.config.bcm" \
            | tar -x -C "$tmp_dir"
        python3 -B "$tmp_dir/scripts/validate-ag9032v1-breakout.py" \
            --root "$tmp_dir"
    )
}

validate_breakout_metadata() {
    run_breakout_validator "refs/heads/$REFRESH" ||
        die "AG9032v1 breakout validation failed"
}

validate_build() {
    need_ref "refs/heads/$BUILD"
    local refresh_sha build_sha
    refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
    build_sha="$(git rev-parse "refs/heads/$BUILD")"
    git merge-base --is-ancestor "$refresh_sha" "$build_sha" ||
        die "$BUILD is not based on $REFRESH"
    [[ "$(git rev-list --count "$refresh_sha..$build_sha")" == 1 ]] ||
        die "$BUILD must add exactly one local build-profile commit"
    ! git rev-list --min-parents=2 "$refresh_sha..$build_sha" | grep -q . ||
        die "$BUILD profile must not be a merge commit"
    [[ "$(git diff --name-only "$refresh_sha..$build_sha")" == rules/config ]] ||
        die "$BUILD must differ from $REFRESH only in rules/config"
    local build_patch profile_patch
    build_patch="$(commit_patch_id "$build_sha")" ||
        die "$BUILD profile commit has no stable patch ID"
    profile_patch="$(commit_patch_id "$local_profile_sha")" ||
        die "$LOCAL_PROFILE has no stable patch ID"
    [[ "$build_patch" == "$profile_patch" ]] ||
        die "$BUILD profile is not patch-equivalent to saved $LOCAL_PROFILE"
}

validate_prepared_tips() {
    [[ "$phase" == done ]] || die "candidate tips are not sealed"
    [[ "$(git rev-parse "refs/heads/$REFRESH")" == "$prepared_refresh_sha" ]] ||
        die "$REFRESH moved after preparation; rebuild and repeat hardware testing"
    [[ "$(git rev-parse "refs/heads/$BUILD")" == "$prepared_build_sha" ]] ||
        die "$BUILD moved after preparation; rebuild and repeat hardware testing"
}

validate_archives() {
    need_ref "refs/heads/$integration_archive"
    need_ref "refs/heads/$master_archive"
    [[ "$(git rev-parse "refs/heads/$integration_archive")" == "$old_integration" ]] ||
        die "$integration_archive no longer points to the reviewed integration tip"
    [[ "$(git rev-parse "refs/heads/$master_archive")" == "$old_master" ]] ||
        die "$master_archive no longer points to the reviewed master tip"
    ! git show-ref --verify --quiet "refs/remotes/origin/$integration_archive" ||
        die "origin/$integration_archive already exists; archive refs are immutable"
    ! git show-ref --verify --quiet "refs/remotes/origin/$master_archive" ||
        die "origin/$master_archive already exists; archive refs are immutable"
}

validate_committed_maintenance() {
    local path worktree_blob promoted_blob
    for path in "${MAINTENANCE_FILES[@]}"; do
        [[ -f "$path" ]] || die "worktree is missing maintenance file: $path"
        worktree_blob="$(git hash-object "$path")"
        promoted_blob="$(git rev-parse "refs/heads/$PROMOTE:$path")" ||
            die "$PROMOTE is missing maintenance file: $path"
        [[ "$worktree_blob" == "$promoted_blob" ]] ||
            die "worktree $path differs from the reviewed $PROMOTE version"
    done
}

# Reuse an unpublished archive pair for the same tips (left by an aborted
# prepare) instead of accumulating identical rollback refs.
create_archives() {
    local ref stamp
    while IFS= read -r ref; do
        [[ "$ref" == archive/ag9032v1-integration-* ]] || continue
        stamp="${ref#archive/ag9032v1-integration-}"
        if [[ "$(git rev-parse -q --verify "refs/heads/archive/master-$stamp" || true)" == "$old_master" ]] &&
            ! git show-ref --verify --quiet "refs/remotes/origin/$ref" &&
            ! git show-ref --verify --quiet "refs/remotes/origin/archive/master-$stamp"; then
            integration_archive="$ref"
            master_archive="archive/master-$stamp"
            printf 'Reusing unpublished rollback refs %s and %s\n' \
                "$integration_archive" "$master_archive"
            return 0
        fi
    done < <(git for-each-ref --points-at "$old_integration" \
        --format='%(refname:short)' refs/heads/archive/)
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-${old_integration:0:8}"
    integration_archive="archive/ag9032v1-integration-$stamp"
    master_archive="archive/master-$stamp"
    git branch "$integration_archive" "$old_integration"
    git branch "$master_archive" "$old_master"
}

return_to_starting_branch() {
    [[ "$(git symbolic-ref --quiet --short HEAD || true)" != "$starting_branch" ]] ||
        return 0
    git switch --quiet "$starting_branch" ||
        warn "could not return to $starting_branch; switch manually so $BUILD is free for the build worktree"
}

print_next_steps() {
    printf '\nPrepared local candidates; no remote refs changed:\n'
    printf '  %s @ %s\n' "$REFRESH" "$prepared_refresh_sha"
    printf '  %s @ %s\n\n' "$BUILD" "$prepared_build_sha"
    printf 'Build in the build worktree, not in this maintenance worktree:\n'
    printf '  git switch %s\n' "$BUILD"
    printf '  make init\n'
    printf '  bash %q\n\n' "$root/scripts/build-ag9032v1.sh"
    printf 'After hardware verification, create the promotion candidate here:\n'
    printf '  git switch -C %s %s\n' "$PROMOTE" "$prepared_refresh_sha"
    if [[ "$maintenance_sha" != absent ]]; then
        printf '  git cherry-pick %s\n' "$maintenance_sha"
    else
        printf '  # commit the consolidated maintenance change\n'
    fi
    printf '  bash scripts/fork-refresh-ag9032v1.sh --print-promotion\n'
}

# Shared by prepare and resume once the rebase has finished.
finish_candidates() {
    local refresh_sha
    validate_refresh
    if [[ "$phase" == rebase ]]; then
        # A finished rebase (manual or paused) leaves REFRESH at the candidate.
        phase=build
        save_state
    fi
    validate_runtime_target
    validate_breakout_metadata
    refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
    printf '\nReviewing old and refreshed reusable stacks:\n'
    git range-diff "$old_base..$old_integration" "$upstream_sha..$refresh_sha"
    if [[ "$phase" == build ]]; then
        if ! profile_is_applied; then
            ensure_branches_free "$BUILD"
            git switch -C "$BUILD" "$refresh_sha"
            if ! git cherry-pick "$local_profile_sha"; then pick_help; exit 1; fi
        fi
        validate_build
        prepared_refresh_sha="$refresh_sha"
        prepared_build_sha="$(git rev-parse "refs/heads/$BUILD")"
        phase=done
        save_state
    else
        validate_build
        validate_prepared_tips
    fi
    return_to_starting_branch
    print_next_steps
}

prepare() {
    rotate_promoted_state
    resolve_refs
    resolve_local_profile
    starting_branch="$(git symbolic-ref --quiet --short HEAD)" ||
        die "prepare mode requires a checked-out branch"
    case "$starting_branch" in
        "$REFRESH"|"$BUILD"|"$PROMOTE")
            die "run prepare from master or another stable branch containing this helper"
            ;;
    esac
    ensure_branches_free "$REFRESH" "$BUILD"
    create_archives
    phase=rebase
    save_state
    git switch -C "$REFRESH" "$old_integration"
    git branch --unset-upstream "$REFRESH" >/dev/null 2>&1 || true
    if ! git rebase --onto "$upstream_sha" "$old_base"; then
        rebase_help
        exit 1
    fi
    if ((pause_after_rebase)); then
        pause_help
        exit 0
    fi
    finish_candidates
}

resume() {
    read_state
    validate_reviewed_inputs
    resolve_local_profile
    finish_candidates
}

md_cell() {
    local text="${1//|/\\|}"
    printf '%s' "${text//$'\n'/ }"
}

replay_commit_tree() {
    GIT_AUTHOR_NAME=replay GIT_AUTHOR_EMAIL=replay@localhost \
    GIT_COMMITTER_NAME=replay GIT_COMMITTER_EMAIL=replay@localhost \
        git commit-tree "$1" -p "$replay_tip" -m "replay $2"
}

# Apply COMMIT onto replay_tip in the private index. Sets replay_result to ok,
# dropped (already upstream), or conflict. Conflicting paths are skipped so
# later commits still build on the rest of the change.
replay_commit() {
    local commit="$1" tree err path
    local -a excludes=()
    replay_conflict_paths=()
    GIT_INDEX_FILE="$replay_index" git read-tree "$replay_tip"
    if err="$(git diff-tree -p --binary --full-index "$commit^" "$commit" |
        GIT_INDEX_FILE="$replay_index" git apply --cached --3way 2>&1 >/dev/null)"; then
        replay_result=ok
    else
        replay_result=conflict
        # Unmerged entries are authoritative. Older Git also reports new files
        # as missing before its direct-application fallback succeeds, so only
        # parse the errors when the three-way merge recorded nothing.
        mapfile -t replay_conflict_paths < <(
            GIT_INDEX_FILE="$replay_index" git ls-files -u | cut -f2 | sort -u
        )
        if ((${#replay_conflict_paths[@]} == 0)); then
            mapfile -t replay_conflict_paths < <(
                printf '%s\n' "$err" | sed -nE \
                    -e 's/^error: patch failed: (.*):[0-9]+$/\1/p' \
                    -e 's/^error: (.*): (patch does not apply|already exists in index|does not exist in index)$/\1/p' |
                    sort -u
            )
        fi
        GIT_INDEX_FILE="$replay_index" git read-tree "$replay_tip"
        for path in "${replay_conflict_paths[@]}"; do
            excludes+=(":(exclude)$path")
        done
        ((${#excludes[@]})) || return 0
        git diff-tree -p --binary --full-index "$commit^" "$commit" -- . "${excludes[@]}" |
            GIT_INDEX_FILE="$replay_index" git apply --cached --3way >/dev/null 2>&1 ||
            return 0
    fi
    tree="$(GIT_INDEX_FILE="$replay_index" git write-tree)"
    if [[ "$tree" == "$(git rev-parse "$replay_tip^{tree}")" ]]; then
        [[ "$replay_result" == conflict ]] || replay_result=dropped
        return 0
    fi
    replay_tip="$(replay_commit_tree "$tree" "$commit")"
}

replay_paths_cell() {
    local path out=""
    for path in "${replay_conflict_paths[@]}"; do
        out+="${out:+, }\`$(md_cell "$path")\`"
    done
    printf '%s' "$out"
}

# Report one commit replayed on top of STACK_TIP and whether its stable patch
# ID survives, since prepare and promotion require an unchanged patch ID.
replay_extra() {
    local label="$1" key="$2" ref="$3" stack_tip="$4" sha
    if ! git show-ref --verify --quiet "$ref"; then
        printf -- '- %s: `%s` not found\n' "$label" "${ref#refs/remotes/}"
        return 0
    fi
    sha="$(git rev-parse "$ref")"
    replay_tip="$stack_tip"
    replay_commit "$sha"
    case "$replay_result" in
        ok)
            if [[ "$(range_patch_id "$stack_tip" "$replay_tip")" == "$(commit_patch_id "$sha")" ]]; then
                printf -- '- %s `%s`: ok, stable patch ID preserved\n' "$label" "${sha:0:9}"
                extra_status+="$key=ok;"
            else
                printf -- '- %s `%s`: applies, but its **patch ID changes**; replace the canonical commit before preparing\n' \
                    "$label" "${sha:0:9}"
                extra_status+="$key=patch-id;"
                check_status=2
            fi
            ;;
        dropped)
            printf -- '- %s `%s`: **already upstream**\n' "$label" "${sha:0:9}"
            extra_status+="$key=dropped;"
            check_status=2
            ;;
        conflict)
            printf -- '- %s `%s`: **conflict** in %s\n' "$label" "${sha:0:9}" "$(replay_paths_cell)"
            extra_status+="$key=conflict;"
            check_status=2
            ;;
    esac
}

check_replay() {
    local commit stack_tip platform_asic validator_output
    local -a commits=() conflicts=() dropped=()
    need_ref "refs/remotes/origin/$INTEGRATION"
    need_ref refs/remotes/upstream/master
    old_integration="$(git rev-parse "refs/remotes/origin/$INTEGRATION")"
    upstream_sha="$(git rev-parse refs/remotes/upstream/master)"
    old_base="$(git merge-base "$old_integration" "$upstream_sha")" ||
        die "integration has no upstream merge base"
    ! git rev-list --min-parents=2 "$old_base..$old_integration" | grep -q . ||
        die "$INTEGRATION is not a linear stack"
    mapfile -t commits < <(git rev-list --reverse "$old_base..$old_integration")

    replay_index="$(mktemp -t ag9032v1-replay.XXXXXXXX)"
    trap 'rm -f "$replay_index"' EXIT
    replay_tip="$upstream_sha"
    check_status=0
    extra_status=""

    printf '### Replay onto upstream `%s`\n\n' "${upstream_sha:0:12}"
    printf '%d commits from `%s` above merge base `%s`.\n\n' \
        "${#commits[@]}" "$INTEGRATION" "${old_base:0:12}"
    printf '| Result | Commit | Subject | Conflicting paths |\n'
    printf '| --- | --- | --- | --- |\n'
    for commit in "${commits[@]}"; do
        replay_commit "$commit"
        case "$replay_result" in
            conflict) conflicts+=("${commit:0:9}"); check_status=2 ;;
            dropped) dropped+=("${commit:0:9}") ;;
        esac
        printf '| %s | `%s` | %s | %s |\n' "$replay_result" "${commit:0:9}" \
            "$(md_cell "$(git log -1 --format=%s "$commit")")" "$(replay_paths_cell)"
    done
    stack_tip="$replay_tip"
    printf '\n'
    replay_extra "Maintenance commit" maintenance "refs/remotes/origin/$MAINTENANCE" "$stack_tip"
    replay_extra "Local profile" profile "refs/remotes/origin/$LOCAL_PROFILE" "$stack_tip"

    platform_asic="$(git show "$stack_tip:$PLATFORM_DIR/platform_asic" 2>/dev/null || true)"
    if [[ "$platform_asic" == broadcom-legacy-th ]]; then
        printf -- '- Runtime target: `broadcom-legacy-th`\n'
    else
        printf -- '- Runtime target: **`%s`**, expected `broadcom-legacy-th`\n' "${platform_asic:-missing}"
        extra_status+="runtime=wrong;"
        check_status=2
    fi
    if validator_output="$(run_breakout_validator "$stack_tip" 2>&1)"; then
        printf -- '- Breakout metadata: valid\n'
    else
        printf -- '- Breakout metadata: **validation failed**\n\n```\n%s\n```\n' \
            "$(printf '%s\n' "$validator_output" | tail -n 20)"
        extra_status+="validator=failed;"
        check_status=2
    fi

    if ((${#conflicts[@]})); then
        printf '\n**%d conflicting commit(s).** Expect to resolve them during the next prepare.\n' \
            "${#conflicts[@]}"
    else
        printf '\n**The stack replays without conflicts.**\n'
    fi
    if ((${#dropped[@]})); then
        printf 'Already upstream and expected to drop: %s\n' "${dropped[*]}"
    fi
    local conflict_list="none"
    if ((${#conflicts[@]})); then
        conflict_list="$(IFS=,; printf '%s' "${conflicts[*]}")"
    fi
    printf '\n<!-- replay-status: conflicts=%s;%s -->\n' "$conflict_list" "$extra_status"
    exit "$check_status"
}

print_promotion() {
    read_state
    validate_reviewed_inputs
    [[ "$phase" == done ]] || die "refresh/build preparation is incomplete (phase: $phase)"

    validate_committed_maintenance
    validate_prepared_tips
    validate_refresh
    validate_runtime_target
    validate_breakout_metadata
    validate_build
    need_ref "refs/heads/$PROMOTE"
    validate_archives
    [[ "$(git rev-parse "refs/remotes/origin/$INTEGRATION")" == "$old_integration" ]] ||
        die "origin/$INTEGRATION moved; start a new refresh"
    [[ "$(git rev-parse refs/remotes/origin/master)" == "$old_master" ]] ||
        die "origin/master moved; start a new refresh"

    local refresh_sha promote_sha path maintenance_path allowed
    local promoted_patch maintenance_patch
    local -a changed=()
    refresh_sha="$prepared_refresh_sha"
    promote_sha="$(git rev-parse "refs/heads/$PROMOTE")"
    git merge-base --is-ancestor "$refresh_sha" "$promote_sha" ||
        die "$PROMOTE is not based on $REFRESH"
    [[ "$(git rev-list --count "$refresh_sha..$promote_sha")" == 1 ]] ||
        die "$PROMOTE must add exactly one consolidated maintenance commit"
    ! git rev-list --min-parents=2 "$refresh_sha..$promote_sha" | grep -q . ||
        die "$PROMOTE maintenance commit must not be a merge commit"

    mapfile -t changed < <(git diff --name-only "$refresh_sha..$promote_sha")
    for path in "${changed[@]}"; do
        allowed=0
        for maintenance_path in "${MAINTENANCE_FILES[@]}"; do
            [[ "$path" != "$maintenance_path" ]] || allowed=1
        done
        ((allowed)) || die "unexpected integration/master delta: $path"
    done
    for maintenance_path in "${MAINTENANCE_FILES[@]}"; do
        printf '%s\n' "${changed[@]}" | grep -Fqx -- "$maintenance_path" ||
            die "$PROMOTE maintenance commit is missing: $maintenance_path"
    done

    if [[ "$maintenance_sha" != absent ]]; then
        promoted_patch="$(commit_patch_id "$promote_sha")" ||
            die "$PROMOTE maintenance commit has no stable patch ID"
        maintenance_patch="$(commit_patch_id "$maintenance_sha")" ||
            die "$MAINTENANCE has no stable patch ID"
        [[ "$promoted_patch" == "$maintenance_patch" ]] ||
            die "$PROMOTE maintenance commit is not patch-equivalent to the reviewed origin tip"
    fi

    printf '\nNo push was performed. After final sign-off, run exactly:\n\n'
    printf 'git push --atomic \\\n'
    printf '  --force-with-lease=refs/heads/%s:%s \\\n' "$INTEGRATION" "$old_integration"
    printf '  --force-with-lease=refs/heads/master:%s \\\n' "$old_master"
    printf '  --force-with-lease=refs/heads/%s:%s \\\n' \
        "$LOCAL_PROFILE" "$old_local_profile_sha"
    if [[ "$maintenance_sha" != absent ]]; then
        printf '  --force-with-lease=refs/heads/%s:%s \\\n' \
            "$MAINTENANCE" "$maintenance_sha"
    else
        printf '  --force-with-lease=refs/heads/%s: \\\n' "$MAINTENANCE"
    fi
    printf '  --force-with-lease=refs/heads/%s: \\\n' "$integration_archive"
    printf '  --force-with-lease=refs/heads/%s: \\\n' "$master_archive"
    printf '  origin \\\n'
    printf '  %s:refs/heads/%s \\\n' "$prepared_refresh_sha" "$INTEGRATION"
    printf '  %s:refs/heads/master \\\n' "$promote_sha"
    printf '  %s:refs/heads/%s \\\n' "$promote_sha" "$MAINTENANCE"
    printf '  %s:refs/heads/%s \\\n' "$local_profile_sha" "$LOCAL_PROFILE"
    printf '  %s:refs/heads/%s \\\n' "$old_integration" "$integration_archive"
    printf '  %s:refs/heads/%s\n' "$old_master" "$master_archive"
    printf '\nExplicit leases make the command fail if a reviewed remote tip moved.\n'
}

# Everything runs from functions so bash has parsed the whole helper before a
# branch switch replaces this file on disk.
main() {
    parse_args "$@"
    preflight
    case "$mode" in
        prepare) prepare ;;
        resume) resume ;;
        check) check_replay ;;
        print-promotion) print_promotion ;;
    esac
}

main "$@"
exit
