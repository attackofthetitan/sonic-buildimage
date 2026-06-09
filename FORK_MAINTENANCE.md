# Fork Maintenance

This fork carries Delta AG9032v1 platform support as a small stacked series on
top of `sonic-net/sonic-buildimage:master`. Keep reusable platform support,
fork-maintenance automation, and local build policy separate.

## Branch Roles

| Branch | Purpose |
| --- | --- |
| `archive/ag9032v1-linear-20260601` | Permanent archive of the original linear development history. |
| `ag9032v1/kernel-modules` | Kernel-facing AG9032v1 module changes. |
| `ag9032v1/package-module` | Debian packaging, Python wheel, and Broadcom build wiring. |
| `ag9032v1/pddf-init` | Deterministic PDDF startup ordering. |
| `ag9032v1/device-pddf-data` | Device metadata, PDDF data, and daemon controls. |
| `ag9032v1/platform-api` | SONiC platform API implementation. |
| `ag9032v1/thermal-control` | Thermal policy and fan handling. |
| `ag9032v1/port-qos-components` | Breakout, QoS, final port configuration, components, and legacy Tomahawk SAI runtime wiring. |
| `integration/ag9032v1` | Reusable AG9032v1 stack. This should point at `ag9032v1/port-qos-components`. |
| `maintenance/upstream-drift` | Weekly alert when the default branch falls behind upstream. |
| `local/ag9032v1-build-profile` | Optional local `rules/config` policy. Keep package wiring upstream-style and do not merge into the reusable stack. |
| `local/debian-archive-compat` | Optional Bullseye archive compatibility. Apply only when required. |

## Refresh From Upstream

Fetch both remotes and record the current integration tip before rebuilding the
stack:

```bash
git fetch --prune upstream
git fetch --prune origin
git branch archive/ag9032v1-integration-YYYYMMDD origin/integration/ag9032v1
git switch --create refresh/ag9032v1 upstream/master
```

Cherry-pick the reusable commits in order:

```bash
git cherry-pick origin/ag9032v1/kernel-modules
git cherry-pick origin/ag9032v1/package-module
git cherry-pick origin/ag9032v1/pddf-init
git cherry-pick origin/ag9032v1/device-pddf-data
git cherry-pick origin/ag9032v1/platform-api
git cherry-pick origin/ag9032v1/thermal-control
git cherry-pick origin/ag9032v1/port-qos-components
```

Resolve conflicts one commit at a time. Keep the commit boundaries intact so a
kernel, packaging, PDDF, API, thermal, or QoS regression can be isolated later.

## AG9032v1 Broadcom Runtime Notes

AG9032v1 is a Tomahawk platform that must use the legacy TH Broadcom SAI path
with current upstream. The minimal runtime fix is:

- `device/delta/x86_64-delta_ag9032v1-r0/platform_asic` is
  `broadcom-legacy-th`.
- `platform/broadcom/one-image.mk` installs
  `$(BRCM_LEGACY_TH_OPENNSL_KERNEL)` for the one-image target so
  `opennsl-modules.service` exists.
- `device/delta/x86_64-delta_ag9032v1-r0/Delta-ag9032v1/sai.profile` sets
  `SAI_STATS_ST_CAPABILITY_SUPPORTED=0` and
  `SAI_STATS_EXT_SWITCH_SUPPORTED=0`.

Do not restore broad upstream `.bcm` churn as a runtime workaround. Keep
AG9032v1 `.bcm` changes limited to AG9032v1 port or SDK configuration changes.

## Build Locally

Create a disposable build branch from the refreshed integration tip and apply
local policy only there. The local build profile should only preserve local
`rules/config` choices; it should not comment out other vendors or Delta
platform packages.

```bash
git switch --create build/ag9032v1 refresh/ag9032v1
git cherry-pick origin/local/ag9032v1-build-profile
```

Apply `origin/local/debian-archive-compat` only for a build that still needs
Bullseye archive backports. Initialize submodules, configure the Broadcom
platform build, and produce the image using the normal SONiC build process.
Confirm that `target/sonic-broadcom.bin` exists and test the image on the target
hardware before promotion.

Before building, remove stale AG9032v1 package wiring from the ignored local
`rules/config.user` file. The reusable stack already registers
`DELTA_AG9032V1_PLATFORM_MODULE`; registering it again in `rules/config.user`
causes GNU Make to report that the generated package targets were given more
than once in the same rule.

## Promote A Refresh

After build and hardware verification:

1. Preserve the previous integration tip under an archive branch.
2. Move the seven `ag9032v1/*` branch pointers to the refreshed commit series.
3. Move `integration/ag9032v1` to the refreshed final feature commit.
4. Recreate the optional local build branches on the refreshed integration tip.
5. Apply the independent maintenance commits when preparing the default branch.
6. Update `master` only after reviewing the resulting diff and retaining the archive branches.

Use `git push --force-with-lease` when moving an existing stacked branch. Avoid
plain `--force`: the lease prevents overwriting a remote update that was not
part of the refresh.

## Weekly Drift Alert

`.github/workflows/upstream-drift.yml` runs every Monday and can also be
dispatched manually. It opens or updates a maintenance issue when the default
branch is behind `sonic-net/sonic-buildimage:master`.

The workflow intentionally reports drift instead of merging upstream
automatically. Rebuild and verify the stack before moving the default branch.
