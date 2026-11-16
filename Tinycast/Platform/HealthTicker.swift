import Foundation

@MainActor
protocol HealthCheckable: AnyObject {
    /// True when the check found nothing to repair and nothing left to wait for.
    func healthCheck() -> Bool
}

/// The taps' shared watchdog: 1 s after trouble, 5 s after a clean run, no timer when unsubscribed.
@MainActor
final class HealthTicker {
    private struct WeakSubscriber {
        weak var value: (any HealthCheckable)?
    }

    private static let watchfulInterval: TimeInterval = 1
    private static let calmInterval: TimeInterval = 5
    private static let cleanTicksBeforeCalm = 10

    private var subscribers: [ObjectIdentifier: WeakSubscriber] = [:]
    private var timer: Timer?
    private var cleanTicks = 0

    func subscribe(_ subscriber: any HealthCheckable) {
        let key = ObjectIdentifier(subscriber)
        guard subscribers.updateValue(WeakSubscriber(value: subscriber), forKey: key)?.value == nil
        else { return }
        wake()
    }

    func unsubscribe(_ subscriber: any HealthCheckable) {
        subscribers.removeValue(forKey: ObjectIdentifier(subscriber))
        stopIfIdle()
    }

    /// A tap just failed or was re-enabled, so the next disable is likelier: check every second.
    func wake() {
        cleanTicks = 0
        schedule(every: Self.watchfulInterval)
    }

    private func tick() {
        var isClean = true
        for (key, subscriber) in subscribers {
            guard let value = subscriber.value else {
                subscribers.removeValue(forKey: key)
                continue
            }
            if !value.healthCheck() { isClean = false }
        }
        guard !stopIfIdle() else { return }
        guard isClean else {
            wake()
            return
        }
        cleanTicks += 1
        if cleanTicks >= Self.cleanTicksBeforeCalm { schedule(every: Self.calmInterval) }
    }

    private func schedule(every interval: TimeInterval) {
        guard !subscribers.isEmpty, timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Recovery, not latency: tolerance lets the kernel coalesce the idle wakeup.
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    private func stopIfIdle() -> Bool {
        guard subscribers.isEmpty else { return false }
        timer?.invalidate()
        timer = nil
        return true
    }
}
