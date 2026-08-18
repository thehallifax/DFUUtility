# Privileged DFU helper architecture

Last reviewed: 18 August 2026.

## Current milestone boundary

DFUUtility builds and distributes the pinned `macvdmtool` binary, but does not grant it persistent privilege. The CLI retains the existing transparent terminal boundary:

```text
dfuctl → /usr/bin/sudo <resolved-macvdmtool> dfu
```

When already running as root, it invokes the resolved tool directly. For the interactive CLI path, `ProcessRunner.runInteractive` explicitly attaches the child process's standard input, output, and error to the caller's corresponding terminal file handles. Foundation creates the child in a new process group, so the runner temporarily makes that group the terminal foreground group and restores the dfuctl group after it exits. Nothing is piped or forwarded by Swift. `sudo` therefore owns terminal echo, authentication, output, and Ctrl-C behavior; DFUUtility never receives, captures, or stores an administrator password. The binary is neither setuid nor installed with weakened permissions. A failed or cancelled authorization is returned as an explicit privilege error; sudo's useful diagnostic is already displayed directly on the terminal.

The process-group handoff cannot be faithfully unit-tested without a real controlling terminal. The manual regression is `dfuctl dfu`: while sudo waits, its process group must equal the TTY foreground group and terminal `echo` must be disabled. Hardware validation must then confirm the same ECID reappears in DFU.

The SwiftUI app must not present a custom password prompt or attempt to drive `sudo`, which does not provide an appropriate GUI authorization architecture. Enter DFU remains unable to elevate reliably from a packaged GUI until the production helper described below is implemented.

## Recommended production design

Use a narrowly scoped, code-signed, `launchd`-managed privileged service registered with `SMAppService` on macOS 13+. Apple describes `SMAppService` as the current API for registering bundled LaunchAgents and LaunchDaemons; `SMJobBless` is deprecated. The main app stays unprivileged and sends a typed XPC request to the helper.

The privileged service should:

1. expose only a single operation such as `enterDFU`, not arbitrary executable paths or arguments;
2. validate the connecting client's code signature, designated requirement, team identifier, and protocol version before accepting a request;
3. request/check an application-specific Authorization Services right immediately before the operation, using the system authorization UI;
4. execute the pinned VDM implementation in-process or as a fixed, verified bundled child—never a caller-supplied path;
5. validate ownership, mode, code signature, and expected hash of any child binary;
6. return structured status and raw IOKit errors over XPC;
7. run only for the minimum time necessary and carry no networking, filesystem-general, shell, or restore capability;
8. keep restore in the separate unprivileged `cfgutil` engine and never chain DFU into restore.

The application and daemon will need consistent signing identities, hardened runtime configuration, launch daemon property-list metadata inside the signed app, secure XPC interfaces, and an installation/registration UX that reflects `SMAppService.Status`. Authorization Services is unavailable to sandboxed apps for privilege escalation, so distribution and sandbox strategy must be resolved before implementation.

Do not use `AuthorizationExecuteWithPrivileges`; Apple deprecates it and directs developers to a `launchd` helper and/or Service Management. Do not use a setuid copy of `macvdmtool`.

## References

- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: Service Management](https://developer.apple.com/documentation/servicemanagement/)
- [Apple: Authorization Services](https://developer.apple.com/documentation/security/authorization-services)
- [Apple: AuthorizationExecuteWithPrivileges (deprecated)](https://developer.apple.com/documentation/security/authorizationexecutewithprivileges)
- [Apple: Authorization Services Programming Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/authorization_concepts/01introduction/introduction.html)
