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
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(report: model.doctorReport, helperState: model.privilegedHelperState).frame(minWidth: 480, minHeight: 430).padding() }
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
                if !model.isDemoMode && !model.privilegedHelperState.isReady { helperSetup }
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
                switch model.catalogueState {
                case .idle, .loading: ProgressView("Loading Apple firmware catalogue…")
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                case .loaded:
                    if let release = model.selectedRelease {
                        Text("macOS \(release.version)").font(.title2.bold())
                        LabeledContent("Build", value: release.build)
                        LabeledContent("Size", value: formatBytes(release.fileSize))
                    } else if case .ready(let url) = model.imageState { Text("Local IPSW").font(.title2.bold()); Text(url.lastPathComponent).foregroundStyle(.secondary) }
                }
                imageStatus
                HStack {
                    downloadControl
                    Button("Other Version…") { showVersions = true }.disabled(model.availableReleases.isEmpty)
                    Button("Choose IPSW…") { showImporter = true }
                }
                if case .running(_, let stage, let fraction) = model.restoreState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stage)
                        if let fraction { ProgressView(value: fraction); Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit()) }
                        else { ProgressView() }
                        Text("Do not disconnect the target Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case .reconnecting = model.restoreState { ProgressView("Operation completed. Waiting for Mac to restart…") }
                if case .completed(let message) = model.restoreState { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if case .failed(let message) = model.restoreState { Label(message, systemImage: "xmark.circle").foregroundStyle(.red) }
                Button("Restore Mac", role: .destructive) { confirmRestore = true }.disabled(!model.canRestore)
                HStack {
                    if let log = model.lastLogURL { Button("View Log") { NSWorkspace.shared.open(log) } }
                    Button("Reveal Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility")]) }
                }
                if !model.canRestore { Text("Restore requires a validated image and a positively detected real DFU target.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label("macOS Restore", systemImage: "arrow.down.circle") }
    }

    @ViewBuilder private var imageStatus: some View {
        switch model.imageState {
        case .none: Text("Image status: Not downloaded").foregroundStyle(.secondary)
        case .partial(let bytes): Label("Partial download available (\(formatBytes(bytes)))", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .validating: ProgressView("Validating image…")
        case .ready: Label("Image ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var downloadControl: some View {
        switch model.downloadState {
        case .downloading(let done, let total, let speed):
            VStack(alignment: .leading) { ProgressView(value: total.map { Double(done) / Double($0) }); Text("\(formatBytes(done)) / \(formatBytes(total))  \(speed.map { formatBytes(Int64($0)) + "/s" } ?? "")").font(.caption.monospacedDigit()); Button("Cancel", role: .cancel) { model.cancelDownload() } }
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
        VStack(alignment: .leading) {
            Text("Other Version").font(.title2.bold())
            List(model.availableReleases, id: \.self) { release in
                Button { model.selectRelease(release); isPresented = false } label: {
                    VStack(alignment: .leading) { Text("macOS \(release.version)").font(.headline); Text("Build \(release.build) · \(release.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size")").foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction) }
        }.padding().frame(minWidth: 450, minHeight: 320)
    }
}
