import Foundation

enum WeatherService {
    enum Failure: Error {
        case locationNotFound
        case locationDenied
        case macLocationUnavailable
        case unavailable
    }

    @concurrent
    static func forecast(for location: String) async throws -> WeatherForecast {
        guard let place = try WeatherPlaces.find(location) else { throw Failure.locationNotFound }
        return try await forecast(for: place)
    }

    @concurrent
    static func forecast(latitude: Double, longitude: Double, fallbackLabel: String) async throws -> WeatherForecast {
        let label = try WeatherPlaces.nearest(latitude: latitude, longitude: longitude) ?? fallbackLabel
        return try await forecast(for: WeatherPlace(
            label: label, latitude: (latitude * 100).rounded() / 100,
            longitude: (longitude * 100).rounded() / 100))
    }

    private static func forecast(for place: WeatherPlace) async throws -> WeatherForecast {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let forecastURL = endpoint("api.open-meteo.com", path: "/v1/forecast", parameters: [
            "latitude": String(place.latitude),
            "longitude": String(place.longitude),
            "timezone": "auto",
            "timeformat": "unixtime",
            "forecast_days": "16",
            "temperature_unit": "celsius",
            "wind_speed_unit": "kmh",
            "precipitation_unit": "mm",
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day",
            "hourly": "temperature_2m,weather_code,is_day,precipitation_probability,precipitation,wind_speed_10m,wind_gusts_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,"
                + "precipitation_probability_max,precipitation_sum,wind_speed_10m_max,wind_gusts_10m_max",
        ])
        let forecast: ForecastResponse = try await response(from: forecastURL, using: session)
        try Task.checkCancellation()
        guard let timeZone = TimeZone(identifier: forecast.timezone),
              !forecast.hourly.time.isEmpty, !forecast.daily.time.isEmpty
        else { throw Failure.unavailable }

        return WeatherForecast(
            place: place.label,
            timeZone: timeZone,
            current: forecast.current.reading,
            hours: forecast.hourly.readings,
            days: forecast.daily.readings)
    }

    private static func endpoint(_ host: String, path: String, parameters: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    private static func response<Value: Decodable>(from url: URL?, using session: URLSession) async throws -> Value {
        guard let url else { throw Failure.unavailable }
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200
            else { throw Failure.unavailable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Value.self, from: data)
        } catch {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
    }
}

private struct ForecastResponse: Decodable {
    let timezone: String
    let current: Current
    let hourly: Hourly
    let daily: Daily

    struct Current: Decodable {
        let time: Date
        let temperature2m: Double?
        let apparentTemperature: Double?
        let relativeHumidity2m: Double?
        let windSpeed10m: Double?
        let weatherCode: Int?
        let isDay: Int?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case relativeHumidity2m = "relative_humidity_2m"
            case windSpeed10m = "wind_speed_10m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }

        var reading: WeatherCurrent {
            WeatherCurrent(
                time: time,
                temperature: temperature2m,
                apparentTemperature: apparentTemperature,
                humidity: relativeHumidity2m,
                windSpeed: windSpeed10m,
                condition: WeatherCondition(code: weatherCode, isDay: isDay != 0))
        }
    }

    struct Hourly: Decodable {
        let time: [Date]
        let temperature2m: [Double?]?
        let weatherCode: [Int?]?
        let isDay: [Int?]?
        let precipitationProbability: [Double?]?
        let precipitation: [Double?]?
        let windSpeed10m: [Double?]?
        let windGusts10m: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case isDay = "is_day"
            case precipitationProbability = "precipitation_probability"
            case windSpeed10m = "wind_speed_10m"
            case windGusts10m = "wind_gusts_10m"
        }

        var readings: [WeatherHour] {
            time.enumerated().map { index, date in
                WeatherHour(
                    time: date,
                    temperature: temperature2m?.value(at: index),
                    condition: WeatherCondition(
                        code: weatherCode?.value(at: index),
                        isDay: isDay?.value(at: index) != 0),
                    precipitationProbability: precipitationProbability?.value(at: index),
                    precipitation: precipitation?.value(at: index),
                    windSpeed: windSpeed10m?.value(at: index),
                    windGusts: windGusts10m?.value(at: index))
            }
        }
    }

    struct Daily: Decodable {
        let time: [Date]
        let weatherCode: [Int?]?
        let temperature2mMax: [Double?]?
        let temperature2mMin: [Double?]?
        let sunrise: [Date?]?
        let sunset: [Date?]?
        let precipitationProbabilityMax: [Double?]?
        let precipitationSum: [Double?]?
        let windSpeed10mMax: [Double?]?
        let windGusts10mMax: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time, sunrise, sunset
            case weatherCode = "weather_code"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case precipitationSum = "precipitation_sum"
            case windSpeed10mMax = "wind_speed_10m_max"
            case windGusts10mMax = "wind_gusts_10m_max"
        }

        var readings: [WeatherDay] {
            time.enumerated().map { index, date in
                WeatherDay(
                    date: date,
                    high: temperature2mMax?.value(at: index),
                    low: temperature2mMin?.value(at: index),
                    condition: WeatherCondition(code: weatherCode?.value(at: index), isDay: true),
                    sunrise: sunrise?.value(at: index),
                    sunset: sunset?.value(at: index),
                    precipitationProbability: precipitationProbabilityMax?.value(at: index),
                    precipitation: precipitationSum?.value(at: index),
                    windSpeed: windSpeed10mMax?.value(at: index),
                    windGusts: windGusts10mMax?.value(at: index))
            }
        }
    }
}

extension Array {
    fileprivate func value<Value>(at index: Int) -> Value? where Element == Value? {
        indices.contains(index) ? self[index] : nil
    }
}
