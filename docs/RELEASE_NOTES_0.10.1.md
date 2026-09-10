# DFUUtility 0.10.1 Community release candidate

DFUUtility 0.10.1 is a maintenance release that makes updater installation
provenance explicit for Community installations.

## Updater installation provenance

- Packaged GitHub Release builds identify themselves as **distribution**
  installations and use the verified binary updater.
- `scripts/install-local.sh` source installations identify themselves as
  **source** installations and retain the Git/source updater.
- A stale machine-global source checkout registration can no longer force a
  marked packaged distribution into source-update mode.
- Historical unmarked bundles retain conservative, backward-compatible mode
  selection; a valid recorded source checkout remains actionable where it can
  be positively associated with that legacy installation.

The installation-kind marker is a mode/provenance signal, not a security or
publisher-authentication mechanism. Existing source-updater safety checks,
binary release verification, and transactional installer rollback protections
are unchanged.

## Community trust model

Community artifacts are ad-hoc signed. Structural code-signature and
SHA-256 checks verify expected artifact integrity and structure, but do not
authenticate a publisher. Community builds do not have Apple Developer ID
publisher authentication or notarization.
