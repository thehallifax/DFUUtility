# DFUUtility 0.10.9 Community release candidate

DFUUtility 0.10.9 is a maintenance release for the corrected binary-update
handoff when the update sheet is attached.

- The update presentation is dismissed and attached AppKit sheets are ended
  before requesting application termination.
- Termination is dispatched on the next main run-loop turn.
- Originating-process waiting, transactional replacement, rollback, relaunch
  verification, and result semantics remain unchanged.
- A non-destructive process-level handoff regression harness covers successful
  termination and installer-spawn failure behavior.

Production self-update acceptance has not yet been performed. Community
artifacts are ad-hoc signed and are not Developer ID authenticated or
notarized.
