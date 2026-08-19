import DFUAppSupport
import SwiftUI

struct OperationProgressView: View {
    let presentation: OperationProgressPresentation

    var body: some View {
        switch presentation.phase {
        case .hidden:
            EmptyView()
        case .active:
            VStack(alignment: .leading, spacing: 7) {
                if let title = presentation.title { Text(title).font(.headline) }
                if let stage = presentation.stage { Text(stage) }
                if let fraction = presentation.fraction {
                    HStack(alignment: .firstTextBaseline) {
                        ProgressView(value: fraction).frame(maxWidth: .infinity)
                        Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).frame(minWidth: 36, alignment: .trailing)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Do not disconnect the target Mac.").font(.caption).foregroundStyle(.secondary)
            }
        case .reconnecting:
            VStack(alignment: .leading, spacing: 7) {
                if let title = presentation.title { Text(title).font(.headline) }
                ProgressView(presentation.stage ?? "Waiting for Mac to restart…")
            }
        case .completed:
            Label(presentation.message ?? "Operation completed successfully.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label(presentation.message ?? "Operation failed.", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}
