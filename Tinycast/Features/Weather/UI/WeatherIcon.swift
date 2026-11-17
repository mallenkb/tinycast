import AppKit
import ImageIO
import SwiftUI

#if DEBUG
struct WeatherIcon: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var playback: Playback?

    let condition: WeatherCondition
    let size: CGFloat

    var body: some View {
        let artwork = Artwork(condition)
        let requested = hovered && settings.animationsEnabled && !reduceMotion ? artwork : nil
        Group {
            if let requested, let playback, playback.artwork == requested {
                TimelineView(.animation(minimumInterval: playback.frameInterval)) { context in
                    if let frame = playback.frame(at: context.date) {
                        illustration(frame)
                    } else {
                        stillImage(artwork)
                    }
                }
            } else {
                stillImage(artwork)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .armedHover($hovered)
        .accessibilityElement(children: .ignore)
        .task(id: requested) {
            playback = nil
            guard let requested,
                let url = Bundle.main.url(forResource: requested.rawValue + "-motion",
                    withExtension: "png", subdirectory: "WeatherIcons"),
                let sheet = await Self.loadSheet(url),
                !Task.isCancelled
            else { return }
            playback = Playback(artwork: requested, sheet: sheet, start: Date())
        }
    }

    @ViewBuilder
    private func stillImage(_ artwork: Artwork?) -> some View {
        if let artwork,
            let url = Bundle.main.url(forResource: artwork.rawValue, withExtension: "png",
                subdirectory: "WeatherIcons"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let cropped = image.cropping(to: artwork.crop(in: CGFloat(image.width)))
        {
            illustration(cropped)
        } else {
            SymbolImage(name: "cloud", size: size * 0.45, monochrome: true)
                .foregroundStyle(.secondary)
        }
    }

    private func illustration(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    @concurrent
    private static func loadSheet(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private enum Artwork: String {
        static let frameSize = 96

        case day
        case night
        case partlyCloudyDay = "cloudy-day-1"
        case mostlyCloudyDay = "cloudy-day-2"
        case partlyCloudyNight = "cloudy-night-1"
        case mostlyCloudyNight = "cloudy-night-2"
        case overcast = "cloudy"
        case drizzle = "rainy-4"
        case rain = "rainy-6"
        case snow = "snowy-4"
        case thunder

        init?(_ condition: WeatherCondition) {
            guard let code = condition.code else { return nil }
            switch code {
            case 0: self = condition.isDay ? .day : .night
            case 1: self = condition.isDay ? .partlyCloudyDay : .partlyCloudyNight
            case 2: self = condition.isDay ? .mostlyCloudyDay : .mostlyCloudyNight
            case 3, 45, 48: self = .overcast
            case 51, 53, 55, 56, 57: self = .drizzle
            case 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
            case 71, 73, 75, 77, 85, 86: self = .snow
            case 95, 96, 97, 99: self = .thunder
            default: return nil
            }
        }

        var cycle: TimeInterval {
            switch self {
            case .day, .night, .partlyCloudyNight, .mostlyCloudyNight: 6
            case .partlyCloudyDay, .mostlyCloudyDay: 9
            case .overcast, .thunder: 7
            case .drizzle: 0.88
            case .rain: 0.64
            case .snow: 2
            }
        }

        func crop(in size: CGFloat) -> CGRect {
            let scale = size / CGFloat(Self.frameSize)
            return bounds.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
                .intersection(CGRect(x: 0, y: 0, width: size, height: size))
        }

        private var bounds: CGRect {
            switch self {
            case .day: CGRect(x: 23, y: 24, width: 50, height: 56)
            case .night: CGRect(x: 26, y: 28, width: 46, height: 55)
            case .partlyCloudyDay, .mostlyCloudyDay: CGRect(x: 4, y: 15, width: 81, height: 66)
            case .partlyCloudyNight, .mostlyCloudyNight: CGRect(x: 14, y: 18, width: 75, height: 63)
            case .overcast: CGRect(x: 13, y: 17, width: 72, height: 64)
            case .drizzle, .rain, .snow: CGRect(x: 15, y: 25, width: 67, height: 71)
            case .thunder: CGRect(x: 13, y: 20, width: 70, height: 80)
            }
        }
    }

    private struct Playback {
        private static let columns = 8
        private static let samplesPerSecond = 12.0

        let artwork: Artwork
        let sheet: CGImage
        let start: Date

        var frameInterval: TimeInterval { artwork.cycle / Double(frameCount) }

        private var frameCount: Int { Int(ceil(artwork.cycle * Self.samplesPerSecond)) }

        func frame(at date: Date) -> CGImage? {
            let elapsed = max(0, date.timeIntervalSince(start))
            let index = Int(elapsed / frameInterval) % frameCount
            let size = Artwork.frameSize
            let crop = artwork.crop(in: CGFloat(size))
            return sheet.cropping(to: crop.offsetBy(
                dx: CGFloat((index % Self.columns) * size),
                dy: CGFloat((index / Self.columns) * size)))
        }
    }
}

struct WeatherSunsetIcon: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    let size: CGFloat

    var body: some View {
        let animated = hovered && settings.animationsEnabled && !reduceMotion
        SymbolImage(name: "sunset", size: size * 0.60, monochrome: true)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Theme.Colors.warning)
            .symbolEffect(.bounce.down, value: animated)
            .symbolEffectsRemoved(!animated)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .armedHover($hovered)
            .accessibilityHidden(true)
    }
}
#endif
