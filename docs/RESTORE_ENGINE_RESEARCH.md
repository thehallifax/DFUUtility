# Restore engine research

Last verified: 18 August 2026. Host: Apple Silicon (`arm64`), macOS 26.6.1 (25G76), Xcode/Swift 6.3.3, Apple Configurator 2.20 (1001.5).

## Finding

The technical workflow is viable without scripting a GUI. Apple Configurator's installed Automation Tools include `cfgutil`; version 2.20 exposes machine-readable discovery, explicit ECID selection, custom-IPSW restore, revive, and progress output. `dfuctl` therefore treats `cfgutil` as the restore boundary and does not implement Apple's restore protocol.

`macvdmtool` remains the practical mechanism for programmatically sending the target the USB-C VDM that requests DFU. It is not an Apple-supported API, needs an Apple Silicon host and root privileges, and should remain an isolated replaceable adapter.

## Commands and APIs tested

These read-only commands were run on the host above:

```sh
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil help
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil help list
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil help get
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil help restore
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil help revive
/Applications/Apple\ Configurator.app/Contents/MacOS/cfgutil --format JSON --timeout 1 list
system_profiler SPUSBDataType
ioreg -p IOUSB -l -w 0
```

The initial spike had no target. Subsequent integration testing used a MacBook Air M2 (`Mac14,2`) and is recorded below. Device identifiers are intentionally omitted from this public document.

Relevant `cfgutil` 2.20 surfaces:

- `list --format JSON` returns a `Devices` collection; an empty collection is a successful no-device result.
- `get` supports `ECID`, `deviceType`, `deviceClass`, `bootedState`, `isRestorable`, `UDID`, and `serialNumber`.
- `restore --ipsw <path>` installs from a custom IPSW. Restore is destructive.
- `revive` attempts recovery without the erase semantics of restore.
- global `--ecid`, `--progress`, `--verbose`, and `--timeout` provide selection and observable output.

For DFU, the upstream command is:

```sh
sudo macvdmtool dfu
```

The upstream project documents port/cable requirements and Apache-2.0 licensing. This repository vendors the unchanged source pinned in `Vendor/macvdmtool/UPSTREAM_REVISION`, builds it as a SwiftPM product, and packages its full license and revision record with the app.

## Real hardware results

Hardware: MacBook Air M2, model `Mac14,2`, connected to the Apple Silicon host through the applicable DFU USB-C path.

| Workflow | Result |
|---|---|
| Normal-state discovery, model, and ECID | PASS |
| Manually entered DFU discovery | PASS |
| `cfgutil revive` | PASS |
| GUI `cfgutil restore` | PASS |
| Target restart verification | PASS |
| Real `cfgutil` progress output | PASS |
| Apple MobileAsset IPSW catalogue | PASS |
| 19.77 GB Apple IPSW download | PASS |
| IPSW validation and cache | PASS |
| Project-built `macvdmtool` direct Normal → DFU | PASS |
| `dfuctl` sudo wrapper before TTY fix | FAIL: capturing runner and background child process group disrupted terminal authentication |

The direct project-built helper emitted the expected HPM discovery, DBMa entry, and reboot messages and moved the same ECID from Normal to DFU. The revive exposed numeric `cfgutil` progress events for both **Unzipping System** and **Installing System**. Those real events should feed a later structured GUI progress parser rather than an invented percentage.

## Detection and state

Primary discovery uses `cfgutil`, because it is also the eventual actor and supplies ECID for safe targeting. A narrow `ioreg` fallback recognizes only Apple USB recovery/DFU identities (including the standard DFU product identity `0x1227`); it does not enumerate or operate on arbitrary USB devices. Fields are omitted when unavailable rather than inferred.

Finder can display and interactively revive or restore a DFU Mac on current macOS, but no stable public Finder framework was found for non-interactive restore. Device-management frameworks are aimed at enrolled/booted management and do not expose the host-side DFU restore operation. GUI scripting is unnecessary because `cfgutil` covers the required operation.

## Privileges and prerequisites

- Host: Apple Silicon is required for `macvdmtool`; Apple documents a compatible current Mac host for Finder restore.
- Apple Configurator must be installed. `dfuctl` locates its bundled `cfgutil`; installing Configurator's Automation Tools may also place it on `PATH`.
- `macvdmtool dfu` needs root. The CLI invokes `sudo` interactively when not already root.
- Restore may trigger macOS privacy/accessory approval or require network access to Apple services for personalization. Keep the host awake, powered, and online.
- A direct data-capable USB-C cable and the target's designated DFU port are required. Hubs and an incorrect port are common failure causes.

## Progress, errors, and success

`cfgutil --progress --verbose` is the supported observable surface. The MVP preserves its stdout/stderr and exit status. Exit zero is treated as command completion; a later milestone should additionally observe the target detach/reboot and reacquire it in a booted/recovery state for stronger end-to-end verification. Apple's own UI likewise reports progress and automatically restarts the target after successful restore.

The current `ProcessRunner` connects restore stdout/stderr directly to the terminal, so `cfgutil` progress is visible live. A SwiftUI adapter should replace this with structured line/event delivery and retain cancellation/process termination without coupling the UI to `Process`.

## Expected stability and limitations

| Surface | Support/stability | Limitation |
|---|---|---|
| `cfgutil` restore/revive | Apple-provided automation tool; best available CLI boundary | Ships with Configurator, not macOS API; output schema can change |
| `cfgutil` JSON/get | Apple-provided | Exact DFU property availability needs hardware validation |
| `ioreg` USB fallback | macOS system interface, heuristic matching | State only; model/ECID generally unavailable |
| `macvdmtool` | Open-source Apache-2.0, reasonably isolated | Unsupported by Apple, root required, hardware/port sensitive |
| Finder DFU UI | Apple-supported user workflow | Interactive; no suitable public automation API found |

## Recommended architecture

Keep four boundaries: discovery (`cfgutil`, narrow IOKit fallback), DFU transition (`macvdmtool`), restore/revive (`cfgutil` selected by ECID), and IPSW discovery/cache. SwiftUI should consume these services asynchronously and never execute tools directly. Restore must remain a separately confirmed, explicit action. Before production use, run a hardware matrix across Mac families, capture real JSON/progress output as fixtures, add cancellation/process termination, and add post-restore state verification.

Primary references:

- [Apple: How to revive or restore Mac firmware](https://support.apple.com/en-us/108900)
- [Apple Configurator User Guide](https://support.apple.com/guide/apple-configurator-mac/welcome/mac)
- [Asahi Linux macvdmtool source and documentation](https://github.com/AsahiLinux/macvdmtool)
