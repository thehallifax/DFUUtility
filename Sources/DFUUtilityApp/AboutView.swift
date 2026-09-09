import DFUCore
import SwiftUI

struct AboutView: View {
    @State private var showLicense = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DFUUtility").font(.largeTitle.bold())
            Text("Version \(BuildMetadata.displayVersion)")
            Text("Community build").font(.headline).foregroundStyle(.secondary)
            Text("DFUUtility is licensed under the Apache License 2.0.")
            Divider()
            Text("Third-party software").font(.title2.bold())
            Text("macvdmtool — Asahi Linux — Apache License 2.0")
            Link("Upstream project", destination: URL(string: "https://github.com/AsahiLinux/macvdmtool")!)
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
