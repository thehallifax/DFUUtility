import DFUCore
import SwiftUI

struct AboutView: View {
    @State private var showProjectLicense = false
    @State private var showThirdPartyLicense = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspacePanel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DFUUtility").font(.largeTitle.bold())
                    Text("Version \(BuildMetadata.displayVersion) · Community build").foregroundStyle(.secondary)
                    Text("A native technician utility for restoring and reviving Apple devices.")
            Text("DFUUtility is licensed under the Apache License 2.0.").font(.subheadline.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            WorkspacePanel("Third-party software", systemImage: "shippingbox") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macvdmtool — Asahi Linux — Apache License 2.0")
                    Link("View upstream project", destination: URL(string: "https://github.com/AsahiLinux/macvdmtool")!)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("View DFUUtility License", isExpanded: $showProjectLicense) {
                ScrollView { Text(projectLicenseText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    .frame(minHeight: 180)
            }
            DisclosureGroup("View macvdmtool License", isExpanded: $showThirdPartyLicense) {
                ScrollView { Text(thirdPartyLicenseText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                    .frame(minHeight: 180)
            }
            Spacer()
        }
    }
    private var projectLicenseText: String {
        let url = Bundle.main.resourceURL?.appendingPathComponent("DFUUtility-LICENSE.txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The full Apache License 2.0 is included in the packaged application."
    }

    private var thirdPartyLicenseText: String {
        let licenseURL = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyLicenses/macvdmtool-Apache-2.0.txt")
        let revisionURL = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt")
        let license = licenseURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The upstream Apache License 2.0 is included in the packaged application."
        let revision = revisionURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return revision.isEmpty ? license : "(license)\n\nUpstream revision:\n(revision)"
    }
}
