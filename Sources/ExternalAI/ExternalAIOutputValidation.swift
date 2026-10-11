import Foundation
import VaultCore

/// A proposal, never an instruction to mutate canonical metadata or other AI artifacts.
public struct ExternalAILCCSuggestion: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let code: String
    public let rationale: String
    public init(code: String, rationale: String) throws {
        guard LCCClassificationVocabulary.isAuthorized(code),
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rationale.utf8.count <= ExternalAILimits.maximumLCCRationaleBytes,
              ExternalAIOutputValidation.isPlainText(rationale) else { throw ExternalAIError.invalidResponse }
        self.code = code
        self.rationale = rationale
    }
    public var description: String { "ExternalAILCCSuggestion(code: <redacted>, rationale: <redacted>)" }
    public var debugDescription: String { description }
}

/// Validation also runs when a caller constructs a result, before publication authority exists.
enum ExternalAIOutputValidation {
    static func isPlainText(_ text: String) -> Bool {
        !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !text.contains("<") && !text.contains(">")
            && !text.contains("`") && !text.contains("*")
            && !text.contains("](")
    }

    static func validateTitle(_ title: String) throws {
        guard !title.isEmpty, title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              title.count <= ExternalAILimits.maximumTitleCharacters,
              title.split(whereSeparator: \.isWhitespace).count <= ExternalAILimits.maximumTitleWords,
              isPlainText(title), !title.hasPrefix("#"), !title.lowercased().hasPrefix("title:"),
              !title.hasPrefix("- "),
              title.range(of: #"^[0-9]+[.)]\s"#, options: .regularExpression) == nil,
              !title.hasPrefix("\""), !title.hasSuffix("\""),
              !title.hasPrefix("“"), !title.hasSuffix("”"),
              !title.hasSuffix(".") else { throw ExternalAIError.invalidResponse }
    }

    static func lccSuggestion(from output: String) throws -> ExternalAILCCSuggestion {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["code", "rationale"],
              let code = object["code"] as? String,
              let rationale = object["rationale"] as? String else { throw ExternalAIError.invalidResponse }
        return try ExternalAILCCSuggestion(code: code, rationale: rationale)
    }
}
