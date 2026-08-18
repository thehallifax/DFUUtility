import Foundation
import Testing
@testable import DFUCore

@Test func releaseCacheDestinationIsStable() throws {
    let release = IPSWRelease(
        version: "26.6", build: "25G76",
        downloadURL: try #require(URL(string: "https://updates.cdn-apple.com/example.ipsw")),
        fileSize: 42
    )
    let cache = IPSWCache(directory: URL(fileURLWithPath: "/tmp/test-cache"))
    #expect(cache.destination(for: release).lastPathComponent == "UniversalMac_26.6_25G76_Restore.ipsw")
}

@Test func errorsExplainDestructivePreconditions() {
    #expect(DFUError.targetNotInDFU.localizedDescription.contains("not in DFU"))
    #expect(DFUError.multipleTargets(2).localizedDescription.contains("2"))
}
