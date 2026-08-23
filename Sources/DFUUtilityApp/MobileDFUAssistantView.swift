import DFUAppSupport
import SwiftUI

struct MobileDFUAssistantView: View {
    @ObservedObject var model: MobileDFUAssistantModel
    @Binding var isPresented: Bool
    @State private var showTiming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.profile.title).font(.title.bold())
                Spacer()
                if model.isDemoMode { Text("DEMO").font(.caption.bold()).foregroundStyle(.orange) }
            }
            stateContent.frame(maxWidth: .infinity, minHeight: 290, alignment: .center)
            if let summary = model.lastAttemptSummary { Text("Last attempt: \(summary)").font(.caption).foregroundStyle(.secondary) }
            if model.shouldProminentlyShowCableAdvice, let advice = model.profile.cableAdvice {
                Label { Text(advice) } icon: { Image(systemName: "cable.connector") }
                    .font(.callout).padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else if let advice = model.profile.cableAdvice {
                DisclosureGroup("Having trouble entering DFU?") { Text(advice).font(.caption).foregroundStyle(.secondary) }
            }
            if model.timing.firstDisappearance != nil {
                DisclosureGroup("Timing details (local only)", isExpanded: $showTiming) {
                    Text(timingDescription).font(.caption.monospaced()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.isDemoMode && !CommandLine.arguments.contains("--capture-screenshot") { demoControls }
            Divider()
            HStack {
                Text("Product: \(model.profile.productType)").font(.caption).foregroundStyle(.secondary)
                Spacer(); controls
            }
        }
        .padding(28).frame(minWidth: 600, minHeight: 480).onAppear { model.activate() }
    }

    @ViewBuilder private var stateContent: some View {
        switch model.state {
        case .ready:
            ready
        case .waitingForButtonHold, .waitingForReset:
            cue("HOLD", model.profile.holdButtonsText, color: .blue, detail: "Keep holding both buttons. DFUUtility is watching for the reset transition.")
        case .postResetHoldBoth:
            cue("RESET DETECTED", "KEEP HOLDING BOTH", color: .orange, detail: "Get ready to release \(model.profile.powerButtonName).")
        case .releasePowerNow:
            cue(model.profile.releaseCueText, "KEEP HOLDING HOME", color: .red, detail: "Do not release Home until a result is detected.")
        case .holdingHome, .waitingForDFU:
            VStack(spacing: 15) {
                ProgressView().controlSize(.large)
                Text("KEEP HOLDING HOME").font(.largeTitle.bold())
                Text("Waiting for this same device to enumerate in DFU.").foregroundStyle(.secondary)
            }
        case .detectedDFU:
            result("checkmark.circle.fill", .green, "DFU detected", "The same ECID is now in DFU. No restore was started.")
        case .detectedRecovery:
            result("arrow.clockwise.circle.fill", .orange, "Recovery detected — timing missed DFU", "The device is safe. Choose Try Again when ready.")
        case .detectedNormal:
            result(model.target.family == .iPad ? "ipad" : "iphone", .orange, "Device restarted normally", "Choose Try Again when ready.")
        case .disconnectedUnexpectedly:
            result("cable.connector.slash", .orange, "Device disconnected", "Reconnect the same \(model.target.family.displayName) to continue.")
        case .targetMismatch:
            result("exclamationmark.triangle.fill", .red, "Different device detected", "Reconnect the original device. Success is restricted to its ECID.")
        case .timedOut:
            result("clock.badge.exclamationmark", .orange, "DFU was not detected", "No conclusive state appeared before the detection timeout.")
        case .cancelled:
            result("xmark.circle", .secondary, "Assistant cancelled", "No device operation was performed.")
        }
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill").font(.system(size: 46)).foregroundStyle(.blue)
            Text(model.startedInRecovery ? "Device is already in Recovery" : "Prepare the physical buttons").font(.title2.bold())
            Text("When you click Start, immediately hold \(model.profile.powerButtonName) + Home. The release cue is anchored to the observed USB reset—not a fixed initial countdown.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if model.startedInRecovery && !model.synchronizedResetAvailable {
                Text("Synchronized Recovery reset is unavailable in this build; state-aware physical guidance remains available.").font(.caption).foregroundStyle(.secondary)
            }
            Text("No restore, revive, erase, or firmware command will be started.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cue(_ title: String, _ buttons: String, color: Color, detail: String) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: title.hasPrefix("RELEASE") ? 42 : 34, weight: .heavy, design: .rounded)).foregroundStyle(color).multilineTextAlignment(.center)
            Text(buttons).font(.title.bold()).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(20).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func result(_ icon: String, _ color: Color, _ title: String, _ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 52)).foregroundStyle(color)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.state {
        case .ready:
            Button("Cancel", role: .cancel) { model.cancel(); isPresented = false }
            if model.synchronizedResetAvailable { Button("Start Synchronized DFU") { Task { await model.startSynchronizedRecoveryReset() } } }
            Button("Start") { model.start() }.keyboardShortcut(.defaultAction)
        case .detectedDFU:
            Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
        case .detectedRecovery, .detectedNormal, .disconnectedUnexpectedly, .targetMismatch, .timedOut:
            Button("Cancel", role: .cancel) { model.cancel(); isPresented = false }
            Button("Try Again") { model.retry() }.keyboardShortcut(.defaultAction)
        case .cancelled:
            Button("Close") { isPresented = false }.keyboardShortcut(.defaultAction)
        default:
            Button("Cancel", role: .cancel) { model.cancel(); isPresented = false }
        }
    }

    private var demoControls: some View {
        HStack {
            Text("Demo state:").font(.caption)
            Button("Recovery") { model.setDemoState(.detectedRecovery) }
            Button("DFU") { model.setDemoState(.detectedDFU) }
            Button("Timeout") { model.setDemoState(.timedOut) }
            Button("Mismatch") { model.setDemoState(.targetMismatch) }
        }.controlSize(.small)
    }

    private var timingDescription: String {
        let values: [(String, Duration?)] = [("disappearance", model.timing.firstDisappearance), ("release cue", model.timing.releaseCue), ("reappearance", model.timing.reappearance), ("Recovery", model.timing.recoveryAppearance), ("DFU", model.timing.dfuAppearance), ("Normal", model.timing.normalAppearance)]
        return values.compactMap { label, value in value.map { "\(label): +\(format($0)) s" } }.joined(separator: "\n")
    }
    private func format(_ duration: Duration) -> String { String(format: "%.3f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
}
