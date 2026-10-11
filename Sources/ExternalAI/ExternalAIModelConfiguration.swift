import Foundation

/// Configuration selects a provider model only; endpoints and instructions remain fixed.
public struct ExternalAIModelConfiguration: Sendable, Equatable {
    public let model: String

    public init(model: String) throws {
        guard Self.isValidModel(model) else { throw ExternalAIError.invalidConfiguration }
        self.model = model
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
