import AVFoundation
import AudioToolbox
import CoreMedia

@MainActor
final class DictationCapture {
    enum Failure: LocalizedError {
        case microphoneUnavailable
        case microphoneDenied
        case captureUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: String(localized: "No microphone is available.")
            case .microphoneDenied:
                String(localized: "Allow Tinycast to use the microphone in System Settings.")
            case .captureUnavailable: String(localized: "Couldn't start recording from this microphone.")
            }
        }
    }

    nonisolated static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    var onLevels: (([Float]) -> Void)?
    var onLimit: (() -> Void)?

    private var active: CaptureSessionBox?
    var isBluetooth: Bool { active?.isBluetooth == true }

    func start(microphoneID: String?, stream: AsyncStream<[Float]>.Continuation? = nil) async throws {
        try Task.checkCancellation()
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        if permission == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            granted = permission == .authorized
        }
        guard granted else { throw Failure.microphoneDenied }
        let id = UUID()
        let box = try await CaptureSessionBox.configure(
            id: id, microphoneID: microphoneID, stream: stream,
            onLevels: { [weak self] levels in
                Task { @MainActor [weak self] in
                    guard let self, active?.id == id else { return }
                    onLevels?(levels)
                }
            },
            onLimit: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, active?.id == id else { return }
                    onLimit?()
                }
            })
        try Task.checkCancellation()
        active = box
        guard await box.start() else {
            _ = await stop()
            try Task.checkCancellation()
            throw Failure.captureUnavailable
        }
    }

    func stop() async -> [Float] {
        guard let active else { return [] }
        self.active = nil
        return await active.stop()
    }

    func recentSamples(seconds: Int) async -> [Float] {
        guard let active else { return [] }
        return await active.recentSamples(seconds: seconds)
    }
}

// The coordinator waits for startup before stopping, so the capture graph has one caller at a time.
private struct CaptureSessionBox: @unchecked Sendable {
    let id: UUID
    let isBluetooth: Bool
    private let session: AVCaptureSession
    private let output: AVCaptureAudioDataOutput
    private let collector: AudioCollector

    @concurrent static func configure(
        id: UUID, microphoneID: String?, stream: AsyncStream<[Float]>.Continuation?,
        onLevels: @escaping @Sendable ([Float]) -> Void,
        onLimit: @escaping @Sendable () -> Void
    ) async throws -> Self {
        try Task.checkCancellation()
        let device =
            microphoneID.map { id in DictationCapture.microphones.first { $0.uniqueID == id } }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw DictationCapture.Failure.microphoneUnavailable }
        let isBluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
            .contains(UInt32(bitPattern: device.transportType))
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw DictationCapture.Failure.captureUnavailable
        }

        let capture = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: DictationWire.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard capture.canAddInput(input), capture.canAddOutput(output) else {
            throw DictationCapture.Failure.captureUnavailable
        }
        capture.addInput(input)
        capture.addOutput(output)
        let collector = try AudioCollector(stream: stream, onLevels: onLevels, onLimit: onLimit)
        output.setSampleBufferDelegate(collector, queue: collector.queue)
        return Self(id: id, isBluetooth: isBluetooth, session: capture, output: output, collector: collector)
    }

    @concurrent func start() async -> Bool {
        guard !Task.isCancelled else { return false }
        session.startRunning()
        return session.isRunning
    }

    @concurrent func stop() async -> [Float] {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        return collector.finish()
    }

    @concurrent func recentSamples(seconds: Int) async -> [Float] { collector.recentSamples(seconds: seconds) }
}

// Sample buffers and mutable state are confined to the delegate queue, including finish().
private final class AudioCollector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "com.tinycast.dictation.audio")
    private var samples: [Float] = []
    private var streamedSamples = 0
    private let stream: AsyncStream<[Float]>.Continuation?
    private var displayedLevels: [Float]
    private let spectrum: DictationSpectrum
    private var waveformStartIndex = 0
    private var lastLevelUpdate: TimeInterval = 0
    private var reachedLimit = false
    private let onLevels: @Sendable ([Float]) -> Void
    private let onLimit: @Sendable () -> Void

    init(
        stream: AsyncStream<[Float]>.Continuation?, onLevels: @escaping @Sendable ([Float]) -> Void,
        onLimit: @escaping @Sendable () -> Void
    ) throws {
        self.stream = stream
        spectrum = try DictationSpectrum()
        displayedLevels = [Float](repeating: 0, count: DictationSpectrum.barCount)
        self.onLevels = onLevels
        self.onLimit = onLimit
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = bufferList.mBuffers.mData else { return }
        let count = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0, samples.count < DictationWire.maximumSamples else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let accepted = min(count, DictationWire.maximumSamples - samples.count)
        samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: accepted))
        if let stream, samples.count - streamedSamples >= DictationWire.sampleRate / 10 {
            stream.yield(Array(samples[streamedSamples...]))
            streamedSamples = samples.count
        }
        if samples.count == DictationWire.maximumSamples, !reachedLimit {
            reachedLimit = true
            onLimit()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelUpdate >= 0.05 else { return }
        lastLevelUpdate = now
        let levels = spectrum.levels(for: samples[waveformStartIndex...])
        waveformStartIndex = samples.count
        for index in levels.indices {
            let response: Float = levels[index] > displayedLevels[index] ? 0.6 : 0.25
            displayedLevels[index] += (levels[index] - displayedLevels[index]) * response
        }
        onLevels(displayedLevels)
    }

    func finish() -> [Float] {
        queue.sync {
            if let stream {
                if streamedSamples < samples.count { stream.yield(Array(samples[streamedSamples...])) }
                stream.finish()
            }
            return samples
        }
    }

    func recentSamples(seconds: Int) -> [Float] {
        queue.sync { Array(samples.suffix(DictationWire.sampleRate * seconds)) }
    }
}
