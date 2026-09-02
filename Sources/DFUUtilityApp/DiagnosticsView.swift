import AppKit
import DFUCore
import SwiftUI

struct DiagnosticsView: View {
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
            HStack {
                Button("Copy Sanitized Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shareableText, forType: .string) }
                Button("Save Sanitized Diagnostics…") { save() }
                Spacer()
            }
        }
    }

    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DFUUtility-Diagnostics.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? shareableText.write(to: url, atomically: true, encoding: .utf8)
    }
}
