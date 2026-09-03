# DFUUtility

DFUUtility is an open-source native macOS utility for entering supported Macs into DFU mode and restoring or reviving Apple devices with Apple IPSWs.

![DFUUtility multi-device workflow](docs/images/multiple-devices.png)

Version 0.7.0 adds independent multi-device sessions, sequential batch operations, product-specific mobile firmware/cache handling, exact cached-firmware assignment, and improved Mac DFU diagnostics. Community builds are local and ad-hoc signed; no paid Apple Developer account is required.

## Features

### Mac

- Detect Normal, Recovery, and DFU targets and preserve the target ECID across transitions.
- Enter DFU using the bundled `macvdmtool` and standard macOS administrator authorization.
- Restore or Revive through Apple Configurator with real stage-local progress and operation logs.

### iPhone and iPad

- Discover mobile targets and retain product type and ECID metadata.
- Guide supported physical-button DFU sequences without sending device commands.
- Require same-ECID DFU enumeration before reporting success.
- Restore compatible validated IPSWs with destructive confirmation and live progress.

### Firmware management

- Discover compatible Apple macOS, iOS, and iPadOS restore images.
- Resume downloads, validate integrity and archive structure, and reuse a platform-separated cache.
- Inspect storage, reveal files, resume partials, and confirm removal in **Manage Downloads…**.
- Select a local IPSW without placing it under DFUUtility's cache management.
- Automatically assign an exact compatible validated cached IPSW to a newly discovered iPhone or iPad without selecting the device or starting an operation.

### Safety

- Explicit target selection when multiple devices are attached.
- Product compatibility and IPSW validation gates before Restore.
- Separate native destructive confirmation; Restore never begins from DFU detection alone.
- Demo and screenshot modes cannot invoke hardware operations.

### Multiple devices

- Multiple connected devices are represented as independent sessions keyed by ECID where available, with UDID/serial used only to preserve non-destructive presentation state when ECID is unavailable.
- A device without ECID, UDID, or serial receives a new ephemeral session on rediscovery so another physical device cannot inherit its firmware or operation state; it remains unavailable for batch execution until an ECID is present.
- Use the checkboxes to build an explicit batch; **Select All Restore-Ready** selects only devices that currently satisfy Restore eligibility. Firmware remains assigned per device.
- Batch Restore, Revive, and Restart freeze the selected devices and firmware assignments, then run sequentially; every cfgutil command remains targeted to one ECID and destructive operations are never run in parallel.
- Firmware selection, validation, progress, reconnect verification, results, and logs remain per device. A failure is recorded and the next queued device continues; **Stop After Current Device** prevents new operations from starting without interrupting the active restore.
- Automatic Mac Enter DFU remains single-target because upstream `macvdmtool dfu` does not provide an unambiguous target selector.

Batch execution is intentionally sequential in this first implementation. Parallel destructive operations are not supported.

## Screenshots

| Guided iPhone DFU | Guided iPad DFU |
| --- | --- |
| ![Guided iPhone DFU](docs/images/iphone-guided-dfu.png) | ![Guided iPad DFU](docs/images/ipad-guided-dfu.png) |

| Firmware chooser | Manage Downloads |
| --- | --- |
| ![Compatible firmware chooser](docs/images/firmware-chooser.png) | ![Managed firmware cache](docs/images/manage-downloads.png) |

| Download progress | Restore progress |
| --- | --- |
| ![Firmware download progress](docs/images/download-progress.png) | ![Structured Restore progress](docs/images/restore-progress.png) |

| Completed Restore |
| --- |
| ![Completed Restore and returned target](docs/images/completed-restore.png) |

All screenshots use deterministic fictional data; they contain no real device or user identifiers.

## Installation

Requirements: macOS 14 or newer, [Apple Configurator](https://apps.apple.com/app/apple-configurator/id1037126344), a data-capable cable, and internet access for automatic firmware downloads. The current Mac DFU workflow requires an Apple Silicon host. Administrator authorization is requested only when entering a Mac into DFU.

```sh
git clone https://github.com/thehallifax/DFUUtility.git
cd DFUUtility
scripts/install-local.sh
```

Open `/Applications/DFUUtility.app`. To uninstall the local build, run `scripts/uninstall-local.sh`.

The normal installer builds, packages, verifies, and installs the app with concise progress output. It does not run the repository test suite, so full Xcode is not required merely to install DFUUtility when the selected Command Line Tools can compile the release app. Contributors with a newer Swift/Xcode toolchain that includes Swift Testing can validate before installation explicitly:

```sh
scripts/install-local.sh --test
```

For complete build, packaging, and verification output, use verbose mode. The flags can be combined in either order:

```sh
scripts/install-local.sh --verbose
scripts/install-local.sh --test --verbose
```

### Updating

DFUUtility normally performs a lightweight daily check for newer Community source after launch. It never installs automatically. Choose **DFUUtility → Check for Updates…** to perform a fresh check; **Update Now** quits the running app, safely fast-forwards its original Git clone, rebuilds and verifies the app locally, installs it, and relaunches it. The original checkout must still exist, remain on `main`, and have no local changes.

The installer records the canonical source location in the user's DFUUtility application-support folder; no developer path is embedded in the app. Update progress and failures are recorded in `~/Library/Logs/DFUUtility/update.log`. A failed build or verification leaves the existing installed app available.

Manual updating remains available as a fallback:

```sh
cd /path/to/DFUUtility
scripts/update.sh
```

The updater checks GitHub for newer source, refuses to overwrite local changes, and fast-forwards the `main` branch without creating a merge commit. When an update is available, it reuses the existing installer to build, verify, and replace `/Applications/DFUUtility.app`; the installer moves the previous application to Trash.

```sh
scripts/update.sh --check    # Check without pulling, building, or installing
scripts/update.sh --verbose  # Show complete installer output
scripts/update.sh --test     # Run the repository tests before installation
```

The flags may be combined. In-app and shell updates are intended for clean end-user clones. Contributors with local changes or feature branches should manage their Git checkout manually; the updater never stashes, resets, cleans, switches branches, or discards work.

## Usage

1. Connect the target with a data-capable cable and select it if more than one device is attached.
2. Choose compatible Apple firmware with **Change Version…**, or use **Choose Local IPSW…**.
3. Download and validate the image if needed.
4. Enter DFU: Mac entry is initiated by the app; supported iPhone/iPad entry follows the guided physical-button assistant.
5. Choose Revive where supported, or confirm Restore.

If Mac Enter DFU reports that the final VDM reply was not received, the target may already have transitioned. Wait briefly and click **Refresh**. If it remains absent, reconnect the cable. USB-C/DFU port behavior varies by model, so consult [Apple's model-specific DFU-port guidance](https://support.apple.com/en-us/108900) rather than assuming every MacBook uses the same port.

On the physically tested `Mac17,6`, automatic DFU entry required the rightmost USB-C port on the left side. After transition, the already-DFU target enumerated immediately when the cable was moved to the other left-side USB-C port. This is an observation for that tested machine, not a universal M4/M5-era port map.

> **Restore erases the target device.** Back up recoverable data first. Restore does not bypass Activation Lock, ownership, enrollment, or setup requirements. Revive is not a backup and offers no data-preservation guarantee.

### Dedicated DFU workstations

On an Apple-silicon Mac laptop, macOS may require approval before a newly connected wired accessory can communicate. DFUUtility cannot reliably read or change this policy. For a trusted technician workstation, review **System Settings → Privacy & Security → Accessories → Allow accessories to connect**. **Automatically allow when unlocked** can reduce repeated prompts while retaining protection when the Mac is locked. **Always allow** reduces prompts further but allows new wired accessories without individual approval, so reserve it for a physically controlled dedicated bench rather than a normal personal Mac.

See [Dedicated DFU host setup](docs/DEDICATED_DFU_HOST.md) for cable, model-specific DFU-port, security, MDM, and trust/pairing distinctions.

## Tested hardware

| Device | Product | Detection | Guided DFU | Restore/Revive |
| --- | --- | --- | --- | --- |
| MacBook Air M2 | `Mac14,2` | Normal/DFU: PASS | GUI same-ECID DFU: PASS | Restore and Revive: PASS |
| Newer Apple Silicon MacBook | `Mac17,6` | Normal/DFU: PASS | Automatic DFU: PASS; tested port-change caveat | Restore, progress, and restart: PASS |
| iPhone 6 | `iPhone7,2` | Normal/Recovery/DFU: PASS | Same-ECID DFU: PASS | End-to-end Restore: PASS |
| iPad (7th generation) Wi-Fi | `iPad7,11` | Normal/Recovery/DFU: PASS | Same-ECID DFU: PASS | Recovery-mode Restore: PASS; progress/restart verification pending |

For `iPad7,11`, compatible iPadOS discovery, GUI download, IPSW validation, and Recovery-mode GUI Restore passed on real hardware. Live Restore progress, restart verification, and full end-to-end acceptance remain pending. The authoritative, deliberately scoped record is [Config/HardwareAcceptance.json](Config/HardwareAcceptance.json).

Two simultaneously connected `iPad12,1` Recovery targets also passed the explicitly selected, ECID-targeted sequential Restore workflow. A subsequently connected replacement `iPad12,1` automatically received the exact validated cached iPadOS 26.6.1 / 23G83 asset and became Restore-ready while remaining unselected until explicit user action.

## Older Lightning troubleshooting

If an older Lightning device repeatedly lands in Recovery with direct USB-C to Lightning, try USB-A to Lightning through a USB-C adapter or hub. This helped the tested iPhone 6; it is troubleshooting guidance, not a universal requirement. Testing has not established that USB-A is required for the iPad.

## Firmware cache

Managed downloads live under `~/Library/Caches/DFUUtility/IPSW/`, separated by platform. **Manage Downloads…** shows total storage, validation state and failure detail, and offers Reveal, Resume, and confirmed Remove actions. Operation logs live under `~/Library/Logs/DFUUtility/` and are available through **View Log**.

**Diagnostics…** shows detailed local information for troubleshooting. **Copy Sanitized Diagnostics** and **Save Sanitized Diagnostics…** create a shareable report that omits full device identifiers, usernames, and local filesystem paths.

## CLI

```sh
swift build -c release
.build/release/dfuctl doctor
.build/release/dfuctl status
.build/release/dfuctl ipsw list
.build/release/dfuctl ipsw cache
```

Explicit hardware commands are `.build/release/dfuctl dfu`, `.build/release/dfuctl revive`, and `.build/release/dfuctl restore /path/to/Restore.ipsw`. Restore is destructive. The CLI's safe privilege behavior is documented in [Privileged helper architecture](docs/PRIVILEGED_HELPER.md).

## Build from source

```sh
swift build
swift test
swift build -c release
scripts/package-app.sh release
scripts/verify-app.sh .build/app/DFUUtility.app
```

Run `swift run DFUUtility --demo` for a hardware-inert demo. `scripts/release-check.sh` performs builds, tests, read-only CLI smoke checks, packaging, metadata, license, signature, acceptance, screenshot, and ZIP checks; it never enters DFU, restores, revives, authorizes, or downloads firmware.

## Security and privilege model

Community builds invoke only the bundled `macvdmtool dfu` operation through macOS's standard administrator UI. DFUUtility never reads or stores a password and does not use interactive `sudo`, setuid, or a custom password dialog. A future Developer ID distribution can use the embedded `SMAppService` privileged helper with matching Team-ID signatures, hardened runtime, and notarization. See [Signing and distribution](docs/SIGNING_AND_DISTRIBUTION.md).

Apple Configurator's `cfgutil` remains required for device discovery, Restore, and Revive. Mobile DFU requires physical button input and is hardware validated only for the products listed above.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for focused development and privacy-safe issue reporting. See the [0.7.0 release notes](docs/RELEASE_NOTES_0.7.0.md) for this release and the [0.6.1 release notes](docs/RELEASE_NOTES_0.6.1.md) for the preceding patch.

## License

DFUUtility is licensed under the [Apache License 2.0](LICENSE).

## Third-party software

DFUUtility bundles upstream [Asahi Linux macvdmtool](https://github.com/AsahiLinux/macvdmtool) at commit `b22ae51eb43a0e1daa21d41616ac899f28e7bf8a`. macvdmtool remains Copyright 2021 The Asahi Linux Contributors and Apache-2.0 licensed; DFUUtility does not claim ownership or relicense it. Its upstream source, attribution, [license](Vendor/macvdmtool/LICENSE), and [revision record](Vendor/macvdmtool/UPSTREAM_REVISION) are preserved and included in packaged apps.
