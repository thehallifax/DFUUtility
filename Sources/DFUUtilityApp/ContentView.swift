import DFUAppSupport
import DFUCore
import SwiftUI
import UniformTypeIdentifiers
import AppKit

private enum SidebarDestination: Hashable {
    case device(DeviceSessionID)
    case restoreRevive
    case firmware
    case deviceCapture
    case diagnostics
    case about
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showVersions = false
    @State private var showImporter = false
    @State private var showMobileDFU = false
    @State private var showCacheManager = false
    @State private var firmwareChooserSessionID: DeviceSessionID?
    @State private var demoTarget = "None"
    @State private var destination: SidebarDestination? = .restoreRevive
    @State private var confirmingSingleRestore = false

    init(model: AppModel) {
        self.model = model
        _showVersions = State(initialValue: CommandLine.arguments.contains("--show-version-chooser"))
    }

    var body: some View {
        navigationRoot
        .frame(minWidth: 920, minHeight: 620)
        .task {
            await model.load()
            if destination == .restoreRevive, model.deviceSessions.sessions.filter(\.isConnected).count == 1,
               let session = model.deviceSessions.sessions.first(where: \.isConnected) {
                model.selectSessionForDetail(session.id)
                destination = .device(session.id)
            }
        }
        .onAppear { model.startBenchDiscovery() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.startBenchDiscovery() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.stopBenchDiscovery() }
        .onDisappear { model.stopBenchDiscovery(); model.cancelMacDFUVerification() }
        .sheet(isPresented: $showVersions, onDismiss: { firmwareChooserSessionID = nil }) {
            VersionPicker(model: model, isPresented: $showVersions, targetSessionID: firmwareChooserSessionID)
        }
        .sheet(isPresented: $showCacheManager) { CacheManagerView(model: model, isPresented: $showCacheManager) }
        .sheet(isPresented: $model.isUpdatePresentationRequested) { UpdateView(model: model) }
        .sheet(isPresented: $showMobileDFU, onDismiss: { model.dismissMobileDFUAssistant() }) {
            if let assistant = model.mobileDFUAssistant { MobileDFUAssistantView(model: assistant, isPresented: $showMobileDFU) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; await model.validateManualIPSW(url) } }
        }
        .alert(model.presentedErrorTitle, isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) { Button("OK") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
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
        .onChange(of: model.deviceSessions.sessions) { _, sessions in
            guard case .device(let id) = destination else { return }
            guard sessions.contains(where: { $0.id == id && $0.isConnected }) else { destination = .restoreRevive; return }
        }
    }

    @ViewBuilder private var navigationRoot: some View {
        if model.isScreenshotPresentation {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("DFUUtility").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
                    Divider()
                    screenshotSidebar
                }
                .frame(width: MainWindowConfiguration.standard.sidebarIdealWidth)
                Divider()
                workspace.frame(maxWidth: .infinity)
            }
        } else {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(
                        min: MainWindowConfiguration.standard.sidebarMinimumWidth,
                        ideal: MainWindowConfiguration.standard.sidebarIdealWidth,
                        max: MainWindowConfiguration.standard.sidebarMaximumWidth
                    )
            } detail: {
                workspace
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Section("Devices") {
                let connected = model.deviceSessions.sessions.filter(\.isConnected)
                if connected.isEmpty {
                    Label("No connected devices", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connected) { session in
                        Button {
                            model.selectSessionForDetail(session.id)
                            destination = .device(session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.device.friendlyName ?? session.device.family.displayName).lineLimit(1)
                                Text([session.device.restoreProductType, session.device.state.rawValue].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .tag(SidebarDestination.device(session.id))
                    }
                }
            }
            Section("Workflows") {
                Label("Restore & Revive", systemImage: "arrow.down.circle").tag(SidebarDestination.restoreRevive)
                Label("Device Capture", systemImage: "doc.text.viewfinder").tag(SidebarDestination.deviceCapture)
            }
            Section("Library") {
                Label("Firmware", systemImage: "shippingbox").tag(SidebarDestination.firmware)
            }
            Section("Utility") {
                Label("Diagnostics", systemImage: "stethoscope").tag(SidebarDestination.diagnostics)
            }
            Section {
                Button(checkButtonTitle) { model.requestManualUpdateCheck() }
                    .disabled(model.isDemoMode || model.isScreenshotPresentation || model.updateCoordinator.state == .checking)
                Label("About", systemImage: "info.circle").tag(SidebarDestination.about)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DFUUtility")
        .safeAreaInset(edge: .bottom) {
            if model.isDemoMode || model.isUpdateTestMode {
                Text(model.isDemoMode ? "DEMO MODE — NO HARDWARE ACTIONS" : "UPDATE TEST — SIMULATION ONLY")
                    .font(.caption.bold()).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity)
            }
        }
    }

    /// The screenshot harness does not host a native window, so AppKit's
    /// sidebar List has no table backing to render. Keep the acceptance image
    /// deterministic while preserving the real NavigationSplitView above.
    private var screenshotSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sidebarSectionTitle("Devices")
                let connected = model.deviceSessions.sessions.filter(\.isConnected)
                if connected.isEmpty {
                    Label("No connected devices", systemImage: "externaldrive.badge.questionmark").foregroundStyle(.secondary)
                } else {
                    ForEach(connected) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.device.friendlyName ?? session.device.family.displayName).lineLimit(1)
                            Text([session.device.restoreProductType, session.device.state.rawValue].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                    }
                }
                sidebarSectionTitle("Workflows")
                Label("Restore & Revive", systemImage: "arrow.down.circle")
                Label("Device Capture", systemImage: "doc.text.viewfinder").foregroundStyle(.secondary)
                sidebarSectionTitle("Library")
                Label("Firmware", systemImage: "shippingbox")
                sidebarSectionTitle("Utility")
                Label("Diagnostics", systemImage: "stethoscope")
                Divider()
                Label("Check for Updates…", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
                Label("About", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(16)
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
    }

    @ViewBuilder private var workspace: some View {
        switch destination {
        case .device(let id): deviceWorkspace(id: id)
        case .restoreRevive, nil: batchWorkspace
        case .firmware: firmwareWorkspace
        case .deviceCapture: captureWorkspace
        case .diagnostics: diagnosticsWorkspace
        case .about: AboutView().padding()
        }
    }

    private func workspaceScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: MainWindowConfiguration.standard.maximumWorkspaceWidth, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .center) }
    }

    private var batchWorkspace: some View {
        workspaceScroll {
            VStack(alignment: .leading, spacing: 20) {
                Text("Restore & Revive").font(.largeTitle.bold())
                Text("Select devices for a sequential operation. Device details and firmware choices are managed from each device workspace.")
                    .foregroundStyle(.secondary)
                GroupBox("Connected Devices") {
                    if model.showsSessionPresentation {
                        DeviceSessionListView(model: model, sessions: model.deviceSessions).padding(8)
                    } else if model.targetDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No target device connected").font(.headline)
                            Text("Connect a supported Apple device using a data-capable cable.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    } else {
                        Text("Refresh to load connected devices.").foregroundStyle(.secondary).padding(8)
                    }
                }
                if model.cfgutilSetupRequired {
                    GroupBox("Apple Configurator tooling") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Install Apple Configurator from the Mac App Store to enable device discovery, Restore, and Revive. Then return to DFUUtility and refresh.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Apple Configurator in the App Store") {
                                NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/apple-configurator/id1037126344")!)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if model.showsSessionPresentation { BatchRestoreControls(model: model, sessions: model.deviceSessions, coordinator: model.batchCoordinator) }
            }
        }
    }

    private var firmwareWorkspace: some View {
        workspaceScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text("Firmware Library").font(.largeTitle.bold())
                Text("Browse, download, validate, and manage restore images independently of connected devices.").foregroundStyle(.secondary)
                firmwareLibraryContent(includeBatch: false)
            }
        }
    }

    private var diagnosticsWorkspace: some View {
        workspaceScroll { DiagnosticsView(report: model.doctorReport, shareableText: model.shareableDiagnosticsText, privilegeMode: model.privilegeMode, helperState: model.privilegedHelperState, registrationErrorDetails: model.helperRegistrationErrorDetails).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private var captureWorkspace: some View {
        workspaceScroll {
            GroupBox("Device Capture") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Read-only technician asset capture is planned for a future release.", systemImage: "doc.text.viewfinder").font(.headline)
                    Text("This workspace will capture device details for technician records without changing the target. CSV export, QR generation, and persistent capture sessions are not part of this pass.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    @ViewBuilder private func deviceWorkspace(id: DeviceSessionID) -> some View {
        workspaceScroll {
            if let session = model.deviceSessions.sessions.first(where: { $0.id == id }), session.isConnected {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.device.friendlyName ?? session.device.family.displayName).font(.largeTitle.bold())
                        Text([session.device.family.displayName, session.device.restoreProductType, model.targetWorkflowState.rawValue].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            deviceInformationCard(session)
                            firmwareCard(session)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            deviceInformationCard(session)
                            firmwareCard(session)
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Device Actions").font(.headline)
                            HStack {
                                if session.device.family == .mac && session.device.state == .normal {
                                    Button("Enter DFU") { Task { await model.enterDFU() } }.disabled(!model.canEnterDFU)
                                } else if (session.device.family == .iPhone || session.device.family == .iPad) && (session.device.state == .normal || session.device.state == .recovery) {
                                    Button("Enter DFU…") { if model.prepareMobileDFUAssistant() { showMobileDFU = true } }.disabled(!model.canUseMobileDFUAssistant)
                                }
                                Button("Restore", role: .destructive) { confirmingSingleRestore = true }.disabled(!model.canRestore)
                                Button("Revive") { model.revive() }.disabled(!model.canRevive)
                                Button("Restart") { model.restart() }.disabled(!model.canRestart)
                            }
                            if !model.canRestore { Text(model.restoreUnavailableMessage).font(.caption).foregroundStyle(.secondary) }
                            if !model.canRevive && session.device.state != .normal { Text("Revive is unavailable in the current device state.").font(.caption).foregroundStyle(.secondary) }
                            if !model.canRestart { Text(model.restartUnavailableMessage).font(.caption).foregroundStyle(.secondary) }
                            if model.macDFUInProgress { Text(AppModel.accessoryDFUGuidance).font(.callout) }
                            OperationProgressView(presentation: OperationProgressPresentation(state: model.restoreState, macOSVersion: session.selectedRelease?.version, platform: session.device.family.restorePlatform), target: session.device)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                .confirmationDialog("Restore \(session.device.friendlyName ?? session.device.family.displayName)?", isPresented: $confirmingSingleRestore) {
                    Button("Restore", role: .destructive) { model.restoreConfirmed() }
                } message: { Text("This erases the selected device and uses its validated firmware.") }
            } else {
                ContentUnavailableView("Device disconnected", systemImage: "externaldrive.badge.xmark")
            }
        }
    }

    private func deviceInformationCard(_ session: DeviceSession) -> some View {
        GroupBox("Device Information") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Family", value: session.device.family.displayName)
                if let product = session.device.restoreProductType { LabeledContent("Product", value: product) }
                if let ecid = session.device.ecid { LabeledContent("ECID", value: ecid) }
                if let serial = session.device.serialNumber { LabeledContent("Serial number", value: serial) }
                if let udid = session.device.identifier { LabeledContent("UDID", value: udid) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firmwareCard(_ session: DeviceSession) -> some View {
        GroupBox {
            firmwareForDevice(session).padding(8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateResultTitle: String {
        if model.updateCoordinator.pendingResult?.isSimulation == true { return "Update Test Completed" }
        return model.updateCoordinator.pendingResult?.outcome == .failure ? "Update Failed" : "DFUUtility Updated"
    }
    private var checkButtonTitle: String { model.updateCoordinator.state == .checking ? "Checking…" : "Check for Updates…" }

    private var targetCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.showsSessionPresentation {
                    Text(model.deviceSessions.sessions.count == 1 ? "Connected target" : "Connected targets").font(.headline)
                    DeviceSessionListView(model: model, sessions: model.deviceSessions)
                    Text(model.deviceSessions.sessions.count == 1
                        ? "Choose the row for its detailed workflow. The checkbox controls whether it participates in a device operation."
                        : "Choose a row for its detailed workflow. Checkboxes select an explicit batch; newly connected devices are never added automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                else if model.targetDevices.isEmpty {
                    Text("No target device connected").font(.headline)
                    Text("Connect a supported Apple device using a data-capable cable.").foregroundStyle(.secondary)
                }
                if model.cfgutilSetupRequired {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Apple Configurator tooling is required", systemImage: "wrench.and.screwdriver")
                            .font(.headline)
                        Text("Install Apple Configurator from the Mac App Store to enable device discovery, Restore, and Revive. Then return to DFUUtility and click Refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Apple Configurator in the App Store") {
                            NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/apple-configurator/id1037126344")!)
                        }
                    }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                else if let target = model.target {
                    if let name = target.friendlyName { Text(name).font(.title2.bold()) }
                    LabeledContent("State", value: model.targetWorkflowState.rawValue)
                    LabeledContent("Family", value: target.family.displayName)
                    if let product = target.restoreProductType { LabeledContent("Product", value: product) }
                    if let serial = target.serialNumber { LabeledContent("Serial number", value: serial) }
                    if let ecid = target.ecid { LabeledContent("ECID", value: ecid) }
                    if let session = model.detailedSession {
                        Divider()
                        firmwareForDevice(session)
                    }
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

    @ViewBuilder private func firmwareForDevice(_ session: DeviceSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Firmware for this device", systemImage: "shippingbox").font(.headline)
            if let release = session.selectedRelease {
                Text("\(release.platform.displayName) \(release.version)").font(.title3.bold())
                LabeledContent("Build", value: release.build)
                Label(session.firmwareState == .validated ? "Downloaded and validated" : "Selected; download and validation required", systemImage: session.firmwareState == .validated ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(session.firmwareState == .validated ? .green : .secondary)
            } else if let url = session.selectedImageURL {
                Text("Local IPSW").font(.title3.bold())
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No firmware chosen").foregroundStyle(.secondary)
            }
            Button(session.selectedRelease == nil && session.selectedImageURL == nil ? "Choose Firmware…" : "Choose Different Firmware…") {
                Task {
                    await model.prepareFirmwareChooser(for: session.id)
                    firmwareChooserSessionID = session.id
                    showVersions = true
                }
            }
            .help("Choose compatible firmware specifically for this device.")
        }
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
        firmwareLibraryContent(includeBatch: true)
    }

    @ViewBuilder private func firmwareLibraryContent(includeBatch: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Platform", selection: Binding(get: { model.browsePlatform }, set: { platform in Task { await model.selectBrowsePlatform(platform) } })) {
                    ForEach(RestorePlatform.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Browse, download, and validate firmware independently of connected devices. A device’s firmware changes only when you choose it specifically.").font(.caption).foregroundStyle(.secondary)
                Text("Selected image").font(.caption).foregroundStyle(.secondary)
                selectedImageSummary
                if case .loading = model.catalogueState { ProgressView("Checking Apple…").controlSize(.small) }
                if let error = model.catalogueErrorMessage { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
                imageStatus
                downloadControl
                ViewThatFits(in: .horizontal) {
                    HStack { firmwareLibraryActions }
                    VStack(alignment: .leading, spacing: 6) { firmwareLibraryActions }
                }
                if includeBatch && model.showsSessionPresentation { BatchRestoreControls(model: model, sessions: model.deviceSessions, coordinator: model.batchCoordinator) }
                if includeBatch && (model.target != nil || model.macDFUInProgress) {
                    if model.macDFUInProgress { Text(AppModel.accessoryDFUGuidance).font(.callout) }
                    OperationProgressView(presentation: OperationProgressPresentation(state: model.restoreState, macOSVersion: model.detailedSession?.selectedRelease?.version, platform: model.targetRestorePlatform), target: model.target)
                    Text("Restore erases the target device.").font(.caption.bold()).foregroundStyle(.secondary)
                    if model.canRevive { Text("Revive attempts repair without erasing recoverable user data, but is not a backup or guarantee.").font(.caption).foregroundStyle(.secondary) }
                }
                if includeBatch {
                    HStack {
                    if let log = model.lastLogURL { Button("View Log") { NSWorkspace.shared.open(log) } }
                    Button("Reveal Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility")]) }
                    }
                    if model.target != nil && !model.canRestore { Text(model.restoreUnavailableMessage).font(.caption).foregroundStyle(.secondary) }
                }
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
            if let products = release.conciseSupportedProducts {
                LabeledContent("Compatible products", value: products).help(release.supportedDevices.sorted().joined(separator: ", "))
            }
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
                    if let fraction = value.fraction {
                        ProgressView(value: fraction).accessibilityLabel("Firmware download progress").accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    } else { ProgressView().accessibilityLabel("Preparing firmware download") }
                    HStack {
                        Text("\(formatBytes(value.completed)) / \(formatBytes(value.total))").font(.caption.monospacedDigit())
                        Spacer()
                        if let fraction = value.fraction { Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()) }
                        if let speed = value.bytesPerSecond { Text("\(formatBytes(Int64(speed)))/s").font(.caption.monospacedDigit()) }
                    }
                    Button("Cancel", role: .cancel) { model.cancelDownload() }
                }
        case .validating: ProgressView("Validating image…").accessibilityLabel("Validating firmware")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default:
            if model.selectedRelease != nil, model.imageURL == nil { Button(model.imageState.isPartial ? "Resume Download" : "Download Image") { model.beginDownload() } }
        }
    }

    private func formatBytes(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown" }

    @ViewBuilder private var firmwareLibraryActions: some View {
        Button("Change Version…") { firmwareChooserSessionID = nil; model.beginChoosingVersion(); showVersions = true }
        Button("Choose Local IPSW…") { showImporter = true }
        Button("Manage Downloads…") { showCacheManager = true }
    }
}

private extension ImageState { var isPartial: Bool { if case .partial = self { true } else { false } } }

struct VersionPicker: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    let targetSessionID: DeviceSessionID?
    init(model: AppModel, isPresented: Binding<Bool>, targetSessionID: DeviceSessionID? = nil) {
        self.model = model
        _isPresented = isPresented
        self.targetSessionID = targetSessionID
    }
    private var choices: [IPSWChoice] { targetSessionID.map(model.firmwareChoices(for:)) ?? model.imageChoices }
    private var canConfirm: Bool {
        guard let pending = model.pendingRelease else { return false }
        return choices.contains { FirmwareReleaseKey($0.release) == FirmwareReleaseKey(pending) }
    }
    private var title: String {
        if let targetSessionID, let session = model.deviceSessions.sessions.first(where: { $0.id == targetSessionID }) {
            return "Choose Firmware for \(session.device.friendlyName ?? session.device.family.displayName)"
        }
        return "Choose \(model.selectedRelease?.platform.displayName ?? model.imageChoices.first?.release.platform.displayName ?? "OS") Version"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button {
                    Task {
                        await model.refreshCatalogue()
                        if let targetSessionID { model.beginChoosingFirmware(for: targetSessionID) }
                        else { model.beginChoosingVersion() }
                    }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.catalogueState == .loading)
            }
            if case .loading = model.catalogueState { ProgressView("Checking Apple…") }
            if choices.isEmpty, model.catalogueState != .loading { ContentUnavailableView("No compatible Apple restore images are currently available", systemImage: "externaldrive.badge.questionmark") }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(choices) { choice in
                        Button { model.choosePendingRelease(choice.release) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: model.pendingRelease.map(FirmwareReleaseKey.init) == FirmwareReleaseKey(choice.release) ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text("\(choice.release.platform.displayName) \(choice.release.version)").font(.headline); if choice.isRecommended { Text("Latest available").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()) } }
                                    Text("Build \(choice.release.build) · \(model.displaySize(for: choice.release).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size")").foregroundStyle(.secondary)
                                    if let products = choice.release.conciseSupportedProducts {
                                        Text("Compatible products: \(products)").font(.caption).foregroundStyle(.secondary).help(choice.release.supportedDevices.sorted().joined(separator: ", "))
                                    }
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
                Button("Use Version") {
                    if let targetSessionID { model.confirmPendingRelease(for: targetSessionID) }
                    else { model.confirmPendingRelease() }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }.padding().frame(minWidth: 590, minHeight: 430).onAppear {
            if let targetSessionID { model.beginChoosingFirmware(for: targetSessionID) }
            else { model.beginChoosingVersion() }
        }
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
        let summary = SessionWorkspaceSummary(sessions: sessions.sessions)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(summary.connected) Connected · \(summary.restoreReady) Restore Ready · \(summary.selected) Selected")
                .font(.subheadline.weight(.medium)).accessibilityLabel("\(summary.connected) connected, \(summary.restoreReady) restore ready, \(summary.selected) selected")
            ForEach(sessions.sessions) { session in
                let presentation = DeviceSessionPresentation(session: session, activeBatchIDs: model.batchCoordinator.frozenTargetIDs, currentBatchID: model.batchCoordinator.currentTargetID, batchIsRunning: model.batchCoordinator.isRunning)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { session.isSelected }, set: { model.setSessionSelected(session.id, selected: $0) }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(!session.hasSafeBatchIdentity)
                        .accessibilityLabel("Select \(session.device.friendlyName ?? session.device.family.displayName) for batch operations")
                        .accessibilityHint(session.hasSafeBatchIdentity ? "Adds or removes this device from the explicit batch selection." : "Unavailable because this device does not have a stable ECID.")
                    Image(systemName: icon(for: session.device.family)).frame(width: 20)
                    Button { model.selectSessionForDetail(session.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.device.family.displayName) · \(session.device.friendlyName ?? session.device.restoreProductType ?? "Unknown product")").font(.headline)
                            Text([session.device.restoreProductType, session.device.state.rawValue].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            if let firmware = presentation.firmware {
                                Text([firmware, presentation.firmwareReadiness].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(presentation.firmwareReadiness == "Validated" ? .green : .secondary)
                            }
                            if let identity = presentation.identity { Text(identity).font(.caption2).foregroundStyle(.tertiary) }
                            Text([presentation.capability, membershipText(presentation.batchMembership)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(session.canRestore ? .green : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    if case .running(_, let fraction) = session.operationState {
                        if let fraction { ProgressView(value: fraction).frame(width: 90).accessibilityLabel("\(session.device.friendlyName ?? "Device") operation progress").accessibilityValue("\(Int(fraction * 100)) percent") } else { ProgressView().controlSize(.small).accessibilityLabel("\(session.device.friendlyName ?? "Device") operation in progress") }
                    }
                    if let log = session.operationLogURL { Button("Log") { NSWorkspace.shared.open(log) }.controlSize(.small) }
                }
                .padding(8).background(model.selectedTargetECID?.caseInsensitiveCompare(session.ecid ?? "") == .orderedSame ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Select All Restore-Ready") { model.selectAllRestoreEligibleSessions() }
                Button("Select Failed") { model.selectFailedSessions() }
                    .disabled(!sessions.hasFailedCandidate(for: model.batchCoordinator.operationKind) || model.batchCoordinator.isRunning)
                Button("Select Not Started") { model.selectNotStartedSessions() }
                    .disabled(!sessions.hasNotStartedCandidate(for: model.batchCoordinator.operationKind) || model.batchCoordinator.isRunning)
                Button("Clear Selection") { model.clearSessionSelection() }
                Spacer()
            }
        }
    }
    private func icon(for family: AppleDeviceFamily) -> String { family == .mac ? "desktopcomputer" : family == .iPad ? "ipad" : "iphone" }
    private func membershipText(_ state: BatchMembershipPresentation) -> String? {
        switch state {
        case .none: nil
        case .active: "Active"
        case .queued: "Queued in current batch"
        case .currentBatch: "Current batch device"
        case .notInCurrentBatch: "Not in current batch"
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
            Text("The selected device set and chosen firmware are frozen when a batch starts. Operations run sequentially and each device is explicitly targeted.").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { firmwareButtons }
                VStack(alignment: .leading, spacing: 8) { firmwareButtons }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { operationButtons }
            }
            if !coordinator.selectedEligibilityFailures(for: .restore).isEmpty {
                Text("Every selected device must be ready. \(coordinator.selectedEligibilityFailures(for: .restore).count) selected device(s) are blocked for Restore.").font(.caption).foregroundStyle(.orange)
            }
            if coordinator.isRunning, let index = coordinator.currentIndex {
                Text("Device \(index + 1) of \(coordinator.frozenTargetIDs.count)")
                ProgressView(value: coordinator.overallFraction).accessibilityLabel("Sequential batch progress").accessibilityValue("Device \(index + 1) of \(coordinator.frozenTargetIDs.count)")
                Text("Overall indicator combines completed-device count with current stage-local progress; it is not byte-linear.").font(.caption).foregroundStyle(.secondary)
            }
            if let summary = coordinator.summary {
                Text("Previous batch complete — Succeeded: \(summary.succeeded), Failed: \(summary.failed), Not started: \(summary.cancelled)").font(.headline)
            }
        }
        .sheet(isPresented: $confirming) {
            let preflight = RestorePreflightPresentation(sessions: sessions.sessions)
            VStack(alignment: .leading, spacing: 14) {
                Text("Restore \(sessions.selectedSessions.count) \(sessions.selectedSessions.count == 1 ? "device" : "devices")?").font(.title2.bold())
                Text("\(preflight.selected) selected of \(preflight.connected) connected. \(preflight.excluded) connected \(preflight.excluded == 1 ? "device is" : "devices are") not included.").font(.headline)
                Text("The selected devices will be erased and restored sequentially. Operations remain individually ECID-targeted.").foregroundStyle(.secondary)
                if preflight.hasMixedFamilies { Label("Selected devices include multiple device families.", systemImage: "square.stack.3d.up.fill").foregroundStyle(.orange) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sessions.selectedSessions) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(session.device.friendlyName ?? session.device.family.displayName) (\(session.device.restoreProductType ?? "Unknown")) — \(session.shortIdentity)").font(.headline)
                                Text("Firmware: \(session.selectedRelease.map { "\($0.platform.displayName) \($0.version) (\($0.build))" } ?? session.selectedImageURL?.lastPathComponent ?? "Not selected")").font(.caption).foregroundStyle(.secondary)
                                Label(session.firmwareState == .validated ? "Validated firmware" : "Firmware not validated", systemImage: session.firmwareState == .validated ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(session.firmwareState == .validated ? .green : .orange)
                            }
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction); Button("Restore Sequentially", role: .destructive) { confirming = false; model.startBatchRestore() }.keyboardShortcut(.defaultAction).accessibilityHint("Erases the selected devices one at a time in the displayed batch.") }
            }.padding().frame(minWidth: 560, minHeight: 380)
        }
    }

    @ViewBuilder private var firmwareButtons: some View {
        Button("Use Latest Compatible Firmware") { Task { await model.useLatestCompatibleFirmwareForSelectedSessions() } }
        Button("Use Library Firmware for Selected") { model.applyCurrentFirmwareToSelectedSessions() }
            .disabled(!model.canApplyCurrentLibraryFirmwareToSelectedSessions)
    }
    @ViewBuilder private var operationButtons: some View {
        Button("Restore \(sessions.selectedSessions.count) \(sessions.selectedSessions.count == 1 ? "Device" : "Devices")", role: .destructive) { confirming = true }
            .disabled(!coordinator.canStartRestore || model.isDemoMode).accessibilityHint("Opens confirmation for a sequential destructive Restore batch.")
        Button("Revive Selected") { model.startBatch(.revive) }.disabled(!coordinator.canStart(.revive) || model.isDemoMode)
        Button("Restart Selected") { model.startBatch(.restart) }.disabled(!coordinator.canStart(.restart) || model.isDemoMode)
        if coordinator.isRunning { Button("Stop After Current Device") { model.stopBatchAfterCurrentTarget() }.accessibilityHint("Allows the active device to finish and cancels queued devices.") }
    }
}
