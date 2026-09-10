# DFUUtility 0.10.7 Community release candidate

DFUUtility 0.10.7 is the corrected bootstrap release for subsequent binary
self-update acceptance.

- Binary updater handoff now has an explicit AppKit termination reply, so the
  originating application can terminate after launching the installer.
- The installer continues to wait for the originating process to disappear
  before replacement and relaunch.
- Transactional replacement, rollback, distinct-process relaunch verification,
  and post-relaunch success safeguards are unchanged.

The real 0.10.7 → 0.10.8 production self-update has not yet been performed or
accepted. Community artifacts are ad-hoc signed and are not Developer ID
authenticated or notarized.
