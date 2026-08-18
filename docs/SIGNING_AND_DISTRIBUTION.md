# Signing and distribution

## Artifact and identity

DFUUtility is distributed as a ZIP containing `DFUUtility.app`. ZIP preserves the signed bundle and supports the normal drag-to-Applications workflow without introducing an installer package. The privileged service is embedded and registered by `SMAppService`; it does not require a custom installer.

Version, build, helper protocol, and vendored revision originate in `Config/Version.env`. `scripts/generate-build-metadata.sh` produces the Swift constants. Packaging records the Git commit and UTC build date in `Info.plist`, so Git is not needed at runtime.

## Deterministic signing order

Production packaging uses Developer ID Application signing in this order:

1. `Contents/Resources/macvdmtool`
2. `Contents/Library/LaunchServices/DFUPrivilegedHelper`
3. `DFUUtility.app`

Each component is signed explicitly with a timestamp and hardened runtime. The production signing path does not use `codesign --deep`; deep verification is used only as a final validation. A requested identity must exist locally or packaging fails—there is no fallback to ad-hoc signing.

Both entitlement files are intentionally empty:

- `Signing/DFUUtility.entitlements`
- `Signing/DFUPrivilegedHelper.entitlements`

The app is not sandboxed because Authorization Services privilege elevation is outside App Sandbox. Neither component enables `get-task-allow`, Apple Events automation, disabled library validation, JIT, unsigned executable memory, or other broad exceptions. `macvdmtool` needs no entitlements. All three executable components use `--options runtime` in production.

## Commands

Begin every release candidate with the non-destructive aggregate check:

```sh
scripts/release-check.sh
```

`--strict` makes a dirty Git tree fail. `--production` additionally requires a Developer ID Application identity supplied through `DFUUTILITY_SIGNING_IDENTITY`, Developer ID signatures, hardened runtime, Team-ID consistency, and a locally verifiable notarization staple. It never submits to Apple:

```sh
scripts/release-check.sh --strict
DFUUTILITY_SIGNING_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
  scripts/release-check.sh --production
```

Development/ad-hoc package:

```sh
scripts/package-app.sh release
scripts/verify-app.sh .build/app/DFUUtility.app
```

Developer ID package:

```sh
scripts/package-app.sh release \
  --identity "Developer ID Application: Example Name (TEAMID)"
scripts/verify-app.sh .build/app/DFUUtility.app
```

The ZIP is written to `.build/distribution/DFUUtility-<version>.zip`.

Store notarization credentials in Keychain using `xcrun notarytool store-credentials`; never put credentials in this repository. Then run:

```sh
scripts/notarize-app.sh .build/app/DFUUtility.app \
  --keychain-profile DFUUtilityNotary
```

The script submits a temporary ZIP with `notarytool --wait`, staples and validates the ticket, runs Gatekeeper assessment, and creates `.build/distribution/DFUUtility-<version>-notarized.zip`.

## Upgrade and removal

A same-Team Developer ID app can connect to a previously registered helper and negotiate its protocol. Matching protocol runs normally. An older protocol triggers unregister/register replacement from the new app bundle. A newer protocol is rejected rather than downgraded silently. Registration is not reported ready until the daemon responds with the required protocol.

Ad-hoc builds are deliberately pinned to the exact containing app code hash; replace an ad-hoc build by unregistering the old helper first. This development restriction is not weakened to simulate production upgrades.

Unregister without deleting the app, cache, logs, or unrelated files:

```sh
scripts/uninstall-helper.sh /Applications/DFUUtility.app
```

After successful unregister, the user may move the app to Trash. Cache and logs are intentionally retained unless the user deletes those specific directories.
