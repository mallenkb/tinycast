import SwiftUI

struct ChatSuggestionChips: View {
    @Environment(\.metrics) private var metrics
    let choices: [String]
    let onChoose: (String) -> Void

    var body: some View {
        WrappingLayout(spacing: metrics.spacing.sm) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                ChatSuggestionChip(choice: choice, onChoose: onChoose)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested replies")
    }
}

private struct ChatSuggestionChip: View {
    @Environment(\.metrics) private var metrics
    let choice: String
    let onChoose: (String) -> Void

    var body: some View {
        Button {
            onChoose(choice)
        } label: {
            HStack(spacing: metrics.spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(choice)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(metrics.typography.rowTrailing)
            .chatChip()
        }
        .buttonStyle(.plain)
        .help("Reply “\(choice)”")
        .accessibilityLabel("Reply: \(choice)")
    }
}

private struct ChatChipSurface: ViewModifier {
    @Environment(\.metrics) private var metrics
    let leadsWithBadge: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.leading, leadsWithBadge ? metrics.spacing.sm : metrics.spacing.xl)
            .padding(.trailing, metrics.spacing.xl)
            .padding(.vertical, metrics.spacing.sm)
            .background { Capsule().fill(Color.clear).frosted(in: Capsule()) }
            .contentShape(Capsule())
    }
}

extension View {
    func chatChip(leadsWithBadge: Bool = false) -> some View {
        modifier(ChatChipSurface(leadsWithBadge: leadsWithBadge))
    }
}
