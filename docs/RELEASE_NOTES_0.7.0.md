# DFUUtility 0.7.0

DFUUtility 0.7.0 expands the Community application with independent device sessions, sequential multi-device operations, and stricter product-specific mobile firmware handling.

## Highlights

- Unified the one-device and multi-device interface around ECID-addressed sessions with explicit selection, per-device firmware, readiness, progress, results, and logs.
- Added sequential Restore, Revive, and Restart batches. Membership is frozen at confirmation, destructive operations remain one-at-a-time, and a failed device does not prevent later queued devices from running.
- Added iPhone and iPad Restore from Recovery as well as DFU, while retaining product compatibility, IPSW validation, ECID targeting, and destructive confirmation gates.
- Preserved complete product-specific mobile firmware identity when Apple publishes multiple IPSWs with the same version and build.
- Isolated mobile partial and completed cache paths by asset identity and hardened HTTP resume handling against mismatched range responses.
- Made exact latest-compatible assignment resolve the complete firmware identity and concrete validated cache URL. Newly discovered mobile sessions can reuse a unique exact cached asset without downloading, selecting the device, or starting an operation.
- Kept the Firmware Library and Manage Downloads presentation synchronized with exact per-session assignments without falsely presenting a single release for mixed-product selections.
- Added the Community in-app updater, which checks explicitly, requires a clean original clone, quits before updating, fast-forwards without merging, rebuilds and verifies locally, and relaunches only after successful replacement.
- Improved Restore/Revive reconnect-state recovery and Mac automatic-DFU diagnostics. A missing final VDM reply remains a failed, unverified command and provides Refresh, reconnect, and model-specific Apple DFU-port guidance only when the captured HPM/DBMa evidence supports it.

## Physical acceptance

- MacBook Air M2 (`Mac14,2`): discovery, automatic DFU, Restore, Revive, structured progress, and restart/reconnect passed.
- Newer Apple Silicon MacBook (`Mac17,6`): discovery, automatic DFU, DFU rediscovery, macOS 26.6.2 / 25G83 Restore, structured progress, and restart to Normal passed. The tested machine required a documented port change; this is not asserted as a universal newer-Mac mapping.
- iPhone 6 (`iPhone7,2`): the physical end-to-end mobile workflow passed.
- iPad (7th generation) Wi-Fi (`iPad7,11`): Normal/Recovery discovery, guided same-ECID DFU, firmware discovery/download/validation, and Recovery-mode Restore passed. Detailed Restore-progress and restart verification remain pending for this device.
- Two simultaneous `iPad12,1` Recovery targets: exact compatible firmware assignment and sequential Restore completed with two successes and no failures.
- Replacement `iPad12,1`: the exact validated cached iPadOS 26.6.1 / 23G83 asset was assigned automatically, the session became Restore-ready, and the destructive-operation checkbox remained unselected until explicit user action.

These observations apply only to the named products and workflows. They do not claim physical validation of every architecturally supported Apple model.

## Distribution

Community releases are built locally and ad-hoc signed; Apple Configurator remains required. Developer ID signing and notarization are not provided by this source release.

DFUUtility is distributed under the [Apache License 2.0](../LICENSE). Bundled upstream Asahi Linux `macvdmtool` retains its own Apache-2.0 license, copyright, attribution, and recorded upstream revision.
