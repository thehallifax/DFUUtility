# Privileged DFU helper architecture

Last reviewed: 18 August 2026.

## CLI privilege boundary

The CLI remains transparent and terminal-native:

```text
dfuctl → /usr/bin/sudo <resolved-macvdmtool> dfu
```

`ProcessRunner.runInteractive` attaches all three standard handles to the controlling terminal and makes Foundation's child process group the foreground group until it exits. `sudo` owns echo, authentication, output, and Ctrl-C. DFUUtility never receives or stores a password. Nothing is setuid and permissions are not weakened.

## Implemented GUI architecture

The SwiftUI app never invokes `sudo`. `PrivilegedDFUOperator` registers the embedded launch daemon using `SMAppService`, asks Authorization Services for the application-specific `org.dfuutility.enter-dfu` right, and sends only its external authorization form over privileged XPC. The system supplies the administrator UI. Cancellation and failure return actionable errors and leave the app usable.

The daemon exports one privileged action, `enterDFU`; its only other method is read-only version/status diagnostics. It:

1. rejects callers whose signed identifier is not `org.dfuutility.app`;
2. binds ad-hoc development connections to the exact containing app code-directory hash and compares Team ID when available;
3. reconstructs and checks the authorization right inside the privileged process;
4. resolves the fixed bundled `macvdmtool` path itself and supplies the fixed `dfu` argument;
5. rejects a writable, non-executable, or invalidly signed tool;
6. has no API for paths, arbitrary arguments, shell commands, networking, revive, or restore.

The app still verifies that the exact pre-operation ECID reappears in DFU. The helper's successful exit alone is insufficient.

```text
DFUUtility.app/Contents/MacOS/DFUUtility
DFUUtility.app/Contents/Library/LaunchServices/DFUPrivilegedHelper
DFUUtility.app/Contents/Library/LaunchDaemons/org.dfuutility.privileged-helper.plist
DFUUtility.app/Contents/Resources/macvdmtool
```

`AuthorizationExecuteWithPrivileges`, setuid, custom password dialogs, and GUI-driven `sudo` are deliberately not used.

## Registration and local development

The GUI requires the packaged `.app`; `swift run DFUUtility` has no embedded daemon to register. `scripts/package-app.sh release` produces `.build/app/DFUUtility.app` with consistent ad-hoc signatures. On first registration, macOS may require approval under System Settings → General → Login Items. Diagnostics reports whether the service is registered.

Ad-hoc signing is only for local development. It is not a public-distribution security identity.

## Production distribution requirements

Before public distribution:

1. sign the app, helper, and nested tool consistently with Developer ID Application identities and hardened runtime;
2. confirm designated requirements, Team IDs, launch-daemon metadata, and the final non-sandboxed Authorization Services strategy;
3. archive, notarize, staple, and test clean installation, upgrade, approval, and removal from `/Applications`;
4. exercise `SMAppService.Status.requiresApproval` on each supported macOS version;
5. independently security-review XPC audit-token/code-signature validation and authorization-right lifecycle.

## References

- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: Service Management](https://developer.apple.com/documentation/servicemanagement/)
- [Apple: Authorization Services](https://developer.apple.com/documentation/security/authorization-services)
- [Apple: AuthorizationExecuteWithPrivileges (deprecated)](https://developer.apple.com/documentation/security/authorizationexecutewithprivileges)
