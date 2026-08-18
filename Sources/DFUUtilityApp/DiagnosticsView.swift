import DFUCore
import SwiftUI

struct DiagnosticsView: View {
    let report: DoctorReport?
    var helperState: PrivilegedHelperState = PrivilegedDFUClient().state()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title.bold())
            if let report {
                diagnostic("Apple Silicon", report.status.host.isAppleSilicon)
                Text("macOS: \(report.status.host.macOSVersion)")
                diagnostic("Apple Configurator", report.configuratorPresent)
                diagnostic("cfgutil", report.status.host.cfgutilPath != nil, detail: report.status.host.cfgutilPath?.path)
                diagnostic("macvdmtool — \(report.status.host.macVDMToolSource?.category ?? "Unavailable")", report.status.host.macVDMToolPath != nil, detail: report.status.host.macVDMToolPath?.path)
                diagnostic("Privileged DFU Helper", helperState == .registered || helperState == .available || helperState == .installed, detail: String(describing: helperState))
                diagnostic("Restore support", report.restoreSupported)
                diagnostic("Cache writable", report.cacheWritable, detail: report.cacheDirectory.path)
                Divider()
                Text("Target: \(report.status.targets.isEmpty ? "No target connected" : report.status.targets.map(\.state.rawValue).joined(separator: ", "))")
            } else { ProgressView("Loading diagnostics…") }
            Spacer()
        }
    }
    private func diagnostic(_ title: String, _ success: Bool, detail: String? = nil) -> some View {
        VStack(alignment: .leading) { Label(title, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(success ? .green : .red); if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
    }
}
