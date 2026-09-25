# Fork Maintenance

Delta AG9032v1 support is kept as a reusable, linear patch stack on top of
`sonic-net/sonic-buildimage:master`. Fork automation and local build policy are
kept outside that stack.

## Canonical branches

| Branch | Purpose |
| --- | --- |
| `integration/ag9032v1` | The canonical reusable AG9032v1 patch stack. Refresh this complete range. |
| `refresh/ag9032v1` | A disposable candidate rebased onto the selected upstream SHA. |
| `build/ag9032v1` | The refresh candidate plus local `rules/config` policy. Never promote it. |
| `local/ag9032v1-build-profile` | The one-commit, local-only `rules/config` policy replayed onto each build candidate. |
| `promote/master` | A hardware-verified refresh plus one consolidated fork-maintenance commit. |
| `maintenance/fork` | That replayable maintenance commit, on top of the integration tip. |
| `master` | The verified reusable stack plus fork maintenance. |
| `archive/*` | Immutable rollback points created before rewritten refs move. |

The former `ag9032v1/*` topic branches are retired. Never replay topic tips:
one topic branch could hold several commits, so replaying tips silently lost
work.

Keep the dynamic-port-breakout fix as one standalone reusable commit on
`integration/ag9032v1`. Do not combine it with `rules/config`, Debian archive
compatibility, or the legacy-TH runtime workaround. Likewise, keep any change
to a file shared by every platform, such as
`dockers/docker-platform-monitor/docker_init.j2`, in its own standalone commit
so it can be proposed upstream and dropped from the stack once merged.

The maintenance commit changes exactly these files, listed in
`MAINTENANCE_FILES` in the helper:

- `FORK_MAINTENANCE.md`;
- `scripts/fork-refresh-ag9032v1.sh`;
- `scripts/build-ag9032v1.sh`;
- `.github/workflows/upstream-drift.yml`; and
- the fork workaround in `.github/workflows/protect-file.yml`.

## Worktrees

Use two worktrees of the same repository:

| Worktree | Checked out | Used for |
| --- | --- | --- |
| Maintenance, for example `../sonic-buildimage-maint` | `master`, or another stable branch containing the helper | `--check`, prepare, conflict resolution, promotion |
| Build | `build/ag9032v1` | `make`, which leaves untracked outputs and dirty submodules |

The helper refuses a worktree with any change or untracked file, which a build
worktree never satisfies, and Git refuses to reset a branch that another
worktree has checked out. Create the maintenance worktree once:

```bash
git worktree add ../sonic-buildimage-maint master
```

Before preparing, detach the build worktree so the build branch is free. The
helper stops with this command if you forget:

```bash
git -C <build-worktree> switch --detach
```

The saved refresh state lives in the shared Git directory, so both worktrees
see it.

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

## Check before refreshing

Preview the next refresh without changing refs, files, or saved state:

```bash
bash scripts/fork-refresh-ag9032v1.sh --check
```

The check replays the integration stack onto `upstream/master` in a private
index and prints a Markdown table. Each commit is `ok`, `dropped` (already
upstream, so it will disappear from the range-diff), or `conflict` with the
conflicting paths. It then replays the maintenance commit and the local profile
on top, reports whether each keeps its stable patch ID, and runs the runtime
target and breakout metadata checks against the replayed tree. Exit status 2
means something needs attention. The drift workflow runs the same check weekly.

## Prepare

From the clean maintenance worktree, run:

```bash
bash scripts/fork-refresh-ag9032v1.sh
```

To replace the local build policy in the same guarded transaction, pass its
reviewed one-commit revision with `--local-profile <revision>`. If that
reviewed profile intentionally changes `DEFAULT_PASSWORD`, explicitly add
`--allow-default-password`. Do not add the flag to routine profiles.

The helper fetches both remotes and records the reviewed SHAs and the selected
profile SHA in `.git`. It creates dated local archives for the old integration
and master tips, reusing an unpublished pair that an aborted run left for the
same tips. It then rebases the entire integration range onto the fetched
`upstream/master`, prints a `range-diff`, and recreates `build/ag9032v1` with
only the pinned local profile applied. Finally it returns to the starting
branch and prints the build and promotion commands. Without `--local-profile`,
the selected profile is the reviewed origin tip.

To add or adapt a reusable commit, such as a new standalone fix, add
`--pause-after-rebase`. The helper stops on `refresh/ag9032v1` after a clean
rebase. Commit the change there, keep the stack linear, return to the starting
branch, and run `--resume --no-fetch`. The range-diff shows the addition.

The local profile must be one non-merge commit changing only `rules/config`.
It may tune build mechanics and optional packages. The helper rejects a
`DEFAULT_PASSWORD` change by default; `--allow-default-password` is an explicit
exception that is recorded in the sealed state and reused for resume and final
promotion validation. The helper warns whenever the exception is active because
the plaintext credential is then present in Git and every resulting image.
Prefer per-device provisioning and rotate any shared bootstrap password.

The saved state uses a versioned, fail-closed format. Once preparation
finishes, it seals the exact refresh and build SHAs; moving either candidate
requires a new build and hardware test. When a completed state's refresh
candidate is already on `origin/integration/ag9032v1`, prepare preserves it as
`fork-refresh-ag9032v1.state.promoted-<timestamp>` automatically. Any other
existing state blocks a fresh prepare: resume it, or preserve it under another
name first. States written by older helper versions are never resumed.

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

When a conflict is in a file shared by every platform, start from upstream's
version and re-apply only the behavior the fork still needs. If that behavior
is generic, move it into a standalone commit before resuming.

To abandon the refresh without touching a remote ref:

```bash
git rebase --abort
git switch <starting-branch-shown-by-helper>
```

For a build-profile conflict, use `git cherry-pick --continue` or
`git cherry-pick --abort`. After continuing, return to the starting branch and
run `--resume --no-fetch`. The build profile's exact tip commit must retain the
saved profile's stable patch ID. If adapting `rules/config` changes that patch
ID, abort, review and replace the canonical local-profile source, preserve the
old state, then start a fresh refresh. Inspect
`git diff refresh/ag9032v1..build/ag9032v1` and the build tip with
`git show build/ag9032v1` directly because the stack range-diff does not
include the build profile. Keep the dated archive branches until the refreshed
image has passed its observation period.

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

### Build

In the build worktree, check out the sealed candidate, synchronize submodules,
and run the build script from the maintenance worktree:

```bash
git switch build/ag9032v1
make init
bash ../sonic-buildimage-maint/scripts/build-ag9032v1.sh
```

`make init` runs `git submodule update --init --recursive`. Without it,
submodules keep whatever commit the previous build left, and the image mixes
old submodule sources with the refreshed superproject. The build script first
checks that the worktree is the sealed `build/ag9032v1`, that tracked files
match it, and that every submodule contains its recorded commit. Build-time
patch commits on top of a recorded commit, such as FRR's, are allowed.
`--preflight` stops after these checks.

The script then:

1. moves the AG9032v1 platform `.deb`, the Broadcom installer images and their
   logs, and the split root-filesystem squashfs files into
   `target/ag9032v1-prebuild-<timestamp>/`;
2. rebuilds the platform package and checks that it ships
   `ag9032v1_wait_pmon_ready.sh` and the pmon `10-ag9032v1-platform-ready.conf`
   drop-in;
3. builds `target/sonic-broadcom.bin`, which also emits the legacy-TH image;
4. verifies the configured default password against the built root
   filesystem without printing either value; and
5. prints the SHA-256 of `target/sonic-broadcom-legacy-th.bin`.

SONiC's outer make target considers an existing output complete without
comparing it to every platform source file. Its split root-filesystem squashfs
targets also capture the default account password and can remain stale even
when the aggregate installer is rebuilt. That is why the script moves the old
outputs aside: the platform `.deb` must be regenerated after platform-module or
packaging changes, and the split root filesystems plus all
aggregate/dependent-machine images must be regenerated after the platform
package or local account policy changes. The timestamped directory preserves
rollback evidence without letting make reuse it.

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

### Hardware gate

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

After hardware verification, create `promote/master` in the maintenance
worktree from the reusable candidate, add exactly one consolidated maintenance
commit, and ask the helper to validate it. Prepare prints these commands with
pinned SHAs:

```bash
git switch -C promote/master refresh/ag9032v1
git cherry-pick origin/maintenance/fork
bash scripts/fork-refresh-ag9032v1.sh --print-promotion
```

The helper verifies the single maintenance commit and path allowlist, checks
that the maintenance files in the worktree exactly match that commit, confirms
the sealed candidate and reviewed origin tips have not moved, and prints one
manual `git push --atomic` command. Every updated ref has an explicit lease,
including the selected local-profile ref and an absence lease for each new
immutable archive, and every source is a pinned raw SHA. The same transaction
publishes the dated rollback refs. The helper does not run the command or switch
branches. It permits unrelated build residue during this final read-only check,
but never permits uncommitted maintenance content to influence the printed
promotion.

The new maintenance tip must retain the saved `origin/maintenance/fork`
commit's stable patch ID. If an upstream conflict requires a semantic
maintenance change, do not weaken the check: publish the change as a
maintenance-only update (below), preserve the old refresh state, and start a
fresh preparation so the new source SHA is pinned before any candidate is built.

Read the printed command before copying it. Never replace its leases with plain
`--force`, and never promote `build/ag9032v1`.

After the push succeeds, bring the local copies of the rewritten refs up to
date so nobody reads a stale guide or helper from them. Their previous tips are
in the archives the push just published:

```bash
git fetch --prune origin
git switch -C master origin/master
git branch -f integration/ag9032v1 origin/integration/ag9032v1
git branch -f maintenance/fork origin/maintenance/fork
```

## Maintenance-only updates

A change that touches only the maintenance files cannot change the image, so it
needs no stack refresh or hardware test. Publish it only while no prepared
candidate is waiting for promotion, because a saved state pins
`origin/master` and `origin/maintenance/fork`.

```bash
git switch -C maintenance/fork-next origin/master
# Edit and test the maintenance files, then:
git commit -a
update="$(git rev-parse HEAD)"
git reset --soft origin/integration/ag9032v1
git commit -C origin/maintenance/fork
test "$(git rev-parse HEAD^{tree})" = "$(git rev-parse "$update^{tree}")"
git push --atomic \
  --force-with-lease=refs/heads/master:"$(git rev-parse origin/master)" \
  --force-with-lease=refs/heads/maintenance/fork:"$(git rev-parse origin/maintenance/fork)" \
  origin "$update:refs/heads/master" "HEAD:refs/heads/maintenance/fork"
```

`master` fast-forwards to the incremental commit, and `maintenance/fork` is
replaced by one squashed commit with the same tree on top of the integration
tip. The next promotion restores `master` to the single-commit shape.

## Roll back and clean up

If deployment fails, identify the dated integration and master archives from
the helper output. Verify their SHAs and restore both canonical refs using the
same atomic, explicit-lease pattern. Do not use `git reset --hard`, delete the
candidate, or remove archives during diagnosis.

After the refreshed image passes its observation period, prune separately:

- keep the canonical branches above and the archive pair published by the most
  recent promotion, which is the current rollback point;
- delete stale local `refresh/*`, `build/*`, and `promote/*` variants, scratch
  branches, unpublished local archives, and older archive pairs on `origin`;
- first save anything deleted that no kept ref still reaches:

```bash
git bundle create ~/sonic-fork-pruned-"$(date -u +%Y%m%d)".bundle \
  <refs-to-delete...> --not origin/master upstream/master
```

## GitHub Actions

`.github/workflows/upstream-drift.yml` runs weekly and on manual dispatch. It
reports the fork, upstream, and merge-base SHAs, the merge base's age, both
unique-commit counts, and the `--check` replay report. It keeps one issue up to
date and adds a comment, which notifies, whenever the merge base crosses 14,
30, 60, or 90 days old or the replay result changes. It never merges, pushes,
or changes repository contents.

Upstream workflows that only make sense in `sonic-net/sonic-buildimage` are
disabled in the fork's Actions settings instead of edited, so refreshes never
conflict on them: automerge, AutoMergeScan, PreCherryPick, PostCherryPick,
Labeler, CodeQL, and Semgrep. Check the list again when a refresh brings new
upstream workflows. `protect-file.yml` stays enabled with its fork workaround.
