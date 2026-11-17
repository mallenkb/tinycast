import Foundation

struct WeatherForecast: Equatable, Sendable {
    let place: String
    let timeZone: TimeZone
    let current: WeatherCurrent
    let hours: [WeatherHour]
    let days: [WeatherDay]
}

struct WeatherCurrent: Equatable, Sendable {
    let time: Date
    let temperature: Double?
    let apparentTemperature: Double?
    let humidity: Double?
    let windSpeed: Double?
    let condition: WeatherCondition
}

struct WeatherHour: Equatable, Sendable {
    let time: Date
    let temperature: Double?
    let condition: WeatherCondition
    let precipitationProbability: Double?
    let precipitation: Double?
    let windSpeed: Double?
    let windGusts: Double?
}

struct WeatherDay: Equatable, Sendable {
    let date: Date
    let high: Double?
    let low: Double?
    let condition: WeatherCondition
    let sunrise: Date?
    let sunset: Date?
    let precipitationProbability: Double?
    let precipitation: Double?
    let windSpeed: Double?
    let windGusts: Double?
}

struct WeatherCondition: Equatable, Sendable {
    let code: Int?
    let isDay: Bool
}
