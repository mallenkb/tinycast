import Darwin
import Foundation

@main
struct SpotlightContentTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func fixture(_ mode: String, marker: String?) async throws {
        if mode == "exit" { exit(3) }
        _ = try FileHandle.standardInput.readToEnd()
        if let marker { try Data("\(getpid())".utf8).write(to: URL(filePath: marker)) }
        switch mode {
        case "paths":
            try FileHandle.standardOutput.write(contentsOf: Data("/tmp/a\nfile.html\0/tmp/café.pdf\0".utf8))
        case "limit", "overflow":
            let count = mode == "limit" ? 2_000 : 2_001
            var output = Data()
            for index in 0..<count { output.append(contentsOf: "/tmp/\(index)\0".utf8) }
            try FileHandle.standardOutput.write(contentsOf: output)
        case "unterminated":
            try FileHandle.standardOutput.write(contentsOf: Data("/tmp/unfinished".utf8))
        case "long":
            try FileHandle.standardOutput.write(contentsOf: Data(("/" + String(repeating: "a", count: 4_096) + "\0").utf8))
        case "hold":
            try await Task.sleep(for: .seconds(30))
        default:
            exit(2)
        }
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--real-helper" {
            exit(await SpotlightContentHandler.run())
        }
        if arguments.count > 2, arguments[1] == "--fixture" {
            try await fixture(arguments[2], marker: arguments.count > 3 ? arguments[3] : nil)
            return
        }
        let executable = URL(filePath: arguments[0]).standardizedFileURL
        let scratch = FileManager.default.temporaryDirectory.appending(path: "spotlight-content-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let request = SpotlightContentRequest(text: "project", filters: nil, scopes: [scratch.path])
        let completedMarker = scratch.appending(path: "completed-pid")
        let paths = try await SpotlightContentSearch.run(
            request, executable: executable, arguments: ["--fixture", "paths", completedMarker.path])
        expect(paths == ["/tmp/a\nfile.html", "/tmp/café.pdf"], "NUL-delimited paths survive newlines and Unicode")
        guard let completedPID = Int32(try String(contentsOf: completedMarker, encoding: .utf8)) else {
            fatalError("Completed helper did not report its process ID")
        }
        expect(kill(completedPID, 0) == -1 && errno == ESRCH, "completed helper was reaped")
        let maximum = try await SpotlightContentSearch.run(request, executable: executable, arguments: ["--fixture", "limit"])
        expect(maximum.count == 2_000, "the complete candidate limit is accepted")
        for mode in ["overflow", "unterminated", "long"] {
            do {
                _ = try await SpotlightContentSearch.run(request, executable: executable, arguments: ["--fixture", mode])
                fatalError("Malformed helper output accepted: \(mode)")
            } catch SpotlightContentSearch.Failure.output {}
        }
        let oversized = SpotlightContentRequest(
            text: "project", filters: nil, scopes: ["/" + String(repeating: "a", count: 1_000_000)])
        do {
            _ = try await SpotlightContentSearch.run(oversized, executable: executable, arguments: ["--fixture", "exit"])
            fatalError("An exited helper was accepted")
        } catch SpotlightContentSearch.Failure.output {}

        var single = SearchFileConstraints()
        single.category = .files
        single.content = ["project"]
        var format = single
        format.extensions = ["pdf"]
        var formats = single
        formats.extensions = ["pdf", "html"]
        var all = single
        all.content = ["project", "meeting"]
        all.textMode = .all
        var any = all
        any.textMode = .any
        var tag = single
        tag.tags = ["Work"]
        var tags = tag
        tags.tags = ["Work", "Tax"]
        tags.allTags = false
        var dates = format
        dates.modified = .init(start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_086_400))
        dates.excludedExtensions = ["txt"]
        let cases = [single, format, formats, all, any, tag, tags, dates]
        for filters in cases {
            let request = SpotlightContentRequest(text: nil, filters: filters, scopes: [scratch.path])
            let decoded = try JSONDecoder().decode(SpotlightContentRequest.self, from: JSONEncoder().encode(request))
            expect(decoded.filters == filters, "structured filters survive the helper boundary")
            let results = try await SpotlightContentSearch.run(request, executable: executable, arguments: ["--real-helper"])
            expect(results.isEmpty, "an empty scope has no matches")
        }
        let plain = try await SpotlightContentSearch.run(request, executable: executable, arguments: ["--real-helper"])
        expect(plain.isEmpty, "unstructured content search completes")

        let marker = scratch.appending(path: "child-pid")
        let task = Task {
            try await SpotlightContentSearch.run(
                request, executable: executable, arguments: ["--fixture", "hold", marker.path])
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pid = Int32(try String(contentsOf: marker, encoding: .utf8)) else {
            fatalError("Helper did not start")
        }
        task.cancel()
        do {
            _ = try await task.value
            fatalError("Cancelled helper returned results")
        } catch is CancellationError {}
        expect(kill(pid, 0) == -1 && errno == ESRCH, "cancelled helper was terminated and reaped")
        let timeoutMarker = scratch.appending(path: "timed-out-pid")
        do {
            _ = try await SpotlightContentSearch.run(
                request, executable: executable, arguments: ["--fixture", "hold", timeoutMarker.path])
            fatalError("A timed-out helper returned results")
        } catch SpotlightContentSearch.Failure.output {}
        guard let timedOutPID = Int32(try String(contentsOf: timeoutMarker, encoding: .utf8)) else {
            fatalError("Timed-out helper did not start")
        }
        expect(kill(timedOutPID, 0) == -1 && errno == ESRCH, "timed-out helper was terminated and reaped")
        print("Spotlight content checks passed")
    }
}
