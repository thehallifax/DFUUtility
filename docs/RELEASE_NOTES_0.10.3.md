# DFUUtility 0.10.3 Community release candidate

DFUUtility 0.10.3 is a maintenance release for the GitHub Release binary
updater.

- GitHub Release downloads now accept the documented `github.com` redirect to
  `release-assets.githubusercontent.com` while retaining HTTPS-only,
  exact-host redirect validation.
- SHA-256, size, archive, bundle, version/build, required-resource, and
  structural code-signature verification remain unchanged.
- Binary-update diagnostics now record useful lifecycle and redirect events
  using hostnames only. Signed redirect query strings and tokens are never
  logged.

The real 0.10.2 → 0.10.3 self-update has not yet been performed or accepted.
Community artifacts remain ad-hoc signed and are not Developer ID
authenticated or notarized.
