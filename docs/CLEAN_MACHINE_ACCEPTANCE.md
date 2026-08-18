# Clean-machine acceptance

Perform this on a Mac that has never run DFUUtility. Do not run Restore during this acceptance test.

## Installation and first run

1. Obtain the notarized distribution ZIP and verify its checksum through the release channel.
2. Expand it and drag `DFUUtility.app` to `/Applications`.
3. Launch `/Applications/DFUUtility.app`. Confirm Gatekeeper opens it without an override.
4. Open Diagnostics, save an initial report, and confirm app version/build, valid Developer ID Team ID, hardened runtime, bundled `macvdmtool`, Configurator, and `cfgutil` status.
5. Confirm the first-run card says **DFU Setup Required** and the helper is **Not registered**.
6. Click **Set Up DFU Helper**.
7. If the state becomes **Awaiting user approval**, click **Open System Settings**, enable DFUUtility under General → Login Items, return to the app, and click **Check Again**.
8. Do not treat setup as complete until the app reports **Running**, the expected version, and protocol 1.

## Non-destructive hardware acceptance

1. Connect exactly one target Mac using the correct DFU port and a data-capable cable.
2. Click Refresh and confirm Normal state, model, and ECID.
3. Record the ECID.
4. Click **Enter DFU** and approve the standard macOS administrator authorization dialog. Never enter a password into a DFUUtility-owned field; none should exist.
5. Confirm the app reports DFU and the same ECID.
6. Save Diagnostics and view the operation log.
7. Stop. Do not click Revive or Restore unless separately intended and authorized.

## Upgrade acceptance

1. With v1 registered, quit v1 and replace `/Applications/DFUUtility.app` with a same-Team signed v2.
2. Launch v2. Confirm a matching helper remains ready, or an older protocol is explicitly reported as requiring upgrade.
3. Run setup when prompted. Confirm the old service is unregistered/replaced and the new version/protocol responds.
4. Confirm no duplicate or orphaned service remains and authorization still uses macOS UI.
5. A newer-than-app helper must be reported incompatible and must not execute DFU.

## Removal acceptance

Run:

```sh
scripts/uninstall-helper.sh /Applications/DFUUtility.app
```

Relaunching should show Not registered. The script must not delete the app, IPSW cache, logs, or unrelated launch daemons. Move the app to Trash only after unregistering.

## Expected failures and troubleshooting

- **Gatekeeper rejects the app:** confirm notarization/stapling with `xcrun stapler validate` and `spctl --assess --type execute --verbose=2`.
- **Awaiting approval:** enable DFUUtility under System Settings → General → Login Items, then check again.
- **Registered but not responding:** save Diagnostics, restart the app, and inspect macOS unified logs for `org.dfuutility.privileged-helper`.
- **Signature or Team ID mismatch:** do not override it; rebuild all nested code with the same Developer ID identity.
- **Upgrade required:** use Set Up DFU Helper; if a development ad-hoc build was replaced, unregister the old build first.
- **No target:** verify the DFU port, cable, host architecture, and Configurator installation.
- **Authorization cancelled:** retry; the app must remain usable.
