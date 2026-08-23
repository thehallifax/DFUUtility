import DFUAppSupport
import DFUCore
import SwiftUI

struct OperationProgressView: View {
    let presentation: OperationProgressPresentation
    let target: DFUDevice?

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
                Text(TargetPresentation.disconnectWarning(for: target)).font(.caption).foregroundStyle(.secondary)
            }
        case .reconnecting:
            VStack(alignment: .leading, spacing: 7) {
                if let title = presentation.title { Text(title).font(.headline) }
                ProgressView(presentation.stage ?? TargetPresentation.restartWaitingText(for: target))
            }
        case .completed:
            Label(presentation.message ?? "Operation completed successfully.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label(presentation.message ?? "Operation failed.", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}
