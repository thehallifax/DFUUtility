# IPSW discovery, download, and caching

Last verified: 18 August 2026 on macOS 26.6.1.

## Chosen Apple source

The implementation reads Apple's macOS IPSW MobileAsset property-list catalogue directly:

```text
https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml
```

It uses the `MobileAsset/1.1` user agent. `MobileDeviceSoftwareVersionsByVersion` maps Mac model identifiers and builds to a `Restore` record containing `FirmwareURL`, `FirmwareSHA1`, `ProductVersion`, and `BuildVersion`. Duplicate universal URLs are aggregated into one release with a set of supported models. Only HTTPS firmware URLs on Apple-controlled hosts are accepted, including after redirects.

On the verification date the catalogue offered macOS 26.6.2 (25G83) at `updates.cdn-apple.com`. An Apple CDN HEAD request reported 19,772,231,540 bytes, an identical SHA-1 metadata value, an additional SHA-256 metadata value, and `Accept-Ranges: bytes`.

This is direct Apple discovery and download. IPSW.me and other community databases are not contacted or required. Apple's [software-update documentation](https://developer.apple.com/documentation/devicemanagement/deploy-software-updates-using-declarative-management) identifies the related GDMF Apple Software Lookup Service as the official list of public OS releases, but GDMF does not provide IPSW download URLs or sizes. The macOS IPSW MobileAsset catalogue is therefore the necessary Apple operational source for restore artifacts.

The MobileAsset schema is not a versioned public developer API. It is isolated behind `IPSWCatalogueFetching`, parsed defensively, covered by local fixtures, and available for an opt-in live check:

```sh
DFU_LIVE_TESTS=1 swift test
```

## Availability and signing

Catalogue presence is represented as availability in CLI output. It is not claimed as cryptographic signing/personalization status. Apple supplies an authoritative SHA-1 for file integrity, but the catalogue does not expose an authoritative per-device “signed” boolean. Compatibility and personalization remain subject to `cfgutil` during an explicitly invoked restore.

When no DFU device is present, `latest` means the numerically newest universal image in the current Apple catalogue. With a device model, `AppleIPSWService` filters releases against the aggregated supported-model set.

## Download and resume

`AppleIPSWDownloader` uses `URLSession.AsyncBytes` and writes in bounded chunks, never buffering the IPSW in memory. Progress includes received/total bytes, percentage when size is known, and current throughput. Normal task cancellation or Ctrl-C never promotes a partial file.

Partials use `downloads/<build>.partial`. If one exists, the downloader sends `Range: bytes=<size>-`. It appends only when Apple returns HTTP 206 and a matching `Content-Range`; a server that returns HTTP 200 causes a clean restart. Apple's CDN advertised byte-range support in the live check. This avoids relying on opaque `URLSession` resume data across application launches.

## Validation and atomic cache completion

Before a partial becomes cached, validation checks:

1. file existence and plausible minimum size;
2. exact catalogue size when available;
3. readable ZIP central directory;
4. `BuildManifest.plist` and `Restore.plist` presence;
5. exact SHA-1 match against Apple's `FirmwareSHA1`.

Only then is it atomically moved to:

```text
~/Library/Caches/DFUUtility/IPSW/<build>/UniversalMac_<version>_<build>_Restore.ipsw
```

Adjacent `metadata.json` records the release metadata. Cache listing and reuse revalidate existence, size, and ZIP manifest structure. They do not re-hash the entire multi-gigabyte image each time; the hash is authoritative at ingestion, while metadata and deterministic layout identify the completed artifact. `.partial` files can never be cache hits.

Cleanup is deliberately explicit: `--partials` removes only marked partial files and `--invalid` removes cache entries that fail validation. Valid IPSWs are preserved.

## Primary references

- [Apple: Deploy software updates using declarative management](https://developer.apple.com/documentation/devicemanagement/deploy-software-updates-using-declarative-management)
- [Apple: Use Apple products on enterprise networks](https://support.apple.com/101555)
- [Apple: How to revive or restore Mac firmware](https://support.apple.com/en-us/108900)
- [Apple Configurator User Guide](https://support.apple.com/guide/apple-configurator-mac/welcome/mac)
