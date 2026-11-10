import Foundation

@main
struct DictationVolumeMigrationTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "dictation-volume.json")
        let record = Data(#"{"deviceUID":"speakers","original":0.5,"lastSet":0.05,"previous":0.08}"#.utf8)
        var volume: Float = 0.05
        var connected = false
        var resolutions = 0

        func apply() throws {
            try DictationVolumeMigration.apply(fileURL: fileURL) { uid in
                precondition(uid == "speakers")
                resolutions += 1
                guard connected else { return nil }
                return .init(read: { volume }, write: { volume = $0 })
            }
        }

        try apply()
        precondition(resolutions == 0, "An ordinary launch leaves output alone")
        try record.write(to: fileURL)
        try apply()
        precondition(FileManager.default.fileExists(atPath: fileURL.path), "A missing device can be retried")

        connected = true
        for lastVolume: Float in [0.05, 0.08] {
            volume = lastVolume
            try record.write(to: fileURL)
            try apply()
            precondition(volume == 0.5, "Restore either volume left behind by a fade step")
        }

        volume = 0.8
        try record.write(to: fileURL)
        try apply()
        precondition(volume == 0.8, "Keep the user's newer volume")
        precondition(!FileManager.default.fileExists(atPath: fileURL.path), "Clear processed recovery state")
    }
}
