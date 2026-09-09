import AppKit
import DFUCore
import SwiftUI

struct DiagnosticsView: View {
    @State private var confirmation: String?
    @State private var saveError: String?
    @State private var showTechnicalDetails = false
    let report: DoctorReport?
    let shareableText: String
    var privilegeMode: PrivilegeMode = PrivilegeModeSelector.select()
    var helperState: PrivilegedHelperState = PrivilegedDFUClient().state()
    var registrationErrorDetails: String?
    private var text: String { AcceptanceDiagnostics.render(report: report, privilegeMode: privilegeMode, helperState: helperState) + (registrationErrorDetails.map { "Registration error details: \($0)\n" } ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title.bold())
            Text("Host readiness and sanitized support information for this Mac.").font(.caption).foregroundStyle(.secondary)
            accessoryReadiness
            DisclosureGroup("Show Technical Details", isExpanded: $showTechnicalDetails) {
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    .frame(minHeight: 180)
            }
            if let confirmation { Text(confirmation).font(.caption).foregroundStyle(.secondary).accessibilityLabel(confirmation) }
            actionButtons
        }
        .alert("Unable to Save Diagnostics", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "The sanitized diagnostics could not be saved.") }
    }

    private var accessoryReadiness: some View {
        let readiness = AccessoryConnectionReadiness()
        return GroupBox("Host Readiness") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Accessory Connections", systemImage: "cable.connector")
                    .font(.headline)
                Text(readiness.detectedState).font(.caption).foregroundStyle(.secondary)
                Text("Check: Privacy & Security → Accessories → Allow accessories to connect")
                    .font(.caption)
                Text("For a dedicated, trusted DFU workstation, **Automatically allow when unlocked** reduces repeated approvals while keeping authorization restricted when the Mac is locked.")
                    .font(.caption)
                Text("**Always allow** reduces prompts further, but permits new wired accessories without individual approval. Consider it only for a physically controlled technician bench, not as a blanket recommendation for a personal Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button("Copy Sanitized Diagnostics") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shareableText, forType: .string)
            confirmation = "Sanitized diagnostics copied."
        }
        Button("Save Sanitized Diagnostics…") { save() }
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DFUUtility-Diagnostics.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try shareableText.write(to: url, atomically: true, encoding: .utf8)
            confirmation = "Sanitized diagnostics saved."
        } catch {
            saveError = "The sanitized diagnostics could not be saved. \(error.localizedDescription)"
        }
    }
}
