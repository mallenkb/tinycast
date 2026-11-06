import AVFAudio
import Foundation
import Observation

@main
@MainActor
struct DictionarySpeechSessionTests {
    @MainActor private final class Engine: DictionarySpeechSession.Engine {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        var utterance: AVSpeechUtterance?
        var stops = 0
        func speak(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
            stops += 1
            utterance = nil
            return true
        }
        func finish(cancelled: Bool = false) {
            guard let utterance else { return }
            if cancelled {
                delegate?.speechSynthesizer?(callbackEngine, didCancel: utterance)
            } else {
                delegate?.speechSynthesizer?(callbackEngine, didFinish: utterance)
            }
        }
    }
    @MainActor private final class Fixture {
        var available = catalog
        var discoveries = 0
        var creations = 0
        var utterances: [(String, String, Float)] = []
        var unavailable = false
        weak var latest: Engine?
        weak var utterance: AVSpeechUtterance?
        func discover() -> [DictionarySpeechVoice] { discoveries += 1; return available }
        func engine() -> any DictionarySpeechSession.Engine {
            let engine = Engine()
            latest = engine
            creations += 1
            return engine
        }
        func makeUtterance(_ text: String, voice: DictionarySpeechVoice, rate: Float) throws -> AVSpeechUtterance {
            if unavailable { throw URLError(.resourceUnavailable) }
            utterances.append((text, voice.id, rate))
            let value = AVSpeechUtterance(string: text)
            value.rate = rate
            utterance = value
            return value
        }
        func session(
            center: NotificationCenter = NotificationCenter(),
            release: @escaping @MainActor () -> Void = {}
        ) -> DictionarySpeechSession {
            DictionarySpeechSession(
                discover: { await self.discover() }, makeEngine: engine,
                makeUtterance: makeUtterance, notificationCenter: center, onResourcesReleased: release)
        }
    }
    @MainActor private final class Gate {
        var waits: [CheckedContinuation<[DictionarySpeechVoice], Never>?] = []
        func load() async -> [DictionarySpeechVoice] {
            await withCheckedContinuation { waits.append($0) }
        }
        func finish(_ voices: [DictionarySpeechVoice], at index: Int) {
            let value = waits[index]
            waits[index] = nil
            value?.resume(returning: voices)
        }
    }
    @MainActor private final class Flag { var value = false }
    private static let callbackEngine = AVSpeechSynthesizer()
    private static let us = DictionarySpeechVoice(id: "us", name: "US", language: "en-US", quality: 1)
    private static let uk = DictionarySpeechVoice(id: "uk", name: "UK", language: "en-GB", quality: 1)
    private static let catalog = [us, uk, DictionarySpeechVoice(id: "fr", name: "FR", language: "fr-FR", quality: 3)]
    private static var passes = 0
    private static var failures = 0
    private static func expect(_ condition: Bool, _ message: String) {
        if condition { passes += 1 } else { failures += 1; print("FAIL: \(message)") }
    }
    private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(false, "operation completed within its deadline")
    }
    private static func catalogLifecycle() async {
        let fixture = Fixture()
        let session = fixture.session()
        expect(fixture.discoveries == 0, "constructing the session does not enumerate voices")
        expect(fixture.creations == 0, "constructing the session does not create an engine")
        expect(session.voices.isEmpty && session.selectedVoice == nil, "voice metadata starts empty")
        expect(!session.slow && !session.isPlaying && !session.loading, "initial state is idle at normal speed")
        session.togglePlayback()
        expect(fixture.creations == 0, "an empty term cannot initialize speech")
        session.prepare(term: " library ")
        expect(session.term == "library", "preparation trims the term")
        expect(session.loading, "first discovery is observable as loading")
        await wait { !session.loading }
        expect(fixture.discoveries == 1, "first preparation enumerates once")
        expect(session.voices == [us, uk], "only preferred English regional voices are exposed")
        expect(session.selectedVoice == us, "US is the initial preferred voice")
        expect(fixture.creations == 0 && fixture.utterances.isEmpty, "discovery does not prepare speech")
        let changed = Flag()
        withObservationTracking { _ = session.selectedVoice } onChange: {
            Task { @MainActor in changed.value = true }
        }
        session.selectVoice(id: uk.id)
        await wait { changed.value }
        expect(session.selectedVoice == uk, "selection updates observable voice state")
        session.selectVoice(id: "missing")
        expect(session.selectedVoice == uk, "unknown voice selections are ignored")
        session.prepare(term: "another")
        expect(session.selectedVoice == uk, "word changes preserve the selected accent")
        expect(fixture.discoveries == 1, "word changes reuse small voice metadata")
        session.reset()
        expect(session.term.isEmpty && !session.isPlaying, "reset clears the word and playback")
        expect(session.voices == [us, uk] && session.selectedVoice == uk, "reset preserves voices and selection")
        session.prepare(term: "next")
        expect(!session.loading && fixture.discoveries == 1, "reopening uses the discovered inventory")
        session.retry()
        await wait { !session.loading }
        expect(fixture.discoveries == 2, "retry refreshes installed voices")
        expect(session.selectedVoice == uk, "refresh preserves an installed selected voice")
        fixture.available = [us]
        session.retry()
        await wait { !session.loading }
        expect(session.selectedVoice == us, "a removed voice falls back to an available voice")
    }
    private static func playbackLifecycle() async {
        let fixture = Fixture()
        var releases = 0
        let session = fixture.session { releases += 1 }
        session.prepare(term: "library")
        await wait { !session.loading }
        session.togglePlayback()
        expect(session.isPlaying && fixture.creations == 1, "Play lazily creates one engine")
        expect(fixture.utterances.last?.0 == "library", "the displayed word is spoken")
        expect(fixture.utterances.last?.1 == us.id, "the selected voice reaches utterance creation")
        expect(fixture.utterance?.rate == AVSpeechUtteranceDefaultSpeechRate, "normal speed uses Apple's default rate")
        expect(fixture.latest?.delegate != nil, "playback owns a completion delegate")
        var oldEngine = fixture.latest
        let oldCompletion = oldEngine?.delegate
        var oldUtterance = fixture.utterance
        session.slow = true
        expect(fixture.creations == 2 && session.isPlaying, "changing speed restarts the word")
        expect(oldEngine?.stops == 1 && oldEngine?.delegate == nil, "speed change stops and detaches the old engine")
        expect(fixture.utterance?.rate == AVSpeechUtteranceDefaultSpeechRate * 0.75, "slow speed applies to the new utterance")
        expect(oldUtterance?.rate == AVSpeechUtteranceDefaultSpeechRate, "an enqueued utterance is never mutated")
        oldCompletion?.speechSynthesizer?(callbackEngine, didFinish: oldUtterance!)
        oldEngine = nil
        oldUtterance = nil
        try? await Task.sleep(for: .milliseconds(10))
        expect(session.isPlaying, "a stale completion cannot cancel the restarted word")
        let prior = fixture.creations
        session.slow = true
        expect(fixture.creations == prior, "assigning the same speed does not restart speech")
        let beforeFinish = releases
        fixture.latest?.finish()
        await wait { !session.isPlaying }
        expect(fixture.latest == nil && fixture.utterance == nil, "completion releases engine and utterance")
        expect(releases > beforeFinish, "completion schedules resource relief")
        session.togglePlayback()
        session.togglePlayback()
        expect(!session.isPlaying && fixture.latest == nil, "Stop releases the engine immediately")
        session.togglePlayback()
        fixture.latest?.finish(cancelled: true)
        await wait { !session.isPlaying }
        expect(fixture.latest == nil && session.error == nil, "native cancellation releases without an error")
        session.togglePlayback()
        session.selectVoice(id: uk.id)
        expect(!session.isPlaying && fixture.latest == nil, "changing voice stops current speech")
        session.togglePlayback()
        expect(fixture.utterances.last?.1 == uk.id, "the next play uses the new voice")
        session.prepare(term: "run")
        expect(!session.isPlaying && fixture.latest == nil, "changing word releases current speech")
        session.togglePlayback()
        session.reset()
        expect(fixture.latest == nil && fixture.utterance == nil, "closing releases all playback resources")
    }
    private static func discoveryCancellation() async {
        let gate = Gate()
        let fixture = Fixture()
        var session: DictionarySpeechSession? = DictionarySpeechSession(
            discover: { await gate.load() }, makeEngine: fixture.engine, makeUtterance: fixture.makeUtterance)
        session?.prepare(term: "old")
        await wait { gate.waits.count == 1 }
        session?.prepare(term: "new")
        expect(gate.waits.count == 1, "typing while discovering does not duplicate inventory work")
        gate.finish(catalog, at: 0)
        await wait { session?.loading == false }
        expect(session?.term == "new" && session?.voices == [us, uk], "inventory applies to the current word")
        session?.retry()
        await wait { gate.waits.count == 2 }
        session?.reset()
        gate.finish([], at: 1)
        try? await Task.sleep(for: .milliseconds(10))
        expect(session?.voices == [us, uk], "a canceled refresh cannot erase cached voices")
        session?.prepare(term: "next")
        expect(session?.loading == false, "canceling a refresh preserves the prior successful inventory")
        session?.retry()
        await wait { gate.waits.count == 3 }
        weak let owner = session
        session = nil
        expect(owner == nil, "pending discovery does not retain its owner")
        gate.finish(catalog, at: 2)
    }
    private static func errorsAndTeardown() async {
        let fixture = Fixture()
        fixture.available = []
        var session: DictionarySpeechSession? = fixture.session()
        session?.prepare(term: "library")
        await wait { session?.loading == false }
        session?.togglePlayback()
        expect(session?.voices.isEmpty == true && fixture.creations == 0, "absent installed voices never initialize speech")
        fixture.available = catalog
        session?.retry()
        await wait { session?.loading == false }
        expect(session?.voices == [us, uk], "retry can discover newly installed voices")
        fixture.unavailable = true
        session?.togglePlayback()
        expect(session?.error != nil && session?.isPlaying == false, "a disappeared voice produces a playback error")
        expect(fixture.creations == 0, "voice resolution failure never creates an engine")
        session?.reset()
        expect(session?.error == nil, "closing clears the playback error")
        fixture.unavailable = false
        session?.prepare(term: "library")
        session?.togglePlayback()
        expect(session?.isPlaying == true, "playback can recover after a voice error")
        weak let owner = session
        session = nil
        expect(owner == nil && fixture.latest == nil && fixture.utterance == nil, "owner teardown stops and releases speech")
    }
    private static func inventoryNotifications() async {
        let center = NotificationCenter()
        let fixture = Fixture()
        fixture.available = [us]
        var session: DictionarySpeechSession? = fixture.session(center: center)
        session?.prepare(term: "library")
        await wait { session?.loading == false }
        fixture.available = catalog
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await wait { fixture.discoveries == 2 && session?.loading == false }
        expect(session?.voices == [us, uk], "install notification refreshes an active voice menu")
        expect(session?.selectedVoice == us, "installing UK preserves the current installed US selection")
        fixture.available = catalog + [DictionarySpeechVoice(id: "us-new", name: "AAA", language: "en-US", quality: 1)]
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await wait { fixture.discoveries == 3 && session?.loading == false }
        expect(session?.selectedVoice == us, "a new voice in the same region cannot displace the selected installed voice")
        fixture.available = catalog
        session?.selectVoice(id: uk.id)
        session?.togglePlayback()
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await wait { fixture.discoveries == 4 && session?.loading == false }
        expect(session?.selectedVoice == uk && session?.isPlaying == true,
               "refresh preserves a selected voice and speech while that voice remains installed")
        fixture.available = [us]
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await wait { fixture.discoveries == 5 && session?.loading == false }
        expect(session?.selectedVoice == us && session?.isPlaying == false,
               "removing the selected voice stops speech before selecting its replacement")
        expect(fixture.latest == nil && fixture.utterance == nil, "voice removal releases native playback resources")
        session?.reset()
        fixture.available = [uk]
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(10))
        expect(fixture.discoveries == 5, "hidden view invalidates its inventory without doing discovery work")
        session?.prepare(term: "run")
        await wait { fixture.discoveries == 6 && session?.loading == false }
        expect(session?.voices == [uk] && session?.selectedVoice == uk, "reopening refreshes an invalidated inventory")
        weak let owner = session
        session = nil
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(10))
        expect(owner == nil && fixture.discoveries == 6, "notification observation does not retain a torn-down session")
    }
    private static func interruptedInventoryChange() async {
        let center = NotificationCenter()
        let gate = Gate()
        let fixture = Fixture()
        let session = DictionarySpeechSession(
            discover: { await gate.load() }, makeEngine: fixture.engine,
            makeUtterance: fixture.makeUtterance, notificationCenter: center)
        session.prepare(term: "library")
        await wait { gate.waits.count == 1 }
        gate.finish(catalog, at: 0)
        await wait { !session.loading }
        center.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        await wait { gate.waits.count == 2 }
        session.reset()
        session.prepare(term: "run")
        await wait { gate.waits.count == 3 }
        expect(session.loading, "closing during a notified refresh requires a fresh inventory next open")
        gate.finish([], at: 1)
        try? await Task.sleep(for: .milliseconds(10))
        expect(session.voices == [us, uk] && session.loading, "the canceled notified refresh cannot publish stale results")
        gate.finish([uk], at: 2)
        await wait { !session.loading }
        expect(session.voices == [uk] && session.selectedVoice == uk, "the reopened view receives the changed inventory")
    }
    static func main() async {
        await catalogLifecycle()
        await playbackLifecycle()
        await discoveryCancellation()
        await errorsAndTeardown()
        await inventoryNotifications()
        await interruptedInventoryChange()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
