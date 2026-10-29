import SwiftUI

struct LinkPreviewLoadingStrip: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let phase = reduceMotion ? 0.5
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                LinearGradient(
                    colors: [.clear, Theme.Colors.progress, .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.4)
                    .offset(x: geometry.size.width * (phase * 1.4 - 0.4))
            }
        }
        .frame(height: metrics.spacing.xxs)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
