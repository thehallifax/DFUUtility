import DFUCore
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DFUUtility").font(.largeTitle.bold())
            Text("Version \(BuildMetadata.displayVersion)")
            Text("Community build").font(.headline).foregroundStyle(.secondary)
            Text("DFUUtility — Apache License 2.0")
            Divider()
            Text("Third-party software").font(.title2.bold())
            Text("macvdmtool — Asahi Linux — Apache License 2.0")
            Link("Upstream project", destination: URL(string: "https://github.com/AsahiLinux/macvdmtool")!)
            ScrollView { Text(licenseText).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Spacer()
        }
    }
    private var licenseText: String {
        let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyLicenses/macvdmtool-Apache-2.0.txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The full Apache License 2.0 is included in the packaged application's ThirdPartyLicenses folder."
    }
}
