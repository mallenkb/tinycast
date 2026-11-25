import AppKit
import Darwin
import os

@MainActor
final class MemoryReclaimer {
    private let activity: () -> String?
    private let releaseHiddenView: () -> Void
    private let releaseCaches: () -> Void
    private var monitor: Any?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private var nextSample: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    private var trimming: Task<Void, Never>?
    private var lastReport: AppMemorySample?
    private var nextTrim = ContinuousClock.now
    private var lastTrimFootprint: UInt64?
    private var pressureReliefPending = false

    init(activity: @escaping () -> String?, releaseHiddenView: @escaping () -> Void, releaseCaches: @escaping () -> Void) {
        self.activity = activity
        self.releaseHiddenView = releaseHiddenView
        self.releaseCaches = releaseCaches
    }

    func start() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.pressureChanged() }
        pressureSource = source
        source.activate()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.schedule()
            return event
        }
        sampleLater(overBudget: false)
        schedule()
    }

    private func pressureChanged() {
        guard let event = pressureSource?.data else { return }
        pressureReliefPending = !event.isDisjoint(with: [.warning, .critical])
        if pressureReliefPending { sample() }
    }

    private func sampleLater(overBudget: Bool) {
        nextSample?.cancel()
        nextSample = Task(priority: .utility) { [weak self] in
            let delay = Duration.seconds(overBudget ? 60 : 600)
            do { try await Task.sleep(for: delay, tolerance: delay / 5) } catch { return }
            self?.sample()
        }
    }

    private func sample() {
        guard pressureSource != nil else { return }
        sampling?.cancel()
        sampling = Task(priority: .utility) { [weak self] in
            let sample = await AppMemorySample.capture()
            guard !Task.isCancelled, let self else { return }
            sampling = nil
            if let sample { check(sample) }
            sampleLater(overBudget: sample?.isOverBudget == true)
        }
    }

    private func check(_ sample: AppMemorySample) {
        let activity = activity()
        if sample.record(activity: activity, since: lastReport) { lastReport = sample }
        guard activity == nil, timer == nil, trimming == nil else { return }
        guard pressureReliefPending || sample.isAboveIdleTarget else { return }
        if let lastTrimFootprint, !pressureReliefPending, ContinuousClock.now < nextTrim,
            sample.footprint < lastTrimFootprint + 10_000_000 { return }

        let underPressure = pressureReliefPending
        pressureReliefPending = false
        nextTrim = .now.advanced(by: .seconds(600))
        lastTrimFootprint = sample.footprint
        autoreleasepool { releaseCaches() }
        trimming = Task(priority: .utility) { [weak self] in
            let after = await Self.trimAllocator(for: sample, underPressure: underPressure)
            guard !Task.isCancelled else { return }
            if let after { self?.lastTrimFootprint = after }
            self?.trimming = nil
        }
    }

    func schedule() {
        guard pressureSource != nil else { return }
        let deadline = Date.now.addingTimeInterval(2)
        if let timer {
            timer.fireDate = deadline
            return
        }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.didSettle() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func didSettle() {
        timer = nil
        autoreleasepool { releaseHiddenView() }
        if activity() == nil { sample() }
    }

    @concurrent private static func trimAllocator(for sample: AppMemorySample, underPressure: Bool) async -> UInt64? {
        guard !Task.isCancelled, let current = AppMemorySample.virtualMemory()?.phys_footprint else { return nil }
        let goal = underPressure ? 0 : sample.allocatorGoal(currentFootprint: current)
        var released = 0
        if underPressure || goal > 0 { released = malloc_zone_pressure_relief(nil, goal) }
        guard let after = AppMemorySample.virtualMemory()?.phys_footprint else { return nil }
        Logger(subsystem: "com.tinycast.app", category: "Memory").notice("""
            Idle cleanup bytes: appBefore=\(sample.footprint) appAfter=\(after) allocatorReleased=\(released)
            """)
        return after
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressureSource?.cancel()
        pressureSource = nil
        pressureReliefPending = false
        timer?.invalidate()
        timer = nil
        nextSample?.cancel()
        nextSample = nil
        sampling?.cancel()
        sampling = nil
        trimming?.cancel()
        trimming = nil
        lastReport = nil
        lastTrimFootprint = nil
        nextTrim = .now
    }

    isolated deinit { stop() }
}
