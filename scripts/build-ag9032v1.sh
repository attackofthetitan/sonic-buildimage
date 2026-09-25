#!/usr/bin/env bash

# Build and gate the AG9032v1 installer from the sealed build/ag9032v1
# candidate. Run it from the build worktree; it never changes refs.

set -euo pipefail

readonly BUILD="build/ag9032v1"
readonly BUILD_TARGET="target/sonic-broadcom.bin"
readonly DNX_IMAGE="target/sonic-broadcom-dnx.bin"
readonly IMAGE="target/sonic-broadcom-legacy-th.bin"
readonly RFS_PREFIX="target/sonic-broadcom.bin"
# Debian suite of the default BLDENV, which builds the platform package.
readonly PLATFORM_DIST="trixie"

preflight_only=0

usage() {
    cat <<'EOF'
Usage: bash /path/to/maintenance-worktree/scripts/build-ag9032v1.sh [--preflight]

Run from the build worktree with build/ag9032v1 checked out. The script checks
that the worktree is the sealed candidate with synchronized submodules,
archives outputs that make would otherwise reuse, rebuilds the AG9032v1
platform package and the Broadcom installer set, verifies the default password
hash, and prints the legacy-TH image checksum.
--preflight stops after the candidate and submodule checks.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

state_field() {
    awk -F= -v key="$1" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' \
        "$state_file"
}

check_candidate() {
    local sealed
    [[ "$(git symbolic-ref --quiet --short HEAD || true)" == "$BUILD" ]] ||
        die "check out $BUILD in this worktree first"
    [[ -f "$state_file" ]] || die "no saved refresh state; prepare candidates first"
    [[ "$(state_field phase)" == done ]] || die "refresh/build preparation is incomplete"
    sealed="$(state_field prepared_build_sha)"
    [[ "$(git rev-parse HEAD)" == "$sealed" ]] ||
        die "$BUILD is not the sealed build candidate $sealed"
    git diff --quiet --ignore-submodules=all HEAD -- ||
        die "tracked files differ from $BUILD; commit or discard them"
}

# Builds may leave patch commits on top of a submodule's recorded commit (FRR
# does), but a checkout that does not contain the recorded commit is stale.
check_submodules() {
    local -a stale=()
    mapfile -t stale < <(
        git submodule status --recursive | awk '/^[-U]/ { print $2 }'
        git submodule foreach --quiet --recursive \
            'git merge-base --is-ancestor "$sha1" HEAD 2>/dev/null || echo "$displaypath"'
    )
    if ((${#stale[@]})); then
        printf '  %s\n' "${stale[@]}" >&2
        die "submodules are not at the recorded commits; run make init"
    fi
}

platform_deb_path() {
    local version
    version="$(awk '$1 == "DELTA_AG9032V1_PLATFORM_MODULE_VERSION" { print $3 }' \
        platform/broadcom/platform-modules-delta.mk)"
    [[ -n "$version" ]] || die "cannot find the AG9032v1 platform module version"
    printf 'target/debs/%s/platform-modules-ag9032v1_%s_amd64.deb\n' "$PLATFORM_DIST" "$version"
}

# The outer make considers existing outputs complete, and the split root
# filesystems capture the default account password, so move them aside.
archive_outputs() {
    local artifact_archive artifact
    local -a artifacts=()
    artifact_archive="target/ag9032v1-prebuild-$(date -u +%Y%m%dT%H%M%SZ)"
    shopt -s nullglob
    artifacts=(
        "$platform_deb" "$BUILD_TARGET" "$BUILD_TARGET.log"
        "$DNX_IMAGE" "$IMAGE"
        "$RFS_PREFIX"__*__rfs.squashfs
        "$RFS_PREFIX"__*__rfs.squashfs.log
    )
    shopt -u nullglob
    for artifact in "${artifacts[@]}"; do
        [[ -e "$artifact" ]] || continue
        mkdir -p "$artifact_archive"
        mv "$artifact" "$artifact_archive/"
    done
    if [[ -d "$artifact_archive" ]]; then
        printf 'Archived previous outputs in %s\n' "$artifact_archive"
    fi
}

check_platform_deb() {
    local contents path
    contents="$(dpkg-deb --fsys-tarfile "$platform_deb" | tar -tf -)"
    for path in \
        ./usr/local/bin/ag9032v1_wait_pmon_ready.sh \
        ./lib/systemd/system/pmon.service.d/10-ag9032v1-platform-ready.conf; do
        grep -Fqx -- "$path" <<<"$contents" || die "$platform_deb is missing $path"
    done
}

verify_password() {
    local build_username build_password shadow_hash
    build_username="$(awk '$1 == "DEFAULT_USERNAME" { value = $3 } END { print value }' rules/config)"
    build_password="$(awk '$1 == "DEFAULT_PASSWORD" { value = $3 } END { print value }' rules/config)"
    shadow_hash="$(sudo awk -F: -v username="$build_username" \
        '$1 == username { print $2 }' fsroot-broadcom-legacy-th/etc/shadow)"
    if [[ -z "$build_password" ]]; then
        [[ -z "$shadow_hash" ]] ||
            die "rules/config has no password but $build_username has a hash"
    else
        BUILD_PASSWORD="$build_password" SHADOW_HASH="$shadow_hash" perl -e \
            'exit crypt($ENV{BUILD_PASSWORD}, $ENV{SHADOW_HASH}) eq $ENV{SHADOW_HASH} ? 0 : 1' ||
            die "default password hash does not match rules/config for $build_username"
    fi
    echo "Default password hash matches rules/config for $build_username"
}

main() {
    while (($#)); do
        case "$1" in
            --preflight) preflight_only=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done

    root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
        die "run inside the build worktree"
    cd "$root"
    state_file="$(git rev-parse --git-common-dir)/fork-refresh-ag9032v1.state"

    check_candidate
    check_submodules
    platform_deb="$(platform_deb_path)"
    if ((preflight_only)); then
        printf 'Build worktree is the sealed %s candidate with synchronized submodules.\n' "$BUILD"
        return 0
    fi

    archive_outputs
    make "$platform_deb"
    check_platform_deb
    make "$BUILD_TARGET"
    verify_password
    [[ -s "$IMAGE" ]] || die "$IMAGE was not produced"
    printf '\nInstall only this image on the AG9032v1:\n'
    sha256sum "$IMAGE"
}

main "$@"
exit
