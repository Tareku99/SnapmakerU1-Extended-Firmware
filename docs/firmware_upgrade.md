---
title: Firmware Upgrade Channels
---

# Firmware Upgrade Channels

Controls how the stock `unisrv` firmware-update check behaves, via the
`components.upgrade` setting in `extended/extended2.cfg`.

Stock firmware periodically asks `https://id.snapmaker.com/api/device/firmware/latest`
whether a new build is available. This project can redirect that check to a
community-run mirror, or disable it outright.

> **Note:** This only has an effect if the printer is connected to Snapmaker
> Cloud. `unisrv` only performs the firmware-update check while signed in, so
> `components.upgrade` is a no-op on a printer that doesn't use Snapmaker Cloud.

## Channels

```ini
[components]
upgrade: none   # or: stable, testing, develop
```

- **none** (default) — the update check fails immediately without making
  any network request at all, so the device never contacts any update host.
- **stable** — redirects the check to a Cloudflare Pages mirror tracking the
  latest tagged [GitHub release](https://github.com/paxx12/SnapmakerU1/releases)
  of this project.
- **testing** — same mirror, but tracks whichever of a release or pre-release
  is newest.
- **develop** — same mirror, but tracks the latest build off the `develop`
  branch — whatever is queued for the next release, ahead of any tag.

## What is being sent

When `stable`, `testing`, or `develop` is selected, `unisrv`'s update-check
request is rewritten to the mirror with the following query parameters:

| Parameter | Source | Example |
|-----------|--------|---------|
| `channel` | the selected value (`stable`/`testing`/`develop`) | `stable` |
| `version` | `/etc/VERSION` — stock firmware version | `1.5.1` |
| `build_version` | `/etc/BUILD_VERSION` — this project's `git describe` string | `0.9.0-paxx12-1-gabcdef0` |
| `build_profile` | `/etc/BUILD_PROFILE` — the build profile used | `extended` |

The device's own `Authorization: Bearer` token is stripped before the
request is sent, so no Snapmaker account credentials reach the mirror.
Nothing else from the request is forwarded — no printer serial number,
network info, or usage data.

When `none` is selected, no request is made at all: the check is failed
locally before any network I/O happens.

See [`overlays/firmware-extended/40-feature-upgrade-firmware`](https://github.com/paxx12/SnapmakerU1/tree/main/overlays/firmware-extended/40-feature-upgrade-firmware)
for the implementation.

## Upgrade safety

The firmware-config upload and download actions accept a firmware container or
a ZIP containing exactly one firmware container. An archive with zero or
multiple `.bin` files is rejected instead of choosing one arbitrarily.

Before printer services are stopped, a bundled parser checks the U1 SNMK
container (format versions 1 and 2), its header and entry checksums, payload
bounds, and each payload's MD5. It then accepts the Rockchip RKAF or RKFW
image formats. Bundling the parser avoids relying on upfileUnpack, which is
not present in every firmware base. These checks detect malformed or corrupted
containers; they are not a cryptographic signature or proof of publisher
identity. A failed preflight stops the operation before the vendor updater is
called. The UI reports preflight failure, upgrade progress, and reboot pending
separately; reaching the vendor updater's reboot boundary is not presented as
proof that the new firmware has booted successfully.

The stronger rootfs, partition, protected-`misc`, and provenance checks run in
the build and CI pipeline. The printer-side preflight is intentionally a small
transport/container check and does not execute code from the candidate image.

## Post-boot health gate

The upgrade flow also records a pending upgrade in
`/userdata/.extended-firmware-upgrade` immediately before calling the vendor
updater through Firmware Config's URL, Upload, or community-channel action. A
candidate carrying this project's commit identity is marked `pending`. On the
next boot, the guard waits for the new A/B slot and checks that the candidate
commit matches `/etc/BUILD_VERSION`, required runtime files are readable,
Moonraker can reach Klipper in `ready` state, and the firmware-config API is
healthy when it is enabled.

Three consecutive healthy checks mark the candidate `verified`. If the new slot
does not become healthy before the bounded retry window, the guard performs one
vendor-supported backup-slot request (`updateEngine --misc=other --reboot`). It
does not erase `/oem` settings, write the `misc` partition directly, or retry a
rollback indefinitely. The result is shown in Firmware Config under **Firmware
Upgrade Safety** as `pending`, `verified`, `rollback requested`, `rollback
failed`, `not switched`, or `not monitored`.

A package without this project's commit identity (for example, stock firmware)
can still be installed after the container preflight, but is recorded as `not
monitored`: the post-boot guard cannot claim that such a package contains this
project's health checks. If a monitored upgrade remains pending because the
guard never ran, a new user-requested upgrade can replace that stale state after
15 minutes; a recent pending upgrade is left alone so its health/rollback window
can finish.

This is defense in depth, not a bootloader guarantee: if a candidate fails so
early that the new root filesystem cannot start the guard, the vendor bootloader
must provide its own boot-count fallback. The build-time validator remains the
first line of defense, and the post-boot gate is intentionally limited to the
existing A/B switch operation. Updates performed directly through USB recovery
or Rockchip tools do not create this pending record and therefore remain a
manual recovery path.
