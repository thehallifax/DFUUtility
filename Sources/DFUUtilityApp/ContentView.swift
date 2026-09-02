import DFUAppSupport
import DFUCore
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showVersions = false
    @State private var showImporter = false
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var confirmRestore = false
    @State private var showMobileDFU = false
    @State private var showCacheManager = false
    @State private var demoTarget = "None"

    init(model: AppModel) {
        self.model = model
        _showVersions = State(initialValue: CommandLine.arguments.contains("--show-version-chooser"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("DFUUtility").font(.largeTitle.bold())
                Spacer()
                if model.isDemoMode { Text("DEMO MODE — NO HARDWARE ACTIONS").font(.caption.bold()).foregroundStyle(.orange).padding(7).background(.orange.opacity(0.12), in: Capsule()) }
                if model.isUpdateTestMode { Text("UPDATE TEST — SIMULATION ONLY").font(.caption.bold()).foregroundStyle(.orange).padding(7).background(.orange.opacity(0.12), in: Capsule()) }
                if case .available = model.updateCoordinator.state {
                    Button("Update Available") { model.isUpdatePresentationRequested = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("Diagnostics…") { showDiagnostics = true }
                Button("About…") { showAbout = true }
                Button(checkButtonTitle) { model.requestManualUpdateCheck() }
                    .disabled(model.isDemoMode || model.isScreenshotPresentation || model.updateCoordinator.state == .checking)
            }
            targetCard
            Divider()
            restoreCard
            Spacer(minLength: 0)
        }
        .padding(24)
        .task { await model.load() }
        .sheet(isPresented: $showVersions) { VersionPicker(model: model, isPresented: $showVersions) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(report: model.doctorReport, privilegeMode: model.privilegeMode, helperState: model.privilegedHelperState, registrationErrorDetails: model.helperRegistrationErrorDetails).frame(minWidth: 480, minHeight: 430).padding() }
        .sheet(isPresented: $showAbout) { AboutView().frame(minWidth: 520, minHeight: 420).padding() }
        .sheet(isPresented: $showCacheManager) { CacheManagerView(model: model, isPresented: $showCacheManager) }
        .sheet(isPresented: $model.isUpdatePresentationRequested) { UpdateView(model: model) }
        .sheet(isPresented: $showMobileDFU, onDismiss: { model.dismissMobileDFUAssistant() }) {
            if let assistant = model.mobileDFUAssistant { MobileDFUAssistantView(model: assistant, isPresented: $showMobileDFU) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; await model.validateManualIPSW(url) } }
        }
        .alert("Restore this \(model.target?.family.displayName ?? "device")?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { model.restoreConfirmed() }
        } message: {
            Text("\(model.target?.friendlyName ?? "Target device")\nProduct: \(model.target?.restoreProductType ?? "Unknown")\nECID: \(model.target?.ecid ?? "Unknown")\n\(model.selectedRelease?.platform.displayName ?? "OS") \(model.selectedRelease?.version ?? "selected image") (\(model.selectedRelease?.build ?? "unknown build"))\n\nThis will erase the target device and reinstall its operating system.")
        }
        .alert("DFUUtility", isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) { Button("OK") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
        .alert(updateResultTitle, isPresented: Binding(get: { model.updateCoordinator.pendingResult != nil }, set: { if !$0 { model.updateCoordinator.clearResult() } })) {
            if model.updateCoordinator.pendingResult?.outcome == .failure { Button("View Update Log") { NSWorkspace.shared.open(model.updateCoordinator.logURL) } }
            Button("OK") { model.updateCoordinator.clearResult() }
        } message: {
            if let result = model.updateCoordinator.pendingResult {
                if result.isSimulation { Text("The in-app update workflow completed successfully in simulation.") }
                else if result.outcome == .failure { Text("DFUUtility could not be updated. The previously installed application remains available.") }
                else if let old = result.oldVersion, let new = result.newVersion, old != new { Text("Updated successfully to \(new).") }
                else { Text("DFUUtility was updated successfully. Version remains \(result.newVersion ?? result.oldVersion ?? "unchanged").") }
            }
        }
    }

    private var checkButtonTitle: String { model.updateCoordinator.state == .checking ? "Checking…" : "Check for Updates…" }
    private var updateResultTitle: String {
        if model.updateCoordinator.pendingResult?.isSimulation == true { return "Update Test Completed" }
        return model.updateCoordinator.pendingResult?.outcome == .failure ? "Update Failed" : "DFUUtility Updated"
    }

    private var targetCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.deviceSessions.sessions.count > 1 {
                    Text("Multiple targets detected").font(.headline)
                    DeviceSessionListView(model: model, sessions: model.deviceSessions)
                    Text("Choose a row for its detailed workflow. Checkboxes select an explicit batch; newly connected devices are never added automatically.").font(.caption).foregroundStyle(.secondary)
                }
                else if model.targetDevices.isEmpty {
                    Text("No target device connected").font(.headline)
                    Text("Connect a supported Apple device using a data-capable cable.").foregroundStyle(.secondary)
                }
                else if let target = model.target {
                    if let name = target.friendlyName { Text(name).font(.title2.bold()) }
                    LabeledContent("State", value: model.targetWorkflowState.rawValue)
                    LabeledContent("Family", value: target.family.displayName)
                    if let product = target.restoreProductType { LabeledContent("Product", value: product) }
                    if let serial = target.serialNumber { LabeledContent("Serial number", value: serial) }
                    if let ecid = target.ecid { LabeledContent("ECID", value: ecid) }
                }
                if model.isDemoMode && !model.isScreenshotPresentation {
                    Picker("Demo target", selection: $demoTarget) { ForEach(["None", "Mac Normal", "Mac Recovery", "Mac DFU", "iPhone 6 Normal", "iPhone 6 Recovery"], id: \.self) { Text($0) } }
                        .onChange(of: demoTarget) { _, value in
                            if value.hasPrefix("iPhone 6 ") { model.setDemoMobileTarget(DeviceState(rawValue: String(value.dropFirst("iPhone 6 ".count)))) }
                            else if value.hasPrefix("Mac ") { model.setDemoTarget(DeviceState(rawValue: String(value.dropFirst("Mac ".count)))) }
                            else { model.setDemoTarget(nil) }
                        }
                }
                HStack {
                    if model.target?.family == .mac {
                        Button("Enter DFU") { Task { await model.enterDFU() } }.disabled(!model.canEnterDFU)
                    } else if let target = model.target, target.state == .normal || target.state == .recovery {
                        Button("Enter DFU…") { if model.prepareMobileDFUAssistant() { showMobileDFU = true } }.disabled(!model.canUseMobileDFUAssistant)
                    }
                    Button("Revive \(model.target?.family == .mac ? "Mac" : "Device")") { model.revive() }.disabled(!model.canRevive)
                    Button("Refresh") { Task { await model.refreshDiagnosticsAndTarget() } }.disabled(model.operationInProgress)
                }
                if !model.isDemoMode && model.privilegeMode == .signedHelper && !model.privilegedHelperState.isReady { helperSetup }
                switch model.targetDFUGuidance {
                case .macAdministratorAuthorization:
                    Text("Administrator authorization appears only when you click Enter DFU.").font(.caption).foregroundStyle(.secondary)
                case .guidedPhysicalButtons:
                    Text("DFU entry requires physical button input. DFUUtility will guide the sequence and detect the result.").font(.caption).foregroundStyle(.secondary)
                case .unsupportedMobileProduct:
                    Text("Guided DFU instructions are not yet available for this product type.").font(.caption).foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
                if model.macDFUMultiTargetUnavailable { Text("Automatic Mac Enter DFU is available only when exactly one target is connected because macvdmtool cannot select a specific Mac.").font(.caption).foregroundStyle(.orange) }
                if model.shouldShowMissingDFUHelperWarning { Text("The bundled DFU helper is unavailable. Rebuild the application or view Diagnostics.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label("Target Device", systemImage: model.target?.family == .mac ? "desktopcomputer" : "iphone") }
    }

    @ViewBuilder private var helperSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DFU Setup Required").font(.headline)
            Text("DFUUtility needs permission to install its privileged DFU helper. This helper is used only to place a connected Mac into DFU mode.").font(.caption).foregroundStyle(.secondary)
            Text(model.privilegedHelperState.description).font(.caption)
            HStack {
                Button(model.privilegedHelperState == .awaitingApproval ? "Check Again" : "Set Up DFU Helper") { Task { await model.setUpPrivilegedHelper() } }
                if model.privilegedHelperState == .awaitingApproval {
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
            }
        }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var restoreCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if model.isFirmwareLibraryMode {
                    Picker("Platform", selection: Binding(get: { model.browsePlatform }, set: { platform in Task { await model.selectBrowsePlatform(platform) } })) {
                        ForEach(RestorePlatform.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Browse, download, and validate firmware without connecting a target. Compatibility is checked again against any device selected later.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Selected image").font(.caption).foregroundStyle(.secondary)
                selectedImageSummary
                if case .loading = model.catalogueState { ProgressView("Checking Apple…").controlSize(.small) }
                if let error = model.catalogueErrorMessage { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
                imageStatus
                downloadControl
                HStack {
                    Button("Change Version…") { model.beginChoosingVersion(); showVersions = true }
                    Button("Choose Local IPSW…") { showImporter = true }
                    Button("Manage Downloads…") { showCacheManager = true }
                }
                if model.deviceSessions.sessions.count > 1 { BatchRestoreControls(model: model, sessions: model.deviceSessions, coordinator: model.batchCoordinator) }
                if !model.isFirmwareLibraryMode {
                    OperationProgressView(presentation: OperationProgressPresentation(state: model.restoreState, macOSVersion: model.selectedRelease?.version, platform: model.targetRestorePlatform), target: model.target)
                    Button("Restore \(model.target?.family.displayName ?? "Device")", role: .destructive) { confirmRestore = true }.disabled(!model.canRestore)
                    Text("Restore erases the target device.").font(.caption.bold()).foregroundStyle(.secondary)
                    if model.canRevive { Text("Revive attempts repair without erasing recoverable user data, but is not a backup or guarantee.").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    if let log = model.lastLogURL { Button("View Log") { NSWorkspace.shared.open(log) } }
                    Button("Reveal Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility")]) }
                }
                if !model.isFirmwareLibraryMode && !model.canRestore { Text(model.restoreUnavailableMessage).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label(model.restoreSectionTitle, systemImage: "arrow.down.circle") }
    }

    @ViewBuilder private var selectedImageSummary: some View {
        switch model.selectedImagePresentation {
        case .unavailable:
            Text("No restore image selected").font(.title3.bold())
        case .managed(let release, _):
            Text("\(release.platform.displayName) \(release.version)").font(.title2.bold())
            LabeledContent("Build", value: release.build)
            LabeledContent("Size", value: formatBytes(model.selectedImageDisplaySize))
        case .local(let url, _, _):
            Text("Local IPSW").font(.title2.bold())
            Text(url.lastPathComponent).font(.headline)
            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @ViewBuilder private var imageStatus: some View {
        switch model.imageState {
        case .none: Text("Image status: Not downloaded").foregroundStyle(.secondary)
        case .partial(let bytes): Label("Partial download available (\(formatBytes(bytes)))", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .validating: ProgressView("Validating image…")
        case .ready: Label(model.selectedRelease == nil ? "Local image valid" : "Downloaded and validated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var downloadControl: some View {
        switch model.downloadPresentationState {
        case .preparing(let value), .downloading(let value):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(value.release.platform.displayName) \(value.release.version)").font(.headline)
                    if let fraction = value.fraction { ProgressView(value: fraction) } else { ProgressView() }
                    HStack {
                        Text("\(formatBytes(value.completed)) / \(formatBytes(value.total))").font(.caption.monospacedDigit())
                        Spacer()
                        if let fraction = value.fraction { Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()) }
                        if let speed = value.bytesPerSecond { Text("\(formatBytes(Int64(speed)))/s").font(.caption.monospacedDigit()) }
                    }
                    Button("Cancel", role: .cancel) { model.cancelDownload() }
                }
        case .validating: ProgressView("Validating image…")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            if model.selectedRelease != nil, model.imageURL == nil { Button(model.imageState.isPartial ? "Resume Download" : "Download Image") { model.beginDownload() } }
        }
    }

    private func formatBytes(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown" }
}

private extension ImageState { var isPartial: Bool { if case .partial = self { true } else { false } } }

struct VersionPicker: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose \(model.selectedRelease?.platform.displayName ?? model.imageChoices.first?.release.platform.displayName ?? "OS") Version").font(.title2.bold())
                Spacer()
                Button { Task { await model.refreshCatalogue(); model.beginChoosingVersion() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.catalogueState == .loading)
            }
            if case .loading = model.catalogueState { ProgressView("Checking Apple…") }
            if model.imageChoices.isEmpty, model.catalogueState != .loading { ContentUnavailableView("No Apple restore images are currently available", systemImage: "externaldrive.badge.questionmark") }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.imageChoices) { choice in
                        Button { model.choosePendingRelease(choice.release) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: model.pendingRelease?.build == choice.release.build ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text("\(choice.release.platform.displayName) \(choice.release.version)").font(.headline); if choice.isRecommended { Text("Latest available").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()) } }
                                    Text("Build \(choice.release.build) · \(model.displaySize(for: choice.release).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size")").foregroundStyle(.secondary)
                                    HStack { cacheLabel(choice.cacheState); Text("· \(choice.compatibility.label)").foregroundStyle(.secondary) }.font(.caption)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if let error = model.catalogueErrorMessage { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelChoosingVersion(); isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Use Version") { model.confirmPendingRelease(); isPresented = false }.keyboardShortcut(.defaultAction).disabled(model.pendingRelease == nil)
            }
        }.padding().frame(minWidth: 590, minHeight: 430).onAppear { model.beginChoosingVersion() }
    }

    @ViewBuilder private func cacheLabel(_ state: IPSWChoiceCacheState) -> some View {
        switch state {
        case .downloaded: Label("Downloaded and validated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial(let bytes): Label("Partial · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .downloadRequired: Text("Download required")
        case .invalid: Label("Invalid cached image", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .validating: ProgressView().controlSize(.mini)
        }
    }
}

private struct DeviceSessionListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sessions: DeviceSessionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sessions.sessions) { session in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { session.isSelected }, set: { model.setSessionSelected(session.id, selected: $0) }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(!session.hasSafeBatchIdentity)
                    Image(systemName: icon(for: session.device.family)).frame(width: 20)
                    Button { model.selectSessionForDetail(session.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.device.friendlyName ?? session.device.family.displayName).font(.headline)
                            Text("\(session.device.restoreProductType ?? "Unknown product") · \(session.device.state.rawValue) · \(session.shortIdentity)").font(.caption).foregroundStyle(.secondary)
                            Text(status(session)).font(.caption).foregroundStyle(session.canRestore ? .green : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    if case .running(_, let fraction) = session.operationState {
                        if let fraction { ProgressView(value: fraction).frame(width: 90) } else { ProgressView().controlSize(.small) }
                    }
                    if let log = session.operationLogURL { Button("Log") { NSWorkspace.shared.open(log) }.controlSize(.small) }
                }
                .padding(8).background(model.selectedTargetECID?.caseInsensitiveCompare(session.ecid ?? "") == .orderedSame ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Select All Ready") { model.selectAllRestoreEligibleSessions() }
                Button("Clear Selection") { model.clearSessionSelection() }
                Spacer()
                Text("\(sessions.selectedSessions.count) selected").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func icon(for family: AppleDeviceFamily) -> String { family == .mac ? "desktopcomputer" : family == .iPad ? "ipad" : "iphone" }
    private func status(_ session: DeviceSession) -> String {
        switch session.operationState {
        case .idle: return session.canRestore ? "Ready to restore" : (session.restoreEligibilityFailure ?? "Not ready")
        case .queued(let position, let total): return "Queued — device \(position) of \(total)"
        case .running(let stage, let fraction): return fraction.map { "\(stage) — \(Int($0 * 100))%" } ?? stage
        case .reconnecting: return "Waiting for restart…"
        case .completed(let result): return "✓ \(result)"
        case .failed(let result): return "✗ \(result)"
        case .cancelled: return "Not started — batch stopped"
        }
    }
}

private struct BatchRestoreControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sessions: DeviceSessionManager
    @ObservedObject var coordinator: BatchCoordinator
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Sequential Batch").font(.headline)
            HStack(spacing: 8) {
                Button("Use Latest Compatible Firmware") { Task { await model.useLatestCompatibleFirmwareForSelectedSessions() } }
                Button("Use Current Firmware for Selected") { model.applyCurrentFirmwareToSelectedSessions() }
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 8) {
                Button("Restore \(sessions.selectedSessions.count) Devices", role: .destructive) { confirming = true }
                    .disabled(!coordinator.canStartRestore || model.isDemoMode)
                Button("Revive Selected") { model.startBatch(.revive) }.disabled(!coordinator.canStart(.revive) || model.isDemoMode)
                Button("Restart Selected") { model.startBatch(.restart) }.disabled(!coordinator.canStart(.restart) || model.isDemoMode)
                if coordinator.isRunning { Button("Stop After Current Device") { model.stopBatchAfterCurrentTarget() } }
            }
            .fixedSize(horizontal: true, vertical: false)
            if !coordinator.selectedEligibilityFailures(for: .restore).isEmpty {
                Text("Every selected device must be ready. \(coordinator.selectedEligibilityFailures(for: .restore).count) selected device(s) are blocked for Restore.").font(.caption).foregroundStyle(.orange)
            }
            if coordinator.isRunning, let index = coordinator.currentIndex {
                Text("Device \(index + 1) of \(coordinator.frozenTargetIDs.count)")
                ProgressView(value: coordinator.overallFraction)
                Text("Overall indicator combines completed-device count with current stage-local progress; it is not byte-linear.").font(.caption).foregroundStyle(.secondary)
            }
            if let summary = coordinator.summary {
                Text("Batch complete — Succeeded: \(summary.succeeded), Failed: \(summary.failed), Not started: \(summary.cancelled)").font(.headline)
            }
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Restore \(sessions.selectedSessions.count) devices?").font(.title2.bold())
                Text("This will erase the following targets. Operations run sequentially and remain individually ECID-targeted.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sessions.selectedSessions) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(session.device.friendlyName ?? session.device.family.displayName) (\(session.device.restoreProductType ?? "Unknown")) — \(session.shortIdentity)").font(.headline)
                                Text("Firmware: \(session.selectedRelease.map { "\($0.platform.displayName) \($0.version) (\($0.build))" } ?? session.selectedImageURL?.lastPathComponent ?? "Not selected")").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("Cancel") { confirming = false }; Button("Restore Sequentially", role: .destructive) { confirming = false; model.startBatchRestore() }.keyboardShortcut(.defaultAction) }
            }.padding().frame(minWidth: 560, minHeight: 380)
        }
    }
}
