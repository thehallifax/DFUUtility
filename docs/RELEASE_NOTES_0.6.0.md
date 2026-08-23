# DFUUtility 0.6.0

DFUUtility 0.6.0 expands the native macOS Community utility from its proven Mac workflow to focused, hardware-validated iPhone and iPad workflows, with guided mobile DFU entry and managed Apple firmware downloads.

## Highlights

- iPhone and iPad discovery, firmware selection, and guided physical-button DFU assistance.
- Apple iOS and iPadOS catalogue discovery with product compatibility filtering, resumable downloads, integrity validation, and managed caching.
- First real end-to-end iPhone Restore acceptance, including same-ECID DFU verification, live progress, and return to Normal.
- Clearer stage-local Mac Restore and Revive progress.
- Manage Downloads for viewing, revealing, resuming, validating, and removing managed IPSWs.
- Community builds that require no paid Apple Developer account.

## Mobile support

**iPhone 6 (`iPhone7,2`)** is end-to-end hardware validated: Normal and Recovery detection, guided DFU, same-ECID verification, firmware discovery/download/validation, GUI Restore, live progress, and restart verification all passed.

**iPad (7th generation) Wi-Fi (`iPad7,11`)** is hardware validated for Normal detection, guided DFU, same-ECID verification, compatible iPadOS discovery, GUI download, and IPSW validation. Destructive Restore, Restore progress, and restart verification were intentionally not tested because the device contains user data.

These results apply to the named products only; they do not imply validation of every iPhone or iPad model.

## DFU guidance

Mobile DFU still requires physical button input. The assistant watches the target's real USB transition, presents a release cue, and accepts success only when the same ECID enumerates in DFU.

On the tested iPhone 6, direct USB-C to Lightning repeatedly entered Recovery, while USB-A to Lightning through a USB-C adapter reached DFU. This is useful troubleshooting guidance for older Lightning devices, not a universal cable requirement. The tested iPad does not establish any USB-A requirement.

## Firmware management

DFUUtility discovers Apple firmware, filters it for the connected product, resumes partial downloads, validates archive structure and metadata, and separates managed macOS, iOS, and iPadOS cache entries. Manage Downloads shows storage use and validation detail and provides Reveal, Resume, and confirmed Remove actions. Local IPSWs selected by the user are never managed or deleted.

## Mac support

The existing Apple Silicon Mac workflow remains available: bundled `macvdmtool`, same-ECID Normal-to-DFU verification, Configurator Restore and Revive, structured live progress, operation logs, safety gating, and restart verification. MacBook Air M2 (`Mac14,2`) has passed the full Community GUI workflow.

## Community builds

Community builds are built locally and ad-hoc signed, so no paid Apple Developer account is required. macOS presents its standard administrator authorization UI only for the privileged Mac DFU operation; DFUUtility never reads or stores the password. The signed `SMAppService` helper architecture remains available for future Developer ID distribution.

## Known limitations

- Broader iPhone, iPad, Apple Silicon Mac, and Intel T2 hardware validation remains pending.
- Destructive iPad Restore has not been hardware validated.
- Mobile DFU cannot be entered fully automatically; physical button input is required.
- Community builds are ad-hoc signed and are not notarized.
- Apple Configurator and its `cfgutil` executable are required for discovery, Restore, and Revive.
- Mobile Revive is not claimed.

DFUUtility is distributed under the [Apache License 2.0](../LICENSE). The bundled upstream Asahi Linux `macvdmtool` retains its own Apache-2.0 attribution and license.
