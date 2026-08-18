# DFUUtility

Native Swift macOS utility for Apple Silicon Mac DFU transition, Apple IPSW discovery/download, revive, and restore on macOS 14+.

## Native macOS app

The SwiftUI app detects one target, requests system authorization for DFU through a narrowly scoped service, verifies the ECID transition, selects Apple's current compatible image, reuses validated cache entries, and exposes carefully gated revive and restore controls with stage-local `cfgutil` progress.

Build and launch with Swift Package Manager:

```sh
cd ~/Library/Codex/DFUUtility
swift build
swift run DFUUtility
```

Use the packaged application for the real GUI workflow; a raw `swift run` executable cannot register an embedded launch daemon. A deterministic development mode never invokes hardware tools:

```sh
DFUUTILITY_DEMO=1 swift run DFUUtility
# or
swift run DFUUtility --demo
```

The app visibly labels demo mode. Its target picker and download animation are synthetic, and mock services never call `cfgutil`, XPC, or `macvdmtool`.

Safety is invariant across the app: catalogue access, downloads, cache operations, navigation, and manual validation cannot touch a target. Downloading never starts restore. Restore requires a separate click, a validated image, exactly one positively detected real DFU target, production mode, and a native destructive confirmation dialog. Revive requires a real DFU/recovery target.

Create a conventional application bundle containing the DFU helper and license material with:

```sh
scripts/package-app.sh release
open .build/app/DFUUtility.app
```

This is explicitly an ad-hoc development package. For signed distribution:

```sh
scripts/package-app.sh release \
  --identity "Developer ID Application: Example Name (TEAMID)"
scripts/verify-app.sh .build/app/DFUUtility.app
scripts/notarize-app.sh .build/app/DFUUtility.app \
  --keychain-profile DFUUtilityNotary
```

Packaging signs nested code explicitly, enables hardened runtime for Developer ID builds, verifies signatures/Team IDs/entitlements, and creates a ZIP under `.build/distribution/`. It never falls back to ad-hoc signing when an identity was requested. See [signing and distribution](docs/SIGNING_AND_DISTRIBUTION.md) and the [clean-machine acceptance checklist](docs/CLEAN_MACHINE_ACCEPTANCE.md).

Normal use is: connect one target, click **Enter DFU**, approve the standard macOS authorization dialog, download the recommended image if needed, then choose **Revive Mac** or **Restore Mac**. Restore always presents a destructive confirmation. Local operation logs live under `~/Library/Logs/DFUUtility/`.

On first launch, click **Set Up DFU Helper**. If macOS requires approval, the app reports **Awaiting user approval** and links to System Settings. Ready means the registered service has responded with the compatible protocol—not merely that registration was requested. To unregister before removal:

```sh
scripts/uninstall-helper.sh /Applications/DFUUtility.app
```

## Build and inspect the host

The standard safe pre-release command is:

```sh
cd ~/Library/Codex/DFUUtility
scripts/release-check.sh
```

It builds, tests, runs only read-only CLI commands, packages and verifies the app, validates metadata/licensing/ZIP structure, and prints the artifact SHA-256. It never enters DFU, revives, restores, downloads an IPSW, changes helper registration, or requests authorization. Use `--strict` to make a dirty tree fatal. Production validation requires an explicit identity and an already notarized/stapled result:

```sh
DFUUTILITY_SIGNING_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
  scripts/release-check.sh --production
```

```sh
cd ~/Library/Codex/DFUUtility
swift build
swift test
swift build -c release
.build/release/dfuctl doctor
.build/release/dfuctl status
```

`doctor` checks architecture, macOS, Apple Configurator, `cfgutil`, the bundled/project-built `macvdmtool`, restore support, cache writability, and target discovery. No attached target is a normal non-fatal result. Users do not install `macvdmtool` separately.

Helper lookup precedence is: application-bundled copy, explicit `DFUCTL_MACVDMTOOL_PATH` development override, SwiftPM-built sibling, `/opt/homebrew/bin`, then `/usr/local/bin`. External copies are developer fallbacks only. The CLI delegates authentication to `/usr/bin/sudo`; the GUI uses Authorization Services and an `SMAppService` launch daemon over authenticated XPC. Neither path sees or stores a password. See [Privileged helper architecture](docs/PRIVILEGED_HELPER.md).

## IPSW commands

```sh
.build/release/dfuctl ipsw list
.build/release/dfuctl ipsw list --verbose
.build/release/dfuctl ipsw latest
.build/release/dfuctl ipsw cache
.build/release/dfuctl ipsw download latest
.build/release/dfuctl ipsw download --build 25G83
.build/release/dfuctl ipsw clean --partials
.build/release/dfuctl ipsw clean --invalid
```

Discovery reads Apple's macOS IPSW MobileAsset catalogue directly; no third-party firmware database is involved. Without a target, `latest` is the numerically newest universal Apple Silicon restore image in that catalogue. Downloads stream to a `.partial` file, show progress, resume with an HTTP byte range when the Apple CDN accepts it, validate size, ZIP manifests, and Apple's catalogue SHA-1, then atomically enter the cache.

Completed images and metadata live in `~/Library/Caches/DFUUtility/IPSW/<build>/`; partials live under `downloads/` and are never reported as complete. A valid cache hit is reused. Cleanup requires an explicit `--partials` and/or `--invalid`; it never removes valid images.

## Device operations

```sh
sudo .build/release/dfuctl dfu
.build/release/dfuctl revive
.build/release/dfuctl restore /path/to/UniversalMac_Restore.ipsw
.build/release/dfuctl restore                 # recommended validated cache; confirms
.build/release/dfuctl restore --download      # explicit download permission; confirms
```

`restore` is destructive and runs only when explicitly invoked. Apple Configurator's `cfgutil` is the restore engine; this project does not implement Apple's low-level protocol.

## Hardware validation

Apple Silicon M2 testing on a **MacBook Air M2 (Mac14,2)**, ECID `0x1569301A08C01E`:

- Normal detection: PASS
- Automated DFU entry and same-ECID verification: PASS
- DFU detection and revive: PASS
- Apple IPSW discovery/download/cache: PASS
- Full restore with macOS 26.6.2 (25G83): PASS
- Post-restore completion: PASS

Broader Apple Silicon hardware coverage is still required.

## Current limitations

- The Apple MobileAsset catalogue is an operational interface and not a versioned public SDK; parsing is fixture-tested and intentionally isolated.
- Catalogue presence means “currently offered,” not authoritative proof that personalization/signing will succeed for every device. `cfgutil` makes that final determination.
- Ctrl-C leaves a clearly marked partial. Resume requires a matching HTTP 206 `Content-Range`; otherwise a full fresh download is used.
- The cache rechecks size and restore manifests when listing/reusing; the authoritative SHA-1 is calculated at download completion because hashing a roughly 20 GB image on every listing would be unnecessarily expensive.
- Restore stages and stage-local percentages come from real `cfgutil` events; the app does not fabricate an overall percentage. Active restore cancellation is intentionally not presented until hardware-tested safely.
- Manual IPSW validation confirms archive structure but does not invent version/build metadata when it cannot be read reliably.
- `scripts/package-app.sh` applies consistent ad-hoc signatures and embeds the Service Management daemon for local testing. Distribution still requires Developer ID signing, hardened runtime, notarization/stapling, and testing from a stable application location.
- A clean-machine Developer ID/notarization acceptance run has not yet been performed. Hardware validated on MacBook Air M2 (Mac14,2); broader Apple Silicon and T2 coverage remains to be tested.

## Third-party licenses

DFUUtility vendors [Asahi Linux macvdmtool](https://github.com/AsahiLinux/macvdmtool) at commit `b22ae51eb43a0e1daa21d41616ac899f28e7bf8a`. It is Copyright 2021 The Asahi Linux Contributors, incorporates credited work from ThunderboltPatcher, and is licensed under Apache License 2.0. The unchanged upstream source, README, full [license](Vendor/macvdmtool/LICENSE), and [pinned revision record](Vendor/macvdmtool/UPSTREAM_REVISION) are retained. Packaged apps include the license and revision under `Contents/Resources/ThirdPartyLicenses/`.

See [restore engine research](docs/RESTORE_ENGINE_RESEARCH.md) and [IPSW discovery details](docs/IPSW_DISCOVERY.md).
