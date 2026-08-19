import AppKit
import DFUCore
import SwiftUI

struct DiagnosticsView: View {
    let report: DoctorReport?
    var privilegeMode: PrivilegeMode = PrivilegeModeSelector.select()
    var helperState: PrivilegedHelperState = PrivilegedDFUClient().state()
    var registrationErrorDetails: String?
    private var text: String { AcceptanceDiagnostics.render(report: report, privilegeMode: privilegeMode, helperState: helperState) + (registrationErrorDetails.map { "Registration error details: \($0)\n" } ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title.bold())
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Save Diagnostics…") { save() }
                Spacer()
            }
        }
    }

    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DFUUtility-Diagnostics.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
