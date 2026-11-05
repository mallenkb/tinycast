import Foundation

@main struct ExtensionOutputTailTests {
    private static let limit = 64 * 1024

    static func main() {
        let empty = ExtensionOutputTail()
        empty.append(Data())
        empty.finish()
        precondition(empty.text().isEmpty)

        let split = ExtensionOutputTail()
        let bytes = Data("hello 😀 world".utf8)
        for byte in bytes { split.append(Data([byte])) }
        split.finish()
        precondition(split.text() == "hello 😀 world")

        let capped = ExtensionOutputTail()
        capped.append(Data(repeating: 65, count: 100_000))
        capped.append(Data("last line".utf8))
        capped.finish()
        let text = capped.text()
        precondition(text.utf8.count == limit)
        precondition(text.hasSuffix("last line"))

        let unicode = ExtensionOutputTail()
        let unicodeBytes = Data(String(repeating: "a😀", count: 20_000).utf8)
        unicode.append(unicodeBytes)
        unicode.finish()
        precondition(unicode.text() == "\u{FFFD}" + String(repeating: "a😀", count: 13_107))

        let slice = ExtensionOutputTail()
        let source = Data(repeating: 67, count: 100_000) + Data("sliced end".utf8)
        slice.append(source.dropFirst(50_000))
        slice.finish()
        precondition(slice.text() == String(repeating: "C", count: 50_000) + "sliced end")

        let pending = ExtensionOutputTail()
        pending.append(Data("child inherited stdout".utf8))
        let start = DispatchTime.now().uptimeNanoseconds
        precondition(pending.text(until: .now() + .milliseconds(20)) == "child inherited stdout")
        precondition(DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000)

        let delayed = ExtensionOutputTail()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            delayed.append(Data("final bytes before EOF".utf8))
            delayed.finish()
        }
        precondition(delayed.text(until: .now() + .seconds(2)) == "final bytes before EOF")

        let streamed = ExtensionOutputTail()
        let chunk = Data(repeating: 66, count: 16 * 1024)
        var streamFootprint: UInt64 = 0
        for index in 0..<8192 {
            streamed.append(chunk)
            if index.isMultiple(of: 256) { streamFootprint = max(streamFootprint, footprint()) }
        }
        streamed.finish()
        precondition(streamed.text() == String(repeating: "B", count: limit))
        precondition(streamFootprint < 16 * 1024 * 1024)

        let oversized = ExtensionOutputTail()
        oversized.append(Data("prefix".utf8))
        appendMappedChunk(to: oversized)
        oversized.finish()
        precondition(oversized.text() == String(repeating: "D", count: limit))
        let retainedFootprint = footprint()
        precondition(retainedFootprint < 16 * 1024 * 1024)

        let concurrent = ExtensionOutputTail()
        DispatchQueue.concurrentPerform(iterations: 4) { writer in
            let chunk = Data(repeating: UInt8(65 + writer), count: 1024)
            for index in 0..<4096 {
                concurrent.append(chunk)
                guard index.isMultiple(of: 64) else { continue }
                let snapshot = concurrent.text(until: .now())
                precondition(snapshot.utf8.count <= limit)
                precondition(snapshot.utf8.allSatisfy { (65...68).contains($0) })
            }
        }
        concurrent.append(Data("all writers finished".utf8))
        concurrent.finish()
        let concurrentText = concurrent.text()
        precondition(concurrentText.utf8.count == limit)
        precondition(concurrentText.hasSuffix("all writers finished"))

        print("Output tail passed UTF-8, truncation, deadlines, delayed EOF and concurrent writers")
        print("128 MiB stream footprint: \(streamFootprint) bytes; oversized chunk retained: \(retainedFootprint) bytes")
    }

    @inline(never)
    private static func appendMappedChunk(to tail: ExtensionOutputTail) {
        let size = 64 * 1024 * 1024
        let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
        precondition(pointer != MAP_FAILED)
        memset(pointer, 68, size)
        // Unmapping excludes the producer's allocation from the tail's retained-memory measurement.
        tail.append(Data(bytesNoCopy: pointer, count: size, deallocator: .custom { pointer, size in
            precondition(munmap(pointer, size) == 0)
        }))
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return info.phys_footprint
    }
}
