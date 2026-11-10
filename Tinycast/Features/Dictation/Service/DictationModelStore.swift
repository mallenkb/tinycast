import Foundation

@MainActor
@Observable
final class DictationModelStore {
    typealias Failure = DictationWire.Failure

    private(set) var downloading: DictationModel?
    private(set) var downloadProgress: (received: Int64, total: Int64)?
    private(set) var removing: DictationModel?
    private(set) var transcribing = false
    private(set) var loadedModel: DictationModel?
    private(set) var installedModels: Set<DictationModel> = []
    @ObservationIgnored private var worker: DictationWorker?
    @ObservationIgnored private var stoppingWorker: (worker: DictationWorker, task: Task<Void, Never>)?
    @ObservationIgnored private var recordingModel: DictationModel?
    @ObservationIgnored private var preparation: (model: DictationModel, task: Task<Void, Never>)?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var idleRelease: DictationIdleRelease
    @ObservationIgnored private var downloadTask: Task<Void, Error>?
    @ObservationIgnored private var downloadID: UUID?
    private let root: URL
    private let makeWorker: () throws -> DictationWorker

    init(
        idleRelease: DictationIdleRelease,
        root: URL = AppPaths.caches().appending(path: "Dictation"),
        makeWorker: @escaping () throws -> DictationWorker = { try DictationWorker() }
    ) {
        self.idleRelease = idleRelease
        self.root = root
        self.makeWorker = makeWorker
        refreshInstalledModels()
    }

    func setIdleRelease(_ option: DictationIdleRelease) {
        idleRelease = option
        scheduleRelease()
    }

    func isInstalled(_ model: DictationModel) -> Bool {
        installedModels.contains(model)
    }

    func refreshInstalledModels() {
        installedModels = Set(
            DictationModel.allCases.filter { model in
                let directory = directory(for: model)
                return model.requiredFiles.allSatisfy {
                    FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
                }
            })
    }

    func installedSize(_ model: DictationModel) async -> Int64? {
        guard isInstalled(model) else { return nil }
        let directory = directory(for: model)
        let task = Task.detached(priority: .utility) { () -> Int64? in
            guard
                let files = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            else { return nil }
            var size: Int64 = 0
            while let url = files.nextObject() as? URL {
                guard !Task.isCancelled else { return nil }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let bytes = values.fileSize
                else { continue }
                size += Int64(bytes)
            }
            return size
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func download(_ model: DictationModel) async throws {
        guard downloading == nil, removing != model else { throw Failure.busy }
        guard !isInstalled(model) else { return }
        downloading = model
        let id = UUID()
        downloadID = id
        let destination = directory(for: model)
        let task = Task.detached(priority: .utility) { [weak self] in
            try await DictationModelDownloader.download(model, destination: destination) {
                [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadID == id else { return }
                    self.downloadProgress = (max(self.downloadProgress?.received ?? 0, received), total)
                }
            }
        }
        downloadTask = task
        defer { downloading = nil; downloadTask = nil; downloadID = nil; downloadProgress = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        installedModels.insert(model)
    }

    func cancelDownload() {
        downloadID = nil
        downloadTask?.cancel()
    }

    func delete(_ model: DictationModel) async throws {
        guard !transcribing, removing == nil, downloading != model else { throw Failure.busy }
        removing = model
        defer { removing = nil }
        if let preparation, preparation.model == model {
            preparation.task.cancel()
            await preparation.task.value
        }
        if loadedModel == model { await stopWorker() }
        await stoppingWorker?.task.value
        let directory = directory(for: model)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }.value
        installedModels.remove(model)
    }

    func beginRecording(_ model: DictationModel) {
        recordingModel = model
        releaseTask?.cancel()
        releaseTask = nil
        prepareRecordingModelIfNeeded()
    }

    func endRecording() {
        guard recordingModel != nil else { return }
        recordingModel = nil
        preparation?.task.cancel()
        scheduleRelease()
    }

    private func prepareRecordingModelIfNeeded() {
        guard let model = recordingModel, loadedModel != model, preparation == nil,
            !transcribing, removing != model, isInstalled(model)
        else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await prepare(model)
        }
        preparation = (model, task)
    }

    private func prepare(_ model: DictationModel) async {
        defer {
            preparation = nil
            if Task.isCancelled { prepareRecordingModelIfNeeded() }
            scheduleRelease()
        }
        guard !Task.isCancelled else { return }
        do {
            let worker = try await worker(for: model)
            let request = DictationWire.Request(
                id: UUID(), model: model, directory: directory(for: model), sampleCount: 0, language: nil)
            try await worker.prepare(request)
            try Task.checkCancellation()
            loadedModel = model
        } catch {
            await stopWorker()
        }
    }

    func transcribe(
        _ samples: [Float], model: DictationModel, language: String? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        guard !transcribing, removing != model else { throw Failure.busy }
        guard isInstalled(model) else { throw Failure.notInstalled }
        releaseTask?.cancel()
        releaseTask = nil
        transcribing = true
        defer { transcribing = false; scheduleRelease() }
        if let preparation {
            if preparation.model != model { preparation.task.cancel() }
            await preparation.task.value
        }
        try Task.checkCancellation()
        do {
            let worker = try await worker(for: model)
            let request = DictationWire.Request(
                id: UUID(), model: model, directory: directory(for: model),
                sampleCount: samples.count, language: model.isQwen ? language : nil)
            let text = try await worker.transcribe(samples, request: request) { [weak self] in
                guard let self, self.worker === worker, self.transcribing else { return }
                self.loadedModel = model
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await stopWorker()
            throw error
        }
    }

    private func worker(for model: DictationModel) async throws -> DictationWorker {
        if loadedModel != model { await stopWorker() }
        try Task.checkCancellation()
        if let worker { return worker }
        let worker = try makeWorker()
        self.worker = worker
        return worker
    }

    private func stopWorker() async {
        guard let worker else {
            await stoppingWorker?.task.value
            return
        }
        self.worker = nil
        loadedModel = nil
        let task = Task { await worker.stop() }
        stoppingWorker = (worker, task)
        await task.value
        if stoppingWorker?.worker === worker { stoppingWorker = nil }
    }

    func stop() async {
        recordingModel = nil
        releaseTask?.cancel()
        releaseTask = nil
        preparation?.task.cancel()
        downloadTask?.cancel()
        await preparation?.task.value
        await stopWorker()
        try? await downloadTask?.value
    }

    func prepareForTermination() {
        recordingModel = nil
        releaseTask?.cancel()
        preparation?.task.cancel()
        downloadTask?.cancel()
        worker?.terminate()
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        guard worker != nil, recordingModel == nil, preparation == nil, !transcribing, idleRelease != .never
        else { return }
        let interval = Duration.seconds(idleRelease.rawValue * 60)
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: interval, tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            guard let self, recordingModel == nil, preparation == nil, !transcribing else { return }
            releaseTask = nil
            await stopWorker()
        }
    }

    private func directory(for model: DictationModel) -> URL {
        root.appendingPathComponent(model.folderName)
    }
}
