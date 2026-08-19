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
    @State private var demoTarget = "None"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("DFUUtility").font(.largeTitle.bold())
                Spacer()
                if model.isDemoMode { Text("DEMO MODE — NO HARDWARE ACTIONS").font(.caption.bold()).foregroundStyle(.orange).padding(7).background(.orange.opacity(0.12), in: Capsule()) }
                Button("Diagnostics…") { showDiagnostics = true }
                Button("About…") { showAbout = true }
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; await model.validateManualIPSW(url) } }
        }
        .alert("Restore this Mac?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { model.restoreConfirmed() }
        } message: {
            Text("\(model.target?.friendlyName ?? "Target Mac")\n\(model.target?.model ?? "Unknown model")\nECID: \(model.target?.ecid ?? "Unknown")\nmacOS \(model.selectedRelease?.version ?? "selected image") (\(model.selectedRelease?.build ?? "unknown build"))\n\nThis will erase the target Mac and reinstall macOS.")
        }
        .alert("DFUUtility", isPresented: Binding(get: { model.presentedError != nil }, set: { if !$0 { model.presentedError = nil } })) { Button("OK") { model.presentedError = nil } } message: { Text(model.presentedError ?? "") }
    }

    private var targetCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.targetDevices.isEmpty { Text("No device connected").foregroundStyle(.secondary) }
                else if model.targetDevices.count > 1 { Text("Multiple targets detected — disconnect all but one.").foregroundStyle(.orange) }
                else if let target = model.target {
                    if let name = target.friendlyName { Text(name).font(.title2.bold()) }
                    LabeledContent("State", value: model.targetWorkflowState.rawValue)
                    if let modelName = target.model { LabeledContent("Identifier", value: modelName) }
                    if let ecid = target.ecid { LabeledContent("ECID", value: ecid) }
                }
                if model.isDemoMode {
                    Picker("Demo target", selection: $demoTarget) { ForEach(["None", "Normal", "Recovery", "DFU"], id: \.self) { Text($0) } }
                        .onChange(of: demoTarget) { _, value in model.setDemoTarget(value == "None" ? nil : DeviceState(rawValue: value)) }
                }
                HStack {
                    Button("Enter DFU") { Task { await model.enterDFU() } }.disabled(!model.canEnterDFU)
                    Button("Revive Mac") { model.revive() }.disabled(!model.canRevive)
                    Button("Refresh") { Task { await model.refreshDiagnosticsAndTarget() } }
                }
                if !model.isDemoMode && model.privilegeMode == .signedHelper && !model.privilegedHelperState.isReady { helperSetup }
                if !model.isDemoMode && model.privilegeMode == .community { Text("Community build — administrator authorization is requested only when entering DFU.").font(.caption).foregroundStyle(.secondary) }
                if model.doctorReport?.status.host.macVDMToolPath == nil { Text("The bundled DFU helper is unavailable. Rebuild the application or view Diagnostics.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label("Target Mac", systemImage: "desktopcomputer") }
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
                Text("Selected image").font(.caption).foregroundStyle(.secondary)
                selectedImageSummary
                if case .loading = model.catalogueState { ProgressView("Checking Apple…").controlSize(.small) }
                if let error = model.catalogueErrorMessage { Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange) }
                imageStatus
                downloadControl
                HStack {
                    Button("Change Version…") { model.beginChoosingVersion(); showVersions = true }
                    Button("Choose Local IPSW…") { showImporter = true }
                }
                OperationProgressView(presentation: OperationProgressPresentation(state: model.restoreState, macOSVersion: model.selectedRelease?.version))
                Button("Restore Mac", role: .destructive) { confirmRestore = true }.disabled(!model.canRestore)
                HStack {
                    if let log = model.lastLogURL { Button("View Log") { NSWorkspace.shared.open(log) } }
                    Button("Reveal Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility")]) }
                }
                if !model.canRestore { Text("Restore requires a validated image and a positively detected real DFU target.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label("macOS Restore", systemImage: "arrow.down.circle") }
    }

    @ViewBuilder private var selectedImageSummary: some View {
        switch model.selectedImagePresentation {
        case .unavailable:
            Text("No macOS image selected").font(.title3.bold())
        case .managed(let release, _):
            Text("macOS \(release.version)").font(.title2.bold())
            LabeledContent("Build", value: release.build)
            LabeledContent("Size", value: formatBytes(release.fileSize))
        case .local(let url, _, _):
            Text("Local IPSW").font(.title2.bold())
            Text(url.lastPathComponent).font(.headline)
            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
        switch model.downloadState {
        case .downloading:
            if let value = model.downloadPresentation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading macOS \(value.release.version)").font(.headline)
                    ProgressView(value: value.fraction)
                    HStack {
                        Text("\(formatBytes(value.completed)) / \(formatBytes(value.total))").font(.caption.monospacedDigit())
                        Spacer()
                        if let fraction = value.fraction { Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()) }
                        if let speed = value.bytesPerSecond { Text("\(formatBytes(Int64(speed)))/s").font(.caption.monospacedDigit()) }
                    }
                    Button("Cancel", role: .cancel) { model.cancelDownload() }
                }
            }
        case .validating: ProgressView("Validating image…")
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
                Text("Choose macOS Version").font(.title2.bold())
                Spacer()
                Button { Task { await model.refreshCatalogue(); model.beginChoosingVersion() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.catalogueState == .loading)
            }
            if case .loading = model.catalogueState { ProgressView("Checking Apple…") }
            if model.imageChoices.isEmpty, model.catalogueState != .loading { ContentUnavailableView("No Apple restore images are currently available", systemImage: "externaldrive.badge.questionmark") }
            List(model.imageChoices) { choice in
                Button { model.choosePendingRelease(choice.release) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.pendingRelease?.build == choice.release.build ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text("macOS \(choice.release.version)").font(.headline); if choice.isRecommended { Text("Latest available").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.blue.opacity(0.12), in: Capsule()) } }
                            Text("Build \(choice.release.build) · \(choice.release.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size")").foregroundStyle(.secondary)
                            HStack { cacheLabel(choice.cacheState); Text("· \(choice.compatibility.label)").foregroundStyle(.secondary) }.font(.caption)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
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
        case .downloaded: Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial(let bytes): Label("Partial · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .downloadRequired: Text("Download required")
        case .invalid: Label("Invalid cached image", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .validating: ProgressView().controlSize(.mini)
        }
    }
}
