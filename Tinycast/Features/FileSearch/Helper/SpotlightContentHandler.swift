import Foundation

nonisolated enum SpotlightContentHandler {
    static func run() async -> Int32 {
        guard let payload = try? FileHandle.standardInput.readToEnd(),
            let request = try? JSONDecoder().decode(SpotlightContentRequest.self, from: payload)
        else { return 2 }
        let paths: [String]
        if let filters = request.filters {
            paths = await SpotlightContentQuery.paths(filters: filters, scopes: request.scopes)
        } else if let text = request.text {
            paths = await SpotlightContentQuery.paths(matching: text, scopes: request.scopes)
        } else {
            return 2
        }
        var buffer = Data()
        do {
            for path in paths {
                buffer.append(contentsOf: path.utf8)
                buffer.append(0)
                if buffer.count >= 8_192 {
                    try FileHandle.standardOutput.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try FileHandle.standardOutput.write(contentsOf: buffer)
            return 0
        } catch {
            return 1
        }
    }
}
