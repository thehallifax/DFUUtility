import AppKit
import DFUAppSupport
import SwiftUI

struct UpdateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            content
            HStack {
                Spacer()
                if case .downloading = model.updateCoordinator.state {
                    Button("Cancel Download") { model.cancelBinaryDownload() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Later") { model.isUpdatePresentationRequested = false }.keyboardShortcut(.cancelAction)
                }
                if case .available = model.updateCoordinator.state {
                    Button("Update Now") {
                        _ = model.prepareUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStartUpdate)
                }
                if case .binaryAvailable = model.updateCoordinator.state {
                    Button("Download Update") {
                        model.startBinaryDownload()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canDownloadBinaryUpdate)
                }
            }
        }
        .padding(24).frame(minWidth: 360, idealWidth: 460, maxWidth: 560)
    }

    private var title: String {
        if model.updateCoordinator.sourceCheckoutUnavailable { return "Source checkout unavailable" }
        return switch model.updateCoordinator.state {
        case .available: "Update Available"
        case .binaryAvailable: "Update Available"
        case .checking: "Checking for Updates…"
        case .current: "DFUUtility Is Up to Date"
        case .preparing: "Preparing Update…"
        case .downloading: "Downloading Update…"
        case .verifying: "Verifying Update…"
        case .verifiedReady: "Verified Update Ready"
        case .blockedByOperation: "Update Blocked"
        case .failed, .unavailable: "Unable to Update"
        case .idle: "DFUUtility Updates"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.updateCoordinator.state {
        case .checking, .preparing, .downloading, .verifying: ProgressView().accessibilityLabel(title)
        case .current: Text("DFUUtility is up to date.")
        case .available(let update):
            Text(update.versionChanged ? "A newer version of DFUUtility is available." : "A newer DFUUtility source revision is available.")
            LabeledContent("Installed source", value: update.currentVersion)
            if update.versionChanged { LabeledContent("Available source", value: update.latestVersion) }
            else { Text("Version remains \(update.currentVersion).").foregroundStyle(.secondary) }
            if !model.canStartUpdate { Text(model.updateBlockedMessage).foregroundStyle(.orange) }
            Text("The application will quit while its original Git clone is safely updated, rebuilt, verified, and installed. It will relaunch when finished.").font(.caption).foregroundStyle(.secondary)
        case .binaryAvailable(let update):
            Text(verbatim: "DFUUtility \(update.version.description) is available.")
            if let url = update.releaseURL { Link("View release notes", destination: url) }
            Text("Download the verified Community release into DFUUtility's controlled staging area. Installation is not performed in this version.").font(.caption).foregroundStyle(.secondary)
        case .verifiedReady(let artifact):
            Label { Text(verbatim: "DFUUtility \(artifact.version.description) is verified and ready to install.") } icon: { Image(systemName: "checkmark.seal") }
            Text("Community release verified against published release metadata and bundle structure. Installation will be added in a future update.").font(.caption).foregroundStyle(.secondary)
        case .blockedByOperation(let message):
            Label(message, systemImage: "hourglass").foregroundStyle(.orange)
        case .unavailable(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("View Update Log") { NSWorkspace.shared.open(model.updateCoordinator.logURL) }
            if model.updateCoordinator.sourceCheckoutUnavailable {
                Link("Installation instructions", destination: URL(string: "https://github.com/thehallifax/DFUUtility#installation")!)
            }
        case .idle: Text("Choose Check for Updates from the DFUUtility menu to check the original source clone.")
        }
    }
}
