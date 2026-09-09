# DFUUtility 0.10.0 Community release candidate

DFUUtility 0.10.0 adds a verified binary-update path for normal Community
installations while retaining the existing Git/source updater for developer
checkouts.

## Binary updates

- Checks published GitHub Release metadata before downloading.
- Verifies the exact asset, size, SHA-256 digest, safe archive structure,
  bundle identity, version/build, required resources, and structural code
  signature before offering installation.
- Requires an explicit **Download Update**, followed by an explicit
  **Install Update** action. Updates are never installed automatically.
- Replaces the application transactionally, preserving a same-volume backup
  until the new bundle passes in-place verification.
- Rolls back on replacement or verification failure and records recovery
  failures for diagnosis.
- Verifies the expected version/build after relaunch before reporting success.

Developer/source installations continue to use the recorded Git checkout and
its clean-worktree, expected-origin, fast-forward-only safety rules. The
binary and source update paths remain isolated.

## Acceptance and testing

`scripts/test-binary-installer.sh` invokes the packaged `DFUBinaryInstaller`
against signed synthetic bundles in a temporary directory. It covers success,
verification rollback, forced rollback failure, invalid transactions,
restrictive permissions, and no-op relaunch isolation without touching
`/Applications`, hardware, firmware, or the real application.

The release also stabilizes async polling/download tests by replacing timing
assumptions with explicit task and event synchronization.

## Community trust model

Community artifacts are ad-hoc signed. Structural code-signature verification
and SHA-256 verification establish artifact integrity and expected structure;
they do not authenticate a publisher. Community builds do not have Apple
Developer ID publisher authentication or notarization.
