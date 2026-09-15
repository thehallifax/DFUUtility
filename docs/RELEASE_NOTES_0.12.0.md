# DFUUtility 0.12.0 Community

DFUUtility 0.12.0 expands the Community release with safer mobile Recovery
Restore workflows, more precise firmware selection, and improved technician
workflows.

## Highlights

- Restore eligible iPhone and iPad devices already in Recovery with exact
  device targeting. Recovery Restore was physically accepted on an
  `iPhone15,4` using iOS 27.0 / 24A437.
- Select firmware by exact ProductType using Apple's current catalogue together
  with validated compatible cached images. Historical compatible cached images
  can remain available in the device chooser, and Restore readiness updates
  immediately after validation.
- Improve reconnect/session reconciliation so operation state remains attached
  to the correct device, while retaining supervision metadata when reported.
- Improve sidebar sizing and live-resize behavior, with refreshed deterministic
  application screenshots.
- Add a public GitHub Release bootstrap installer while keeping distribution
  and source-checkout update paths separate.
- Extend deterministic coverage with the current 291-test suite, screenshot
  generation, and process-level regression harnesses.

Catalogue presence does not guarantee that Apple will authorize a downgrade,
and firmware signing status is not inferred where Apple does not provide an
authoritative value. These changes do not claim universal iPhone/iPad support,
parallel Restore, or hardware coverage beyond the recorded acceptance matrix.

Community artifacts remain ad-hoc signed and are not Developer ID authenticated
or notarized.
