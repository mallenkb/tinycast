import CoreLocation
import Foundation

@Observable
@MainActor
final class WeatherCoordinator {
    private struct CachedForecast {
        let forecast: WeatherForecast
        let fetched: Date
        let expires: Date
    }

    private unowned let core: AppCore
    private var cache: [String: CachedForecast] = [:]
    private static let cacheLimit = 16

    init(core: AppCore) {
        self.core = core
    }

    /// One fetch per place per local day; failures are never kept, so Retry always refetches.
    func forecast(for place: WeatherQuery.Place) async throws -> WeatherForecast {
        let key = Self.cacheKey(place)
        if let key, let cached = cache[key], cached.expires > .now { return cached.forecast }
        let forecast = try await fetch(place)
        if let key { store(forecast, for: key) }
        return forecast
    }

    private func store(_ forecast: WeatherForecast, for key: String) {
        let now = Date.now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let midnight = calendar.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        cache = cache.filter { $0.value.expires > now }
        if cache.count >= Self.cacheLimit,
           let oldest = cache.min(by: { $0.value.fetched < $1.value.fetched })?.key {
            cache[oldest] = nil
        }
        cache[key] = CachedForecast(
            forecast: forecast, fetched: now, expires: midnight ?? now.addingTimeInterval(3600))
    }

    private static func cacheKey(_ place: WeatherQuery.Place) -> String? {
        switch place {
        case .city(let city):
            "city:" + city.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .macLocation: "mac"
        case .setup, .missingCity: nil
        }
    }

    private func fetch(_ place: WeatherQuery.Place) async throws -> WeatherForecast {
        switch place {
        case .city(let city):
            try await Task.sleep(for: .milliseconds(400))
            return try await WeatherService.forecast(for: city)
        case .macLocation:
            let location = try await Self.macLocation()
            try Task.checkCancellation()
            return try await WeatherService.forecast(
                latitude: location.latitude, longitude: location.longitude,
                fallbackLabel: String(localized: "Current location"))
        case .setup, .missingCity:
            throw WeatherService.Failure.locationNotFound
        }
    }

    private static func macLocation() async throws -> CLLocationCoordinate2D {
        try await withThrowingTaskGroup(of: CLLocationCoordinate2D.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally
                        || update.authorizationRestricted {
                        throw WeatherService.Failure.locationDenied
                    }
                    if let location = update.location, location.horizontalAccuracy >= 0,
                       abs(location.timestamp.timeIntervalSinceNow) < 120 {
                        return location.coordinate
                    }
                }
                throw WeatherService.Failure.macLocationUnavailable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw WeatherService.Failure.macLocationUnavailable
            }
            defer { group.cancelAll() }
            guard let coordinate = try await group.next() else {
                throw WeatherService.Failure.macLocationUnavailable
            }
            return coordinate
        }
    }

    func showSettings() {
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: .weather, revealing: .section(.weatherWeather))
    }
}
