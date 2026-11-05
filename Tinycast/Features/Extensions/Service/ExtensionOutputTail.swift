import Foundation

/// The lock guards captured bytes; the semaphore signals EOF from the pipe reader.
final class ExtensionOutputTail: @unchecked Sendable {
    private static let limit = 64 * 1024
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let suffix = chunk.suffix(Self.limit)
        let overflow = data.count + suffix.count - Self.limit
        if overflow > 0 { data.removeSubrange(data.startIndex..<(data.startIndex + overflow)) }
        suffix.withUnsafeBytes { bytes in
            data.append(bytes.bindMemory(to: UInt8.self))
        }
    }

    func finish() {
        ended.signal()
    }

    func text(until deadline: DispatchTime = .now() + .seconds(1)) -> String {
        _ = ended.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        return data.withUnsafeBytes { bytes in
            String(decoding: bytes, as: Unicode.UTF8.self)
        }
    }
}
