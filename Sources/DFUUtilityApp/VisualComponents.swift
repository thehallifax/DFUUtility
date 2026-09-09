import DFUCore
import SwiftUI

struct WorkspacePanel<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        GroupBox {
            content().padding(8)
        } label: {
            if let title {
                Label(title, systemImage: systemImage ?? "square")
                    .font(.headline)
            }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let tint: Color
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct DeviceStateBadge: View {
    let state: DeviceState

    var body: some View {
        StatusBadge(title: state.rawValue, tint: color, systemImage: icon)
    }

    private var color: Color {
        switch state {
        case .normal: .green
        case .recovery: .orange
        case .dfu: .blue
        case .unknown: .secondary
        }
    }

    private var icon: String {
        switch state {
        case .normal: "checkmark.circle.fill"
        case .recovery: "exclamationmark.triangle.fill"
        case .dfu: "bolt.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct ActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isDestructive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: systemImage).font(.title3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(.quaternary.opacity(isDisabled ? 0.35 : 0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .tint(isDestructive ? .red : .accentColor)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

func deviceFamilySymbol(_ family: AppleDeviceFamily) -> String {
    switch family {
    case .mac: "laptopcomputer"
    case .iPhone: "iphone"
    case .iPad: "ipad"
    case .unknown: "externaldrive"
    }
}
