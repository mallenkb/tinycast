import CoreAudio
import Foundation

enum DictationVolumeMigration {
    struct Output {
        let read: () throws -> Float
        let write: (Float) throws -> Void
    }

    private struct Snapshot: Decodable {
        let deviceUID: String
        let original: Float
        let lastSet: Float
        let previous: Float?

        var isValid: Bool {
            !deviceUID.isEmpty && (0...1).contains(original) && (0...1).contains(lastSet)
                && previous.map { (0...1).contains($0) } != false
        }

        func matches(_ volume: Float) -> Bool {
            abs(volume - lastSet) < 0.01 || previous.map { abs(volume - $0) < 0.01 } == true
        }
    }

    @concurrent
    static func apply() async {
        let fileURL = AppPaths.applicationSupport().appending(path: "dictation-volume.json")
        try? apply(fileURL: fileURL, resolveOutput: output(for:))
    }

    static func apply(fileURL: URL, resolveOutput: (String) throws -> Output?) throws {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }

        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.isValid {
            guard let output = try resolveOutput(snapshot.deviceUID) else { return }
            let current = try output.read()
            if snapshot.matches(current), current != snapshot.original {
                try output.write(snapshot.original)
            }
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static func output(for uid: String) throws -> Output? {
        guard let device = try AudioHardwareSystem.shared.device(forUID: uid),
            let control = try device.controls.first(where: isMainOutputVolume)
        else { return nil }
        return Output(read: { try control.volumeScalarValue }, write: { try control.setVolumeScalarValue($0) })
    }

    private static func isMainOutputVolume(_ control: AudioHardwareControl) -> Bool {
        guard (try? control.classID) == kAudioVolumeControlClassID else { return false }
        func value(for selector: AudioObjectPropertySelector) -> UInt32? {
            let address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard let data = try? control.propertyData(address: address, qualifier: nil),
                data.count == MemoryLayout<UInt32>.size
            else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        return value(for: kAudioControlPropertyScope) == kAudioObjectPropertyScopeOutput
            && value(for: kAudioControlPropertyElement) == kAudioObjectPropertyElementMain
    }
}
