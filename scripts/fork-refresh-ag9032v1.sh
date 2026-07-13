#!/usr/bin/env bash

# Prepare AG9032v1 refresh/build candidates and print a guarded promotion.
# Rebase/cherry-pick rewrite disposable local candidates; the script never
# pushes, promotes, or deletes refs.

set -euo pipefail

readonly INTEGRATION="integration/ag9032v1"
readonly REFRESH="refresh/ag9032v1"
readonly BUILD="build/ag9032v1"
readonly PROMOTE="promote/master"
readonly MAINTENANCE="maintenance/fork"
readonly LOCAL_PROFILE="local/ag9032v1-build-profile"
readonly BUILD_TARGET="target/sonic-broadcom.bin"
readonly DNX_IMAGE="target/sonic-broadcom-dnx.bin"
readonly IMAGE="target/sonic-broadcom-legacy-th.bin"
readonly PLATFORM_DEB="target/debs/trixie/platform-modules-ag9032v1_1.1_amd64.deb"
readonly RFS_PREFIX="target/sonic-broadcom.bin"
readonly STATE_VERSION=4

mode=prepare
fetch=1
breakout_fix=""
breakout_fix_sha=""
breakout_parent=""
local_profile=""
allow_default_password=0
password_warning_emitted=0
phase=""
state_version="$STATE_VERSION"
old_local_profile_sha=""
local_profile_sha=""
maintenance_sha="absent"
prepared_refresh_sha=""
prepared_build_sha=""

usage() {
    cat <<'EOF'
Usage:
  scripts/fork-refresh-ag9032v1.sh [--no-fetch] [--breakout-fix REV] [--local-profile REV] [--allow-default-password]
  scripts/fork-refresh-ag9032v1.sh --resume [--no-fetch] [--breakout-fix REV] [--local-profile REV]
  scripts/fork-refresh-ag9032v1.sh --adopt-existing [--no-fetch] [--breakout-fix REV] [--local-profile REV] [--allow-default-password]
  scripts/fork-refresh-ag9032v1.sh --print-promotion [--no-fetch]

The default mode archives the reviewed remote tips, rebases the entire
integration stack onto upstream/master, prints a range-diff, and creates a
local build candidate. These operations create/rewrite local candidate commits.
--resume finishes after manually resolved conflicts.
--adopt-existing validates and seals already-prepared refresh/build candidates
without rewriting them; use it for a deliberately reviewed one-time migration.
--allow-default-password explicitly approves a local profile which embeds a
DEFAULT_PASSWORD change. The approval is saved with the sealed candidate.
--print-promotion validates candidates and prints, but never runs, an atomic
force-with-lease push command.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

while (($#)); do
    case "$1" in
        --resume)
            [[ "$mode" == prepare ]] || die "choose only one mode"
            mode=resume
            ;;
        --print-promotion)
            [[ "$mode" == prepare ]] || die "choose only one mode"
            mode=print-promotion
            ;;
        --adopt-existing)
            [[ "$mode" == prepare ]] || die "choose only one mode"
            mode=adopt-existing
            ;;
        --breakout-fix)
            shift
            (($#)) || die "--breakout-fix requires a revision"
            breakout_fix="$1"
            ;;
        --local-profile)
            shift
            (($#)) || die "--local-profile requires a revision"
            local_profile="$1"
            ;;
        --allow-default-password) allow_default_password=1 ;;
        --no-fetch) fetch=0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[[ "$mode" != print-promotion || -z "$breakout_fix" ]] ||
    die "--breakout-fix is not valid with --print-promotion"
[[ "$mode" != print-promotion || -z "$local_profile" ]] ||
    die "--local-profile is not valid with --print-promotion"
[[ "$allow_default_password" == 0 || "$mode" == prepare || "$mode" == adopt-existing ]] ||
    die "--allow-default-password is valid only when preparing or adopting candidates"

root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run inside sonic-buildimage"
cd "$root"
git_dir="$(git rev-parse --git-dir)"
git_common_dir="$(git rev-parse --git-common-dir)"
state_file="$git_common_dir/fork-refresh-ag9032v1.state"

if [[ "$mode" == prepare || "$mode" == resume ]]; then
    clean="$(git status --porcelain=v1 --untracked-files=all)"
    [[ -z "$clean" ]] || {
        printf '%s\n' "$clean" >&2
        die "worktree is not clean"
    }
fi
[[ ! -d "$git_dir/rebase-merge" && ! -d "$git_dir/rebase-apply" ]] ||
    die "finish or abort the active rebase first"
[[ ! -f "$git_dir/CHERRY_PICK_HEAD" ]] ||
    die "finish or abort the active cherry-pick first"

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

remote_urls_are origin fetch "attackofthetitan/sonic-buildimage"
remote_urls_are origin push "attackofthetitan/sonic-buildimage"
remote_urls_are upstream fetch "sonic-net/sonic-buildimage"
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

need_ref() {
    git show-ref --verify --quiet "$1" || die "missing required ref: $1"
}

commit_patch_id() {
    git show --format= --no-ext-diff "$1" |
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
            die "$LOCAL_PROFILE changes DEFAULT_PASSWORD; review it and rerun prepare/adopt with --allow-default-password"
        if [[ "$password_warning_emitted" == 0 ]]; then
            warn "$LOCAL_PROFILE embeds DEFAULT_PASSWORD in Git and in every resulting image"
            password_warning_emitted=1
        fi
    fi
}

read_state() {
    [[ -f "$state_file" ]] || die "no saved refresh state; run prepare mode first"
    state_version=""
    old_integration=""; old_master=""; upstream_sha=""; old_base=""
    integration_archive=""; master_archive=""; starting_branch=""
    breakout_fix_sha=""; breakout_parent=""; phase=""
    old_local_profile_sha=""; local_profile_sha=""; maintenance_sha=""
    allow_default_password=""
    prepared_refresh_sha=""; prepared_build_sha=""
    while IFS='=' read -r key value; do
        case "$key" in
            state_version|old_integration|old_master|upstream_sha|old_base|\
            integration_archive|master_archive|starting_branch|breakout_fix_sha|\
            breakout_parent|old_local_profile_sha|local_profile_sha|maintenance_sha|\
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
    [[ -z "$breakout_fix_sha" || "$breakout_fix_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved breakout-fix SHA"
    [[ -z "$breakout_parent" || "$breakout_parent" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved breakout parent SHA"
    [[ "$old_local_profile_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved old local-profile SHA"
    [[ "$local_profile_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved local-profile SHA"
    [[ "$maintenance_sha" == absent || "$maintenance_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "invalid saved maintenance SHA"
    [[ "$allow_default_password" == 0 || "$allow_default_password" == 1 ]] ||
        die "invalid saved default-password approval"
    case "$phase" in rebase|breakout|build|done) ;; *) die "invalid saved phase" ;; esac
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
}

save_state() {
    local tmp="$state_file.tmp"
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
        printf 'breakout_fix_sha=%s\n' "$breakout_fix_sha"
        printf 'breakout_parent=%s\n' "$breakout_parent"
        printf 'old_local_profile_sha=%s\n' "$old_local_profile_sha"
        printf 'local_profile_sha=%s\n' "$local_profile_sha"
        printf 'maintenance_sha=%s\n' "$maintenance_sha"
        printf 'allow_default_password=%s\n' "$allow_default_password"
        printf 'prepared_refresh_sha=%s\n' "$prepared_refresh_sha"
        printf 'prepared_build_sha=%s\n' "$prepared_build_sha"
        printf 'phase=%s\n' "$phase"
    } >"$tmp"
    mv "$tmp" "$state_file"
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
        if [[ "$mode" == prepare || "$mode" == adopt-existing ]]; then
            local_profile_sha="$cli_sha"
        elif [[ "$cli_sha" != "$local_profile_sha" ]]; then
            die "--local-profile does not match the revision saved during preparation"
        fi
    fi
    validate_profile_source "$local_profile_sha"
}

resolve_breakout_fix() {
    [[ -n "$breakout_fix" ]] || return 0
    local cli_sha parent_count
    cli_sha="$(git rev-parse --verify "$breakout_fix^{commit}")" ||
        die "invalid breakout-fix revision: $breakout_fix"
    parent_count="$(git rev-list --parents -n1 "$cli_sha" | awk '{print NF - 1}')"
    ((parent_count == 1)) || die "breakout fix must be one non-merge commit"

    if [[ "$mode" == prepare || "$mode" == adopt-existing ]]; then
        breakout_fix_sha="$cli_sha"
    elif [[ "$cli_sha" != "$breakout_fix_sha" ]]; then
        die "--breakout-fix does not match the revision saved during prepare"
    fi
}

breakout_is_applied() {
    [[ -n "$breakout_fix_sha" ]] || return 0
    local cherry refresh_tip path
    local -a source_paths=() candidate_paths=()
    cherry="$(git cherry "$REFRESH" "$breakout_fix_sha" "$breakout_fix_sha^")"
    if [[ -z "$cherry" || "${cherry:0:1}" == "-" ]]; then
        return 0
    fi

    # A conflict resolution may intentionally adapt the patch to new upstream
    # code, changing its patch ID. Accept only one resolved, non-merge commit
    # on the exact pre-pick parent and restrict it to the source patch's paths.
    [[ -n "$breakout_parent" ]] || return 1
    refresh_tip="$(git rev-parse "refs/heads/$REFRESH")"
    [[ "$refresh_tip" != "$breakout_parent" ]] || return 1
    git merge-base --is-ancestor "$breakout_parent" "$refresh_tip" ||
        die "$REFRESH diverged from the saved breakout parent"
    [[ "$(git rev-list --count "$breakout_parent..$refresh_tip")" == 1 ]] ||
        die "resolved breakout must add exactly one commit"
    ! git rev-list --min-parents=2 "$breakout_parent..$refresh_tip" | grep -q . ||
        die "resolved breakout must not be a merge commit"

    mapfile -t source_paths < <(
        git diff-tree --no-commit-id --name-only -r "$breakout_fix_sha"
    )
    mapfile -t candidate_paths < <(
        git diff --name-only "$breakout_parent..$refresh_tip"
    )
    ((${#candidate_paths[@]})) || die "resolved breakout commit is empty"
    for path in "${candidate_paths[@]}"; do
        printf '%s\n' "${source_paths[@]}" | grep -Fqx -- "$path" ||
            die "resolved breakout changed an unexpected path: $path"
    done
    warn "accepting one manually adapted breakout commit; review the range-diff"
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

pick_help() {
    local candidate="$REFRESH"
    [[ "$phase" == build ]] && candidate="$BUILD"
    cat >&2 <<EOF

No remote ref changed. Resolve with git add and git cherry-pick --continue,
then return to the helper branch and resume:
  git switch $starting_branch
  bash scripts/fork-refresh-ag9032v1.sh --resume --no-fetch
Abort with git cherry-pick --abort. The candidate remains at $candidate.
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
    platform_asic="$(
        git show "refs/heads/$REFRESH:device/delta/x86_64-delta_ag9032v1-r0/platform_asic"
    )" || die "refresh candidate is missing AG9032v1 platform_asic"
    [[ "$platform_asic" == broadcom-legacy-th ]] ||
        die "AG9032v1 platform_asic must be broadcom-legacy-th, found: $platform_asic"
}

validate_breakout_metadata() {
    local trusted_validator_ref="$old_integration"
    [[ -z "$breakout_fix_sha" ]] || trusted_validator_ref="$breakout_fix_sha"
    (
        tmp_dir="$(mktemp -d -t ag9032v1-validate.XXXXXXXX)"
        trap 'rm -rf "$tmp_dir"' EXIT
        git archive "$trusted_validator_ref" -- \
            scripts/validate-ag9032v1-breakout.py | tar -x -C "$tmp_dir"
        git archive "refs/heads/$REFRESH" -- \
            device/delta/x86_64-delta_ag9032v1-r0/platform.json \
            device/delta/x86_64-delta_ag9032v1-r0/Delta-ag9032v1/hwsku.json \
            device/delta/x86_64-delta_ag9032v1-r0/Delta-ag9032v1/th-ag9032v1-32x100G.config.bcm \
            | tar -x -C "$tmp_dir"
        python3 -B "$tmp_dir/scripts/validate-ag9032v1-breakout.py" \
            --root "$tmp_dir"
    ) || die "AG9032v1 breakout validation failed"
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
    for path in \
        .github/workflows/protect-file.yml \
        .github/workflows/upstream-drift.yml \
        FORK_MAINTENANCE.md \
        scripts/fork-refresh-ag9032v1.sh; do
        [[ -f "$path" ]] || die "worktree is missing maintenance file: $path"
        worktree_blob="$(git hash-object "$path")"
        promoted_blob="$(git rev-parse "refs/heads/$PROMOTE:$path")" ||
            die "$PROMOTE is missing maintenance file: $path"
        [[ "$worktree_blob" == "$promoted_blob" ]] ||
            die "worktree $path differs from the reviewed $PROMOTE version"
    done
}

create_archives() {
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-${old_integration:0:8}"
    integration_archive="archive/ag9032v1-integration-$stamp"
    master_archive="archive/master-$stamp"
    git branch "$integration_archive" "$old_integration"
    git branch "$master_archive" "$old_master"
}

if [[ "$mode" == prepare ]]; then
    [[ ! -e "$state_file" ]] ||
        die "saved refresh state already exists; resume it or preserve and move it aside before a fresh prepare"
    resolve_refs
    resolve_local_profile
    resolve_breakout_fix
    starting_branch="$(git symbolic-ref --quiet --short HEAD)" ||
        die "prepare mode requires a checked-out branch"
    case "$starting_branch" in
        "$REFRESH"|"$BUILD"|"$PROMOTE")
            die "run prepare from master or another stable branch containing this helper"
            ;;
    esac
    need_ref "refs/remotes/origin/$INTEGRATION"
    create_archives
    phase=rebase
    save_state
    git switch -C "$REFRESH" "$old_integration"
    git branch --unset-upstream "$REFRESH" >/dev/null 2>&1 || true
    if ! git rebase --onto "$upstream_sha" "$old_base"; then
        rebase_help
        exit 1
    fi
    breakout_parent="$(git rev-parse "refs/heads/$REFRESH")"
    phase=breakout
    save_state
elif [[ "$mode" == adopt-existing ]]; then
    [[ ! -e "$state_file" ]] ||
        die "saved refresh state already exists; preserve and move it aside before adopting candidates"
    resolve_refs
    resolve_local_profile
    resolve_breakout_fix
    starting_branch="$(git symbolic-ref --quiet --short HEAD)" ||
        die "adopt-existing mode requires a checked-out branch"
    validate_committed_maintenance
    validate_refresh
    validate_runtime_target
    validate_breakout_metadata
    validate_build
    create_archives
    prepared_refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
    prepared_build_sha="$(git rev-parse "refs/heads/$BUILD")"
    phase=done
    save_state
else
    read_state
    validate_reviewed_inputs
    resolve_local_profile
    [[ -z "$breakout_fix" ]] || resolve_breakout_fix
fi

if [[ "$mode" != print-promotion ]]; then
    validate_refresh
    if [[ "$phase" == rebase ]]; then
        # A successful manual rebase --continue leaves REFRESH at the candidate.
        breakout_parent="$(git rev-parse "refs/heads/$REFRESH")"
        phase=breakout
        save_state
    fi
    if [[ "$phase" == breakout ]]; then
        if [[ -n "$breakout_fix_sha" ]] && ! breakout_is_applied; then
            git switch "$REFRESH"
            if ! git cherry-pick "$breakout_fix_sha"; then pick_help; exit 1; fi
        fi
        phase=build
        save_state
    fi
    validate_refresh
    validate_runtime_target
    validate_breakout_metadata
    refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
    printf '\nReviewing old and refreshed reusable stacks:\n'
    git range-diff "$old_base..$old_integration" "$upstream_sha..$refresh_sha"
    if [[ "$phase" == build ]]; then
        if ! profile_is_applied; then
            git switch -C "$BUILD" "$refresh_sha"
            if ! git cherry-pick "$local_profile_sha"; then pick_help; exit 1; fi
        fi
        validate_build
        prepared_refresh_sha="$(git rev-parse "refs/heads/$REFRESH")"
        prepared_build_sha="$(git rev-parse "refs/heads/$BUILD")"
        phase=done
        save_state
    elif [[ "$phase" == done ]]; then
        validate_build
        validate_prepared_tips
    else
        die "saved refresh phase cannot prepare a build: $phase"
    fi
    printf '\nPrepared local candidates; no remote refs changed:\n'
    printf '  %s @ %s\n' "$REFRESH" "$refresh_sha"
    printf '  %s @ %s\n\n' "$BUILD" "$(git rev-parse "refs/heads/$BUILD")"
    printf 'Archive possibly stale outputs and split root filesystems, rebuild the platform package, then build the installer set:\n'
    printf '  artifact_archive="target/ag9032v1-prebuild-$(date -u +%%Y%%m%%dT%%H%%M%%SZ)"\n'
    printf '  mkdir -p "$artifact_archive"\n'
    printf '  for artifact in %s %s %s.log %s %s %s__*__rfs.squashfs %s__*__rfs.squashfs.log; do\n' \
        "$PLATFORM_DEB" "$BUILD_TARGET" "$BUILD_TARGET" "$DNX_IMAGE" "$IMAGE" "$RFS_PREFIX" "$RFS_PREFIX"
    printf '    [[ ! -e "$artifact" ]] || mv "$artifact" "$artifact_archive/"\n'
    printf '  done\n'
    printf '  make %s\n' "$PLATFORM_DEB"
    printf "  dpkg-deb --fsys-tarfile %s | tar -tf - | grep -Fx './usr/local/bin/ag9032v1_wait_pmon_ready.sh'\n" "$PLATFORM_DEB"
    printf "  dpkg-deb --fsys-tarfile %s | tar -tf - | grep -Fx './lib/systemd/system/pmon.service.d/10-ag9032v1-platform-ready.conf'\n" "$PLATFORM_DEB"
    printf '  make %s\n' "$BUILD_TARGET"
    cat <<'EOF_PASSWORD_GATE'
  build_username="$(awk '$1 == "DEFAULT_USERNAME" { value = $3 } END { print value }' rules/config)"
  build_password="$(awk '$1 == "DEFAULT_PASSWORD" { value = $3 } END { print value }' rules/config)"
  shadow_hash="$(sudo awk -F: -v username="$build_username" '$1 == username { print $2 }' fsroot-broadcom-legacy-th/etc/shadow)"
  if [[ -z "$build_password" ]]; then
    [[ -z "$shadow_hash" ]]
  else
    BUILD_PASSWORD="$build_password" SHADOW_HASH="$shadow_hash" perl -e 'exit crypt($ENV{BUILD_PASSWORD}, $ENV{SHADOW_HASH}) eq $ENV{SHADOW_HASH} ? 0 : 1'
  fi
  echo "Default password hash matches rules/config for $build_username"
EOF_PASSWORD_GATE
    printf '  test -s %s && sha256sum %s\n\n' "$IMAGE" "$IMAGE"
    printf 'Then create %s and run:\n' "$PROMOTE"
    printf '  git switch %s\n' "$starting_branch"
    printf '  bash scripts/fork-refresh-ag9032v1.sh --print-promotion\n'
    exit 0
fi

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

refresh_sha="$prepared_refresh_sha"
promote_sha="$(git rev-parse "refs/heads/$PROMOTE")"
git merge-base --is-ancestor "$refresh_sha" "$promote_sha" ||
    die "$PROMOTE is not based on $REFRESH"
[[ "$(git rev-list --count "$refresh_sha..$promote_sha")" == 1 ]] ||
    die "$PROMOTE must add exactly one consolidated maintenance commit"
! git rev-list --min-parents=2 "$refresh_sha..$promote_sha" | grep -q . ||
    die "$PROMOTE maintenance commit must not be a merge commit"

declare -A maintenance_paths=()
while IFS= read -r path; do
    case "$path" in
        .github/workflows/protect-file.yml|.github/workflows/upstream-drift.yml|\
        FORK_MAINTENANCE.md|scripts/fork-refresh-ag9032v1.sh)
            maintenance_paths["$path"]=1
            ;;
        *) die "unexpected integration/master delta: $path" ;;
    esac
done < <(git diff --name-only "$refresh_sha..$promote_sha")
for path in \
    .github/workflows/protect-file.yml \
    .github/workflows/upstream-drift.yml \
    FORK_MAINTENANCE.md \
    scripts/fork-refresh-ag9032v1.sh; do
    [[ -n "${maintenance_paths[$path]:-}" ]] ||
        die "$PROMOTE maintenance commit is missing: $path"
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
