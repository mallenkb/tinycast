import AppKit
import Darwin

@MainActor
final class MemoryReclaimer {
    private let releaseCaches: () -> Void
    private var monitor: Any?
    private var timer: Timer?
    private var trimming: Task<Void, Never>?

    init(releaseCaches: @escaping () -> Void) {
        self.releaseCaches = releaseCaches
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.schedule()
            return event
        }
        schedule()
    }

    func schedule() {
        let deadline = Date.now.addingTimeInterval(2)
        if let timer {
            timer.fireDate = deadline
            return
        }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaim() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reclaim() {
        timer = nil
        releaseCaches()
        guard trimming == nil else { return }
        trimming = Task { [weak self] in
            await Self.trimAllocator()
            self?.trimming = nil
        }
    }

    @concurrent private static func trimAllocator() async {
        guard !Task.isCancelled else { return }
        malloc_zone_pressure_relief(nil, 0)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        trimming?.cancel()
        trimming = nil
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer?.invalidate()
        trimming?.cancel()
    }
}
