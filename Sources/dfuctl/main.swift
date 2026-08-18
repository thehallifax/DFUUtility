import DFUCore
import Foundation

@main
struct DFUCLI {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage(exitCode: 64) }
        switch command {
        case "status":
            let status = try StatusService().status()
            print("Host:")
            print("  Apple Silicon: \(status.host.isAppleSilicon ? "Yes" : "No")")
            print("  macOS: \(status.host.macOSVersion)")
            print("  macvdmtool: \(status.host.macVDMToolPath == nil ? "Unavailable" : "Available")")
            print("  cfgutil: \(status.host.cfgutilPath == nil ? "Unavailable" : "Available")")
            print("Target:")
            print("  Connected: \(status.targets.isEmpty ? "No" : "Yes")")
            if status.targets.isEmpty { print("  State: Unknown") }
            for (index, device) in status.targets.enumerated() {
                if status.targets.count > 1 { print("  Device \(index + 1):") }
                print("  State: \(device.state.rawValue)")
                if let model = device.model { print("  Model: \(model)") }
                if let identifier = device.identifier { print("  Identifier: \(identifier)") }
                if let ecid = device.ecid { print("  ECID: \(ecid)") }
            }
        case "dfu": try DFUController().enterDFU(); print("Target verified in DFU mode.")
        case "restore":
            guard arguments.count == 2 else { usage(exitCode: 64) }
            let url = URL(fileURLWithPath: NSString(string: arguments[1]).expandingTildeInPath)
            try RestoreEngine().perform(.restore(url)); print("Restore completed successfully.")
        case "revive": try RestoreEngine().perform(.revive); print("Revive completed successfully.")
        case "reboot": try RestoreEngine().perform(.reboot); print("Reboot requested successfully.")
        case "recovery":
            throw DFUError.toolUnavailable("a reliable Apple-supported command for entering Recovery was not identified")
        case "help", "--help", "-h": usage(exitCode: 0)
        default: usage(exitCode: 64)
        }
    }

    static func usage(exitCode: Int32) -> Never {
        let text = """
        Usage:
          dfuctl status
          dfuctl dfu
          dfuctl restore /path/to/image.ipsw   # ERASES the selected target
          dfuctl revive
          dfuctl reboot
        """
        (exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
        exit(exitCode)
    }
}
