import Foundation
import SQLite3

struct WeatherPlace: Sendable {
    let label: String
    let latitude: Double
    let longitude: Double
}

enum WeatherPlaces {
    @concurrent
    static func suggestions(for query: String) async throws -> [WeatherPlace] {
        let (name, qualifier) = terms(query)
        guard (2...100).contains(name.count) else { return [] }
        return try withStatement("""
            SELECT c.label, c.latitude, c.longitude
            FROM name n JOIN city c ON c.id = n.city
            WHERE n.key >= ?1 AND n.key < ?1 || ?3
                AND (?2 = '' OR ?2 = substr(c.country, 1, length(?2))
                    OR ?2 = substr(c.region, 1, length(?2))
                    OR ?2 = substr(c.region_ascii, 1, length(?2))
                    OR ?2 = substr(c.qualifier, 1, length(?2))
                    OR ?2 IN (c.country_code, c.region_code))
            GROUP BY c.id
            ORDER BY max(n.key = ?1) DESC, min(n.rank), c.population DESC, c.id LIMIT 12
            """) { statement in
            bind(name, at: 1, to: statement)
            bind(qualifier, at: 2, to: statement)
            bind("\u{10FFFF}", at: 3, to: statement)
            var places: [WeatherPlace] = []
            var labels: Set<String> = []
            while let place = try next(statement) {
                try Task.checkCancellation()
                if labels.insert(place.label).inserted { places.append(place) }
            }
            return places
        }
    }

    static func find(_ location: String) throws -> WeatherPlace? {
        let (name, qualifier) = terms(location)
        guard !name.isEmpty else { return nil }
        return try withStatement("""
            SELECT c.label, c.latitude, c.longitude, -1 AS rank, c.population, c.id
            FROM country_capital k JOIN city c ON c.id = k.city
            WHERE ?2 = '' AND k.key = ?1
            UNION ALL
            SELECT c.label, c.latitude, c.longitude, n.rank, c.population, c.id
            FROM name n JOIN city c ON c.id = n.city
            WHERE n.key = ?1 AND (?2 = '' OR ?2 IN
                (c.country, c.region, c.region_ascii, c.country_code, c.region_code, c.qualifier))
            ORDER BY rank, population DESC, id LIMIT 1
            """) { statement in
            bind(name, at: 1, to: statement)
            bind(qualifier, at: 2, to: statement)
            return try next(statement)
        }
    }

    private static func terms(_ query: String) -> (name: String, qualifier: String) {
        let parts = query.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        return (parts.first.map { key(String($0)) } ?? "", parts.dropFirst().first.map { key(String($0)) } ?? "")
    }

    static func nearest(latitude: Double, longitude: Double) throws -> String? {
        try withStatement("""
            SELECT label, latitude, longitude FROM city
            WHERE latitude BETWEEN ?1 - 0.75 AND ?1 + 0.75
                AND min(abs(longitude - ?2), 360 - abs(longitude - ?2)) <= 5
            """) { statement in
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, longitude)
            let radians = Double.pi / 180
            let latitudeCosine = cos(latitude * radians)
            var closest: String?
            var distance = pow(sin(0.35 * radians), 2)
            while let city = try next(statement) {
                try Task.checkCancellation()
                let score = pow(sin((city.latitude - latitude) * radians / 2), 2)
                    + latitudeCosine * cos(city.latitude * radians)
                    * pow(sin((city.longitude - longitude) * radians / 2), 2)
                if score < distance {
                    closest = city.label
                    distance = score
                }
            }
            return closest
        }
    }

    private static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .decomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
            .map(String.init).joined()
    }

    private static func bind(_ text: String, at index: Int32, to statement: OpaquePointer) {
        _ = sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func next(_ statement: OpaquePointer) throws -> WeatherPlace? {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let label = sqlite3_column_text(statement, 0) else { throw WeatherService.Failure.unavailable }
            return WeatherPlace(label: String(cString: label),
                                latitude: sqlite3_column_double(statement, 1),
                                longitude: sqlite3_column_double(statement, 2))
        case SQLITE_DONE: return nil
        default: throw WeatherService.Failure.unavailable
        }
    }

    private static func withStatement<Result>(
        _ sql: String, _ read: (OpaquePointer) throws -> Result
    ) throws -> Result {
        guard let url = Bundle.main.url(forResource: "WeatherPlaces", withExtension: "sqlite")
        else { throw WeatherService.Failure.unavailable }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { throw WeatherService.Failure.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw WeatherService.Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        return try read(statement)
    }
}
