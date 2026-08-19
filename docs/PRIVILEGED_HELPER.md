# Privileged DFU helper architecture

Last reviewed: 18 August 2026.

## CLI privilege boundary

The CLI remains transparent and terminal-native:

```text
dfuctl → /usr/bin/sudo <resolved-macvdmtool> dfu
```

`ProcessRunner.runInteractive` attaches all three standard handles to the controlling terminal and makes Foundation's child process group the foreground group until it exits. `sudo` owns echo, authentication, output, and Ctrl-C. DFUUtility never receives or stores a password. Nothing is setuid and permissions are not weakened.

## Implemented GUI architecture

The GUI selects its privilege mode from the packaged signatures. An ad-hoc app or an app/helper pair without the same Apple-issued Team ID uses **Community** mode. A matching Team-ID pair uses **Signed helper** mode.

In Community mode, the app launches `/usr/bin/osascript` directly and asks it to perform `do shell script` with administrator privileges. The generated command contains only a robustly quoted, trusted bundled/project `macvdmtool` path and the constant `dfu` argument. Environment overrides, Homebrew copies, arbitrary paths, arbitrary arguments, Terminal, `sudo`, stdin, and application-owned password UI are excluded. macOS owns the authorization dialog. The same outer `PrivilegedDFUOperator` performs the preflight and same-ECID post-transition verification for both modes.

Community mode does not query, register, unregister, or require `SMAppService` during ordinary startup. Stale signed-helper state is ignored unless the user explicitly runs the scoped removal workflow.

### Signed helper mode

The SwiftUI app never invokes `sudo`. `PrivilegedDFUOperator` registers the embedded launch daemon using `SMAppService`, asks Authorization Services for the application-specific `org.dfuutility.enter-dfu` right, and sends only its external authorization form over privileged XPC. The system supplies the administrator UI. Cancellation and failure return actionable errors and leave the app usable.

The daemon exports one privileged action, `enterDFU`; its only other method is read-only version/status diagnostics. It:

1. rejects callers whose signed identifier is not `org.dfuutility.app`;
2. in production, requires valid code with the exact app identifier and the containing app's Developer ID Team ID, providing a stable requirement across same-Team upgrades; ad-hoc development connections are instead pinned to the exact containing app code-directory hash;
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

The GUI requires the packaged `.app`; `swift run DFUUtility` has no embedded daemon to register. `scripts/package-app.sh release` produces an ad-hoc package suitable for UI development, but not privileged-helper registration. To exercise the helper locally, package with a stable Apple Development identity:

```sh
scripts/package-app.sh release --identity "Apple Development: Developer Name (TEAMID)"
```

Developer ID Application remains the distribution identity. On first registration, macOS may require approval under System Settings → General → Login Items. Diagnostics reports both registration state and signing readiness.

Ad-hoc signing is only for unprivileged local UI development. On macOS 26.6.1, Service Management accepted the registration request but launchd rejected the daemon with `OS_REASON_CODESIGNING`; Background Task Management logged Security error `-67068` (`cannot find code object on disk`) and ignored the launchd plist's associated bundle identifiers because the executable had no Team ID. The request originated successfully from `.build/app`, so that location was not the blocker. Rebuilding changed the ad-hoc code directory and also left approval records tied to obsolete identities. A stable Apple-issued Team ID is therefore required for supported helper development; no global Background Items reset is part of the workflow.

Clicking setup for an enabled but non-responsive service does not automatically unregister it. This preserves launchd failure evidence and avoids turning a diagnosable signing failure into a destructive unregister/re-register cycle. Only a responding helper that proves its protocol is outdated is replaced automatically.

The helper must resolve its own image with `proc_pidpath`, not `argv[0]`. Service Management intentionally launches an embedded `BundleProgram` with a relative argv such as `Contents/Library/LaunchServices/DFUPrivilegedHelper`. Treating that as an absolute anchor causes containing-app validation to inspect `/` and reject every XPC peer. This was observed on macOS 26.6.1 as Security.framework UNIX error 21 followed by “Peer connection was rejected by the listener.”

An initial `SMAppService.register()` error may coincide with the OS moving the service to `requiresApproval`. The client rechecks the authoritative Service Management state briefly after registration failure and presents **Approval Required** instead of an authorization or generic setup failure. `enabled` remains distinct from a responding, protocol-compatible helper.

Development builds log registration state, XPC connection lifecycle, helper startup/listener activation, and caller-validation results through unified logging under subsystems `org.dfuutility.app` and `org.dfuutility.privileged-helper`. Authorization external forms and credentials are never logged.

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
