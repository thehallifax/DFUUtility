# IPSW discovery and caching

Last reviewed: 18 August 2026.

## Recommendation

Do not make a community firmware index a runtime dependency. For the MVP, accept an explicitly supplied local IPSW and let Apple's `cfgutil` validate compatibility/personalize during restore. For automatic discovery, use Apple's signed MobileAsset software-update catalog as the source of candidates, then filter the asset's supported-device/build metadata against the ECID/device identity returned by Configurator.

Apple's catalog formats and endpoints are operational interfaces rather than a documented, compatibility-guaranteed developer API. They need fixture tests and tolerant parsing. URLs accepted for download must be HTTPS and restricted to Apple-controlled hosts (typically `updates.cdn-apple.com` or another Apple catalog CDN); redirects must be revalidated. Do not infer “signed” merely because an asset remains in a catalog. If the personalization/signing status cannot be authoritatively established, expose it as unknown and allow `cfgutil` to make the final decision.

Apple's deployment documentation describes software-update services and the requirement to reach Apple hosts; Apple Configurator/Finder are the authoritative restore clients. Relevant primary references:

- [Apple Platform Deployment: Use Apple products on enterprise networks](https://support.apple.com/guide/deployment/use-apple-products-on-enterprise-networks-depae9c269d8/web)
- [Apple: How to revive or restore Mac firmware](https://support.apple.com/en-us/108900)
- [Apple Configurator User Guide](https://support.apple.com/guide/apple-configurator-mac/welcome/mac)

## Service boundary

`IPSWService` exposes candidate lookup, recommendation, and download independently from restore. `IPSWRelease` carries version, build, URL, optional size/checksum, supported identifiers, and tri-state signing information. A catalog implementation should preserve unknown fields and reject a recommendation unless compatibility is positively matched.

Selection order:

1. Obtain a stable target identity/model from `cfgutil` in DFU.
2. Fetch Apple catalog metadata with normal HTTP cache validators.
3. Accept only universal Mac restore assets whose supported-device set includes the target.
4. Prefer the newest production release that the catalog marks applicable; never call it signed unless verified by an authoritative response.
5. Return multiple candidates to the UI/CLI when applicability is ambiguous.

## Cache design

Default directory: `~/Library/Caches/DFUUtility/IPSW/`.

Each completed file should have adjacent atomic JSON metadata containing version, build, source URL, expected/actual size, checksum algorithm/value when supplied, supported devices, fetch time, and relevant ETag/Last-Modified values. The current `IPSWCache` establishes deterministic destinations and size-aware reuse; download transport is intentionally not wired until the catalog shape is validated against target hardware.

A production downloader should:

- download to a unique `.partial` file in the same directory;
- report byte progress from `URLSessionDownloadDelegate` and support task cancellation;
- retain resume data when Apple/CDN response semantics permit it;
- verify expected size and a catalog checksum when available;
- open and validate the ZIP central directory plus `BuildManifest.plist` and `Restore.plist`;
- atomically rename the completed file and metadata into place;
- never treat `.partial` files as cached images.

Compatibility metadata, not filenames, must drive target selection. Exact URL, build, expected size, and checksum prevent accidental reuse when Apple republishes metadata or two releases share a marketing version.
