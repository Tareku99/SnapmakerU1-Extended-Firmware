---
title: Anycubic ACE via multiACE
---

# Anycubic ACE via multiACE

This firmware can install an experimental, PAXX-managed multiACE package for
Anycubic ACE and ACE 2 Pro hardware. The provider is downloaded only when
selected in Firmware Config; it is not bundled into the firmware image.

The PAXX integration follows the same general model used by other optional
third-party applications in this firmware: the provider release is pinned in
the firmware source, downloaded on demand, and verified with a SHA256 checksum.

## Enable it

1. Open **Firmware Config**.
2. Open **Snapmaker Components**.
3. Set **Anycubic ACE** to **multiACE (pinned package)**.
4. Confirm the action and allow the printer to reboot.

Remove any separately installed or manually started multiACE copy before
enabling this option. Two copies must not be active at the same time: they can
both try to provide the same Klipper modules or web port.

The first installation also installs the provider's constrained web
dependencies into the persistent `lava` user Python environment. This may take
longer than subsequent starts and requires the printer to be able to download
the package and dependencies.

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
  controlled by a reviewed firmware package pin.

The managed installation leaves a marker at
`/oem/apps/multiace/.paxx-managed`. It is used by the provider to distinguish
this installation from a standalone deployment.

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

This branch currently pins the PAXX-managed provider release
`multiace-v1.00.1b` from the [Tareku99/multiACE fork](https://github.com/Tareku99/multiACE/releases/tag/multiace-v1.00.1b).
The archive and checksum are intentionally changed only through a reviewed
firmware commit.

This is a draft integration for hardware testing. It has been checked for
package structure, checksum verification, shell syntax, and provider-side
managed-boundary tests; ACE loading, unloading, tool changes, recovery, and
long-print behavior still require testing on a connected printer.

For the package boundary and provider-side implementation, see the
[multiACE managed-package PR](https://github.com/Tareku99/multiACE/pull/1).
