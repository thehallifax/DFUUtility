# DFUUtility 0.10.5 Community release candidate

DFUUtility 0.10.5 is the production acceptance release for the corrected
binary self-update handoff.

- The installer waits for the originating DFUUtility process to terminate
  before replacement and relaunch.
- Relaunch verification requires a distinct process for the installed
  destination bundle.
- Update success is not recorded before relaunch verification completes.
- Backup transactions now use unique generated UUID paths.
- Additional non-destructive regression coverage exercises handoff timeout,
  result ordering, process identity, and backup-path safety.

The real 0.10.4 → 0.10.5 production self-update has not yet been performed or
accepted. Community artifacts are ad-hoc signed and are not Developer ID
authenticated or notarized.
