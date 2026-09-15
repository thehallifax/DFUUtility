# iOS and iPadOS IPSW discovery

Last researched: 15 September 2026, using Apple Configurator 2.20 (`cfgutil` 2.20 / 1001.5).

## Apple sources

DFUUtility uses Apple's `https://itunes.apple.com/check/version` property list for iPhone and iPad full-restore images. The response is an Apple-hosted `MobileDeviceSoftwareVersionsByVersion` document. Under generation `1`, `MobileDeviceSoftwareVersions` maps product types such as `iPhone15,2` and `iPad13,18` to restore entries containing:

- `ProductVersion`
- `BuildVersion`
- `FirmwareURL`
- `FirmwareSHA1`

Firmware URLs are accepted only over HTTPS from Apple hosts. iPhone and iPad entries share this feed; DFUUtility classifies `iPhone*` product types as iOS and `iPad*` product types as iPadOS. Identical firmware URLs are coalesced while retaining every compatible product type.

The Apple MobileAsset software-update feed at `https://mesu.apple.com/assets/com_apple_MobileAsset_SoftwareUpdate/com_apple_MobileAsset_SoftwareUpdate.xml` was also inspected. It describes OTA assets, not the full `.ipsw` restore packages required by this workflow, and is therefore not used for restore selection.

These are direct Apple operational endpoints, not documented versioned SDK APIs. Parsing is isolated and fixture-tested. The feed contains historical entries, so catalogue presence is **not** treated as an authoritative current/signing assertion. DFUUtility records only that an image is Apple-catalogue-listed and keeps `isSigned` unknown. Non-HTTPS legacy entries are ignored. Apple Configurator makes the final personalization/restore decision.

The live feed is not a complete version history for each product. On 15 September 2026 its newest generation listed one exact restore asset for `iPad11,6` (iPadOS 26.7, build 23H24), even though other product branches and legacy devices produced other OS versions elsewhere in the same document. Older generation keys are schema/device generations rather than a trustworthy archive of every formerly offered IPSW. Apple may continue hosting a known older CDN URL after removing it from this catalogue, but URL reachability does not establish signing or restore eligibility.

No documented Apple endpoint used by DFUUtility supplies both a complete historical full-IPSW catalogue and authoritative current signing status. Expanding beyond Apple-listed entries would therefore require an explicitly optional third-party metadata provider, a documented trust policy, and separate presentation of metadata provenance. DFUUtility does not introduce that dependency implicitly.

The feed does not reliably provide a full IPSW byte size. Download progress uses the Apple CDN HTTP response size when available, and a completed download is validated before becoming usable.

## Compatibility and validation

Firmware selection requires an exact match between the target's authoritative `cfgutil deviceType` product type and the restore entry's product-type set. Unknown compatibility produces no selectable recommended image.

The shared validator checks archive readability, `BuildManifest.plist`, `Restore.plist`, expected download size when supplied, and Apple's SHA-1 when supplied. For a catalogue release, `SupportedProductTypes` in `BuildManifest.plist` must intersect the release product types. This prevents an IPSW for another iPhone or iPad model from becoming usable.

Mobile cache entries are separated under `IPSW/iOS/` and `IPSW/iPadOS/`. The existing macOS cache layout remains unchanged for backward compatibility.

## Device discovery and state

Apple Configurator's bundled `cfgutil` is the primary supported mechanism:

```sh
cfgutil --format JSON --timeout 1 list
cfgutil --format JSON --timeout 1 --ecid <ECID> get \
  ECID deviceType deviceClass bootedState isRestorable isSupervised UDID serialNumber name
```

- Family comes from `deviceClass` plus the authoritative product-type prefix.
- Product type comes from `deviceType`.
- ECID, UDID, and serial number are retained in separate fields when reported.
- Supervision state is retained when cfgutil reports it; an absent value remains unknown.
- `bootedState` values containing booted/normal, recovery/restore, or DFU map to Normal, Recovery, or DFU. Anything else remains Unknown.

The narrow `ioreg` fallback can detect Apple Recovery/DFU USB identities when Configurator metadata is unavailable. If USB metadata does not distinguish Mac, iPhone, or iPad, the family remains Unknown rather than being guessed. Normal iPhone/iPad discovery depends on `cfgutil`.

No synthetic state is generated. No automatic iPhone/iPad DFU transition is attempted, and `macvdmtool` is rejected for non-Mac targets.

## Restore and revive boundary

Local `cfgutil help` confirms an ECID-selectable `restore --ipsw <path>` operation and the existing `--progress`, `--verbose`, and timeout options. DFUUtility reuses its single structured progress parser and sends the selected ECID, including for a Recovery-mode Restore. This targeting path is physically accepted on iPad Recovery hardware.

`cfgutil restart` is documented by the installed tool as supervised-only. It is not documented as a command for exiting Recovery or DFU. DFUUtility therefore offers mobile Restart only when cfgutil has positively reported a supervised device in Normal mode; it does not issue an untargeted restart or infer success from disappearance.

The GUI conservatively enables mobile Restore only for an exact-product validated image and a target positively reported in Recovery or DFU. Restore erases the target. It does not automate activation, bypass Activation Lock, or change setup ownership.

Apple documents that Configurator can restore iPhone and iPad and that its Revive Device action can attempt recovery while retaining recoverable data. DFUUtility enables mobile Revive only when `cfgutil` reports Recovery state. This still requires physical-device validation before being described as supported beyond experimental status.

Primary documentation:

- [Apple Configurator User Guide](https://support.apple.com/guide/apple-configurator-mac/welcome/mac)
- [Update or restore devices](https://support.apple.com/en-lamr/guide/apple-configurator-mac/cad789a3f0bd/mac)
- [Revive an iPhone, iPad, or Apple TV](https://support.apple.com/en-gb/guide/apple-configurator-mac/cad367dc4593/mac)
- [Back up and restore iPhone and iPad devices](https://support.apple.com/en-au/guide/apple-configurator-mac/cadbf9b61c/mac)

## Hardware validation still required

iPhone 6 (`iPhone7,2`) has since passed Normal and Recovery detection, guided same-ECID DFU, Apple image discovery/download, IPSW validation, GUI Restore, live progress, and restart verification. Sanitized observed fixtures are stored under `Tests/Fixtures`. This does not establish coverage for other iPhone models or end-to-end iPad support. A destructive restore continues to require separate explicit authorization from the device owner.

The iPad (7th generation) Wi-Fi (`iPad7,11`) has passed Normal and Recovery detection, guided same-ECID DFU, compatible image discovery, GUI download, IPSW validation, and an ECID-targeted Recovery-mode Restore. Live Restore progress, restart verification, and full end-to-end acceptance remain pending for that model. Two simultaneously connected `iPad12,1` Recovery targets have also passed sequential ECID-targeted Restore. These results do not establish support for `iPad11,6`; the observed `iPad11,6` Recovery Restart failure is the evidence for the stricter supervised-Normal restart gate described above.

An `iPhone15,4` in Recovery has also completed an exact-ECID Restore using iOS 27.0 / 24A437 after the image was downloaded and validated. This is current-image acceptance evidence only; historical iPhone15,4 Restore has not been tested.
