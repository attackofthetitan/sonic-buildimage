# Fork Maintenance

Delta AG9032v1 support is maintained as a reusable stack on top of
`sonic-net/sonic-buildimage:master`. Keep reusable platform support, local build
policy, and archive branches separate.

## Stack

`integration/ag9032v1` should point at the final reusable feature branch:

1. `ag9032v1/kernel-modules`
2. `ag9032v1/package-module`
3. `ag9032v1/pddf-init`
4. `ag9032v1/device-pddf-data`
5. `ag9032v1/platform-api`
6. `ag9032v1/thermal-control`
7. `ag9032v1/port-qos-components`
8. `ag9032v1/runtime-legacy-th`

`local/ag9032v1-build-profile` is only local `rules/config` policy. Package
wiring stays upstream-style. `local/debian-archive-compat` is optional and only
for builds that still need Bullseye archive backports.

## Refresh

```bash
git fetch --prune upstream
git fetch --prune origin
git branch archive/ag9032v1-integration-YYYYMMDD origin/integration/ag9032v1
git switch -C refresh/ag9032v1 upstream/master

git cherry-pick origin/ag9032v1/kernel-modules
git cherry-pick origin/ag9032v1/package-module
git cherry-pick origin/ag9032v1/pddf-init
git cherry-pick origin/ag9032v1/device-pddf-data
git cherry-pick origin/ag9032v1/platform-api
git cherry-pick origin/ag9032v1/thermal-control
git cherry-pick origin/ag9032v1/port-qos-components
git cherry-pick origin/ag9032v1/runtime-legacy-th
```

Resolve conflicts one commit at a time and keep commit boundaries intact. Do
not restore broad upstream `.bcm` churn as a runtime workaround; keep `.bcm`
changes limited to AG9032v1 unless the change is intentionally upstream-wide.

## Runtime Branch

`ag9032v1/runtime-legacy-th` carries the AG9032v1 Broadcom runtime workaround:

- `device/delta/x86_64-delta_ag9032v1-r0/platform_asic` is
  `broadcom-legacy-th`.
- `platform/broadcom/one-image.mk` installs
  `$(BRCM_LEGACY_TH_OPENNSL_KERNEL)` for one-image builds.
- `device/delta/x86_64-delta_ag9032v1-r0/Delta-ag9032v1/sai.profile` disables
  `SAI_STATS_ST_CAPABILITY_SUPPORTED` and `SAI_STATS_EXT_SWITCH_SUPPORTED`.

## Build

```bash
git switch -C build/ag9032v1 refresh/ag9032v1
git cherry-pick origin/local/ag9032v1-build-profile
# Optional only when required:
git cherry-pick origin/local/debian-archive-compat
```

Before building, remove stale AG9032v1 package wiring from ignored
`rules/config.user`; the reusable stack already registers
`DELTA_AG9032V1_PLATFORM_MODULE`. Build `target/sonic-broadcom.bin` and test it
on the switch before promotion.

## Promote

After hardware verification, archive the previous integration tip, move each
`ag9032v1/*` branch to the refreshed commit that represents that step, and move
`integration/ag9032v1` to `ag9032v1/runtime-legacy-th`.

Use `git push --force-with-lease` for rewritten stacked branches. Avoid plain
`--force`.

## Drift

`.github/workflows/upstream-drift.yml` reports when the default branch falls
behind upstream. It intentionally does not merge automatically; refresh, build,
and hardware-test the stack before moving `master`.
