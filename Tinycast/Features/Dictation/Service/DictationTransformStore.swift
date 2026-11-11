import Foundation

struct DictationTransform: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var instructions: String

    static let paragraphsID = UUID(uuidString: "D1C70000-0000-4000-8000-000000000005")!
}

@MainActor
@Observable
final class DictationTransformStore {
    private let fileURL = AppPaths.applicationSupport().appending(path: "dictation-transforms.json")
    private(set) var savedTransforms: [DictationTransform]
    let paragraphs = DictationTransform(
        id: DictationTransform.paragraphsID, name: String(localized: "Paragraphs"), instructions: "")
    var transforms: [DictationTransform] { savedTransforms + [paragraphs] }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DictationTransform].self, from: data) {
            savedTransforms = saved
        } else {
            savedTransforms = [
                DictationTransform(
                    id: UUID(uuidString: "D1C70000-0000-4000-8000-000000000001")!, name: String(localized: "Polish"),
                    instructions: String(
                        localized: "Improve clarity while preserving meaning, tone, and every factual detail.")),
                DictationTransform(
                    id: UUID(uuidString: "D1C70000-0000-4000-8000-000000000002")!, name: String(localized: "Shorten"),
                    instructions: String(
                        localized: "Remove repetition and unnecessary wording. Preserve every important detail.")),
                DictationTransform(
                    id: UUID(uuidString: "D1C70000-0000-4000-8000-000000000003")!, name: String(localized: "Make a list"),
                    instructions: String(
                        localized: "Organize suitable content into bullet points without adding or omitting information.")),
                Self.promptEngineer
            ]
        }
    }

    static var promptEngineer: DictationTransform {
        DictationTransform(
            id: UUID(uuidString: "D1C70000-0000-4000-8000-000000000004")!,
            name: String(localized: "Prompt Engineer"),
            instructions: [
                String(localized: "Turn the transcript into an AI prompt, without performing its task."),
                String(localized: "Use placeholders for missing details; never invent requirements or available inputs."),
                String(localized: "Preserve examples verbatim and include conflict resolution only when needed."),
                """
                Use this output template:
                **Title**
                (1 concise line)

                **Role & stance**
                (who the model is and how it should behave)

                **Task**
                (what the model must do)

                **Context**
                (only what the model needs to know)

                **Inputs available**
                (explicit list)

                **Output requirements**
                (format, structure, tone, length only if specified; otherwise placeholders)

                **Constraints / Do-nots**
                (bulleted)

                **Examples / References**
                (include all examples verbatim)

                **Execution checklist**
                (short, factual verification list)

                **Conflict resolution**
                (only if applicable)
                """
            ].joined(separator: "\n"))
    }

    func save(_ transform: DictationTransform) throws {
        var updated = savedTransforms
        if let index = updated.firstIndex(where: { $0.id == transform.id }) {
            updated[index] = transform
        } else {
            updated.append(transform)
        }
        try persist(updated)
    }

    func remove(_ id: UUID) throws {
        try persist(savedTransforms.filter { $0.id != id })
    }

    private func persist(_ updated: [DictationTransform]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: fileURL, options: .atomic)
        savedTransforms = updated
    }
}
