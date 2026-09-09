import DFUCore
import SwiftUI

struct AboutView: View {
    @State private var showLicense = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DFUUtility").font(.largeTitle.bold())
                    Text("Version \(BuildMetadata.displayVersion) · Community build").foregroundStyle(.secondary)
                    Text("A native technician utility for restoring and reviving Apple devices.")
                    Text("Apache License 2.0").font(.subheadline.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            WorkspacePanel("Third-party software", systemImage: "shippingbox") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macvdmtool — Asahi Linux — Apache License 2.0")
                    Link("View upstream project", destination: URL(string: "https://github.com/AsahiLinux/macvdmtool")!)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("View License", isExpanded: $showLicense) {
                ScrollView { Text(licenseText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    .frame(minHeight: 180)
            }
            Spacer()
        }
    }
    private var licenseText: String {
        let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyLicenses/macvdmtool-Apache-2.0.txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The full Apache License 2.0 is included in the packaged application's ThirdPartyLicenses folder."
    }
}
