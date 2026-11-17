import CoreLocation
import Foundation

@Observable
@MainActor
final class WeatherCoordinator {
    private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    func forecast(for place: WeatherQuery.Place) async throws -> WeatherForecast {
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
