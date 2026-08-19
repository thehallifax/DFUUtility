# DFUUtility 0.5.0 Community Beta

DFUUtility 0.5.0 is the first Community beta: a locally built, ad-hoc signed native macOS app for a focused single-target DFU revive and restore workflow.

[DFUUtility](https://github.com/thehallifax/DFUUtility) is distributed under the Apache License 2.0. Bundled third-party software retains its own upstream copyright, attribution, and license notices.

## Highlights

- Detects one connected target Mac in Normal, Recovery, or DFU state.
- Enters DFU from the GUI using macOS-provided administrator authorization, then verifies the same ECID appeared in DFU.
- Revives and restores through Apple Configurator's `cfgutil`.
- Discovers current macOS IPSWs directly from Apple, downloads with resume support, validates them, and reuses cached images.
- Provides a native version chooser plus validated local IPSW fallback.
- Shows real `cfgutil` stage names and stage-local progress during Revive and Restore.
- Bundles the pinned Apache-2.0-licensed `macvdmtool` dependency.
- Installs locally with `scripts/install-local.sh`; no Apple Developer Program membership is required.

## Hardware acceptance

The complete Community GUI path passed on a **MacBook Air M2 (Mac14,2)**, including Normal detection, GUI Enter DFU, same-ECID verification, GUI Revive, GUI Restore, live progress, and target restart verification. The acceptance record is dated 2026-08-19 and stored in `Config/HardwareAcceptance.json`.

This is one tested model, not a claim of general Apple Silicon or Intel T2 compatibility.

## Known limitations

- Broader Apple Silicon and Intel T2 hardware coverage is pending.
- Community builds are local and ad-hoc signed; no notarized binary distribution is available.
- Apple Configurator and `cfgutil` remain required.
- Only one connected target is supported.
- Restore erases the target Mac. Revive is intended to avoid erasing user data, but is not a backup or guarantee.
- Progress percentages are stage-local and appear only when emitted by `cfgutil`; no overall percentage is invented.
- Active Revive/Restore cancellation is not exposed until its behavior is hardware-tested safely.

## Third-party licensing

The bundled macvdmtool source remains Copyright 2021 The Asahi Linux Contributors, includes its credited ThunderboltPatcher-derived work, and retains the upstream Apache License 2.0 text and revision record. DFUUtility does not claim ownership of or relicense macvdmtool.
