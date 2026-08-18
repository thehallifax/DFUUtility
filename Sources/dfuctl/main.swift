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
        case "dfu":
            let before = try StatusService().status()
            print("Target before DFU:")
            printTarget(before.targets)
            if geteuid() != 0 { print("Administrator authorization required.") }
            print("Entering DFU…")
            try DFUController().enterDFU()
            let after = try StatusService().status()
            print("Target transitioned to DFU successfully.")
            if let ecid = after.targets.first(where: { $0.state == .dfu })?.ecid { print("ECID: \(ecid)") }
        case "restore":
            if arguments.count == 2, !arguments[1].hasPrefix("--") {
                try RestoreEngine().perform(.restore(URL(fileURLWithPath: NSString(string: arguments[1]).expandingTildeInPath)))
            } else { try await restoreRecommended(Array(arguments.dropFirst())) }
            print("Restore completed successfully.")
        case "revive": try RestoreEngine().perform(.revive); print("Revive completed successfully.")
        case "reboot": try RestoreEngine().perform(.reboot); print("Reboot requested successfully.")
        case "recovery": throw DFUError.toolUnavailable("a reliable Apple-supported command for entering Recovery was not identified")
        case "help", "--help", "-h": usage(exitCode: 0)
        default: usage(exitCode: 64)
        }
    }

    static func restoreRecommended(_ arguments: [String]) async throws {
        guard arguments.allSatisfy({ $0 == "--download" }) else { usage(exitCode: 64) }
        let devices = try ConfiguratorDeviceDiscovery().devices()
        guard devices.count == 1 else { if devices.isEmpty { throw DFUError.noTarget }; throw DFUError.multipleTargets(devices.count) }
        guard devices[0].state == .dfu else { throw DFUError.targetNotInDFU }
        let service = AppleIPSWService(), cache = IPSWCache(), validator = IPSWValidator()
        let release = try await service.recommendedImage(for: devices[0])
        var url = try cache.validCachedURL(for: release, validator: validator)
        print("Target:\n\(devices[0].model ?? "Unknown")\nECID: \(devices[0].ecid ?? "Unknown")\nRestore image:\nmacOS \(release.version) (\(release.build))")
        if url == nil {
            guard arguments.contains("--download") else { throw DFUError.invalidIPSW("The recommended image is not cached. Run `dfuctl ipsw download latest` or repeat with `dfuctl restore --download`.") }
            print("Downloading the explicitly requested image…")
            url = try await service.download(release) { progress in
                FileHandle.standardError.write(Data("\r\(formatBytes(progress.received)) / \(formatBytes(progress.total))".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
        } else { print("✓ Cached and validated") }
        print("WARNING: Restore will erase the target Mac.\nContinue? [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), answer == "y" || answer == "yes" else { throw CancellationError() }
        try RestoreEngine().perform(.restore(url!))
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
            var completedURL: URL?
            for try await event in service.downloadEvents(release) {
                switch event {
                case .started: print("Downloading macOS \(release.version) (\(release.build))")
                case .resumed(let bytes): print("Found partial download: \(formatBytes(bytes))\nResuming…")
                case .progress(let completed, let total, let speed):
                    let percent = total.map { $0 > 0 ? " \(Int(Double(completed) / Double($0) * 100))%" : "" } ?? ""
                    FileHandle.standardError.write(Data("\r\(formatBytes(completed)) / \(formatBytes(total))\(percent)  \(formatRate(speed ?? 0))".utf8))
                case .validating: FileHandle.standardError.write(Data("\nValidating image…\n".utf8))
                case .completed(let url): completedURL = url
                case .cancelled: FileHandle.standardError.write(Data("\nDownload cancelled; partial retained.\n".utf8))
                }
            }
            if let completedURL { FileHandle.standardError.write(Data("\n".utf8)); print("Cached and validated:\n\(completedURL.path)") }
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
    static func printTarget(_ devices: [DFUDevice]) {
        print("  Connected: \(devices.isEmpty ? "No" : "Yes")")
        if devices.isEmpty { print("  State: Unknown"); return }
        for device in devices { print("  State: \(device.state.rawValue)"); if let model = device.model { print("  Model: \(model)") }; if let ecid = device.ecid { print("  ECID: \(ecid)") } }
    }
    static func printDoctor(_ r: DoctorReport) {
        func mark(_ value: Bool) -> String { value ? "✓" : "✗" }
        let helper = "\(mark(r.status.host.macVDMToolPath != nil)) macvdmtool\n  Source: \(r.status.host.macVDMToolSource?.category ?? "Unavailable")\n  Path: \(r.status.host.macVDMToolPath?.path ?? "—")"
        print("DFUUtility Doctor\nHost\n\(mark(r.status.host.isAppleSilicon)) Apple Silicon\n✓ macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nDependencies\n\(mark(r.configuratorPresent)) Apple Configurator\n\(mark(r.status.host.cfgutilPath != nil)) cfgutil \(r.status.host.cfgutilPath?.path ?? "")\n\(helper)\nRestore\n\(mark(r.restoreSupported)) cfgutil restore support available\nIPSW Cache\n\(mark(r.cacheWritable)) Writable\n  \(r.cacheDirectory.path)\nTarget\n\(r.status.targets.isEmpty ? "– No target connected" : "✓ \(r.status.targets.count) target(s) connected")\nOverall")
        if r.setupComplete { print("✓ Host setup complete") } else if r.isFundamentallyUsable { print("⚠ Host setup incomplete: macvdmtool unavailable") } else { print("✗ Host configuration has blocking failures") }
    }
    static func formatBytes(_ value: Int64?) -> String { guard let value else { return "Unknown" }; return ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func formatRate(_ value: Double) -> String { value > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s" : "" }
    static func usage(exitCode: Int32) -> Never {
        let text = "Usage:\n  dfuctl doctor | status | dfu | revive | reboot\n  dfuctl restore                       # recommended cached image; prompts\n  dfuctl restore --download            # explicitly permits download; prompts\n  dfuctl restore /path/to/image.ipsw   # scripting form; ERASES target\n  dfuctl ipsw list [--verbose]\n  dfuctl ipsw latest\n  dfuctl ipsw download latest | --build BUILD\n  dfuctl ipsw cache\n  dfuctl ipsw clean --partials [--invalid]"
        (exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8)); exit(exitCode)
    }
}
