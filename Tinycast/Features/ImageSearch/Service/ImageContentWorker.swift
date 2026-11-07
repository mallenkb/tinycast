import Foundation
import FoundationModels

nonisolated enum ImageContentWorker {
    static var version: Int {
        if #available(macOS 27, *), case .available = SystemLanguageModel.default.availability,
            SystemLanguageModel.default.capabilities.contains(.vision)
        { return 2 }
        return 1
    }

    static func extract(at url: URL) async throws -> ImageContent {
        let output = try await ClipboardTextWorker.extract(
            at: url, isPDF: false, executable: ClipboardTextWorker.executable, includeImageDescription: true)
        return try JSONDecoder().decode(ImageContent.self, from: Data(output.utf8))
    }

    static func extract(_ item: ClipboardItem) async throws -> ImageContent {
        guard let path = item.imagePath ?? item.filePath else { return ImageContent(text: "", caption: "") }
        let kind = item.kind == .image ? ClipboardFileKind.image : ClipboardFileKind.of(path: path)
        if kind == .movie, version == 1 { return ImageContent(text: "", caption: nil) }
        guard kind == .image || kind == .movie else {
            return ImageContent(text: try await ClipboardTextWorker.extract(item), caption: "")
        }
        return try await extract(at: URL(fileURLWithPath: path))
    }
}
