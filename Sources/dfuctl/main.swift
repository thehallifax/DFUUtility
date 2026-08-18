import DFUCore
import Foundation

@main
struct DFUCLI {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst()); guard let command = arguments.first else { usage(exitCode: 64) }
        switch command {
        case "doctor":
            let report = try DoctorService().report(); printDoctor(report); if !report.isFundamentallyUsable { exit(1) }
        case "status": printStatus(try StatusService().status())
        case "ipsw": try await ipsw(Array(arguments.dropFirst()))
        case "dfu": try DFUController().enterDFU(); print("Target verified in DFU mode.")
        case "restore":
            guard arguments.count == 2 else { usage(exitCode: 64) }
            try RestoreEngine().perform(.restore(URL(fileURLWithPath: NSString(string: arguments[1]).expandingTildeInPath))); print("Restore completed successfully.")
        case "revive": try RestoreEngine().perform(.revive); print("Revive completed successfully.")
        case "reboot": try RestoreEngine().perform(.reboot); print("Reboot requested successfully.")
        case "recovery": throw DFUError.toolUnavailable("a reliable Apple-supported command for entering Recovery was not identified")
        case "help", "--help", "-h": usage(exitCode: 0)
        default: usage(exitCode: 64)
        }
    }

    static func ipsw(_ arguments: [String]) async throws {
        guard let command = arguments.first else { usage(exitCode: 64) }
        let service = AppleIPSWService(), cache = IPSWCache(), validator = IPSWValidator()
        switch command {
        case "list":
            let verbose = arguments.contains("--verbose"), releases = try await service.availableImages(for: nil)
            print("Available macOS IPSWs")
            for release in releases {
                print("macOS \(release.version)\nBuild: \(release.build)\nSize: \(formatBytes(release.fileSize))\nURL: Apple\nStatus: Available")
                if verbose { print("Models: \(release.supportedDevices.joined(separator: ", "))\nDownload: \(release.downloadURL.absoluteString)\nSHA-1: \(release.checksum ?? "Not supplied")") }
                print()
            }
        case "latest":
            let release = try await service.recommendedImage(for: nil), cached = try cache.validCachedURL(for: release, validator: validator) != nil
            print("Latest macOS restore image\nVersion: \(release.version)\nBuild: \(release.build)\nSize: \(formatBytes(release.fileSize))\nCached: \(cached ? "Yes" : "No")")
        case "download":
            let releases = try await service.availableImages(for: nil); let release: IPSWRelease
            if arguments.dropFirst().first == "latest" { guard let first = releases.first else { throw IPSWServiceError.noReleases }; release = first }
            else if let index = arguments.firstIndex(of: "--build"), arguments.indices.contains(index + 1) {
                let build = arguments[index + 1]; guard let found = releases.first(where: { $0.build == build }) else { throw IPSWServiceError.unknownBuild(build) }; release = found
            } else { usage(exitCode: 64) }
            if let cached = try cache.validCachedURL(for: release, validator: validator) { print("Using valid cached IPSW:\n\(cached.path)"); return }
            let partial = cache.partialURL(for: release), partialSize = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
            print("Downloading macOS \(release.version) (\(release.build))"); if partialSize > 0 { print("Found partial download: \(formatBytes(partialSize))\nResuming…") }
            let url = try await service.download(release) { value in
                let percent = value.total.map { $0 > 0 ? " \(Int(Double(value.received) / Double($0) * 100))%" : "" } ?? ""
                FileHandle.standardError.write(Data("\r\(formatBytes(value.received)) / \(formatBytes(value.total))\(percent)  \(formatRate(value.bytesPerSecond))".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8)); print("Cached and validated:\n\(url.path)")
        case "cache":
            let entries = try cache.entries(validator: validator); print("Cached IPSWs")
            if entries.isEmpty { print("None") }
            for entry in entries { print("macOS \(entry.release.version)\nBuild: \(entry.release.build)\nSize: \(formatBytes(entry.release.fileSize))\nPath:\n\(entry.url.path)\nStatus: \(entry.isValid ? "Valid" : "Invalid")\n") }
        case "clean":
            let partials = arguments.contains("--partials"), invalid = arguments.contains("--invalid")
            guard partials || invalid else { FileHandle.standardError.write(Data("Specify --partials and/or --invalid; valid IPSWs are never removed.\n".utf8)); exit(64) }
            print("Removed \(try cache.clean(partials: partials, invalid: invalid, validator: validator)) cache item(s).")
        default: usage(exitCode: 64)
        }
    }

    static func printStatus(_ status: UtilityStatus) {
        print("Host:\n  Apple Silicon: \(status.host.isAppleSilicon ? "Yes" : "No")\n  macOS: \(status.host.macOSVersion)\n  macvdmtool: \(status.host.macVDMToolPath == nil ? "Unavailable" : "Available")\n  cfgutil: \(status.host.cfgutilPath == nil ? "Unavailable" : "Available")\nTarget:\n  Connected: \(status.targets.isEmpty ? "No" : "Yes")")
        if status.targets.isEmpty { print("  State: Unknown") }
        for device in status.targets { print("  State: \(device.state.rawValue)"); if let model = device.model { print("  Model: \(model)") }; if let id = device.identifier { print("  Identifier: \(id)") }; if let ecid = device.ecid { print("  ECID: \(ecid)") } }
    }
    static func printDoctor(_ r: DoctorReport) {
        func mark(_ value: Bool) -> String { value ? "✓" : "✗" }
        print("DFUUtility Doctor\nHost\n\(mark(r.status.host.isAppleSilicon)) Apple Silicon\n✓ macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nDependencies\n\(mark(r.configuratorPresent)) Apple Configurator\n\(mark(r.status.host.cfgutilPath != nil)) cfgutil \(r.status.host.cfgutilPath?.path ?? "")\n\(mark(r.status.host.macVDMToolPath != nil)) macvdmtool \(r.status.host.macVDMToolPath?.path ?? "")\nRestore\n\(mark(r.restoreSupported)) cfgutil restore support available\nIPSW Cache\n\(mark(r.cacheWritable)) Writable\n  \(r.cacheDirectory.path)\nTarget\n\(r.status.targets.isEmpty ? "– No target connected" : "✓ \(r.status.targets.count) target(s) connected")\nOverall")
        if r.setupComplete { print("✓ Host setup complete") } else if r.isFundamentallyUsable { print("⚠ Host setup incomplete: macvdmtool unavailable\n  Install macvdmtool from https://github.com/AsahiLinux/macvdmtool") } else { print("✗ Host configuration has blocking failures") }
    }
    static func formatBytes(_ value: Int64?) -> String { guard let value else { return "Unknown" }; return ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func formatRate(_ value: Double) -> String { value > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s" : "" }
    static func usage(exitCode: Int32) -> Never {
        let text = "Usage:\n  dfuctl doctor | status | dfu | revive | reboot\n  dfuctl restore /path/to/image.ipsw   # ERASES the selected target\n  dfuctl ipsw list [--verbose]\n  dfuctl ipsw latest\n  dfuctl ipsw download latest | --build BUILD\n  dfuctl ipsw cache\n  dfuctl ipsw clean --partials [--invalid]"
        (exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8)); exit(exitCode)
    }
}
