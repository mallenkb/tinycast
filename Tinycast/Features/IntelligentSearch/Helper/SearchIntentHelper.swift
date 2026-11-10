import Foundation

@main
nonisolated enum SearchIntentHelper {
    static func main() async {
        do {
            guard let data = try FileHandle.standardInput.readToEnd() else { exit(2) }
            let request = try JSONDecoder().decode(SearchIntentRequest.self, from: data)
            let intent = try await SearchIntentResolver.resolve(
                request.query, context: request.context, commands: request.commands,
                websites: request.websites, now: request.now, calendar: request.calendar)
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(intent))
        } catch {
            exit(1)
        }
    }
}
