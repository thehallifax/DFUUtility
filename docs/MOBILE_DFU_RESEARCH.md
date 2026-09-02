# Mobile DFU entry research

Research date: 22 August 2026

Implementation status: the transition-driven guided assistant is hardware-accepted on iPhone 6 (`iPhone7,2`) and iPad (7th generation) Wi-Fi (`iPad7,11`). The assistant itself remains guidance/observation only: no Recovery reset, MobileDevice command, Restore, or Revive is invoked. It polls only while open, treats target disappearance as the reset anchor, waits a profile-owned 1.0 seconds before the release cue, and requires same-ECID DFU enumeration.

## iPhone7,2 hardware acceptance — 2026-08-22

The earlier fixed 8-second plus 10-second timer repeatedly landed in Recovery and did not provide a sufficiently reliable release anchor. The state-aware assistant succeeded by observing the real USB disappearance and issuing its release cue after that transition.

Sanitized monotonic observations from the accepted session:

- Successful DFU attempt: disappearance at +7.587 s, release cue at +8.664 s, DFU reappearance at +15.374 s.
- Recorded Recovery attempt: disappearance at +8.584 s, release cue at +9.648 s, Recovery reappearance at +15.077 s.
- A second Recovery attempt reappeared at +16.460 s after a disappearance at +8.589 s.

On this specific test device, direct USB-C to Lightning repeatedly produced Recovery. USB-A to Lightning through a USB-C adapter produced the successful DFU transition. This is troubleshooting evidence for an older Lightning profile, not a universal claim that USB-C to Lightning cannot enter DFU.

Hardware acceptance passed for Normal and Recovery detection, guided same-ECID DFU, Apple iOS image discovery, GUI download, IPSW validation, GUI Restore, live restore progress, and restart verification. Sanitized real observations are retained under `Tests/Fixtures/`; no real ECID, serial number, UDID, device name, or personal path is included.

## iPad7,11 guided-DFU hardware acceptance — 2026-08-23

`iPad7,11` maps to the Wi-Fi iPad (7th generation), model A2197. The product-type mapping is the authoritative profile key; the marketing name alone is not used for selection. Apple identifies the seventh-generation Wi-Fi hardware as A2197 and documents this generation with a Home/Touch ID button, a Top button, and a Lightning connector:

- Apple model identification: <https://support.apple.com/en-gb/108043>
- Apple iPad (7th generation) hardware guide: <https://support.apple.com/en-au/guide/ipad/aside/ipada3ae0131>
- ProductType-to-model mapping: <https://theapplewiki.com/wiki/IPad7%2C11>

Because its topology is Top + physical Home, it reuses the existing `physicalHome` transition state machine. The profile supplies iPad-specific **Top** wording and separately owned timing values: 1.0-second post-reset both-button hold, 12-second Home hold timeout, and 20-second reset/detection timeout.

Real Normal-state discovery, guided DFU, and same-ECID DFU verification are PASS. The successful packaged-GUI attempt reported DFU detected for the authoritative target ECID. Sanitized monotonic timing was: disappearance at +5.370 s, release cue at +6.438 s, and DFU enumeration at +17.170 s. No restore was initiated, and the successful run does not justify changing the current timing profile.

Subsequent packaged-GUI hardware acceptance observed this iPad in Recovery and completed a Recovery-mode GUI Restore successfully after compatible iPadOS discovery, download, and IPSW validation. Those observations establish Recovery detection and GUI Restore only. Live Restore progress, restart verification, and full end-to-end Restore acceptance were not separately recorded and remain pending. The profile's optional repeated-Recovery cable note remains a troubleshooting option only; this test does not establish that USB-A to Lightning is required.

This spike investigates whether DFUUtility can move an iPhone or iPad from Normal or Recovery mode into Device Firmware Update (DFU) mode without physical button interaction. It does not change the current restore implementation and did not send commands to a device.

## Conclusion

Recommendation: **C — do not implement automatic mobile DFU entry; implement a guided DFU assistant.**

Software can request **Normal → Recovery** through Apple's private MobileDevice stack or an open-source implementation of the same device protocol. No documented Apple API or supported `cfgutil` command provides **Normal → DFU** or **Recovery → DFU** for iPhone/iPad. Established open-source tools also require the user to press the device buttons; their “DFU helper” synchronizes a Recovery reset with countdowns and watches USB mode changes. It does not remove the physical-button requirement.

The private MobileDevice binary exports a symbol named `AMRestorableDevicePutIntoDFU`, but this is not a public API contract. Its presence does not establish supported product coverage, required preconditions, safety, or that it can make a production mobile device enter Boot ROM DFU without the hardware button condition. Calling it speculatively would be inappropriate for DFUUtility.

## Hardware observation motivating this spike

The current physical target is `iPhone7,2`, which is **iPhone 6**, not iPhone 7. The product mapping is corroborated by libirecovery's device database.

Observed by the project owner:

- Normal: family iPhone, product `iPhone7,2`, state Normal, stable ECID.
- Recovery: family iPhone, product `iPhone7,2`, state Recovery, same ECID, `bootedState = Recovery`, `isRestorable = true`.
- In Recovery, `UDID`, `serialNumber`, and `name` queries fail with ConfigurationUtilityKit error 604 because the System is not booted.
- Manual DFU entry has not yet been achieved reliably.

These observations remain the only claimed mobile hardware results. This research did not attempt DFU, Revive, Restore, erase, or an undocumented transition command.

## Apple Configurator and cfgutil

Local inspection was performed on macOS 26.6.1 (25G76), Apple Configurator 2.20 (1001.5), and `cfgutil` 2.20 (1001.5).

Public `cfgutil` commands relevant to this investigation are:

- `restart`: reboots an attached supervised, normally booted device.
- `revive`: attempts to revive a device from Recovery.
- `restore` / `update`: installs system software.
- `list` / `get`: detects and describes Normal, Recovery, and DFU attachments.

There is no advertised `enter-dfu` command. Configurator's documented UI likewise supports detecting Recovery, reviving, restoring, and device management, but does not advertise programmatic mobile DFU entry. Apple describes DFU as a manually entered alternate boot mode.

Binary inspection found an internal `cfgutil` string for `enter-recovery` (“Force attached devices into recovery mode. (INTERNAL)”) and ConfigurationUtilityKit classes named `ACUEnterRecoveryCommand` and `ACUEnterRecoveryServiceRequest`. This confirms a private Normal → Recovery path, not a DFU path. Because the command is hidden/internal, DFUUtility should not treat it as a stable supported CLI contract.

Apple's Configurator documentation says Revive operates on an iPhone/iPad in Recovery and may preserve recoverable data. It does not say that Revive enters DFU. Apple's security documentation distinguishes Recovery, which is set by iBoot on applicable devices, from DFU, which is a Boot ROM state.

Sources:

- [Apple Configurator User Guide](https://support.apple.com/guide/apple-configurator-mac/welcome/mac)
- [Intro to Apple Configurator](https://support.apple.com/en-ca/guide/apple-configurator-mac/cadf1802aed/mac)
- [Revive an iPhone, iPad, or Apple TV](https://support.apple.com/en-gb/guide/apple-configurator-mac/cad367dc4593/mac)
- [Boot process for iPad and iPhone](https://support.apple.com/en-euro/guide/security/secb3000f149/1/web/1)
- [Protecting keys in alternate boot modes](https://support.apple.com/en-ca/guide/security/sece49ec4098/web)

## MobileDevice capabilities

`MobileDevice.framework` and Configurator's bundled MobileDeviceKit are private Apple frameworks. They are not part of a documented public SDK.

Local exported-symbol inspection found:

- `AMDeviceEnterRecovery`: requests Normal → Recovery for a connected mobile device.
- Recovery-device functions for rebooting, setting auto-boot, sending iBoot commands/files, and observing Recovery devices.
- DFU-device functions for discovering and communicating with a device that is already in DFU.
- Restorable-device restore/recovery functions, including private symbols named `AMRestorableDeviceRebootToRecovery` and `AMRestorableDevicePutIntoDFU`.

The first three groups align with established behavior: request Recovery from a booted/pairable device, detect Recovery/DFU USB modes, and perform a restore after the relevant boot mode exists. The last symbol is insufficient evidence for a safe product feature. There are no public headers, availability guarantees, error contracts, entitlement requirements, or device-family guarantees. It may serve an internal restore state machine, special hardware, development configurations, or transitions with additional physical/precondition input.

Therefore:

- **Documented public API:** none for mobile Recovery or DFU entry.
- **Apple-private capability:** Normal → Recovery is well established; Recovery/DFU discovery and restore communication are well established.
- **Apple-private DFU symbol:** present, but unproven and unsupported; do not call it.
- **Exploit-assisted transitions:** out of scope.

## Established open-source tools

### libimobiledevice

`ideviceenterrecovery` is explicitly a utility for making a normally booted device enter Recovery. It uses the lockdownd/mobile-device protocol and requires the device identifier. It does not claim to enter DFU.

This is a legitimate technical option for Normal → Recovery without linking Apple's private framework, but it is still an independently implemented private protocol rather than an Apple public API.

License: LGPL-2.1-or-later for the library; individual utilities and repository files must be audited before distribution.

Sources:

- [ideviceenterrecovery source](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/ideviceenterrecovery.c)
- [libimobiledevice project and license](https://github.com/libimobiledevice/libimobiledevice)

### libirecovery

libirecovery communicates with iBoot/iBSS over USB after a device is already in Recovery or DFU. It detects the modes using different USB product IDs (`0x1280`–`0x1283` for Recovery and `0x1227` for classic DFU) and exposes connection/reset/command primitives. Its README directs users to `ideviceenterrecovery` when starting in Normal mode; it does not offer a general automatic enter-DFU operation.

This library is architecturally useful for a guided assistant because it can subscribe to Recovery/DFU attach-detach events and reset Recovery at a precisely chosen point. It is not necessary merely to detect state if `cfgutil` polling remains reliable.

License: LGPL-2.1.

Sources:

- [libirecovery project](https://github.com/libimobiledevice/libirecovery)
- [libirecovery public modes/API](https://github.com/libimobiledevice/libirecovery/blob/master/include/libirecovery.h)
- [irecovery CLI implementation](https://github.com/libimobiledevice/libirecovery/blob/master/tools/irecovery.c)

### idevicerestore

idevicerestore uses libimobiledevice for Normal mode and libirecovery for Recovery/DFU and the restore state machine. Its DFU code assumes the required mode is already present. “Pwned DFU” options are exploit-specific and explicitly limited to old vulnerable devices; they are irrelevant and prohibited for DFUUtility.

License: LGPL-2.1-or-later/GPL material depending on the component and linkage. It would be a large, duplicative dependency when DFUUtility already uses Apple's cfgutil restore pipeline.

Sources:

- [idevicerestore project](https://github.com/libimobiledevice/idevicerestore)
- [idevicerestore DFU implementation](https://github.com/libimobiledevice/idevicerestore/blob/master/src/dfu.c)

### pymobiledevice3

pymobiledevice3 reimplements many MobileDevice and restore protocols in Python and can discover Recovery/DFU devices and perform restores. Its restore code connects to an already-present Recovery/DFU transport. It does not establish a supported, universal button-free Recovery → DFU mechanism.

License: GPL-3.0. Bundling or deriving implementation code would impose materially different licensing obligations and a large runtime footprint, so it is not a suitable dependency for the native application.

Sources:

- [pymobiledevice3 project and license](https://github.com/doronz88/pymobiledevice3)
- [pymobiledevice3 restore implementation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/restore/restore.py)

### palera1n DFU helper (design reference only)

palera1n is jailbreak software and must not become a DFUUtility dependency. Its DFU-helper source is nevertheless useful evidence for the non-exploit transition UX: it asks the user to hold buttons, issues a Recovery reset at a timed point, watches attach/detach events, and declares success only after USB reports DFU. The helper itself does not exploit the device to enter DFU; later palera1n stages do, and those later stages are strictly out of scope.

License: MIT for the current palera1n repository, but its embedded components have their own licenses. No code should be copied without a specific license and provenance review.

Source: [palera1n guided DFU implementation](https://github.com/palera1n/palera1n/blob/main/src/tui_screen_enter_dfu.c)

## Specific result for iPhone7,2

`iPhone7,2` maps to iPhone 6 with an A8 SoC. It has a physical Home button. It must not be assigned the iPhone 7 (volume-down) sequence merely because its product identifier begins with `iPhone7`.

For this device:

- Normal → Recovery can be requested in software using the private MobileDevice operation or an open-source implementation, subject to pairing/trust and device availability.
- Recovery → DFU cannot be completed in software through a supported non-exploit operation found in this research.
- A guided workflow can reset it from Recovery while the user holds Side/Power + Home, then prompt the user to release Side/Power while continuing to hold Home and monitor for DFU USB enumeration.
- The assistant must preserve and verify the ECID when DFU appears. If ECID is unavailable transiently, it must wait rather than selecting another target.
- checkm8-class exploit paths exist for A8 but are prohibited and unnecessary for a normal Apple-signed restore.

Product mapping source: [libirecovery device database](https://github.com/libimobiledevice/libirecovery/blob/master/src/libirecovery.c)

## Device-family differences

DFU instructions should be based primarily on **button topology and boot-generation family**, not connector type and not the numeric prefix alone.

| Instruction family | Representative devices | Guided controls |
| --- | --- | --- |
| Physical Home button | iPhone 6/6s/SE 1; older and Home-button iPads | Side/Top + Home; release Side/Top and retain Home |
| Haptic Home, no mechanical Home during power-off | iPhone 7/7 Plus (`iPhone9,x`) | Side + Volume Down; release Side and retain Volume Down |
| No Home button | iPhone 8 and later; Face ID iPhones; modern no-Home iPads | Volume/Side-or-Top sequence; use a separately validated timing profile |

Important qualifications:

- iPhone 8 has a Home button visually, but it belongs with the later volume/side workflow because the Home control is not a mechanical boot input.
- iPads with a physical Home button use the Home-button family. Newer Face ID or top-button Touch ID iPads without Home need the modern volume/top sequence.
- Lightning versus USB-C changes cabling and USB behavior, not by itself the boot-button sequence.
- Exact timings and modern iPad/iPhone sequences must be validated per family before shipping. A small versioned rules table with explicit supported ranges is safer than a guessed exhaustive product list.
- Apple publicly documents Recovery button sequences by these broad physical families. Apple's documentation does not provide a stable developer API for DFU automation.

Apple Recovery reference: [If you can't update or restore your iPhone](https://support.apple.com/en-ie/118106)

## Recommended guided DFU assistant UX

The mobile **Enter DFU…** action now opens a sheet and does not immediately perform any device operation.

Suggested flow for the tested target:

```text
DFU Assistant

iPhone 6
Product: iPhone7,2
ECID: …

Connected in Recovery

1. Place your fingers on Side and Home.
2. When ready, choose Start.
3. Hold Side + Home                 4…3…2…1
4. Release Side; keep holding Home 10…9…8…
5. Waiting for DFU…

[Cancel]                         [Start]
```

Live outcomes should replace guesswork:

- Normal detected: offer “Move to Recovery” only if a reviewed mechanism is enabled; otherwise show the manual Recovery step.
- Recovery detected: show Ready and select the matching instruction profile.
- Expected disconnect during reset: continue the active countdown.
- DFU with the same ECID: success and close/advance to image selection.
- Recovery reappears: “Recovery detected — timing was missed,” then offer Retry.
- Normal reappears: “Device restarted normally,” then offer Retry.
- No matching device before timeout: stop and explain cable/button checks.
- Another ECID appears: do not select it; show a target-mismatch warning.

The screen must make clear that a black display alone does not prove DFU. Only actual DFU enumeration completes the assistant.

## Proposed architecture

Keep this separate from restore and privilege code:

1. `MobileDFUInstructionProfile`
   - family/range matcher
   - button labels and illustrations
   - timed phases
   - whether a controlled Recovery reset is supported
   - source/provenance and hardware-validation status
2. `MobileDeviceStateMonitor`
   - consumes the existing device discovery abstraction
   - polls or subscribes at a short interval during the assistant only
   - emits Normal/Recovery/DFU/disconnected/unknown with ECID
3. `MobileDFUAssistantModel` (`@MainActor`)
   - deterministic phase state machine
   - monotonic-clock countdowns
   - cancels all timers/tasks on dismissal
   - accepts success only for the expected ECID
4. Optional `RecoveryResetting` adapter
   - phase two, behind capability detection and explicit user action
   - preferred evaluation: a narrowly scoped libirecovery-based reset helper
   - alternative spike: a dynamically resolved private Apple recovery reset, never `AMRestorableDevicePutIntoDFU`
   - failure returns the UI to instructions; it never falls through to restore
5. Existing restore gating
   - unchanged
   - Restore remains disabled until real discovery reports DFU and image compatibility passes

USB events can make the assistant smarter than a fixed tutorial. A reset causes an expected detach, followed by either DFU, Recovery, or Normal enumeration. The state machine can react immediately, while countdowns provide button timing. Raw discovery messages should remain in logs, with identifiers sanitized in fixtures.

## Safety and support boundary

- Do not call `AMRestorableDevicePutIntoDFU` based only on its symbol name.
- Do not send arbitrary iBoot commands.
- Do not bundle jailbreak/exploit payloads or “pwned DFU” functionality.
- Do not weaken ECID selection, restore confirmation, IPSW validation, or authorization boundaries.
- Do not claim button-free DFU.
- Keep Cancel immediately available and never start Restore from the assistant.
- Hardware-test each instruction profile using detection only before enabling it generally.

## Licensing implications

No new dependency is required for the first assistant milestone if it uses the existing cfgutil discovery loop and purely visual countdowns.

If controlled Recovery reset is added later:

- libirecovery is LGPL-2.1; dynamic linking plus license/source-notice compliance is the most straightforward distribution model, but must receive a dedicated legal/build review.
- libimobiledevice is LGPL-2.1-or-later and adds further dependencies; use only if software Normal → Recovery materially improves the UX.
- pymobiledevice3 is GPL-3.0 and is not recommended for bundling.
- palera1n is a design reference only, not a dependency; do not copy exploit-related code or assets.
- Apple's MobileDevice/ConfigurationUtilityKit frameworks are private and redistribution is neither necessary nor appropriate. Dynamic use also carries compatibility/App Review risk even for a free utility.

## Implemented state-aware architecture

The implementation adds:

- `MobileDFUInstructionProfile`, with an authoritative `iPhone7,2` product mapping and centralized post-reset, Home-hold, and detection timings.
- `MobileDFUAssistantModel`, a main-actor transition state machine with injected generalized `DeviceDiscovering` and a monotonic clock source.
- Assistant-scoped polling with a 150 ms interval after each completed discovery attempt; it is inactive when the sheet is closed and in demo mode.
- The first expected disappearance after Start anchors the release cue. It is not treated as a cable failure; disappearance before an attempt remains an unexpected disconnect.
- Strict case-insensitive same-ECID DFU completion, immediate Recovery/Normal outcomes, retry summaries, timeout, cancellation, and different-device rejection.
- `MobileDFUAssistantView`, with large hold/release instructions and a local-only timing disclosure.
- Local operation logs record monotonic offsets for start, disappearance, release cue, reappearance, and detected outcome. No upload mechanism exists.
- `MobileRecoveryResetting`, an explicit capability boundary for a possible synchronized Recovery reset. Production currently injects the unavailable implementation, so no reset command is exposed or run.

Restore gating remains independent and unchanged. Successful detection updates the main target to the actually observed DFU device but never starts Restore.

## Exact next implementation milestone

Hardware-accept **phase 1: the non-mutating guided DFU assistant**:

1. Package and launch the app without starting Restore or Revive.
2. Connect the known `iPhone7,2` in Normal or Recovery and verify product/ECID.
3. Run the assistant and tune only the centralized timing values if hardware evidence requires it.
4. Verify that DFU success requires the same ECID and that Recovery/Normal outcomes offer Retry.
5. Capture sanitized Normal, Recovery, and DFU fixtures only after actual observation.
6. Only after the transition-driven physical flow is proven, separately review a dynamically linked libirecovery adapter. It must remain opt-in, preserve LGPL-2.1 notices/source-relocation obligations, and must not use exploits or `AMRestorableDevicePutIntoDFU`.
