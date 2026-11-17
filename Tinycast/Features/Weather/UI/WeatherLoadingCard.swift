import SwiftUI

#if DEBUG
struct WeatherLoadingCard: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PaletteState.self) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            HStack {
                Text("Weather").foregroundStyle(.secondary)
                Spacer()
                block(width: Theme.Weather.overviewWidth, height: Theme.Weather.metricHeight)
                    .foregroundStyle(Theme.Colors.weatherSkeleton)
            }
            .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
            .padding(.horizontal, metrics.spacing.xs)
            placeholders
                .foregroundStyle(Theme.Colors.weatherSkeleton)
                .overlay {
                    if palette.isVisible && !reduceMotion && Motion.isEnabled {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Theme.Weather.shimmerDuration)
                                / Theme.Weather.shimmerDuration
                            let center = phase * 1.6 - 0.3
                            LinearGradient(colors: [.clear, Theme.Colors.weatherShimmer, .clear],
                                           startPoint: UnitPoint(x: center - 0.25, y: 0),
                                           endPoint: UnitPoint(x: center + 0.25, y: 1))
                                .mask(placeholders.foregroundStyle(.white))
                        }
                    }
                }
                .padding(.horizontal, metrics.scaled(Theme.Weather.inset))
                .padding(.vertical, metrics.spacing.xl)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.weatherCardFill,
                            in: RoundedRectangle(cornerRadius: metrics.scaled(Theme.Weather.cornerRadius)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading…"))
        .allowsHitTesting(false)
    }

    private var placeholders: some View {
        VStack(spacing: metrics.spacing.lg) {
            HStack(alignment: .top, spacing: metrics.scaled(Theme.Weather.inset)) {
                VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                    block(height: Theme.Weather.loadingTitleHeight)
                    block(width: Theme.Weather.overviewWidth * 0.7, height: Theme.Weather.loadingLineHeight)
                    HStack {
                        block(width: Theme.Weather.temperatureSize * 1.5, height: Theme.Weather.temperatureSize)
                        Spacer()
                        Circle().fill(.foreground)
                            .frame(width: metrics.scaled(Theme.Weather.overviewIllustration))
                    }
                    .frame(height: metrics.scaled(Theme.Weather.readingHeight))
                    block(width: Theme.Weather.overviewWidth * 0.5, height: Theme.Weather.loadingTitleHeight)
                    block(width: Theme.Weather.overviewWidth * 0.7, height: Theme.Weather.loadingLineHeight)
                    block(width: Theme.Weather.overviewWidth * 0.8, height: Theme.Weather.loadingLineHeight)
                }
                .frame(width: metrics.scaled(Theme.Weather.overviewWidth))
                .padding(.trailing, metrics.scaled(Theme.Weather.inset))
                VStack(alignment: .leading, spacing: metrics.spacing.xxl) {
                    block(width: Theme.Weather.overviewWidth, height: Theme.Weather.metricHeight)
                    HStack(spacing: metrics.spacing.xl) {
                        ForEach(0..<5) { _ in block(height: Theme.Weather.readingHeight) }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(height: metrics.scaled(Theme.Weather.loadingHeight), alignment: .top)
            HStack(spacing: metrics.spacing.xl) {
                ForEach(0..<7) { _ in block(height: Theme.Weather.loadingDayHeight) }
            }
        }
    }

    private func block(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: metrics.radius.keyCap)
            .fill(.foreground)
            .frame(width: width.map { metrics.scaled($0) }, height: metrics.scaled(height))
    }
}
#endif
