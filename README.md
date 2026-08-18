# DFUUtility

Native Swift technical-spike CLI for Apple Silicon Mac DFU transition, Apple IPSW discovery/download, and restore on macOS 14+.

## Native macOS app

Milestone 3 adds a one-window SwiftUI application backed by the same `DFUCore` services as the CLI. It displays target state, loads Apple's live IPSW catalogue, selects current or alternate releases, downloads/resumes/cancels images, validates manually chosen IPSWs, shows shared diagnostics, and exposes carefully gated DFU/revive/restore controls.

Build and launch with Swift Package Manager:

```sh
cd ~/Library/Codex/DFUUtility
swift build --product DFUUtility
swift run DFUUtility
```

The package product and executable target are `DFUUtility` and `DFUUtilityApp`, respectively. To open the package in Xcode, run `open Package.swift`, select the `DFUUtility` scheme, and Run. A deterministic development mode never invokes hardware tools:

```sh
DFUUTILITY_DEMO=1 swift run DFUUtility
# or
swift run DFUUtility --demo
```

The app visibly labels demo mode. Its target picker and download animation are synthetic, and mock restore/DFU services never call `cfgutil` or `macvdmtool`.

Safety is invariant across the app: catalogue access, downloads, cache operations, navigation, and manual validation cannot touch a target. Downloading never starts restore. Restore requires a separate click, a validated image, exactly one positively detected real DFU target, production mode, and a native destructive confirmation dialog. Revive requires a real DFU/recovery target. Missing `macvdmtool` disables Enter DFU and diagnostics explains why.

## Build and inspect the host

```sh
cd ~/Library/Codex/DFUUtility
swift build
swift test
swift build -c release
.build/release/dfuctl doctor
.build/release/dfuctl status
```

`doctor` checks architecture, macOS, Apple Configurator, `cfgutil`, `macvdmtool`, restore support, cache writability, and target discovery. No attached target is a normal non-fatal result. Install [macvdmtool](https://github.com/AsahiLinux/macvdmtool) separately; the project neither vendors nor silently installs it. `DFUCTL_CFGUTIL_PATH` and `DFUCTL_MACVDMTOOL_PATH` override tool discovery.

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
```

`restore` is destructive and runs only when explicitly invoked. Apple Configurator's `cfgutil` is the restore engine; this project does not implement Apple's low-level protocol.

## Current limitations

- Physical DFU transition, revive, and restore remain untested pending access to a second Apple Silicon Mac.
- The Apple MobileAsset catalogue is an operational interface and not a versioned public SDK; parsing is fixture-tested and intentionally isolated.
- Catalogue presence means “currently offered,” not authoritative proof that personalization/signing will succeed for every device. `cfgutil` makes that final determination.
- Ctrl-C leaves a clearly marked partial. Resume requires a matching HTTP 206 `Content-Range`; otherwise a full fresh download is used.
- The cache rechecks size and restore manifests when listing/reusing; the authoritative SHA-1 is calculated at download completion because hashing a roughly 20 GB image on every listing would be unnecessarily expensive.
- Restore event stages are structured, but `cfgutil` exposes primarily textual progress; the app does not invent a percentage. Process-level cancellation for an active `cfgutil` restore is intentionally not presented until it can be hardware-tested safely.
- Manual IPSW validation confirms archive structure but does not invent version/build metadata when it cannot be read reliably.
- The app is currently an SPM executable rather than a signed/distributable `.app` product with installer packaging.

See [restore engine research](docs/RESTORE_ENGINE_RESEARCH.md) and [IPSW discovery details](docs/IPSW_DISCOVERY.md).
