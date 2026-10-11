import Foundation

public enum ExternalAIReasoningEffort: String, Sendable, CaseIterable, Encodable {
    case none, low, medium

    public var displayName: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        }
    }
}

/// Configuration selects a model and reasoning effort; endpoints and instructions remain fixed.
public struct ExternalAIModelConfiguration: Sendable, Equatable {
    public let model: String
    public let reasoningEffort: ExternalAIReasoningEffort
    public var supportsReasoningEffort: Bool { model == "gpt-6-luna" }

    public init(model: String, reasoningEffort: ExternalAIReasoningEffort = .low) throws {
        guard Self.isValidModel(model) else { throw ExternalAIError.invalidConfiguration }
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && !model.hasPrefix("sk-") && model != "." && model != ".."
            && model.utf8.count <= 100 && model.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    public static let `default` = try! ExternalAIModelConfiguration(model: "gpt-4.1-mini")
}
