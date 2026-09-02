import AppKit
import DFUCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: String?
    @State private var saveError: String?
    let report: DoctorReport?
    let shareableText: String
    var privilegeMode: PrivilegeMode = PrivilegeModeSelector.select()
    var helperState: PrivilegedHelperState = PrivilegedDFUClient().state()
    var registrationErrorDetails: String?
    private var text: String { AcceptanceDiagnostics.render(report: report, privilegeMode: privilegeMode, helperState: helperState) + (registrationErrorDetails.map { "Registration error details: \($0)\n" } ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title.bold())
            Text("Detailed local diagnostics are shown below. Copy and Save create a sanitized report suitable for sharing.").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let confirmation { Text(confirmation).font(.caption).foregroundStyle(.secondary).accessibilityLabel(confirmation) }
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons; Spacer(); doneButton }
                VStack(alignment: .leading, spacing: 8) { actionButtons; doneButton }
            }
        }
        .alert("Unable to Save Diagnostics", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "The sanitized diagnostics could not be saved.") }
    }

    @ViewBuilder private var actionButtons: some View {
        Button("Copy Sanitized Diagnostics") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shareableText, forType: .string)
            confirmation = "Sanitized diagnostics copied."
        }
        Button("Save Sanitized Diagnostics…") { save() }
    }
    private var doneButton: some View { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }

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
