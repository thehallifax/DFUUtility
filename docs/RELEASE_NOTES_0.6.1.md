# DFUUtility 0.6.1

DFUUtility 0.6.1 is a focused patch release over 0.6.0.

- Fixed Refresh and capability controls remaining stuck after successful Restore or Revive.
- Fixed stale reconnect tasks racing newer Refresh results.
- Improved Mac Enter DFU failure classification and concise error handling.
- Preserved opaque VDM response codes in operation logs instead of showing raw tool output in the primary UI.
- Changed the Community installer so it no longer runs the full test suite by default.
- Added explicit `--test` and `--verbose` installer modes, including combined use.
- Improved concise progress, requirements checks, and actionable failure diagnostics for clean-machine installation.

DFU transition behavior, Restore and Revive execution, IPSW compatibility, ECID safety, guided mobile DFU behavior, and the privilege architecture are unchanged.
