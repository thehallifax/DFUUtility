# DFUUtility 0.11.0 Community

DFUUtility 0.11.0 is a polished Community release for technicians restoring,
reviving, preparing, and inventorying Apple devices.

## Highlights

- Production-accepted binary self-updating for packaged installations through
  GitHub Releases, with explicit download and install actions, transactional
  replacement, destination verification, rollback protection, and verified
  relaunch. Source installations retain their separate, safety-gated Git
  update workflow.
- Technician-oriented multi-device sessions and sequential Restore, Revive,
  and Restart workflows with explicit selection and per-device firmware.
- Independent macOS, iOS, and iPadOS Firmware Library browsing, validated
  managed downloads, local IPSW selection, and exact compatibility gates.
- Guided physical-button DFU assistance for supported iPhone and iPad models,
  plus Mac DFU, Restore, and Revive workflows with same-device verification and
  structured operation progress.
- Read-only Device Capture with identifiers, serial-number QR codes, asset
  tags, and CSV export, together with Diagnostics and dedicated-host readiness
  guidance.
- Refreshed end-user documentation and deterministic fictional-data
  screenshots, with clearer separation between DFUUtility's Apache-2.0 license
  and the preserved Asahi Linux `macvdmtool` license, attribution, and pinned
  upstream revision.

## Distribution and compatibility

Community artifacts are ad-hoc signed and are not Developer ID authenticated
or notarized. Physical acceptance applies only to the products and workflows
listed in the project's hardware-acceptance documentation; this release does
not claim universal Apple hardware compatibility.

The complete packaged binary updater lifecycle was production accepted for
`0.10.9 → 0.10.10`.
