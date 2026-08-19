# Contributing to DFUUtility

DFUUtility is an early Community beta. Bug reports, focused fixes, documentation improvements, and results from additional Mac models are welcome.

Report bugs and request enhancements through the [DFUUtility issue tracker](https://github.com/thehallifax/DFUUtility/issues).

## Before reporting an issue

1. Confirm the host runs macOS 14 or newer and Apple Configurator is installed.
2. Run `.build/release/dfuctl doctor` or open **Diagnostics** in the app.
3. Reproduce with exactly one target connected.
4. Retain the relevant operation log from `~/Library/Logs/DFUUtility/`.

Never publish administrator credentials, Apple IDs, local usernames, home-directory paths, serial numbers, ECIDs, or other device identifiers. Redact those values from screenshots, diagnostics, and logs before attaching them.

An effective report includes the DFUUtility version/build, host macOS and hardware, target model identifier, target state, expected and observed behavior, reproducible steps, and sanitized logs. State explicitly whether any destructive Restore operation was involved.

## Development workflow

Keep changes focused and preserve the safety boundaries around authorization, same-ECID verification, image validation, and destructive confirmation. Automated tests must not invoke real DFU, Revive, or Restore operations.

Before proposing a change, run:

```sh
swift build
swift test
swift build -c release
scripts/package-app.sh release
scripts/verify-app.sh .build/app/DFUUtility.app
git diff --check
```

For release-oriented changes, also run `scripts/release-check.sh`. Its `--strict` mode requires a clean worktree and is therefore intended for a committed release candidate.

## Hardware results

Hardware tests must be deliberate and manually initiated. Include the Mac marketing name and model identifier, but omit ECIDs and serial numbers from public material. Report Normal detection, DFU entry, same-target verification, Revive or Restore, live progress, and restart verification as separate results; do not generalize one model's result to a hardware family.

## License

DFUUtility is licensed under the Apache License 2.0. Unless explicitly stated otherwise, contributions submitted for inclusion are made under that license. Vendored dependencies retain their own upstream copyright, license, and attribution.
