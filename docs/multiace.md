---
title: Anycubic ACE via multiACE
---

# Anycubic ACE via multiACE

This experimental integration is provided by the rolling-only
`extended-multiace` firmware profile. It is not included in stable firmware
images. The PAXX-managed multiACE provider package is downloaded only when
selected in Firmware Config; it is not bundled into the firmware image.

**This draft is not currently ready to enable on a printer.** Its legacy test
package URL currently returns 404. Wait until Decay merges the provider
contract and publishes the managed archive and checksum, then until PAXX pins
that release in this integration.

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
- Provider self-update and mode-switch actions are disabled so upgrades remain
  controlled by a reviewed firmware package pin. With the current test archive,
  PAXX removes the `ACEH__Update_Check` and `ACEH__Update_Apply` wrapper macros
  and sets its legacy update-disable flag. The Decay managed archive will own
  those guards; PAXX should drop this compatibility handling when it switches
  to that archive.

The integration uses the platform-neutral `.multiace-managed` marker in its
persistent state directory. Decay's managed-package PR defines this provider
contract:

- `MULTIACE_MANAGED=1`
- `MULTIACE_MANAGED_MARKER`
- `MULTIACE_APP_DIR`
- `MULTIACE_CONFIG_DIR`
- `MULTIACE_PRINTER_DATA`

The marker and paths let multiACE distinguish a platform-managed install from
its standalone installation without coupling provider code to PAXX-specific
paths or names. While this branch still pins the older Tareku test archive,
PAXX keeps a temporary compatibility adapter for that archive's legacy path
variables. The adapter must be switched to this five-variable contract in the
same reviewed change that pins Decay's released managed archive and checksum;
the unmerged PR is not used as a firmware package source.

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

This test branch still contains the old `multiace-v1.00.1b` test-archive pin,
whose Tareku fork URL currently returns 404. The long-term provider change is under review in
[decay71/multiACE PR #151](https://github.com/decay71/multiACE/pull/151).
PAXX must not substitute a branch archive or invent a checksum. The package
URL, checksum, and runtime environment contract must be updated together after
that PR is merged and Decay publishes the managed release archive and SHA256.

This is a draft integration for hardware testing. It has been checked for
package structure, checksum verification, shell syntax, and provider-side
managed-boundary tests; ACE loading, unloading, tool changes, recovery, and
long-print behavior still require testing on a connected printer.

The PR adds `overlays/mods/multiace/` and a separate `extended-multiace`
rolling image; it does not add multiACE to the stable release workflow or
combine it with the AFC profile.
