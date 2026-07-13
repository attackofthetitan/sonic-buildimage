# Fork Maintenance

Delta AG9032v1 support is kept as a reusable, linear patch stack on top of
`sonic-net/sonic-buildimage:master`. Fork automation and local build policy are
kept outside that stack.

## Canonical branches

| Branch | Purpose |
| --- | --- |
| `integration/ag9032v1` | The canonical reusable AG9032v1 patch stack. Refresh this complete range, not individual topic tips. |
| `refresh/ag9032v1` | A disposable candidate rebased onto the selected upstream SHA. |
| `build/ag9032v1` | The refresh candidate plus local `rules/config` policy. Never promote it. |
| `local/ag9032v1-build-profile` | The one-commit, local-only `rules/config` policy replayed onto each build candidate. |
| `promote/master` | A hardware-verified refresh plus one consolidated fork-maintenance commit. |
| `maintenance/fork` | A pointer to that replayable maintenance commit at the tip of `master`. |
| `master` | The verified reusable stack plus fork maintenance. |
| `archive/*` | Immutable rollback points created before rewritten refs move. |

The legacy `ag9032v1/*` topic branches may remain as historical labels, but
they are not replay inputs. This avoids silently losing commits when one topic
branch contains more than one commit.

Keep the dynamic-port-breakout fix as one standalone reusable commit on
`integration/ag9032v1`. Do not combine it with `rules/config`, Debian archive
compatibility, or the legacy-TH runtime workaround.

## One-time push safety

Confirm the fetch URLs, make the fork the default push destination, and disable
pushes to upstream locally:

```bash
git remote get-url origin
git remote get-url --push --all origin
git remote get-url upstream
git remote get-url --push --all upstream
git config remote.pushDefault origin
git config remote.upstream.pushurl DISABLED
git config pull.ff only
git branch --set-upstream-to=origin/integration/ag9032v1 integration/ag9032v1
git branch --unset-upstream refresh/ag9032v1 2>/dev/null || true
```

The helper expects `attackofthetitan/sonic-buildimage` as `origin` and
`sonic-net/sonic-buildimage` as `upstream`. It refuses to run if upstream is
still pushable or any origin push URL does not point to the fork. Fast-forward-
only pulls prevent an accidental merge; the canonical integration branch tracks
the fork branch, while disposable refresh branches deliberately track nothing.

## Prepare

Start from a clean `master` worktree (or another stable branch containing the
helper). Do not start from a disposable refresh, build, or promotion branch. If
the breakout fix is not already in the remote integration stack, pass its
standalone commit. To replace the local build policy in the same guarded
transaction, also pass its reviewed one-commit revision:

```bash
bash scripts/fork-refresh-ag9032v1.sh \
  --breakout-fix <revision> \
  --local-profile <revision>
```

If that reviewed profile intentionally changes `DEFAULT_PASSWORD`, explicitly
add `--allow-default-password`. Do not add the flag to routine profiles.

The helper fetches both remotes, records the reviewed SHAs and requested
breakout-fix/profile SHAs in `.git`, creates dated local archives for the old
integration and master tips, and rebases the entire integration range onto the
fetched `upstream/master`. It then prints a `range-diff` and recreates
`build/ag9032v1` with only the pinned local profile applied. Without
`--local-profile`, the selected profile is the reviewed origin tip.

The local profile must be one non-merge commit changing only `rules/config`.
It may tune build mechanics and optional packages. The helper rejects a
`DEFAULT_PASSWORD` change by default; `--allow-default-password` is an explicit
exception that is recorded in the sealed state and reused for resume and final
promotion validation. The helper warns whenever the exception is active because
the plaintext credential is then present in Git and every resulting image.
Prefer per-device provisioning and rotate any shared bootstrap password.

The saved state uses a versioned, fail-closed format. Once preparation finishes,
it seals the exact refresh and build SHAs; moving either candidate requires a
new build and hardware test. A completed or legacy state is never silently
reused. Preserve it under another name before beginning the next refresh, for
example (this also works from a linked worktree):

```bash
state="$(git rev-parse --git-common-dir)/fork-refresh-ag9032v1.state"
mv "$state" "${state}.$(date -u +%Y%m%dT%H%M%SZ)"
```

Rebase and cherry-pick create or rewrite disposable local candidate commits.
The helper never pushes, promotes, or deletes refs. `--no-fetch` is available
for an intentional offline run or conflict recovery, but may use stale tracking
refs.

## Resolve or abort

Resolve rebase conflicts one commit at a time:

```bash
git status
git add <resolved-files>
git rebase --continue
# Repeat until complete, return to the branch containing the helper, then:
git switch <starting-branch-shown-by-helper>
bash scripts/fork-refresh-ag9032v1.sh --resume --no-fetch
```

To abandon the refresh without touching a remote ref:

```bash
git rebase --abort
git switch <starting-branch-shown-by-helper>
```

For a breakout or build-profile conflict, use `git cherry-pick --continue` or
`git cherry-pick --abort`. After continuing, return to the starting branch and
run `--resume --no-fetch`. The helper accepts a manually adapted, non-merge
breakout commit on the recorded pre-pick parent, but restricts it to the source
patch's paths and calls it out beside the range-diff. The build profile is
stricter: its exact tip commit must retain the saved profile's stable patch ID.
If adapting `rules/config` changes that patch ID, abort, review and replace the
canonical local-profile source, preserve the old state, then start a fresh
refresh. Inspect `git diff refresh/ag9032v1..build/ag9032v1` and the build tip
with `git show build/ag9032v1` directly because the stack range-diff does not
include the build profile. A conflicting `--breakout-fix` override is rejected.
Keep the dated archive branches until the refreshed image has passed its
observation period.

## Adopt an existing candidate

`--adopt-existing` is a narrow migration path for refresh/build branches that
were deliberately prepared before this helper state existed. Run it from the
committed `promote/master` worktree and name the trusted breakout validator and
the exact local profile when they are not yet on their canonical remote refs:

```bash
bash scripts/fork-refresh-ag9032v1.sh --adopt-existing \
  --breakout-fix <trusted-validator-revision> \
  --local-profile <reviewed-profile-revision> \
  --allow-default-password
```

Omit `--allow-default-password` when the selected profile does not change it.

This mode does not rebase, cherry-pick, or move either candidate. It validates
the current `refresh/ag9032v1` and `build/ag9032v1` refs, prints the full
range-diff, creates rollback archives, and seals their exact SHAs. It tolerates
unrelated generated build residue because validation reads committed objects,
but the four maintenance files must exactly match `promote/master`. Use normal
prepare mode after the one-time migration.

## Validate

Review every change in the printed `range-diff`. A patch may disappear because
upstream now contains it, but that must be a deliberate decision. Confirm the
candidate scopes as well:

```bash
git diff --stat upstream/master..refresh/ag9032v1
git diff --name-only refresh/ag9032v1..build/ag9032v1
```

The second command should show only `rules/config`. Before the build candidate
is created, the helper also runs `scripts/validate-ag9032v1-breakout.py` against
the reusable refresh tree and stops if the port, HWSKU, platform, or BCM
metadata is inconsistent. It also requires the platform runtime to remain
`broadcom-legacy-th`.

SONiC's outer make target considers an existing output complete without
comparing it to every platform source file. Its split root-filesystem squashfs
targets also capture the default account password and can remain stale even
when the aggregate installer is rebuilt. Preserve all previous outputs and
remove them from the active target paths before rebuilding. Rebuild and inspect
the AG9032v1 platform package first, then build the Broadcom installer set,
verify the configured password against the built root filesystem, and checksum
its machine-specific image:

```bash
PLATFORM_DEB=target/debs/trixie/platform-modules-ag9032v1_1.1_amd64.deb
BUILD_TARGET=target/sonic-broadcom.bin
DNX_IMAGE=target/sonic-broadcom-dnx.bin
IMAGE=target/sonic-broadcom-legacy-th.bin
RFS_PREFIX=target/sonic-broadcom.bin
artifact_archive="target/ag9032v1-prebuild-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$artifact_archive"
for artifact in \
    "$PLATFORM_DEB" "$BUILD_TARGET" "${BUILD_TARGET}.log" \
    "$DNX_IMAGE" "$IMAGE" \
    "${RFS_PREFIX}"__*__rfs.squashfs \
    "${RFS_PREFIX}"__*__rfs.squashfs.log; do
    [[ ! -e "$artifact" ]] || mv "$artifact" "$artifact_archive/"
done

make "$PLATFORM_DEB"
dpkg-deb --fsys-tarfile "$PLATFORM_DEB" | tar -tf - |
    grep -Fx './usr/local/bin/ag9032v1_wait_pmon_ready.sh'
dpkg-deb --fsys-tarfile "$PLATFORM_DEB" | tar -tf - |
    grep -Fx './lib/systemd/system/pmon.service.d/10-ag9032v1-platform-ready.conf'
make target/sonic-broadcom.bin
build_username="$(awk '$1 == "DEFAULT_USERNAME" { value = $3 } END { print value }' rules/config)"
build_password="$(awk '$1 == "DEFAULT_PASSWORD" { value = $3 } END { print value }' rules/config)"
shadow_hash="$(sudo awk -F: -v username="$build_username" \
    '$1 == username { print $2 }' fsroot-broadcom-legacy-th/etc/shadow)"
if [[ -z "$build_password" ]]; then
    [[ -z "$shadow_hash" ]]
else
    BUILD_PASSWORD="$build_password" SHADOW_HASH="$shadow_hash" perl -e \
        'exit crypt($ENV{BUILD_PASSWORD}, $ENV{SHADOW_HASH}) eq $ENV{SHADOW_HASH} ? 0 : 1'
fi
echo "Default password hash matches rules/config for $build_username"
test -s target/sonic-broadcom-legacy-th.bin
sha256sum target/sonic-broadcom-legacy-th.bin
```

The archive step is deliberate: the platform `.deb` must be regenerated after
platform-module or packaging changes, and the split root filesystems plus all
aggregate/dependent-machine images must be regenerated after the platform
package or local account policy changes. Keeping the old outputs under a
timestamped directory preserves rollback evidence without letting make reuse
them. The password validator compares the configured password to the built
hash without printing either value.

Do not run `make reset` before each build. In this tree it is a destructive
repository reset, not an ordinary dependency refresh: it removes every
`fsroot*`, runs `git clean -xfdf` and `git reset --hard` in the main repository
and submodules, updates submodule remotes, and discards untracked build caches
and local source changes. Use it only for an intentional from-scratch recovery
after every wanted change is committed and rollback refs exist. The targeted
archive above is sufficient for an AG9032v1 platform-package or `rules/config`
change and retains expensive unrelated dependency and container caches.

Install only `target/sonic-broadcom-legacy-th.bin` on the Delta AG9032v1. The
aggregate target emits that legacy-TH image as a dependent-machine artifact;
the generic `target/sonic-broadcom.bin` does not select AG9032v1 in its
`platforms_asic` metadata and carries the wrong SAI/OpenNSL generation.

On the rebuilt image, verify the platform API package invariant and the pmon
self-repair path as part of the boot gate:

```bash
test -s /usr/share/sonic/platform/sonic_platform-1.0-py3-none-any.whl
test -s /usr/share/sonic/platform/pddf/sonic_platform-1.0-py3-none-any.whl
systemctl is-enabled platform-modules-ag9032v1 pddf-platform-init
systemctl is-active platform-modules-ag9032v1 pddf-platform-init
# On a fresh image, pmon remains activating while it installs the platform
# wheel. It becomes active only after the API and required daemons are ready.
timeout 700 bash -c '
  until systemctl is-active --quiet pmon; do
    systemctl is-failed --quiet pmon && exit 1
    sleep 5
  done'
systemctl is-active pmon
docker exec pmon python3 -c 'from sonic_platform.platform import Platform'
docker exec pmon supervisorctl status psud thermalctld xcvrd
show platform psustatus
show platform fan
show platform temperature
```

The AG9032v1 package adds a systemd readiness gate: `pmon.service` now depends
on completed PDDF initialization and remains `activating` until the Platform
class imports and `psud`, `thermalctld`, and `xcvrd` all report `RUNNING`. If an
available Python 3 platform wheel cannot be installed or still lacks a usable
Platform class, container initialization fails instead of silently starting
without telemetry. If the wait fails, preserve `docker logs pmon` plus the
`pmon`, `pddf-platform-init`, and `platform-modules-ag9032v1` journals before
recovery. Do not use a manual `pmon` restart to pass this first-start gate.

An absent PSU's fan must report not present, not `Present / Not OK`.

Choose a parent that is still in `1x100G[40G]` mode. Use at least one parent
from each Tomahawk tile:

| Tile | Candidate parents |
| --- | --- |
| 0 | `Ethernet88`, `Ethernet96`, `Ethernet108`, `Ethernet112`, `Ethernet120`, `Ethernet124`, `Ethernet116`, `Ethernet104` |
| 1 | `Ethernet16`, `Ethernet12`, `Ethernet0`, `Ethernet4`, `Ethernet8`, `Ethernet20`, `Ethernet24`, `Ethernet28` |
| 2 | `Ethernet32` through `Ethernet60` in steps of four |
| 3 | `Ethernet64`, `Ethernet68`, `Ethernet72`, `Ethernet76`, `Ethernet84`, `Ethernet92`, `Ethernet80`, `Ethernet100` |

Prefer an unused parent. If every candidate is configured, record and
explicitly remove one port's dependencies, then restore them after the test.
Never use `--force-remove-dependencies`: a missed dependency should stop the
test instead of being deleted. Do not use `--load-predefined-config`; hardware
images do not provide the optional predefined-config file used by that mode.

Before changing a port, save an exact rollback point. This example uses
`Ethernet4`; substitute the parent selected above:

```bash
P=4
PARENT="Ethernet${P}"
CHECKPOINT="ag9032-dpb-$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/host/${CHECKPOINT}.json"
sudo config save -y
sudo cp -p /etc/sonic/config_db.json "$BACKUP"
sudo config checkpoint "$CHECKPOINT"
show interfaces breakout current-mode "$PARENT"
docker inspect -f '{{.State.Running}} {{.RestartCount}}' syncd

# Remove only the dependencies recorded above. This lab config uses Vlan1000
# plus the per-port default QoS map. The checkpoint restores both exactly.
show vlan brief
sonic-db-cli CONFIG_DB HGETALL "PORT_QOS_MAP|${PARENT}"
sudo config vlan member del 1000 "$PARENT"
sudo sonic-db-cli CONFIG_DB DEL "PORT_QOS_MAP|${PARENT}"

sudo config interface breakout "$PARENT" '4x25G[10G]' -v -y
show interfaces breakout current-mode "$PARENT"
for offset in 0 1 2 3; do
    sonic-db-cli CONFIG_DB HGETALL "PORT|Ethernet$((P + offset))"
done
docker exec syncd supervisorctl status syncd
docker exec swss supervisorctl status orchagent
docker inspect -f '{{.State.Running}} {{.RestartCount}}' syncd

sudo config interface breakout "$PARENT" '2x50G' -v -y
show interfaces breakout current-mode "$PARENT"
sonic-db-cli CONFIG_DB HGETALL "PORT|Ethernet${P}"
sonic-db-cli CONFIG_DB HGETALL "PORT|Ethernet$((P + 2))"

sudo config interface breakout "$PARENT" '1x100G[40G]' -v -y
show interfaces breakout current-mode "$PARENT"

# Restore the saved VLAN and QoS entries after the parent is back in 1x100G.
sudo config rollback "$CHECKPOINT" -v
show vlan brief
sonic-db-cli CONFIG_DB HGETALL "PORT_QOS_MAP|${PARENT}"
show interfaces breakout current-mode "$PARENT"
```

If a transition fails, do not save it. Capture `journalctl -u syncd`, syncd and
orchagent supervisor status, and ASIC/CONFIG DB state. First try to restore
`1x100G[40G]`; if that fails, run `sudo config rollback "$CHECKPOINT" -v`.
The JSON backup supports a final `config reload` recovery from the serial
console. After all live transitions pass, reuse the same controlled parent:
start from a checkpoint with its dependencies restored, remove those same
recorded dependencies, set a non-default mode, run `sudo config save -y`,
reboot, and verify that mode and its child ports. Then restore
`1x100G[40G]`, roll back the checkpoint to restore the original dependencies,
and save again. If breakout reports any dependency other than the ones
deliberately recorded and removed, stop and investigate it; do not broaden the
deletion.

During the hardware gate, verify:

- the original 1x100G layout;
- each supported breakout mode and restoration to 1x100G on at least one port
  from each of the four ASIC tiles;
- port names, lanes, aliases, speed, and persistence across reboot;
- link on every child, traffic counters, error/BER behavior, transceiver, QoS,
  and buffer behavior;
- `syncd`/SAI logs after every transition; and
- existing platform, thermal, PSU, fan, and legacy-TH behavior.

The inherited static SerDes pre-emphasis table was removed: it used obsolete
logical-port numbers, contained duplicate conflicting keys, and one static value
cannot distinguish the 100G parent from its leading 50G or 25G child. The BCM SDK
therefore selects speed-appropriate defaults, matching other Tomahawk dynamic-
flex profiles. If a child stays down or accumulates errors, capture the SDK state
and add lab-calibrated, mode/media-aware runtime tuning rather than restoring the
legacy 100G values. A successful image build or CLI transition alone is not
sufficient for promotion.

## Promote

After hardware verification, create `promote/master` from the reusable
candidate and add exactly one consolidated maintenance commit:

```bash
git switch -C promote/master refresh/ag9032v1
git cherry-pick origin/maintenance/fork
```

During the one-time migration from the existing three-commit maintenance
history, create one replacement commit instead. The helper requires this exact
four-file change set:

- `FORK_MAINTENANCE.md`;
- `scripts/fork-refresh-ag9032v1.sh`;
- `.github/workflows/upstream-drift.yml`; and
- the fork workaround in `.github/workflows/protect-file.yml`.

Ask the helper to validate the candidate and print the exact promotion command:

```bash
bash scripts/fork-refresh-ag9032v1.sh --print-promotion
```

It verifies the single maintenance commit and path allowlist, checks that the
four maintenance files in the worktree exactly match that commit, confirms the
sealed candidate and reviewed origin tips have not moved, and prints one manual
`git push --atomic` command. Every updated ref has an explicit lease, including
the selected local-profile ref and an absence lease for each new immutable
archive, and every source is a pinned raw SHA. The same transaction publishes
the dated rollback refs. The helper does not run the command or switch branches.
It permits unrelated build residue during this final read-only check, but never
permits uncommitted maintenance content to influence the printed promotion.

On later refreshes the new maintenance tip must retain the saved
`origin/maintenance/fork` commit's stable patch ID. If an upstream conflict
requires a semantic maintenance change, do not weaken the check: review and
replace the canonical maintenance source with an explicit lease, preserve the
old refresh state, and start a fresh preparation so the new source SHA is pinned
before any candidate is built.

Read the printed command before copying it. Never replace its leases with plain
`--force`, and never promote `build/ag9032v1`.

## Roll back and clean up

If deployment fails, identify the dated integration and master archives from
the helper output. Verify their SHAs and restore both canonical refs using the
same atomic, explicit-lease pattern. Do not use `git reset --hard`, delete the
candidate, or remove archives during diagnosis.

After a successful observation period, stale `refresh/*`, `build/*`, old
maintenance branches, and superseded topic refs may be pruned separately.

## Drift alert

`.github/workflows/upstream-drift.yml` runs weekly and on manual dispatch. It
reports the exact fork, upstream, and merge-base SHAs plus both unique-commit
counts. It maintains an issue without merging, pushing, or changing repository
contents.
