# Binary update foundation

DFUUtility 0.10 introduces a non-destructive foundation for checking and verifying future GitHub Release updates. It stops at **Verified update artifact ready**. It does not replace the installed application, terminate the app, or relaunch it.

The release source is fixed to `thehallifax/DFUUtility` over GitHub's HTTPS API. The foundation accepts only published stable releases with strict `vMAJOR.MINOR.PATCH` tags, a newer semantic version, the exact `DFUUtility-<version>.zip` asset, a GitHub release-download URL, a sane size, and a `sha256:<64-hex>` digest.

Downloaded artifacts are written to a caller-controlled temporary directory, bounded by a safety size limit, and removed after failure. The local SHA-256 must match the release digest before archive inspection. ZIP paths are checked for absolute paths, traversal, unexpected application bundles, and escaping symbolic links. Extraction occurs in a staging directory.

The extracted bundle must contain the expected `org.dfuutility.app` identifier, selected version, numeric build, app executable, privileged-helper executable, bundled `macvdmtool`, project license, and macvdmtool attribution resources. Fixed-path `codesign --verify --deep --strict` checks structural signature validity.

This is not publisher authentication. Community artifacts are ad-hoc signed, so structural verification does not establish an Apple-authenticated Developer ID identity. Developer ID signing, notarization, and a stronger release-signing/manifest model remain future distribution work.

Installation mode is selected from the recorded update-source file. A missing
record means the app is a normal binary install and uses GitHub Releases. A
recorded existing directory remains a source/developer install and continues
to use the clean-worktree, expected-origin, main-branch, fetch-first,
fast-forward-only source updater. A recorded path that has moved or is not a
Git worktree is reported as an invalid source checkout with reinstall guidance;
it is never silently converted into a source update.

For binary installs, the coordinator checks stable GitHub Releases without
downloading. The user must explicitly choose **Download Update**. Downloaded
assets are staged under `~/Library/Application Support/DFUUtility/Updates`,
then checked for size, SHA-256, safe ZIP structure, bundle identity/version,
required resources, and structural code-signature validity. Successful work
ends at **Verified update ready to install**. This milestone never replaces,
terminates, or relaunches the installed application.
