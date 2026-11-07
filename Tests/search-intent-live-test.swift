import Foundation

@main
struct SearchIntentLiveTests {
    static func main() async throws {
        guard SearchIntentResolver.isAvailable else {
            print("SKIP: Apple's on-device model is unavailable")
            return
        }
        let commands = [
            SearchIntent.Command(id: "define", title: "Define Word"),
            SearchIntent.Command(id: "clipboard", title: "Clipboard History"),
            SearchIntent.Command(id: "left", title: "Move Window Left Half"),
            SearchIntent.Command(id: "settings", title: "Settings")
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        var failures = 0
        let queries: [(String, SearchIntent.Context)] = [
            ("links from flaticons", .launcher),
            ("show me the URLs I copied from flaticons", .launcher),
            ("the github links I copied yesterday", .clipboard),
            ("find the screenshot showing memory usage", .launcher),
            ("PDF invoices I modified last week", .files),
            ("PDF invoices I downloaded last week", .files),
            ("PDF invoices not in Downloads", .files),
            ("PDF invoices from two months ago", .files),
            ("PDF invoices Acme 2025", .files),
            ("put this window on the left", .launcher),
            ("look up a word", .launcher),
            ("I need to check what a word means", .launcher),
            ("Safari", .launcher)
        ]
        for (query, context) in queries {
            let start = Date()
            let result = try await SearchIntentResolver.resolve(
                query, context: context, commands: commands,
                websites: ["flaticon.com", "github.com"], now: now, calendar: calendar)
            let passed: Bool
            switch query {
            case "links from flaticons", "show me the URLs I copied from flaticons":
                passed = result?.destination == .clipboard && result?.description?.kind == .links
                    && result?.description?.website == "flaticon.com"
                    && result?.description?.text == "" && result?.description?.dates == nil
            case "the github links I copied yesterday":
                passed = result?.destination == .clipboard && result?.description?.website == "github.com"
                    && result?.description?.dates?.end == calendar.startOfDay(for: now)
                    && result?.description?.text == ""
            case "find the screenshot showing memory usage":
                passed = result?.destination == .clipboard && result?.description?.kind == .images
                    && result?.description?.text.lowercased().contains("memory") == true
                    && result?.description?.website == nil && result?.description?.dates == nil
            case "PDF invoices I modified last week":
                passed = result?.destination == .files && result?.description?.fileExtension == "pdf"
                    && result?.description?.text.lowercased().contains("invoice") == true
                    && result?.description?.dates?.end == calendar.dateInterval(of: .weekOfYear, for: now)?.start
                    && result?.description?.website == nil
            case "PDF invoices Acme 2025":
                passed = result?.description?.text == "invoices Acme 2025"
            case "put this window on the left": passed = result?.commandID == "left"
            case "look up a word", "I need to check what a word means": passed = result?.commandID == "define"
            default: passed = result == nil
            }
            print("\(passed ? "PASS" : "FAIL"): \(query) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
            if !passed { failures += 1; print(String(describing: result)) }
        }
        print("Live intent tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
