import AppKit
import DFUAppSupport
import DFUCore
import SwiftUI

struct CacheManagerView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var pendingRemoval: ManagedIPSWEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage Downloads").font(.title2.bold())
                    Text("IPSW Cache · \(format(model.managedCacheTotalBytes)) used").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Cache in Finder") {
                    if let url = model.prepareCacheDirectoryForReveal() { NSWorkspace.shared.open(url) }
                }
                Button { Task { await model.refreshManagedCache() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }

            if model.managedCacheEntries.isEmpty {
                ContentUnavailableView("No Managed Downloads", systemImage: "externaldrive", description: Text("Downloaded and partial IPSWs managed by DFUUtility appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(RestorePlatform.allCases, id: \.self) { platform in
                        let entries = model.managedCacheEntries.filter { $0.release.platform == platform }
                        if !entries.isEmpty {
                            Text(platform.displayName).font(.headline).foregroundStyle(.secondary)
                            ForEach(entries) { entry in
                                entryRow(entry)
                                if entry.id != entries.last?.id { Divider() }
                            }
                        }
                    }
                    }
                    .padding(12)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }

            Text("User-selected local IPSWs are not managed or deleted here.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 520)
        .task { if !model.isDemoMode { await model.refreshManagedCache() } }
        .alert(removalTitle, isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                guard let entry = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.removeManagedCacheEntry(entry) }
            }
        } message: {
            if let entry = pendingRemoval {
                Text("\(entry.release.platform.displayName) \(entry.release.version)\nBuild \(entry.release.build)\n\(format(entry.sizeBytes))\n\nThis removes the local cached file only. It does not affect any connected device.")
            }
        }
    }

    private func entryRow(_ entry: ManagedIPSWEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(entry.release.platform.displayName) \(entry.release.version)").font(.headline)
                    Text("Build \(entry.release.build) · \(format(entry.sizeBytes))\(entry.state == .partial ? " partial" : "")").foregroundStyle(.secondary)
                    stateLabel(entry.state)
                    if let failure = entry.validationFailure { Text("\(failure.predicate.rawValue): \(failure.reason)").font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if entry.state == .partial { Button("Resume") { model.resumeManagedPartial(entry) }.disabled(model.cacheRemovalDisabledReason(for: entry) != nil) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.cacheRevealURL(for: entry)]) }
                Button("Remove", role: .destructive) { pendingRemoval = entry }.disabled(model.cacheRemovalDisabledReason(for: entry) != nil)
            }
            if let reason = model.cacheRemovalDisabledReason(for: entry) { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }

    @ViewBuilder private func stateLabel(_ state: ManagedIPSWEntryState) -> some View {
        switch state {
        case .completeValidated: Label("Validated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .completeUnvalidated: Label("Validation not recorded", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .partial: Label("Partial download", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .invalid: Label("Invalid cached image", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var removalTitle: String { pendingRemoval?.state == .partial ? "Remove partial download?" : "Remove downloaded image?" }
    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
