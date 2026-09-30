---
title: Anycubic ACE via multiACE
---

# Anycubic ACE via multiACE

This experimental integration is provided by the rolling-only
`extended-multiace` firmware profile. It is not included in stable firmware
images. The PAXX-managed multiACE provider package is downloaded only when
selected in Firmware Config; it is not bundled into the firmware image.

This draft now pins a published **test prerelease** of the provider. It is for
hardware validation on the rolling `extended-multiace` image only; it is not a
stable multiACE release, and ACE behavior has not yet been fully validated on a
connected printer.

The PAXX integration follows the same general model used by other optional
third-party applications in this firmware: the provider release is pinned in
the firmware source, downloaded on demand, and verified with a SHA256 checksum.

## Enable it

1. Install the `extended-multiace` image from the project's rolling release.
2. Open **Firmware Config** and then **Snapmaker Components**.
3. Set **Anycubic ACE** to **multiACE (pinned package)**.
4. Confirm the action and allow the printer to reboot.

For firmware updates, select the `develop` upgrade channel. The rolling
release includes a matching `extended-multiace` image; stable and testing
releases do not.

Remove any separately installed or manually started multiACE copy before
enabling this option. Two copies must not be active at the same time: they can
both try to provide the same Klipper modules or web port.

The first installation also installs the provider's constrained web
dependencies into the versioned MultiACE package. This may take longer than
subsequent starts and requires the printer to be able to download the package
and dependencies. The dependencies therefore survive reboot without requiring
the firmware's debug-persistence mode.

## What PAXX manages

The firmware owns the integration boundary while the provider owns its ACE
behavior:

- The exact provider release URL and SHA256 checksum are pinned in the
  firmware package definition.
- The release is installed under `/oem/apps/multiace/` with a `latest` link.
- Provider Klipper modules are mounted read-only over their stock paths only
  when `components ace: multiace` is selected.
- The stock files are not overwritten. Disabling the component removes the
  mounts and restores the stock paths on the next Klipper start.
- Persistent configuration is kept under
  `/home/lava/printer_data/config/extended/multiace/`.
- The provider configuration is linked into the normal extended Klipper
  include directory only while the managed integration is enabled.
- The web UI is served through the authenticated Fluidd or Mainsail origin at
  `/multiace/`; its backend listens only on localhost.
- The managed provider package disables standalone install, uninstall,
  self-update, and file-copy mode switching. multiACE-to-head runtime mode
  changes remain available. PAXX owns package upgrades through the reviewed
  version and checksum pin.
- PAXX retains an idempotent cleanup for stale update-wrapper macros in
  persistent configs created by the older test archive; it does not pass the
  legacy update-disable environment flag. The managed provider package ships
  without those wrappers and enforces managed mode itself.

The integration uses the platform-neutral `.multiace-managed` marker in its
persistent state directory. Decay's managed-package PR defines this provider
contract:

- `MULTIACE_MANAGED=1`
- `MULTIACE_MANAGED_MARKER`
- `MULTIACE_APP_DIR`
- `MULTIACE_CONFIG_DIR` (the directory containing `printer.cfg`,
  `/home/lava/printer_data/config` on the U1)
- `MULTIACE_PRINTER_DATA`

The marker and paths let multiACE distinguish a platform-managed install from
its standalone installation without coupling provider code to PAXX-specific
paths or names. PAXX passes the five-variable contract to the managed web
service and preserves the provider's default U1 paths for Klipper.

## Disable or remove it

In Firmware Config, set **Anycubic ACE** to **Disabled** and confirm the
reboot. The PAXX service stops the web UI, removes the provider mounts, and
removes the downloaded package. Persistent ACE configuration is intentionally
left in place so it can be inspected or reused if the integration is enabled
again.

If a package is present but cannot be activated, the activation hook fails
closed: it unmounts any partial provider mounts and leaves the stock Klipper
paths available. A conflicting file or an already occupied provider web port
is treated as an error rather than silently replacing another installation.

## Current pin and scope

For this hardware-test build, PAXX pins multiACE version `1.11b` from the
[`v1.11b-test.090d54d` prerelease](https://github.com/decay71/multiACE/releases/tag/v1.11b-test.090d54d),
built from commit [`090d54d`](https://github.com/decay71/multiACE/commit/090d54da9a7aa52f72ed9e2049306f330827e2d0)
on [multiACE PR #151](https://github.com/decay71/multiACE/pull/151). The exact
managed archive URL and SHA256 are pinned in the package definition; the
installer does not follow a moving `latest` release or an unverified branch.
This prerelease is temporary test input, not the stable update channel.

This is a draft integration for hardware testing. It has been checked for
package structure, checksum verification, shell syntax, and provider-side
managed-boundary tests; ACE loading, unloading, tool changes, recovery, and
long-print behavior still require testing on a connected printer.

The PR adds `overlays/mods/multiace/` and a separate `extended-multiace`
rolling image; it does not add multiACE to the stable release workflow or
combine it with the AFC profile.
