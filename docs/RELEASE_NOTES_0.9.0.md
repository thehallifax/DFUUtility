# DFUUtility 0.9.0 Community

DFUUtility 0.9.0 is an operator-focused Community release for technician DFU benches. Community artifacts are locally built and ad-hoc signed; Apple Configurator remains required for discovery, Restore, and Revive.

## Highlights

- Reworked navigation around Restore & Revive, Device Capture, Firmware Library, Diagnostics, and About workspaces, with responsive sidebar/window behavior.
- Added read-only Device Capture with automatic/manual capture, stable identifiers where providers expose them, exact-serial QR codes, CSV export, and optional asset tags.
- Added independent macOS, iOS, and iPadOS Firmware Library browsing and clearer sequential batch Restore, Revive, and Restart presentation.
- Improved Mac DFU transition verification: evidence-sensitive missing-VDM-reply handling can verify success only after fresh same-ECID DFU rediscovery, without retrying the command.
- Added actionable updater guidance for missing or invalid Git source checkouts and dedicated-host accessory-readiness guidance without changing macOS security settings.
- Preserved exact product compatibility, cache validation, explicit destructive-operation selection, and structured Restore/Revive progress.

## Physical acceptance

- MacBook Air M2 (`Mac14,2`): Normal/DFU discovery, automatic DFU, Restore, Revive, structured progress, and restart/reconnect passed.
- Newer Apple Silicon MacBook (`Mac17,6`): discovery, automatic DFU, DFU rediscovery, macOS 26.6.2 / 25G83 Restore, structured progress, and restart to Normal passed. The tested machine required a documented port change; this is not a universal newer-Mac mapping.
- iPhone 6 (`iPhone7,2`): end-to-end Restore workflow passed.
- iPad (7th generation) Wi-Fi (`iPad7,11`): Normal/Recovery discovery, guided same-ECID DFU, firmware discovery/download/validation, and Recovery-mode Restore passed; detailed progress and restart verification remain pending.
- Two simultaneous `iPad12,1` Recovery targets: exact compatible assignment and explicitly selected sequential Restore passed.
- Device Capture was physically accepted on an iPhone Normal session with serial, ECID, UDID, and QR display. Provider identifier availability varies by family and state.

These observations apply only to the named products and workflows. They do not claim universal Apple hardware coverage.

## Distribution

DFUUtility is distributed under the [Apache License 2.0](../LICENSE). Bundled upstream Asahi Linux `macvdmtool` retains its own Apache-2.0 license, copyright, attribution, and recorded upstream revision.
