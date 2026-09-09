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
                Button("Later") { model.isUpdatePresentationRequested = false }.keyboardShortcut(.cancelAction)
                if case .available = model.updateCoordinator.state {
                    Button("Update Now") {
                        _ = model.prepareUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStartUpdate)
                }
            }
        }
        .padding(24).frame(minWidth: 360, idealWidth: 460, maxWidth: 560)
    }

    private var title: String {
        if model.updateCoordinator.sourceCheckoutUnavailable { return "Source checkout unavailable" }
        return switch model.updateCoordinator.state {
        case .available: "Update Available"
        case .checking: "Checking for Updates…"
        case .current: "DFUUtility Is Up to Date"
        case .preparing: "Preparing Update…"
        case .failed, .unavailable: "Unable to Update"
        case .idle: "DFUUtility Updates"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.updateCoordinator.state {
        case .checking, .preparing: ProgressView().accessibilityLabel(title)
        case .current: Text("DFUUtility is up to date.")
        case .available(let update):
            Text(update.versionChanged ? "A newer version of DFUUtility is available." : "A newer DFUUtility source revision is available.")
            LabeledContent("Installed source", value: update.currentVersion)
            if update.versionChanged { LabeledContent("Available source", value: update.latestVersion) }
            else { Text("Version remains \(update.currentVersion).").foregroundStyle(.secondary) }
            if !model.canStartUpdate { Text(model.updateBlockedMessage).foregroundStyle(.orange) }
            Text("The application will quit while its original Git clone is safely updated, rebuilt, verified, and installed. It will relaunch when finished.").font(.caption).foregroundStyle(.secondary)
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
