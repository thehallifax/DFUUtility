# DFUUtility 0.12.1 Community

DFUUtility 0.12.1 adds focused handling for Apple's
`ConfigurationUtilityKit.error` Code 401 restore failure.

- Restore failures caused by an outdated MobileDevice host framework now show
  concise guidance to update macOS and try again.
- The alert retains safe target and selected-system context without exposing
  identifiers, commands, or local IPSW paths.
- Complete cfgutil evidence remains available in the protected operation log.
- Restore execution, targeting, firmware compatibility, and privilege behavior
  are unchanged.

Community artifacts remain ad-hoc signed and are not Developer ID authenticated
or notarized.
