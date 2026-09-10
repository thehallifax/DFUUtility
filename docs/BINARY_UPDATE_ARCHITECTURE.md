# Binary update foundation

DFUUtility 0.10 introduces a staged GitHub Release updater and a transactional application installer. Artifact verification is always completed before installation; installation is explicit and recoverable.

The release source is fixed to `thehallifax/DFUUtility` over GitHub's HTTPS API. The foundation accepts only published stable releases with strict `vMAJOR.MINOR.PATCH` tags, a newer semantic version, the exact `DFUUtility-<version>.zip` asset, a GitHub release-download URL, a sane size, and a `sha256:<64-hex>` digest.

Downloaded artifacts are written to a caller-controlled temporary directory, bounded by a safety size limit, and removed after failure. The local SHA-256 must match the release digest before archive inspection. ZIP paths are checked for absolute paths, traversal, unexpected application bundles, and escaping symbolic links. Extraction occurs in a staging directory.

The extracted bundle must contain the expected `org.dfuutility.app` identifier, selected version, numeric build, app executable, privileged-helper executable, bundled `macvdmtool`, project license, and macvdmtool attribution resources. Fixed-path `codesign --verify --deep --strict` checks structural signature validity.

This is not publisher authentication. Community artifacts are ad-hoc signed, so structural verification does not establish an Apple-authenticated Developer ID identity. Developer ID signing, notarization, and a stronger release-signing/manifest model remain future distribution work.

Installation mode is selected from installation provenance first. Packaged
distribution bundles carry `DFUUtilityInstallationKind=distribution` in their
generated bundle metadata and use GitHub Releases even if an older machine-
global `update-source` record remains. Source installs are packaged with
`DFUUtilityInstallationKind=source` by `scripts/install-local.sh` and continue
to use the recorded checkout. The marker is a mode-selection signal, not a
publisher-authentication boundary.

Unmarked historical bundles retain the legacy conservative behavior: an
existing source record remains source-mode, while a packaged `.app` without a
record uses binary mode. A recorded path that has moved or is not a Git
worktree is reported as an invalid source checkout with reinstall guidance; it
is never silently converted into a source update.

For binary installs, the coordinator checks stable GitHub Releases without
downloading. The user must explicitly choose **Download Update**. Downloaded
assets are staged under `~/Library/Application Support/DFUUtility/Updates`,
then checked for size, SHA-256, safe ZIP structure, bundle identity/version,
required resources, and structural code-signature validity. Successful work
ends at **Verified update ready to install**. Installation is a separate,
explicit transaction: the running app writes a restrictive descriptor and
hands it to the bundled one-shot `DFUBinaryInstaller`, then quits. The helper
validates the descriptor, preserves the current bundle as a same-volume
backup, moves the verified staged bundle into the validated destination,
verifies it in place, and rolls back on replacement or verification failure.
The backup is removed only after successful in-place verification. The helper
writes a restrictive result record and launches the actual destination bundle;
the next DFUUtility launch consumes that record and reports success only when
the running version matches the expected transaction.

The destination is the currently running `org.dfuutility.app` bundle, whether
that is `/Applications/DFUUtility.app` or another existing writable location.
An unrelated bundle, missing destination, ambiguous path, non-writable parent,
or artifact outside the controlled staging area is rejected. No persistent
privileged updater or sudo-based escalation is used; a non-writable location
fails with a permission error. Source/Git updating remains isolated and never
invokes the binary transaction helper.

## Production acceptance

The complete Community binary updater lifecycle was production accepted for
`0.10.9 → 0.10.10`. Acceptance covered GitHub Release discovery, legitimate
GitHub asset redirects, asset download and SHA-256 verification, explicit
Download Update and Install Update actions, update-sheet dismissal,
external-installer handoff, originating-process termination and bounded PID
waiting, transactional replacement, rollback protections, destination
validation, and relaunch verification using a distinct `0.10.10` process.

Source-checkout updates and binary-distribution updates remain separate
workflows. This acceptance applies to the Community binary updater only; it
does not claim Developer ID distribution, publisher authentication, or
notarization. Community artifacts remain ad-hoc signed.

## Local installer acceptance harness

The packaged helper can be exercised without touching an installed application:

```sh
scripts/test-binary-installer.sh
```

The harness packages the current `DFUBinaryInstaller`, creates signed synthetic
DFUUtility bundles beneath a temporary directory, and invokes the real helper
as a child process. It covers replacement, post-replacement verification
rollback, forced rollback failure with preserved recovery evidence, malformed
or out-of-root transactions, restrictive result permissions, and a no-op
relaunch marker. Its explicit test-only environment overrides are accepted by
the helper only when `DFUUTILITY_INSTALLER_TEST_MODE=1`; production launches
continue to use the normal Application Support root and `/usr/bin/open`.
The harness never uses `/Applications` as a destination and makes no network,
Git updater, firmware, or hardware calls.
